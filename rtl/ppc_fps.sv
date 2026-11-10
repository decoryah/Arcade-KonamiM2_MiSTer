// The PPC602's float units as the chip has them: single precision. 32-bit values (an FPR's 33rd bit, the LT bit of the 602's
// SP / LT registers, says it holds an integer: rtl/ppc_pipe.sv's stfd needs that). A multiply-add is fused (the 48-bit product
// goes to the add whole, as in the manual), a result rounded once.
//   M0-M2  a * c: the operands' specials and a denormal's leading zeros; the normalized multiply; the product normalized
//   A0-A2  the add: the operands unpacked, the specials and the larger by magnitude; aligned and added; normalized
//   S0-S1  the shift into a denormal and the round's increment; the pack (or fctiw[z], or frsp, which has nothing to do but
//          quiet a NaN)
// An op goes through the units it needs, in that order, always S: fmadds M A S (8 stages), fmuls M S (5), fadds A S (5).
// ppc_fps_it is the iterative unit: divide, square root, fres, frsqrte, two bits a clock.
//
// The control is rtl/ppc_fpp.sv's (a result leaves its last stage, ev, for the next op's operands, and is registered, wv, for the
// FPRs; see there), and ppc_fps_ctl a CPU's part of it. The double forms do what the single forms do: the real chip
// traps them to software (0x1600), which this core doesn't.
`default_nettype none
module ppc_fps_ctl (
	input  logic        clk,
	input  logic        rst,
	input  logic        allow,          // this CPU's clock for an op
	input  logic [15:0] res_a, res_s, res_w,
	input  logic        issue,
	// verilator lint_off UNUSEDSIGNAL
	input  ppc_fpu_pkg::fpk_t pk,       // the op's (fpk_s: a ppc_fpu_pkg::fop_t, not F_DIV(S) / F_SQRT(S) / F_RES / F_RSQRTE / F_CMP)
	// verilator lint_on UNUSEDSIGNAL
	input  logic [4:0]  rd,
	input  logic [4:0]  ra, rb, rc,     // its operands' FPRs (b: a multiply-add's addend, taken late)
	output logic        ok,             // op can issue this clock
	output logic        dok,            // ... as far as rd goes
	output logic        busy,           // an op of this CPU's is in flight
	output logic [2:0]  bw,             // a multiply-add's addend still to come: the clocks until it leaves its last stage
	output logic [2:0]  fe, fw,         // operands a, b, c leaving the last stage this clock (ev), registered (wv)
	output logic [31:0] pe, pw, pn,     // FPRs not written by this clock's end: with ev, with wv, at all
	output logic [31:0] lb              // FPRs a multiply-add's addend may be made in, b taken late
);
	import ppc_fpu_pkg::*;

	logic [3:0]  cnt [0:31];            // the clocks until the last op writing the FPR has its wv (1: this clock)
	// verilator lint_off UNUSEDSIGNAL
	cls_t        ik;                    // (its add and mul)
	// verilator lint_on UNUSEDSIGNAL
	assign ik = pk.k;
	assign ok = allow && !(ik.add && res_a[pk.a0]) && !res_s[pk.s] && !res_w[pk.w0];
	assign dok = cnt[rd] < pk.w0 + 4'd2;
	// pe, pw, pn and lb from registers, each its compare on cnt's next value: from the counts through the compares to X's
	// hazards was a long path
	logic [31:0] pe_q, pw_q, pn_q, lb_q;
	assign pe = pe_q;
	assign pw = pw_q;
	assign pn = pn_q;
	assign lb = lb_q;
	assign busy = pn != 32'h0;
	assign bw = ik.mul && ik.add && cnt[rb] > 4'd2 ? 3'(cnt[rb] - 4'd2) : 3'd0;
	assign fe = {cnt[rc] == 4'd2, cnt[rb] == 4'd2, cnt[ra] == 4'd2};
	assign fw = {cnt[rc] == 4'd1, cnt[rb] == 4'd1, cnt[ra] == 4'd1};

	always_ff @(posedge clk)
		for (int f = 0; f < 32; f++)
		begin
			cnt[f] <= rst ? 4'd0 : issue && rd == 5'(f) ? pk.w0 + 4'd1 : cnt[f] == 4'd0 ? 4'd0 : cnt[f] - 4'd1;
			if (rst)
			begin
				pe_q[f] <= 1'b0; pw_q[f] <= 1'b0; pn_q[f] <= 1'b0; lb_q[f] <= 1'b1;
			end
			else if (issue && rd == 5'(f))
			begin
				pe_q[f] <= pk.w0 + 4'd1 > 4'd2; pw_q[f] <= pk.w0 + 4'd1 > 4'd1; pn_q[f] <= pk.w0 + 4'd1 != 4'd0;
				lb_q[f] <= pk.w0 + 4'd1 <= 4'(SLM + 2);
			end
			else
			begin
				// (a count of 0 stays 0, any other goes down by 1)
				pe_q[f] <= cnt[f] > 4'd3; pw_q[f] <= cnt[f] > 4'd2; pn_q[f] <= cnt[f] > 4'd1; lb_q[f] <= cnt[f] <= 4'(SLM + 3);
			end
		end
`ifdef VERILATOR
	always_ff @(posedge clk)
		for (int f = 0; f < 32; f++)
			if (!rst && (pe_q[f] != (cnt[f] > 4'd2) || pw_q[f] != (cnt[f] > 4'd1) || pn_q[f] != (cnt[f] != 4'd0) ||
				lb_q[f] != (cnt[f] <= 4'(SLM + 2))))
				$display("FPCTL p wrong: %0d %0d", f, cnt[f]);
	always_ff @(posedge clk)
		if (!rst && issue && (pk.a0 != sat_a(pk.k) || pk.s != sat_s(pk.k) || pk.w0 != sat_w(pk.k))) $display("FPCTL pk wrong");
`endif
endmodule

module ppc_fps_dp (
	input  logic        clk,
	input  logic        rst,
	input  logic        issue,
	input  logic        cpu,            // whose
	input  logic [4:0]  op,
	input  logic [1:0]  rn,
	input  logic [31:0] a, b, c,
	input  logic [4:0]  rd,
	input  logic [2:0]  i_bw,           // a multiply-add's addend: the clocks until it comes (evl), 0 if it's in b
	input  logic [2:0]  i_fe, i_fw,     // a, b, c: this clock's evl instead, or wval
	output logic [15:0] res_a, res_s, res_w, // the reservations: bit j, the clock j from now
	output logic        ev,             // a result leaving its last stage (for the operands): FPR erd = evl
	output logic        ecpu,
	output logic [4:0]  erd,
	output logic [32:0] evl,
	output logic        wv,             // a result: FPR wrd = wval at the clock's end
	output logic        wcpu,
	output logic [4:0]  wrd,
	output logic [32:0] wval
);
	import ppc_fpu_pkg::*;

	typedef struct packed { logic v; logic cpu; cls_t k; logic [4:0] rd; logic [1:0] rn; } meta_t;

	cls_t        ik;
	assign ik = cls(op);
	meta_t im;
	assign im = '{1'b1, cpu, ik, rd, rn};
	// the issued op's operands, those made in the pipeline taken as they leave it (or from wval, a clock after)
	wire [31:0] ia = i_fe[0] ? evl[31:0] : i_fw[0] ? wval[31:0] : a;
	wire [31:0] ib = i_fe[1] ? evl[31:0] : i_fw[1] ? wval[31:0] : b;
	wire [31:0] ic = i_fe[2] ? evl[31:0] : i_fw[2] ? wval[31:0] : c;

	// ---- M: a * c --------------------------------------------------------------------------------------------------
	meta_t        m0, m1, m2;
	logic [31:0]  m0_a, m0_c;
	logic [31:0]  m0_b, m1_b, m2_b;     // the add's operand, carried along ...
	logic [2:0]   m0_bw, m1_bw, m2_bw;  // ... or the clocks until it comes (ev)
	logic         m1_sp, m2_sp;         // a special result (NaN, infinity, zero) ...
	logic [31:0]  m1_spv, m2_spv;       // ... this one
	logic         m1_s, m2_s;
	logic signed [9:0] m1_e, m2_e;
	logic [23:0]  m1_ma, m1_mc;         // unnormalized, ...
	logic [4:0]   m1_ka, m1_kc;         // ... and their shifts
	logic [47:0]  m2_p;

	// M0: the specials; a denormal's shift and its exponent
	logic        m0_sp;
	logic [31:0] m0_spv;
	logic [4:0]  m0_ka, m0_kc;
	logic signed [9:0] m0_e;
	always_comb
	begin
		logic sg, ai, ci, az, cz;
		logic signed [9:0] ea, ec;
		sg = m0_a[31] ^ m0_c[31];
		ai = m0_a[30:0] == 31'h7f800000;
		ci = m0_c[30:0] == 31'h7f800000;
		az = m0_a[30:0] == 31'h0;
		cz = m0_c[30:0] == 31'h0;
		m0_sp = 1'b1;
		if (snan(m0_a)) m0_spv = squiet(m0_a);
		else if (snan(m0_c)) m0_spv = squiet(m0_c);
		else if ((ai && cz) || (az && ci)) m0_spv = SDNAN;
		else if (ai || ci) m0_spv = {sg, 31'h7f800000};
		else if (az || cz) m0_spv = {sg, 31'h0};
		else begin m0_sp = 1'b0; m0_spv = 32'h0; end
		m0_ka = m0_a[30:23] == 8'h0 ? lz24({1'b0, m0_a[22:0]}) : 5'd0;
		m0_kc = m0_c[30:23] == 8'h0 ? lz24({1'b0, m0_c[22:0]}) : 5'd0;
		ea = m0_a[30:23] == 8'h0 ? -10'sd126 - 10'($signed({1'b0, m0_ka})) : 10'($signed({2'b0, m0_a[30:23]}) - 127);
		ec = m0_c[30:23] == 8'h0 ? -10'sd126 - 10'($signed({1'b0, m0_kc})) : 10'($signed({2'b0, m0_c[30:23]}) - 127);
		m0_e = ea + ec;
	end
	// M1: normalized, the product
	wire [23:0] m1_na = m1_ma << m1_ka, m1_nc = m1_mc << m1_kc;
	// M2: the product normalized
	wire [47:0] m_m = m2_p[47] ? m2_p : {m2_p[46:0], 1'b0};
	wire signed [9:0] m_e = m2_p[47] ? m2_e + 10'sd1 : m2_e;
	// (the addend, as M2's op goes on)
	wire [31:0] m_bv = m2_bw == 3'd1 ? evl[31:0] : m2_b;
	sx_t m_prod;
	assign m_prod = '{1'b0, 1'b0, 1'b0, m2_s, m_e, m_m};
	// (to A, a product under the normal range shifted to a denormal's exponent, the bits shifted out or'd into the last: A's
	// operands' exponents are all -126 or more, so the larger exponent is the larger operand)
	sden_t m_pd;
	assign m_pd = sden(m_e, m_m, 1'b0);
	sx_t m_proda;
	assign m_proda = '{1'b0, 1'b0, 1'b0, m2_s, m_pd.e, {m_pd.m[47:1], m_pd.m[0] | m_pd.st}};

	// ---- A: x + y (x - y) ------------------------------------------------------------------------------------------
	meta_t       a0, a1, a2;
	logic [31:0] a0_x, a0_y;                // an operand as it is, ...
	logic        a0_xp, a0_yp;              // ... or the product
	sx_t         a0_p;
	logic        a1_sp, a2_sp;
	logic [31:0] a1_spv, a2_spv;
	logic        a1_s, a2_s;                // the result's sign (the larger operand's)
	logic        a1_sub;                    // the signs differ
	logic [47:0] a1_mb, a1_ms;              // the larger and smaller operand's significands
	logic signed [9:0] a1_eb, a2_e;
	logic [10:0] a1_d;                      // the difference of the exponents
	logic [51:0] a2_sum;

	// A0: the operands unpacked (a denormal as it is, its exponent -126: A2 normalizes the sum); the specials; the larger by
	// magnitude
	sx_t a0_ux, a0_uy;
	assign a0_ux = a0_xp ? a0_p : sunpack_a(a0_x);
	assign a0_uy = a0_yp ? a0_p : sunpack_a(a0_y);
	logic        a0_sp;
	logic [31:0] a0_spv;
	logic        a0_big;                    // x is the larger
	logic        a0_sy;
	always_comb
	begin
		logic xz, yz;
		a0_sy = a0_uy.s ^ a0.k.sub;
		xz = a0_ux.zero;
		yz = a0_uy.zero;
		a0_sp = 1'b1;
		if (a0_ux.nan) a0_spv = squiet(a0_x);
		else if (a0_uy.nan) a0_spv = squiet(a0_y);
		else if (a0_ux.inf && a0_uy.inf) a0_spv = a0_ux.s != a0_sy ? SDNAN : {a0_ux.s, 31'h7f800000};
		else if (a0_ux.inf) a0_spv = {a0_ux.s, 31'h7f800000};
		else if (a0_uy.inf) a0_spv = {a0_sy, 31'h7f800000};
		else if (xz && yz) a0_spv = {(a0_ux.s && a0_sy) || (a0_ux.s != a0_sy && a0.rn == 2'd3), 31'h0};
		else begin a0_sp = 1'b0; a0_spv = 32'h0; end
		// (a zero's exponent is the lowest: it's the smaller, shifted out with nothing to lose; an exponent over -126 has its
		// significand's top bit set)
		a0_big = a0_ux.e > a0_uy.e || (a0_ux.e == a0_uy.e && a0_ux.m >= a0_uy.m);
	end

	// A1: the smaller aligned (the bits shifted out in the last), and the sum
	logic [51:0] a1_sum;
	always_comb
	begin
		logic [50:0] sm;
		sm = shr51({a1_ms, 3'b000}, a1_d > 11'd63 ? 6'd63 : a1_d[5:0]);
		a1_sum = a1_sub ? {1'b0, a1_mb, 3'b000} - {1'b0, sm} : {1'b0, a1_mb, 3'b000} + {1'b0, sm};
	end

	// A2: normalized
	logic [47:0] a_m;
	logic        a_st;
	logic signed [9:0] a_e;
	logic [50:0] a_n;
	always_comb
	begin
		logic [5:0] l;
		l = lz51(a2_sum[50:0]);
		a_n = a2_sum[50:0] << l;
		if (a2_sum[51]) begin a_m = a2_sum[51:4]; a_st = a2_sum[3:0] != 4'h0; a_e = a2_e + 10'sd1; end
		else begin a_m = a_n[50:3]; a_st = a_n[2:0] != 3'h0; a_e = a2_e - 10'($signed({1'b0, l})); end
	end
	wire         a_zero = a2_sum == 52'h0;
	wire         a_sp = a2_sp || a_zero;
	wire [31:0]  a_spv = a2_sp ? a2_spv : {a2.rn == 2'd3, 31'h0};

	// ---- S: to a denormal, the round, the pack; or the conversion to an integer ------------------------------------
	meta_t       s0, s1;
	logic        s0_sp, s1_sp;
	logic [31:0] s0_spv, s1_spv;
	logic        s0_s, s1_s;
	logic signed [9:0] s0_e, s1_e;
	logic [47:0] s0_m;
	logic        s0_st;
	logic [23:0] s1_kept;
	logic        s1_inc;
	logic [31:0] s0_b;                      // fctiw's operand
	logic        s1_cvsp;                   // a special result (0, 0x80000000)
	logic [31:0] s1_cvspv;
	logic [33:0] s1_mag;

	// S0: to a denormal, and the round's increment; or fctiw[z]'s shift to the integer, and its increment
	logic        s0_cvsp;
	logic [31:0] s0_cvspv;
	sden_t       s0_d;
	logic [33:0] s0_mag;
	logic        s0_inc;
	always_comb
	begin
		logic signed [9:0] e;
		logic tiny;                         // under 2^-2: 0 and the sticky bit
		logic [5:0] sh;                     // the right shift to the integer
		logic r, st;
		logic [1:0] md;
		logic [63:0] m;
		s0_d = sden(s0_e, s0_m, s0_st);
		e = 10'($signed({2'b0, s0_b[30:23]}) - 127);
		s0_cvsp = 1'b1; s0_cvspv = 32'h80000000; tiny = 1'b0;
		sh = 6'(10'sd55 - e);
		if (s0_b[30:23] == 8'hff) ;
		else if (s0_b[30:0] == 31'h0) s0_cvspv = 32'h0;
		else if (e >= 10'sd32) ;
		else
		begin
			s0_cvsp = 1'b0;
			tiny = s0_b[30:23] == 8'h0 || e < -10'sd2;
		end
		m = {8'h0, 1'b1, s0_b[22:0], 32'h0};
		if (s0.k.cv)
		begin
			if (tiny) begin s0_mag = 34'h0; r = 1'b0; st = 1'b1; end
			else
			begin
				s0_mag = 34'(m >> sh);
				r = m[sh - 6'd1];
				st = 1'b0;
				for (int i = 0; i < 63; i++) if (i < int'(sh) - 1 && m[i]) st = 1'b1;
			end
			md = s0.k.cvz ? 2'd1 : s0.rn;
			case (md)
				2'd0: s0_inc = r && (st || s0_mag[0]);
				2'd1: s0_inc = 1'b0;
				2'd2: s0_inc = !s0_s && (r || st);
				default: s0_inc = s0_s && (r || st);
			endcase
		end
		else
		begin
			s0_mag = 34'h0;
			s0_inc = sinc(s0_s, s0_d.m, s0_d.st, s0.rn);
		end
	end

	// S1: the pack
	logic [32:0] s_out;
	always_comb
	begin
		logic [33:0] mag;
		logic [31:0] iv;
		mag = s1_mag + 34'(s1_inc);
		if (s1_cvsp) iv = s1_cvspv;
		else if (s1_s) iv = mag > 34'h80000000 ? 32'h80000000 : 32'(-mag);
		else iv = mag >= 34'h80000000 ? 32'h80000000 : mag[31:0];
		s_out = s1.k.cv ? {1'b1, iv} : {1'b0, s1_sp ? s1_spv : spack(s1_s, s1_e, s1_kept, s1_inc, s1.rn)};
	end

	assign ev = s1.v;
	assign ecpu = s1.cpu;
	assign erd = s1.rd;
	assign evl = s_out;

	always_ff @(posedge clk)
	begin
		if (rst)
		begin
			m0.v <= 1'b0; m1.v <= 1'b0; m2.v <= 1'b0;
			a0.v <= 1'b0; a1.v <= 1'b0; a2.v <= 1'b0;
			s0.v <= 1'b0; s1.v <= 1'b0;
			wv <= 1'b0;
			res_a <= '0; res_s <= '0; res_w <= '0;
			m0_bw <= 3'd0;
		end
		else
		begin
			// M
			m0.v <= 1'b0;
			if (issue && ik.mul) begin m0 <= im; m0_a <= ia; m0_c <= ic; m0_b <= ib; m0_bw <= i_bw; end
			m1 <= m0; m1_sp <= m0_sp; m1_spv <= m0_spv; m1_s <= m0_a[31] ^ m0_c[31]; m1_e <= m0_e;
			m1_ma <= {m0_a[30:23] != 8'h0, m0_a[22:0]}; m1_mc <= {m0_c[30:23] != 8'h0, m0_c[22:0]}; m1_ka <= m0_ka; m1_kc <= m0_kc;
			m2 <= m1; m2_sp <= m1_sp; m2_spv <= m1_spv; m2_s <= m1_s; m2_e <= m1_e;
			m2_p <= m1_na * m1_nc;
			// the addend through M: taken from ev on the clock it comes
			m1_b <= m0_bw == 3'd1 ? evl[31:0] : m0_b; m1_bw <= m0_bw == 3'd0 ? 3'd0 : m0_bw - 3'd1;
			m2_b <= m1_bw == 3'd1 ? evl[31:0] : m1_b; m2_bw <= m1_bw == 3'd0 ? 3'd0 : m1_bw - 3'd1;

			// A0: from M2 (after a product), or issued
			a0.v <= 1'b0;
			if (m2.v && m2.k.add)
			begin
				a0 <= m2;
				a0_xp <= !m2.k.swap; a0_yp <= m2.k.swap;
				a0_p <= m_proda;
				a0_x <= m_bv; a0_y <= m_bv;     // (whichever isn't the product)
				// a special product's raw value, for a NaN
				if (m2_sp) begin if (m2.k.swap) a0_y <= m2_spv; else a0_x <= m2_spv; a0_xp <= 1'b0; a0_yp <= 1'b0; end
			end
			else if (issue && ik.add && !ik.mul)
			begin
				a0 <= im; a0_x <= ia; a0_y <= ib; a0_xp <= 1'b0; a0_yp <= 1'b0;
			end
			a1 <= a0; a1_sp <= a0_sp; a1_spv <= a0_spv;
			a1_s <= a0_big ? a0_ux.s : a0_sy;
			a1_sub <= a0_ux.s != a0_sy;
			a1_mb <= a0_big ? a0_ux.m : a0_uy.m; a1_ms <= a0_big ? a0_uy.m : a0_ux.m;
			a1_eb <= a0_big ? a0_ux.e : a0_uy.e;
			a1_d <= a0_big ? 11'($signed({a0_ux.e[9], a0_ux.e}) - $signed({a0_uy.e[9], a0_uy.e})) :
				11'($signed({a0_uy.e[9], a0_uy.e}) - $signed({a0_ux.e[9], a0_ux.e}));
			a2 <= a1; a2_sp <= a1_sp; a2_spv <= a1_spv; a2_s <= a1_s; a2_e <= a1_eb; a2_sum <= a1_sum;

			// S0: from A2, M2 or issued
			s0.v <= 1'b0;
			if (a2.v)
			begin
				s0 <= a2;
				// (fnmadd's negation)
				s0_sp <= a_sp; s0_spv <= a2.k.neg ? a_spv ^ 32'h80000000 : a_spv;
				s0_s <= a2_s ^ a2.k.neg; s0_e <= a_e; s0_m <= a_m; s0_st <= a_st;
			end
			else if (m2.v && !m2.k.add)
			begin
				s0 <= m2;
				s0_sp <= m2_sp; s0_spv <= m2_spv; s0_s <= m2_s; s0_e <= m_e; s0_m <= m_m; s0_st <= 1'b0;
			end
			else if (issue && !ik.mul && !ik.add)
			begin
				s0 <= im; s0_b <= ib; s0_s <= ib[31];
				s0_sp <= 1'b1; s0_spv <= snan(ib) ? squiet(ib) : ib;
			end
			s1 <= s0; s1_sp <= s0_sp; s1_spv <= s0_spv; s1_s <= s0_s; s1_e <= s0_d.e; s1_kept <= s0_d.m[47:24];
			s1_cvsp <= s0_cvsp; s1_cvspv <= s0_cvspv; s1_mag <= s0_mag; s1_inc <= s0_inc;

			wv <= ev; wcpu <= ecpu; wrd <= erd; wval <= evl;

			// the reservations move a clock on
			res_a <= (res_a | (issue && ik.add ? 16'h1 << sat_a(ik) : 16'h0)) >> 1;
			res_s <= (res_s | (issue ? 16'h1 << sat_s(ik) : 16'h0)) >> 1;
			res_w <= (res_w | (issue ? 16'h1 << sat_w(ik) : 16'h0)) >> 1;
		end
	end
endmodule

// divide, square root, fres (1 / b), frsqrte (the root, then 1 / it): two bits a clock
module ppc_fps_it (
	input  logic        clk,
	input  logic        rst,
	input  logic        start,
	input  logic [4:0]  op,             // F_DIV(S), F_SQRT(S), F_RES, F_RSQRTE
	input  logic [1:0]  rn,
	input  logic [31:0] a, b,
	output logic        done,           // a clock, with res
	output logic [31:0] res
);
	import ppc_fpu_pkg::*;

	typedef enum logic [3:0] { S_IDLE, S_U, S_DIV0, S_DIV, S_SQRT0, S_SQRT, S_N, S_R0, S_R1, S_R2 } state_t;
	state_t      state;
	logic        q_rsq;                 // frsqrte: the root first, then the divide
	logic [1:0]  q_rn;
	logic        q_sq;
	logic [31:0] x, y;                  // the operands, as they are: x / y, or the root of y
	sx_t         ux, uy;

	logic [27:0] q;                     // the quotient or the root
	logic [31:0] r;                     // the remainder
	logic [55:0] n;                     // the root's radicand, two bits a step
	logic [4:0]  k;                     // the steps still to go, two a clock
	logic        fs;
	logic signed [9:0] fe;
	logic [47:0] fm;
	logic        fst;
	logic [47:0] rm;
	logic [23:0] kept;
	logic        rinc;

	task automatic fin(input logic [31:0] v);
		if (q_rsq && q_sq)
		begin
			// the root's done: 1 / it
			x <= 32'h3f800000; y <= v; q_sq <= 1'b0; state <= S_U;
		end
		else
		begin
			res <= v; done <= 1'b1; state <= S_IDLE;
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
						q_rn <= rn;
						q_rsq <= fop_t'(op) == F_RSQRTE;
						q_sq <= fop_t'(op) == F_RSQRTE || fop_t'(op) == F_SQRT || fop_t'(op) == F_SQRTS;
						x <= fop_t'(op) == F_RES ? 32'h3f800000 : a;
						y <= b;
						state <= S_U;
					end
				S_U:
				begin
					ux <= sunpack(x);
					uy <= sunpack(y);
					state <= q_sq ? S_SQRT0 : S_DIV0;
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
				S_SQRT0:
				begin
					logic signed [9:0] ee;
					if (uy.nan) fin(squiet(y));
					else if (uy.zero) fin(y);
					else if (uy.s) fin(SDNAN);
					else if (uy.inf) fin(y);
					else
					begin
						// m * 2^E, E = e - 23; the radicand m << 32 (E even) or m << 31 (E odd): the root's top bit is its 27
						ee = uy.e - 10'sd23;
						n <= ee[0] ? {1'b0, uy.m[47:24], 31'h0} : {uy.m[47:24], 32'h0};
						fe <= 10'sd27 + ((ee - (ee[0] ? 10'sd31 : 10'sd32)) >>> 1);
						r <= 32'h0;
						q <= 28'h0;
						k <= 5'd14;
						fs <= 1'b0;
						state <= S_SQRT;
					end
				end
				S_SQRT:
				begin
					logic [31:0] r1, r2, t1, t2;
					logic [27:0] q1, q2;
					r1 = {r[29:0], n[55:54]};
					t1 = {2'b0, q, 2'b01};
					if (r1 >= t1) begin r1 = r1 - t1; q1 = {q[26:0], 1'b1}; end else q1 = {q[26:0], 1'b0};
					r2 = {r1[29:0], n[53:52]};
					t2 = {2'b0, q1, 2'b01};
					if (r2 >= t2) begin r2 = r2 - t2; q2 = {q1[26:0], 1'b1}; end else q2 = {q1[26:0], 1'b0};
					r <= r2;
					q <= q2;
					n <= {n[51:0], 4'h0};
					k <= k - 5'd1;
					if (k == 5'd1) state <= S_N;
				end
				// normalized: the quotient's top bit is 27 or 26; the root's 27
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
