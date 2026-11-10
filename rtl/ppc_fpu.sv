// PPC602 float unit, bit-exact with MAME's x64 back end (x86 SSE with MXCSR's FTZ / DAZ off): IEEE double arithmetic
// in the four rounding modes with denormals; a NaN operand comes back quieted (the first, if both are NaNs), an invalid
// operation gives the default NaN 0xfff8000000000000.
// Each operation is MAME's sequence of x86 operations (ppcdrc.cpp), run one step at a time:
//   add / sub / mul: one step;  div: 56 bits, sqrt: 56, four a clock (after four clocks to unpack, three for sqrt, and
//   one to start), then the round (two clocks);  a single-precision op: the double op, then a round to single and
//   back (cvtsd2ss / cvtss2sd, three clocks);  fmadd: a double multiply, then a double add (nothing fused);  fres:
//   1.0f / (float)b (divss);  frsqrte: 1.0 / sqrt(b), each step rounded (the root, a normal double, straight into the
//   divide).
// Rounding needs 54 bits (53 and the round bit) and whether there's more (the sticky bit): the divide makes 56 (the
// quotient's top bit is one of the top two), the square root 56 (its top bit the top), the remainder the sticky bit.
// FULL = 0 leaves only divide, square root, fres and frsqrte (rtl/ppc_pipe.sv's; rtl/ppc_fpp.sv has the rest); the
// one-step operations are single clocks too long for the machine's clock, there for rtl/ppc_core.sv.
`default_nettype none
module ppc_fpu #(
	parameter bit FULL = 1'b1           // all the operations (else F_DIV(S), F_SQRT(S), F_RES, F_RSQRTE)
) (
	input  logic        clk,
	input  logic        rst,
	input  logic        start,
	input  logic [4:0]  op,             // ppc_fpu_pkg::fop_t
	input  logic [1:0]  rn,             // FPSCR RN: nearest, zero, +inf, -inf
	input  logic [63:0] a, b, c,
	output logic        done,           // a clock, with res / crf
	output logic [63:0] res,
	output logic [3:0]  crf             // F_CMP: LT GT EQ UN
);
	import ppc_fpu_pkg::*;

	// ---- the sequences ------------------------------------------------------------------------------------------------
	typedef enum logic [3:0] { U_ADD, U_SUB, U_MUL, U_DIV, U_DIVS, U_SQRT, U_RNDS, U_NEG, U_D2I, U_D2IZ, U_CMP, U_D2S,
		U_S2D } uop_t;
	typedef enum logic [2:0] { O_A, O_B, O_C, O_T, O_ONE } opnd_t;
	typedef struct packed { uop_t u; opnd_t x, y; logic last; } step_t;

	function automatic step_t prog(input logic [4:0] o, input logic [1:0] n);
		step_t s0, s1, s2, s3;
		s0 = '{U_ADD, O_A, O_B, 1'b1};
		s1 = '{U_ADD, O_T, O_B, 1'b1};
		s2 = '{U_NEG, O_T, O_T, 1'b1};
		s3 = '{U_RNDS, O_T, O_T, 1'b1};
		case (fop_t'(o))
			F_ADD, F_ADDS:   s0 = '{U_ADD, O_A, O_B, 1'b0};
			F_SUB, F_SUBS:   s0 = '{U_SUB, O_A, O_B, 1'b0};
			F_MUL, F_MULS:   s0 = '{U_MUL, O_A, O_C, 1'b0};
			F_DIV, F_DIVS:   s0 = '{U_DIV, O_A, O_B, 1'b0};
			F_SQRT, F_SQRTS: s0 = '{U_SQRT, O_B, O_B, 1'b0};
			F_RSQRTE:        begin s0 = '{U_SQRT, O_B, O_B, 1'b0}; s1 = '{U_DIV, O_ONE, O_T, 1'b1}; end
			F_MADD, F_MADDS, F_NMADD, F_NMADDS: begin s0 = '{U_MUL, O_A, O_C, 1'b0}; s1 = '{U_ADD, O_T, O_B, 1'b0}; end
			F_MSUB, F_MSUBS: begin s0 = '{U_MUL, O_A, O_C, 1'b0}; s1 = '{U_SUB, O_T, O_B, 1'b0}; end
			F_NMSUB, F_NMSUBS: begin s0 = '{U_MUL, O_A, O_C, 1'b0}; s1 = '{U_SUB, O_B, O_T, 1'b0}; end
			F_RES:           begin s0 = '{U_RNDS, O_B, O_B, 1'b0}; s1 = '{U_DIVS, O_ONE, O_T, 1'b1}; end
			F_RSP:           s0 = '{U_RNDS, O_B, O_B, 1'b1};
			F_CTIW:          s0 = '{U_D2I, O_B, O_B, 1'b1};
			F_CTIWZ:         s0 = '{U_D2IZ, O_B, O_B, 1'b1};
			F_CMP:           s0 = '{U_CMP, O_A, O_B, 1'b1};
			F_D2S:           s0 = '{U_D2S, O_A, O_A, 1'b1};
			F_S2D:           s0 = '{U_S2D, O_A, O_A, 1'b1};
			default: ;
		endcase
		// one-step doubles end at s0; the rest go on
		case (fop_t'(o))
			F_ADD, F_SUB, F_MUL, F_DIV, F_SQRT: s0 = '{s0.u, s0.x, s0.y, 1'b1};   // (Quartus 17: no field writes here)
			F_MADD, F_MSUB, F_NMSUB:            s1 = '{s1.u, s1.x, s1.y, 1'b1};
			F_ADDS, F_SUBS, F_MULS, F_DIVS, F_SQRTS: s1 = s3;
			F_MADDS, F_MSUBS, F_NMSUBS:         s2 = s3;
			F_NMADD:                            s2 = '{U_NEG, O_T, O_T, 1'b1};
			F_NMADDS:                           s2 = '{U_NEG, O_T, O_T, 1'b0};
			default: ;
		endcase
		case (n)
			2'd0: return s0;
			2'd1: return s1;
			2'd2: return s2;
			default: return s3;
		endcase
	endfunction

	typedef enum logic [3:0] { S_IDLE, S_RUN, S_DU, S_DU2, S_DU3, S_DIV0, S_DIV, S_SU, S_SU2, S_SQRT0, S_SQRT, S_DN, S_DR,
		S_RS2, S_RS3, S_RQ } state_t;
	// (Verilator takes the tasks' writes for another process)
	// verilator lint_off MULTIDRIVEN
	state_t      state;
	// verilator lint_on MULTIDRIVEN
	logic [4:0]  q_op;
	logic [1:0]  q_rn, n;
	logic [63:0] qa, qb, qc, t;

	// divide / square root
	logic [55:0] it_q;                  // the quotient or the root, in at the bottom
	logic [58:0] it_r;
	logic [111:0] it_n;                 // square root: the radicand, two bits a step
	logic signed [6:0] it_k;            // the bit to make; done below 0
	logic        it_s, it_sgl;
	logic signed [13:0] it_e;
	logic [52:0] it_d;
	logic [54:0] it_d3;                 // 3 * it_d

	// two quotient bits (floor(r * 4 / d) with r < 2d, the r in): r = (r >= d ? r - d : r) << 1 twice, so r - d, then
	// 2r - 3d or 2r - d, taken side by side; {the bits, the remainder (not yet shifted for the next)}
	function automatic logic [60:0] div2(input logic [58:0] r0, input logic [52:0] d, input logic [54:0] d3);
		// verilator lint_off UNUSEDSIGNAL
		logic [60:0] t1, t2, t3;
		// verilator lint_on UNUSEDSIGNAL
		t1 = {2'b0, r0} - {8'h0, d};
		t2 = {1'b0, r0, 1'b0} - {8'h0, d};
		t3 = {1'b0, r0, 1'b0} - {6'h0, d3};
		if (!t1[60]) return {1'b1, !t3[60], t3[60] ? {t1[57:0], 1'b0} : t3[58:0]};
		return {1'b0, !t2[60], t2[60] ? {r0[57:0], 1'b0} : t2[58:0]};
	endfunction

	// two root bits: a step is r = 4r + the next two radicand bits, less 4 root + 1 if that's not more (a root bit 1); so
	// two are y = 4r + p1 less 4 root + 1, then x = 16r + 4p1 + p2 less 24 root + 9 or 8 root + 1, taken side by side
	// (x - (24 root + 9) as x + ~(16 root + 7) + ~(8 root): an add of three, one carry chain); {the bits, the remainder}
	function automatic logic [60:0] sq2(input logic [58:0] r0, input logic [3:0] p, input logic [55:0] root);
		// verilator lint_off UNUSEDSIGNAL
		logic [62:0] y, x, d1, e2, f2;
		// verilator lint_on UNUSEDSIGNAL
		logic c1, c2;
		y = {2'b0, r0, p[3:2]};
		x = {r0, p};
		d1 = y - {5'h0, root, 2'b01};
		e2 = x + {3'h7, ~root, 4'b1000} + {4'hf, ~root, 3'b111};
		f2 = x - {4'h0, root, 3'b001};
		c1 = !d1[62];
		c2 = c1 ? !e2[62] : !f2[62];
		return {c1, c2, c1 ? (c2 ? e2[58:0] : {d1[56:0], p[1:0]}) : (c2 ? f2[58:0] : x[58:0])};
	endfunction
	logic [63:0] it_ox, it_oy;          // the operands (S_DU, S_SU)
	unp_t        it_ux, it_uy;          // ... unpacked (S_DIV0, S_SQRT0); before, a denormal's m not yet shifted
	logic [5:0]  it_kx, it_ky;          // ... by these (its leading zeros)

	// unpack_d over two clocks: the fields (a denormal's m as it is, e -1022) and m's leading zeros; then the shift
	function automatic unp_t unpack_r(input logic [63:0] x);
		unp_t u;
		if (x[62:52] == 11'h7ff) u = '{x[51:0] != 0, x[51:0] == 0, 1'b0, x[63], 14'sd0, 53'h0};
		else if (x[62:52] == 0) u = '{1'b0, 1'b0, x[51:0] == 0, x[63], -14'sd1022, {1'b0, x[51:0]}};
		else u = '{1'b0, 1'b0, 1'b0, x[63], 14'($signed({3'b0, x[62:52]}) - 1023), {1'b1, x[51:0]}};
		return u;
	endfunction
	function automatic logic [5:0] lz53(input logic [52:0] m);
		for (int i = 52; i >= 0; i--) if (m[i]) return 6'(52 - i);
		return 6'd53;
	endfunction
	function automatic unp_t unpack_n(input unp_t u, input logic [5:0] k);
		return '{u.nan, u.inf, u.zero, u.s, u.e - {8'h0, k}, u.m << k};
	endfunction

	// the round after: (-1)^fin_s * fin_sig * 2^(fin_e - 55), fin_st the bits below (S_DN shifts it into a denormal,
	// S_DR rounds to double); or to single (S_RS2-3)
	logic        fin_s;
	logic signed [13:0] fin_e;
	logic [55:0] fin_sig;
	logic        fin_st;
	rsa_t        fin_rsa;
	rsb_t        fin_rsb;

	// the unpacked operands' normalization, one a clock: x (S_DU2, S_SU2), then y (S_DU3)
	unp_t nrm;
	assign nrm = unpack_n(state == S_DU3 ? it_uy : it_ux, state == S_DU3 ? it_ky : it_kx);

	step_t st_c;
	logic [63:0] ox, oy;
	assign st_c = prog(q_op, n);
	always_comb
	begin
		case (st_c.x)
			O_A: ox = qa; O_B: ox = qb; O_C: ox = qc; O_T: ox = t; default: ox = ONE;
		endcase
		case (st_c.y)
			O_A: oy = qa; O_B: oy = qb; O_C: oy = qc; O_T: oy = t; default: oy = ONE;
		endcase
	end

	task automatic finish(input logic [63:0] v, input logic [3:0] f);
		t <= v;
		if (st_c.last)
		begin
			done <= 1'b1;
			res <= v;
			crf <= f;
			state <= S_IDLE;
		end
		else
		begin
			n <= n + 2'd1;
			state <= S_RUN;
		end
	endtask

	always_ff @(posedge clk)
	begin
		done <= 1'b0;
		if (rst) state <= S_IDLE;
		else
			case (state)
				S_IDLE:
					if (start)
					begin
						q_op <= op; q_rn <= rn; qa <= a; qb <= b; qc <= c;
						n <= 2'd0;
						state <= S_RUN;
					end

				S_RUN:
					case (st_c.u)
						U_ADD:  if (FULL) finish(add(ox, oy, 1'b0, q_rn), 4'h0);
						U_SUB:  if (FULL) finish(add(ox, oy, 1'b1, q_rn), 4'h0);
						U_MUL:  if (FULL) finish(mul(ox, oy, q_rn), 4'h0);
						U_RNDS:
						begin
							fin_rsa <= rs_d(ox, q_rn);
							state <= S_RS2;
						end
						U_NEG:  if (FULL) finish(ox ^ 64'h8000000000000000, 4'h0);
						U_D2I:  if (FULL) finish({32'h0, d2i(ox, q_rn)}, 4'h0);
						U_D2IZ: if (FULL) finish({32'h0, d2i(ox, 2'd1)}, 4'h0);
						U_CMP:  if (FULL) finish(64'h0, cmp(ox, oy));
						U_D2S:  if (FULL) finish({32'h0, d2s(ox, q_rn)}, 4'h0);
						U_S2D:  if (FULL) finish(s2d(ox[31:0]), 4'h0);
						U_DIV, U_DIVS:
						begin
							it_ox <= ox;
							it_oy <= oy;
							it_sgl <= st_c.u == U_DIVS;
							state <= S_DU;
						end
						U_SQRT:
						begin
							it_ox <= ox;
							state <= S_SU;
						end
						default: finish(64'h0, 4'h0);
					endcase

				S_DU:
				begin
					it_ux <= unpack_r(it_ox);
					it_uy <= unpack_r(it_oy);
					it_kx <= lz53({it_ox[62:52] != 0, it_ox[51:0]});
					it_ky <= lz53({it_oy[62:52] != 0, it_oy[51:0]});
					state <= S_DU2;
				end
				S_DU2:
				begin
					it_ux <= nrm;
					state <= S_DU3;
				end
				S_DU3:
				begin
					it_uy <= nrm;
					state <= S_DIV0;
				end
				S_SU:
				begin
					it_ux <= unpack_r(it_ox);
					it_kx <= lz53({it_ox[62:52] != 0, it_ox[51:0]});
					state <= S_SU2;
				end
				S_SU2:
				begin
					it_ux <= nrm;
					state <= S_SQRT0;
				end

				// the specials, or the iteration's start
				S_DIV0:
				begin
					unp_t ux, uy;
					logic sgn;
					ux = it_ux;
					uy = it_uy;
					sgn = ux.s ^ uy.s;
					if (ux.nan) finish(quiet(ox), 4'h0);
					else if (uy.nan) finish(quiet(oy), 4'h0);
					else if ((ux.inf && uy.inf) || (ux.zero && uy.zero)) finish(DNAN, 4'h0);
					else if (ux.inf || uy.zero) finish({sgn, 63'h7ff0000000000000}, 4'h0);
					else if (ux.zero || uy.inf) finish({sgn, 63'h0}, 4'h0);
					else
					begin
						it_r <= {6'h0, ux.m};
						it_d <= uy.m;
						it_d3 <= {2'b0, uy.m} + {1'b0, uy.m, 1'b0};
						it_q <= 56'h0;
						it_k <= 7'sd55;
						it_s <= sgn;
						it_e <= ux.e - uy.e;
						state <= S_DIV;
					end
				end
				S_SQRT0:
				begin
					unp_t ux;
					logic signed [13:0] e;
					ux = it_ux;
					if (ux.nan) finish(quiet(ox), 4'h0);
					else if (ux.zero) finish(ox, 4'h0);
					else if (ux.s) finish(DNAN, 4'h0);
					else if (ux.inf) finish(ox, 4'h0);
					else
					begin
						// m * 2^E, E = e - 52 made even; the root of m << 58 has its top bit at 55
						e = ux.e - 14'sd52;
						if (e[0])
						begin
							it_n <= {ux.m, 59'h0};
							e = e - 14'sd1;
						end
						else
							it_n <= {1'b0, ux.m, 58'h0};
						it_e <= ((e - 14'sd58) >>> 1) + 14'sd55;
						it_r <= 59'h0;
						it_q <= 56'h0;
						it_k <= 7'sd55;
						it_s <= 1'b0;
						it_sgl <= 1'b0;
						state <= S_SQRT;
					end
				end

				S_DIV:
				begin
					// four quotient bits a clock (floor(mx * 2^55 / my), 56 bits, in at the bottom), two and two
					// verilator lint_off UNUSEDSIGNAL
					logic [60:0] a2, b2;
					// verilator lint_on UNUSEDSIGNAL
					a2 = div2(it_r, it_d, it_d3);
					b2 = div2({a2[57:0], 1'b0}, it_d, it_d3);
					it_r <= {b2[57:0], 1'b0};
					it_q <= {it_q[51:0], a2[60:59], b2[60:59]};
					it_k <= it_k - 7'sd4;
					if (it_k < 7'sd4) state <= S_DN;
				end

				// the quotient normalized (its last bit, if it's below the top, below the round bit: a zero, the
				// remainder saying whether it's more); to a denormal (a double), or to single. (A root: its top bit the
				// top, never a denormal, double.)
				S_DN:
				begin
					logic [55:0] sig;
					logic st;
					logic signed [13:0] e, dn;
					logic [56:0] sh;
					st = it_r != 0;
					if (it_q[55]) begin sig = it_q; e = it_e; end
					else begin sig = {it_q[54:0], 1'b0}; e = it_e - 14'sd1; end
					fin_s <= it_s;
					if (it_sgl)
					begin
						fin_rsa <= rs_a(it_s, e, sig[55:3], st || sig[2:0] != 0, q_rn);
						state <= S_RS2;
					end
					else
					begin
						dn = -14'sd1022 - e;
						sh = shr_st(sig, dn > 14'sd63 ? 6'd63 : dn[5:0]);
						if (e < -14'sd1022) begin fin_sig <= sh[56:1]; fin_st <= st || sh[0]; fin_e <= -14'sd1022; end
						else begin fin_sig <= sig; fin_st <= st; fin_e <= e; end
						state <= S_DR;
					end
				end
				S_DR:
				begin
					finish(rnd_d(fin_s, fin_e, fin_sig, fin_st, q_rn), 4'h0);
					if (fop_t'(q_op) == F_RSQRTE && n == 2'd0) state <= S_RQ;
				end
				// frsqrte's divide, 1.0 / t (the root, rounded: a normal double), as S_RUN to S_DIV0 would start it
				S_RQ:
				begin
					it_r <= {6'h0, 1'b1, 52'h0};
					it_d <= {1'b1, t[51:0]};
					it_d3 <= {3'b001, t[51:0]} + {2'b01, t[51:0], 1'b0};
					it_q <= 56'h0;
					it_k <= 7'sd55;
					it_s <= 1'b0;
					it_sgl <= 1'b0;
					it_e <= 14'sd1023 - {3'b0, t[62:52]};
					n <= 2'd1;
					state <= S_DIV;
				end
				S_RS2:
				begin
					fin_rsb <= rs_b(fin_rsa, q_rn);
					state <= S_RS3;
				end
				S_RS3: finish(rs_c(fin_rsb, q_rn), 4'h0);

				S_SQRT:
				begin
					// four root bits a clock (in at the bottom of it_q), two and two (sq2)
					// verilator lint_off UNUSEDSIGNAL
					logic [60:0] a2, b2;
					// verilator lint_on UNUSEDSIGNAL
					a2 = sq2(it_r, it_n[111:108], it_q);
					b2 = sq2(a2[58:0], it_n[107:104], {it_q[53:0], a2[60:59]});
					it_r <= b2[58:0];
					it_q <= {it_q[51:0], a2[60:59], b2[60:59]};
					it_n <= it_n << 8;
					it_k <= it_k - 7'sd4;
					if (it_k < 7'sd4) state <= S_DN;
				end

				default: state <= S_IDLE;
			endcase
	end
endmodule
