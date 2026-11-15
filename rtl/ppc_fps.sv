// The PPC602's float units as the chip has them: single precision. 32-bit values (an FPR's 33rd bit, the LT bit of the 602's
// SP / LT registers, says it holds an integer: rtl/ppc_pipe.sv's stfd needs that). A multiply-add is fused (the 48-bit product
// goes to the add whole, as in the manual), a result rounded once.
//   ppc_fps3     the pipeline: every op 3 clocks, as the chip (a denormal a or c 4), one issued a clock
//   ppc_fps_it   the iterative unit: divide and fres, two bits a clock
//   ppc_fps_ctl  a CPU's part of the control: its FPRs' counts (a result leaves the pipeline's last stage, ev, for the next
//                op's operands, and is registered, wv, for the FPRs)
// The double forms do what the single forms do: the real chip traps them to software (0x1600), which this core doesn't.
`default_nettype none
module ppc_fps_ctl (
	input  logic        clk,
	input  logic        rst,
	input  logic        allow,          // this CPU's clock for an op
	input  logic        hold,           // ppc_fps3 holds the op issued last clock a clock more: no op, and if it's ours, its
	                                    // FPR's count waits a clock
	input  logic        issue,
	// verilator lint_off UNUSEDSIGNAL
	input  ppc_fpu_pkg::fpk_t pk,       // the op's (fpk_s: a ppc_fpu_pkg::fop_t, not F_DIV(S) / F_SQRT(S) / F_RES / F_RSQRTE / F_CMP)
	// verilator lint_on UNUSEDSIGNAL
	input  logic [4:0]  rd,
	input  logic [4:0]  ra, rb, rc,     // its operands' FPRs
	output logic        ok,             // op can issue this clock
	output logic        dok,            // ... as far as rd goes
	output logic        busy,           // an op of this CPU's is in flight
	output logic [2:0]  fe, fw,         // operands a, b, c leaving the last stage this clock (ev), registered (wv)
	output logic [31:0] pe, pw, pn      // FPRs not written by this clock's end: with ev, with wv, at all
);
	import ppc_fpu_pkg::*;

	logic [3:0]  cnt [0:31];            // the clocks until the last op writing the FPR has its wv (1: this clock)
	// the op issued last clock (frz: held, its count stays)
	logic        l_v;
	logic [4:0]  l_rd;
	always_ff @(posedge clk) begin l_v <= !rst && issue; l_rd <= rd; end
	wire         frz = hold && l_v;
	// one pipe, every op the same clocks: an op goes in its CPU's clock unless the pipeline holds one
	assign ok = allow && !hold;
	assign dok = cnt[rd] < pk.w0 + 4'd2;
	// pe, pw and pn from registers, each its compare on cnt's next value: from the counts through the compares to X's hazards
	// was a long path
	logic [31:0] pe_q, pw_q, pn_q;
	assign pe = pe_q;
	assign pw = pw_q;
	assign pn = pn_q;
	assign busy = pn != 32'h0;
	assign fe = {cnt[rc] == 4'd2, cnt[rb] == 4'd2, cnt[ra] == 4'd2};
	assign fw = {cnt[rc] == 4'd1, cnt[rb] == 4'd1, cnt[ra] == 4'd1};

	always_ff @(posedge clk)
		for (int f = 0; f < 32; f++)
		begin
			cnt[f] <= rst ? 4'd0 : issue && rd == 5'(f) ? pk.w0 + 4'd1 : frz && l_rd == 5'(f) ? cnt[f] :
				cnt[f] == 4'd0 ? 4'd0 : cnt[f] - 4'd1;
			if (rst)
			begin
				pe_q[f] <= 1'b0; pw_q[f] <= 1'b0; pn_q[f] <= 1'b0;
			end
			else if (issue && rd == 5'(f))
			begin
				pe_q[f] <= pk.w0 + 4'd1 > 4'd2; pw_q[f] <= pk.w0 + 4'd1 > 4'd1; pn_q[f] <= pk.w0 + 4'd1 != 4'd0;
			end
			else if (frz && l_rd == 5'(f))
			begin
				// (held: the count stays)
				pe_q[f] <= cnt[f] > 4'd2; pw_q[f] <= cnt[f] > 4'd1; pn_q[f] <= cnt[f] != 4'd0;
			end
			else
			begin
				// (a count of 0 stays 0, any other goes down by 1)
				pe_q[f] <= cnt[f] > 4'd3; pw_q[f] <= cnt[f] > 4'd2; pn_q[f] <= cnt[f] > 4'd1;
			end
		end
`ifdef VERILATOR
	always_ff @(posedge clk)
		for (int f = 0; f < 32; f++)
			if (!rst && (pe_q[f] != (cnt[f] > 4'd2) || pw_q[f] != (cnt[f] > 4'd1) || pn_q[f] != (cnt[f] != 4'd0)))
				$display("FPCTL p wrong: %0d %0d", f, cnt[f]);
	always_ff @(posedge clk)
		if (!rst && issue && pk.w0 != 4'(SLAT)) $display("FPCTL pk wrong");
`endif
endmodule

// divide and fres (1 / b), two bits a clock (no square root: the 602 has no fsqrt, rtl/ppc_pipe.sv makes it illegal; frsqrte
// is the pipeline's, as on the 602)
module ppc_fps_it (
	input  logic        clk,
	input  logic        rst,
	input  logic        start,
	input  logic [4:0]  op,             // F_DIV(S), F_RES
	input  logic [1:0]  rn,
	input  logic [31:0] a, b,
	output logic        done,           // a clock, with res
	output logic [31:0] res
);
	import ppc_fpu_pkg::*;

	typedef enum logic [3:0] { S_IDLE, S_U, S_DIV0, S_DIV, S_N, S_R0, S_R1, S_R2 } state_t;
	state_t      state;
	logic [1:0]  q_rn;
	logic [31:0] x, y;                  // the operands, as they are: x / y
	sx_t         ux, uy;

	logic [27:0] q;                     // the quotient
	logic [31:0] r;                     // the remainder
	logic [4:0]  k;                     // the steps still to go, two a clock
	logic        fs;
	logic signed [9:0] fe;
	logic [47:0] fm;
	logic        fst;
	logic [47:0] rm;
	logic [23:0] kept;
	logic        rinc;

	task automatic fin(input logic [31:0] v);
		res <= v; done <= 1'b1; state <= S_IDLE;
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
						q_rn <= rn;
						x <= fop_t'(op) == F_RES ? 32'h3f800000 : a;
						y <= b;
						state <= S_U;
					end
				S_U:
				begin
					ux <= sunpack(x);
					uy <= sunpack(y);
					state <= S_DIV0;
				end
				S_DIV0:
				begin
					logic sgn;
					sgn = ux.s ^ uy.s;
					if (ux.nan) fin(squiet(x));
					else if (uy.nan) fin(squiet(y));
					else if ((ux.inf && uy.inf) || (ux.zero && uy.zero)) fin(SDNAN);
					else if (ux.inf || uy.zero) fin({sgn, 31'h7f800000});
					else if (ux.zero || uy.inf) fin({sgn, 31'h0});
					else
					begin
						r <= {8'h0, ux.m[47:24]};
						q <= 28'h0;
						k <= 5'd14;
						fs <= sgn;
						fe <= ux.e - uy.e;
						state <= S_DIV;
					end
				end
				S_DIV:
				begin
					// a step: a quotient bit if r >= d, r - d if so, then r << 1. q = floor(mx * 2^27 / my)
					logic [31:0] d, r1, r2;
					logic b1, b2;
					d = {8'h0, uy.m[47:24]};
					b1 = r >= d;
					r1 = {b1 ? r - d : r} << 1;
					b2 = r1 >= d;
					r2 = {b2 ? r1 - d : r1} << 1;
					r <= r2;
					q <= {q[25:0], b1, b2};
					k <= k - 5'd1;
					if (k == 5'd1) state <= S_N;
				end
				// normalized: the quotient's top bit is 27 or 26
				S_N:
				begin
					if (q[27]) begin fm <= {q, 20'h0}; end
					else begin fm <= {q[26:0], 21'h0}; fe <= fe - 10'sd1; end
					fst <= r != 32'h0;
					state <= S_R0;
				end
				S_R0:
				begin
					sden_t d;
					d = sden(fe, fm, fst);
					fe <= d.e; rm <= d.m; fst <= d.st;
					state <= S_R1;
				end
				S_R1:
				begin
					kept <= rm[47:24];
					rinc <= sinc(fs, rm, fst, q_rn);
					state <= S_R2;
				end
				S_R2: fin(spack(fs, fe, kept, rinc, q_rn));
				default: state <= S_IDLE;
			endcase
	end
endmodule

// ppc_fps3: the 602's single-precision float pipeline in three clocks, as the chip has it (PowerPC 602 RISC Microprocessor
// User's Manual, IBM MPR602UMU-01 / Motorola MPC602UM/AD, 6.4.3: "a three-stage pipeline with three-cycle completion
// latency"; measured on a Panasonic FZ-35S: 3 clocks for a dependent fadds, fmuls, fmadds or frsqrte). The unit before it
// took 5 (fadds, fmuls) and 8 (fmadds).
//
// One fused multiply-add datapath for all: fadds/fsubs are a * 1.0 +- b, fmuls a * c with no addend.
//   issue  the operands (forwarded from ev / wv), captured in R1
//   C1     unpack; the specials (the result's whole value, if it's one); a and c normalized (a denormal's leading zeros);
//          the 24 x 24 multiply (a DSP); the addend aligned against the product's exponent into a 75-bit window -> R2
//   C2     the product into the window; the sum, or both differences and the non-negative one; its leading zeros -> R3
//   C3     normalized; to a denormal (or to zero in NI mode); the round; the pack -> ev / evl (to the next op's operands)
// The window [74:0]: the product at [48:1]; the addend at [d+24:d+1], d = eb - ep + 23; an addend under the product by more
// than its own width, or a product under the addend by more than 2 bits, becomes a sticky bit at [0]. Bit k is worth
// 2^(ebase + k - 1).
// One pipe, every op 3 clocks: no structural hazards (the iterative unit goes only with the pipe empty). A multiply-add
// issues with its addend ready. No FPSCR flags. hold: ppc_fps_ctl issues nothing that clock and counts the held op's FPR a
// clock more. FPSCR[NI] (ni): a result under the normal range is zero; tied off in ppc_fpx for now (IEEE denormals).
`default_nettype none
module ppc_fps3 (
	input  logic        clk,
	input  logic        rst,
	input  logic        issue,
	input  logic        cpu,
	input  logic [4:0]  op,
	input  logic [1:0]  rn,
	input  logic [31:0] a, b, c,
	input  logic [4:0]  rd,
	input  logic [2:0]  i_fe, i_fw,
	input  logic        ni,             // FPSCR[NI]: a result under the normal range is zero (the 602's non-IEEE mode)
	output logic        hold,           // an op with a denormal a or c takes a clock more in R1: no issue this clock
	output logic        ev,
	output logic        ecpu,
	output logic [4:0]  erd,
	output logic [32:0] evl,
	output logic        wv,
	output logic        wcpu,
	output logic [4:0]  wrd,
	output logic [32:0] wval
);
	import ppc_fpu_pkg::*;

	typedef struct packed { logic v; logic cpu; cls_t k; logic [4:0] rd; logic [1:0] rn; } meta_t;
	cls_t ik;
	assign ik = cls(op);

	wire [31:0] ia = i_fe[0] ? evl[31:0] : i_fw[0] ? wval[31:0] : a;
	wire [31:0] ib = i_fe[1] ? evl[31:0] : i_fw[1] ? wval[31:0] : b;
	wire [31:0] ic = i_fe[2] ? evl[31:0] : i_fw[2] ? wval[31:0] : c;

	// ---- R1: the issued op ----
	meta_t       r1;
	logic [31:0] r1_a, r1_b, r1_c;
	logic        r1_ni;
	logic        r1_pre;                // a and c normalized (a denormal's extra clock): use r1_am .. r1_ce
	logic [23:0] r1_am, r1_cm;
	logic signed [9:0] r1_ae, r1_ce;

	// ---- C1 ----
	typedef struct packed { logic nan, inf, zero, s; logic signed [9:0] e; logic [23:0] m; } u_t;
	function automatic u_t up(input logic [31:0] x);
		u_t u;
		u.s = x[31];
		u.nan = x[30:23] == 8'hff && x[22:0] != 23'h0;
		u.inf = x[30:23] == 8'hff && x[22:0] == 23'h0;
		u.zero = x[30:0] == 31'h0;
		u.m = {x[30:23] != 8'h0, x[22:0]};
		u.e = x[30:23] == 8'h0 ? -10'sd126 : 10'($signed({2'b0, x[30:23]}) - 127);
		return u;
	endfunction
	u_t ua, ub, uc;
	assign ua = up(r1_a); assign ub = up(r1_b); assign uc = up(r1_c);
	// the specials: the result's whole value when an operand decides it
	logic        c1_sp;
	logic [31:0] c1_spv;
	logic        c1_nob;                // no addend to add (fmuls, or b a zero beside a finite non-zero product)
	always_comb
	begin
		logic        psp, sg, sy, xs, xnan, ynan, xinf, yinf, xz, yz;
		logic [31:0] pspv, xraw, yraw;
		{sy, xs, xnan, ynan, xinf, yinf, xz, yz} = '0; xraw = 32'h0; yraw = 32'h0;   // (only the add's, below: no latch)
		sg = ua.s ^ uc.s;
		psp = 1'b1;
		if (ua.nan) pspv = squiet(r1_a);
		else if (uc.nan) pspv = squiet(r1_c);
		else if ((ua.inf && uc.zero) || (ua.zero && uc.inf)) pspv = SDNAN;
		else if (ua.inf || uc.inf) pspv = {sg, 31'h7f800000};
		else if (ua.zero || uc.zero) pspv = {sg, 31'h0};
		else begin psp = 1'b0; pspv = 32'h0; end
		c1_sp = 1'b0; c1_spv = 32'h0; c1_nob = !r1.k.add || ub.zero;
		if (!r1.k.add)
		begin
			c1_sp = psp; c1_spv = pspv;
		end
		else
		begin
			// x op y: the product and b, or b and the product (swap); a special product as its raw value
			xraw = r1.k.swap ? r1_b : pspv; yraw = r1.k.swap ? pspv : r1_b;
			xnan = r1.k.swap ? ub.nan : psp && pspv[30:23] == 8'hff && pspv[22:0] != 23'h0;
			ynan = r1.k.swap ? psp && pspv[30:23] == 8'hff && pspv[22:0] != 23'h0 : ub.nan;
			xinf = r1.k.swap ? ub.inf : psp && pspv[30:0] == 31'h7f800000;
			yinf = r1.k.swap ? psp && pspv[30:0] == 31'h7f800000 : ub.inf;
			xz = r1.k.swap ? ub.zero : psp && pspv[30:0] == 31'h0;
			yz = r1.k.swap ? psp && pspv[30:0] == 31'h0 : ub.zero;
			xs = r1.k.swap ? ub.s : (psp ? pspv[31] : sg);
			sy = (r1.k.swap ? (psp ? pspv[31] : sg) : ub.s) ^ r1.k.sub;
			c1_sp = 1'b1;
			if (xnan) c1_spv = squiet(xraw);
			else if (ynan) c1_spv = squiet(yraw);
			else if (xinf && yinf) c1_spv = xs != sy ? SDNAN : {xs, 31'h7f800000};
			else if (xinf) c1_spv = {xs, 31'h7f800000};
			else if (yinf) c1_spv = {sy, 31'h7f800000};
			else if (xz && yz) c1_spv = {(xs && sy) || (xs != sy && r1.rn == 2'd3), 31'h0};
			else if (psp)
			begin
				// a zero product beside a finite non-zero b: b exactly (its sign through the swap / sub); not a special after
				// all for the datapath, which adds nothing to b
				c1_sp = 1'b0;
			end
			else c1_sp = 1'b0;
		end
	end
	// a and c normalized. A denormal a or c takes a clock first (c1_dn: the op held in R1, its normalized mantissas and exponents
	// into r1_am / r1_ae / r1_cm / r1_ce, r1_pre set; the manual's "three- or four-cycle latency"), so C1 always starts from
	// normalized operands: no leading zeros counted and no shift before the exponents and the addend's alignment (C1's long path)
	wire         c1_dn = r1.v && r1.k.mul && !r1_pre && ((r1_a[30:23] == 8'h0 && r1_a[22:0] != 23'h0) ||
		(r1_c[30:23] == 8'h0 && r1_c[22:0] != 23'h0));
	assign       hold = c1_dn;
	wire  [4:0]  za = r1_a[30:23] == 8'h0 ? lz24(ua.m) : 5'd0, zc = r1_c[30:23] == 8'h0 ? lz24(uc.m) : 5'd0;
	wire  [23:0] na = r1_pre ? r1_am : ua.m, nc = r1_pre ? r1_cm : uc.m;
	wire signed [9:0] ea = r1_pre ? r1_ae : ua.e, ec = r1_pre ? r1_ce : uc.e;
	wire signed [10:0] ep = 11'(ea) + 11'(ec);
	// the product's sign as an addend's: x's or y's, and sub
	wire         psgn = (ua.s ^ uc.s) ^ (r1.k.swap && r1.k.sub);
	wire         bsgn = ub.s ^ (!r1.k.swap && r1.k.sub);
	// a zero product (a or c a zero) beside b: only b
	wire         pzero = ua.zero || uc.zero;
	// the addend's place, from the biased exponents (a denormal's 1; a normalized one's 1 - its leading zeros), the constants
	// in one: dsh = d + 24 = eb - (ea + ec) + 47, with e = biased - 127
	wire signed [10:0] bea = r1_pre ? 11'(r1_ae) + 11'sd127 : 11'({3'b0, r1_a[30:23] == 8'h0 ? 8'h1 : r1_a[30:23]});
	wire signed [10:0] bec = r1_pre ? 11'(r1_ce) + 11'sd127 : 11'({3'b0, r1_c[30:23] == 8'h0 ? 8'h1 : r1_c[30:23]});
	wire signed [11:0] dsh = 12'({4'b0, r1_b[30:23] == 8'h0 ? 8'h1 : r1_b[30:23]}) - 12'(bea) - 12'(bec) + 12'sd174;
	logic        c1_bigb;               // the product under the addend's last bit by more than 2: a sticky bit
	logic        c1_smallb;             // the addend under the product's: a sticky bit
	logic [74:0] c1_bacc;
	// b's trailing zeros, beside the shift: the bits shifted under the window's bit 1 are set if any of b's lowest 24 - sh are
	// (a compare, not an OR of the shifted bits after the shift: that was C1's longest path)
	logic [4:0]  tzb;
	always_comb
	begin
		tzb = 5'd24;
		for (int i = 23; i >= 0; i--) if (ub.m[i]) tzb = 5'(i);
	end
	always_comb
	begin
		// verilator lint_off UNUSEDSIGNAL
		logic [97:0] bx;                // (the bits under the window: the sticky's, from b's trailing zeros)
		// verilator lint_on UNUSEDSIGNAL
		logic [6:0]  sh;
		logic        stb;
		// the shift from dsh at once; the out-of-window cases (the compares beside it) chosen on its output
		sh = 7'(dsh);
		bx = 98'(ub.m) << sh;
		stb = sh < 7'd24 && 7'(tzb) < 7'd24 - sh;
		c1_smallb = dsh < 12'sd0;
		// the product under the addend's last bit by more than 2 (d > 50), or a zero product (b alone): b at the window's top
		c1_bigb = (dsh > 12'sd74 && !c1_nob) || pzero;     // (no addend: the product's own window)
		c1_bacc = dsh > 12'sd74 || pzero ? {ub.m, 51'h0} : c1_smallb ? 75'h1 : {bx[97:24], stb};
		if (pzero) c1_smallb = 1'b0;
	end

	// ---- R2 ----
	meta_t       r2;
	logic        r2_sp, r2_nob, r2_bigb, r2_psgn, r2_bsgn, r2_pzero, r2_ni;
	logic [31:0] r2_spv, r2_b;
	logic [47:0] r2_p;
	logic [74:0] r2_bacc;
	// the window's exponent base, its two candidates registered and chosen here (bit k worth 2^(ebase + k - 1)): the product's
	// (ep - 46), or the addend's when the product's only a sticky bit or zero (eb - 73)
	logic signed [10:0] r2_ep46, r2_eb73;
	wire  signed [10:0] r2_ebase = r2_bigb ? r2_eb73 : r2_ep46;
	// C3's denormal limit for an exponent base (C2's comment below): dneg, the right shift, the sentinel; made in C1 for both
	// candidates, so C2 only chooses
	typedef struct packed { logic dneg; logic [6:0] rs; logic [75:0] sen; } lim_t;
	function automatic lim_t limf(input logic signed [10:0] eb);
		lim_t l;
		logic signed [11:0] dlim;
		dlim = 12'(eb) + 12'sd200;
		l.dneg = dlim < 12'sd0;
		l.rs = l.dneg ? (dlim < -12'sd76 ? 7'd76 : 7'(-dlim)) : 7'd0;
		l.sen = l.dneg ? 76'h1 << 75 : dlim <= 12'sd75 ? 76'h1 << (7'd75 - 7'(dlim)) : 76'h0;
		return l;
	endfunction
	lim_t r2_limp, r2_limb;

	// ---- C2: the sum ----
	// x = the product in the window, y = the addend. One add-or-subtract chain t (x + y, or x - y) and y - x beside it for a
	// negative difference (pick: t's sign); below, each counted for its leading zeros, the count chosen late with the sum
	wire  [75:0] c2_x = r2_pzero ? 76'h0 : r2_bigb ? 76'h1 : {27'h0, r2_p, 1'b0};
	wire  [75:0] c2_y = r2_nob ? 76'h0 : {1'b0, r2_bacc};
	wire         c2_sub = !(r2_psgn == r2_bsgn || r2_nob);
	wire  [75:0] c2_t = c2_sub ? c2_x - c2_y : c2_x + c2_y;
	wire  [75:0] c2_u = c2_y - c2_x;
	wire         c2_pick = c2_sub && c2_t[75];
	wire  [75:0] c2_s = c2_pick ? c2_u : c2_t;
	wire         c2_sgn = !c2_sub ? (r2_pzero ? r2_bsgn : r2_psgn) : c2_pick ? r2_bsgn : r2_psgn;
	wire         c2_zero = c2_t == 76'h0;
	// leading zeros of 76 bits (76 for none) as a tree: groups of 4, groups of 4 groups, then the 5 of those
	function automatic logic [6:0] lzc76(input logic [75:0] v);
		logic [79:0] w;
		logic [19:0] gz;
		logic [1:0]  gc [0:19];
		logic [3:0]  sz;                // (the last group of groups is never all zeros: w's low 4 bits are ones)
		logic [3:0]  sc [0:4];
		logic [3:0]  q4;
		w = {v, 4'hf};
		for (int g = 0; g < 20; g++)
		begin
			q4 = w[79 - 4 * g -: 4];
			gz[g] = q4 == 4'h0;
			gc[g] = q4[3] ? 2'd0 : q4[2] ? 2'd1 : q4[1] ? 2'd2 : 2'd3;
		end
		for (int h = 0; h < 5; h++)
		begin
			if (h < 4) sz[h] = &gz[4 * h +: 4];
			sc[h] = !gz[4 * h] ? {2'd0, gc[4 * h]} : !gz[4 * h + 1] ? {2'd1, gc[4 * h + 1]} :
				!gz[4 * h + 2] ? {2'd2, gc[4 * h + 2]} : {2'd3, gc[4 * h + 3]};
		end
		return !sz[0] ? {3'd0, sc[0]} : !sz[1] ? 7'd16 + 7'(sc[1]) : !sz[2] ? 7'd32 + 7'(sc[2]) :
			!sz[3] ? 7'd48 + 7'(sc[3]) : 7'd64 + 7'(sc[4]);
	endfunction
	// C3's one shift, decided here: normalized (left by the leading zeros), or, under the normal range, as a denormal: the sum's
	// bit k is worth 2^(ebase + k - 1) and a denormal's last kept bit (n[28] after the shift) 2^-149, so a denormal's shift is
	// dlim = ebase + 200 (left, or right with the bits out sticky when that's under 0). The limit is a sentinel bit ORed in
	// before the count (bit 75 - dlim; bit 75 when dlim < 0, where the shift is right), so the count is the left shift itself:
	// no compare after it. All of dlim's side comes from ebase alone, a register.
	lim_t        c2_lim;
	assign c2_lim = r2_bigb ? r2_limb : r2_limp;
	wire         c2_dneg = c2_lim.dneg;
	wire  [6:0]  c2_rs = c2_lim.rs;
	wire  [75:0] c2_sen = c2_lim.sen;
	wire  [6:0]  c2_lzt = lzc76(c2_t | c2_sen), c2_lzu = lzc76(c2_u | c2_sen);
	wire  [6:0]  c2_ls = c2_pick ? c2_lzu : c2_lzt;
	// the sum's trailing zeros (127 for a zero sum), for C3's sticky: u = -t has t's, so t is counted
	function automatic logic [6:0] ctz76(input logic [75:0] v);
		logic [75:0] r;
		for (int i = 0; i < 76; i++) r[i] = v[75 - i];
		return v == 76'h0 ? 7'd127 : lzc76(r);
	endfunction
	wire  [6:0]  c2_tz = ctz76(c2_t);
	// the result when it isn't the datapath's: a special (its value from C1) or a zero sum (+0, or -0 rounding down), negated
	// for fnmadd / fnmsub; use_alt says it is
	wire  [31:0] a2_alt = (r2_sp ? r2_spv : {r2.rn == 2'd3, 31'h0}) ^ (r2.k.neg ? 32'h80000000 : 32'h0);
	// the S ops (fctiw[z], frsp, frsqrte) on b
	logic        c2_cvsp, c2_inc;
	logic [31:0] c2_cvspv;
	logic [33:0] c2_mag;
	always_comb
	begin
		logic signed [9:0] e;
		logic tiny, r, st;
		logic [5:0] sh;
		logic [1:0] md;
		logic [63:0] m;
		e = 10'($signed({2'b0, r2_b[30:23]}) - 127);
		c2_cvsp = 1'b1; c2_cvspv = 32'h80000000; tiny = 1'b0;
		sh = 6'(10'sd55 - e);
		if (r2_b[30:23] == 8'hff) ;
		else if (r2_b[30:0] == 31'h0) c2_cvspv = 32'h0;
		else if (e >= 10'sd32) ;
		else begin c2_cvsp = 1'b0; tiny = r2_b[30:23] == 8'h0 || e < -10'sd2; end
		m = {8'h0, 1'b1, r2_b[22:0], 32'h0};
		if (tiny) begin c2_mag = 34'h0; r = 1'b0; st = 1'b1; end
		else
		begin
			c2_mag = 34'(m >> sh);
			r = m[sh - 6'd1];
			st = 1'b0;
			for (int i = 0; i < 63; i++) if (i < int'(sh) - 1 && m[i]) st = 1'b1;
		end
		md = r2.k.cvz ? 2'd1 : r2.rn;
		case (md)
			2'd0: c2_inc = r && (st || c2_mag[0]);
			2'd1: c2_inc = 1'b0;
			2'd2: c2_inc = !r2_b[31] && (r || st);
			default: c2_inc = r2_b[31] && (r || st);
		endcase
	end

	// ---- R3 ----
	meta_t       r3;
	logic        r3_sgn, r3_ni, r3_cvsp, r3_inc, r3_bs, r3_use_alt;
	logic [31:0] r3_alt, r3_cvspv;
	logic [75:0] r3_s;
	logic [6:0]  r3_ls, r3_rs, r3_tz;
	logic        r3_dneg;
	logic signed [10:0] r3_ebase;
	logic [33:0] r3_mag;

	// ---- C3: normalize, round, pack ----
	// (ppc_fpu_pkg's sinc and spack, laid out so that only the shift and one choice are in series: the sticky from the trailing
	// zeros, both rounded candidates and their exponents beside the shift, everything else from registers)
	logic [32:0] c3_out;
	always_comb
	begin
		// verilator lint_off UNUSEDSIGNAL
		logic [75:0] n;                 // (only n[75:51]: the bits under the round bit are the sticky's, from tz)
		// verilator lint_on UNUSEDSIGNAL
		logic [23:0] kept;
		logic [24:0] kp1;
		logic        s, r, sk, inc, ovfm;
		logic signed [10:0] e;
		logic [7:0]  ex0, ex1;
		logic [31:0] ovf, p0, p1, fv, iv;
		logic [33:0] mag;
		s = r3_sgn ^ r3.k.neg;
		n = r3_rs != 7'd0 ? (r3_s >> r3_rs) : (r3_s << r3_ls);
		kept = n[75:52];
		r = n[51];
		// a bit under the round bit, or shifted out on the right: the lowest set bit (tz) ends under bit 51
		sk = $signed({2'b0, r3_tz}) <= $signed(9'sd50 + 9'($signed({2'b0, r3_rs})) - 9'($signed({2'b0, r3_ls})));
		case (r3.rn)
			2'd0: inc = r && (sk || kept[0]);
			2'd1: inc = 1'b0;
			2'd2: inc = !s && (r || sk);
			default: inc = s && (r || sk);
		endcase
		kp1 = {1'b0, kept} + 25'd1;
		// (normal: -126 or more; a denormal's -126, its leading bit clear: at the sentinel's limit ebase + 74 - ls is -126 itself)
		e = r3_dneg ? -11'sd126 : r3_ebase + 11'sd74 - 11'($signed({4'b0, r3_ls}));
		ovfm = r3.rn == 2'd1 || (r3.rn == 2'd2 && s) || (r3.rn == 2'd3 && !s);
		ovf = ovfm ? {s, 31'h7f7fffff} : {s, 31'h7f800000};
		ex0 = 8'(e + 11'sd127);
		ex1 = 8'(e + 11'sd128);
		// spack: no increment, or an increment (kp1[24]: it carried out of 24 bits, so 1.0 x 2^(e + 1))
		p0 = e > 11'sd127 ? ovf : {s, kept[23] ? ex0 : 8'h0, kept[22:0]};
		p1 = kp1[24] ? (e >= 11'sd127 ? ovf : {s, ex1, 23'h0}) : (e > 11'sd127 ? ovf : {s, kp1[23] ? ex0 : 8'h0, kp1[22:0]});
		fv = inc ? p1 : p0;
		// (under the normal range: shifted right, or the leading bit not reached; a zero sum is alt's)
		if (r3_ni && (r3_dneg || !n[75])) fv = {s, 31'h0};
		if (r3_use_alt) fv = r3_alt;
		mag = r3_mag + 34'(r3_inc);
		if (r3_cvsp) iv = r3_cvspv;
		else if (r3_bs) iv = mag > 34'h80000000 ? 32'h80000000 : 32'(-mag);
		else iv = mag >= 34'h80000000 ? 32'h80000000 : mag[31:0];
		c3_out = r3.k.cv ? {1'b1, iv} : {1'b0, fv};
	end
	assign ev = r3.v;
	assign ecpu = r3.cpu;
	assign erd = r3.rd;
	assign evl = c3_out;

	always_ff @(posedge clk)
	begin
		if (rst) begin r1.v <= 1'b0; r2.v <= 1'b0; r3.v <= 1'b0; wv <= 1'b0; r1_pre <= 1'b0; end
		else
		begin
			if (c1_dn)
			begin
				// the denormal's extra clock: the op stays in R1, a and c normalized (nothing issues: hold)
				r1_pre <= 1'b1;
				r1_am <= ua.m << za; r1_ae <= ua.e - 10'($signed({1'b0, za}));
				r1_cm <= uc.m << zc; r1_ce <= uc.e - 10'($signed({1'b0, zc}));
			end
			else
			begin
				r1.v <= 1'b0;
				r1_pre <= 1'b0;
			end
			if (issue)
			begin
				r1 <= '{1'b1, cpu, ik, rd, rn};
				r1_pre <= 1'b0;
				r1_ni <= ni;
				// fadds / fsubs: a * 1.0 op b
				r1_a <= ia; r1_b <= ib; r1_c <= ik.add && !ik.mul ? 32'h3f800000 : ic;
			end
			r2 <= r1;
			if (c1_dn) r2.v <= 1'b0;
			// the S ops (cv, rq, rs alone): b passed on; their result decided in C2 / C3
			r2_sp <= c1_sp || !(r1.k.mul || r1.k.add);
			r2_spv <= r1.k.mul || r1.k.add ? c1_spv : r1.k.rq ? rsqrte602(r1_b) : (snan(r1_b) ? squiet(r1_b) : r1_b);
			r2_nob <= c1_nob; r2_bigb <= c1_bigb; r2_psgn <= psgn; r2_bsgn <= bsgn; r2_pzero <= pzero; r2_ni <= r1_ni;
			r2_p <= na * nc;
			r2_bacc <= c1_bacc; r2_ep46 <= ep - 11'sd46; r2_eb73 <= 11'(ub.e) - 11'sd73; r2_b <= r1_b;
			r2_limp <= limf(ep - 11'sd46); r2_limb <= limf(11'(ub.e) - 11'sd73);
			r3 <= r2;
			r3_use_alt <= r2_sp || c2_zero; r3_alt <= a2_alt; r3_sgn <= c2_sgn; r3_ni <= r2_ni;
			r3_s <= c2_s; r3_ls <= c2_ls; r3_rs <= c2_rs; r3_tz <= c2_tz; r3_dneg <= c2_dneg;
			r3_ebase <= r2_ebase;
			r3_cvsp <= c2_cvsp; r3_cvspv <= c2_cvspv; r3_mag <= c2_mag; r3_inc <= c2_inc; r3_bs <= r2_b[31];
			wv <= ev; wcpu <= ecpu; wrd <= erd; wval <= evl;
		end
	end
endmodule
