// PPC602 float pipeline: the float ops but divide and square root (those are rtl/ppc_fpu.sv's), an op a clock, each
// MAME's sequence of x86 steps (see ppc_fpu.sv), in stages short enough for 66.67 MHz:
//   M0-M4  the double multiply a * c: unpack (a denormal's leading zeros), the four partial products (DSPs, after the
//          denormal's shift), their sum, the normalization (and the shift into a denormal), the round to double
//   A0-A3  the double add (a + b, the product + b, b - the product): compare and swap, align and add (guard, round and
//          sticky bits), normalize (no further than a denormal), round; fnmadd's negation after it
//   S0-S2  the round to single and back (the single ops, frsp), or the conversion to an integer (fctiw / fctiwz)
// An op goes through the units it needs, in that order: fmadds M A S (12 stages), fmul M (5), fadd A (4), frsp S (3).
// Its result leaves the last stage (ev, for the next op's operands) and is registered (wv, for the FPRs and X). A0, S0
// and the write are each taken by one op a clock: ok says the op can go now, from what the ops in flight have reserved.
// For each FPR, the clocks until the last op in flight that writes it is done (cnt): pe / pw / pn say it isn't written by
// the end of this clock with ev / with wv / at all. A multiply-add whose addend (b) an op in flight is still making may
// issue when that comes out (ev) by the time it reaches A0 (lb): it takes it from ev on that clock. An op may write an
// FPR another in flight writes when its own write comes after (dok).
//
// The pipeline can serve two CPUs (rtl/ppc_fpx.sv): ppc_fpp_ctl is a CPU's, what it knows of its own FPRs and whether its next op
// can go, and ppc_fpp_dp the stages, shared, each result tagged with whose it is. ppc_fpp is the two together, for one CPU.
`default_nettype none
module ppc_fpp_ctl (
	input  logic        clk,
	input  logic        rst,
	input  logic        allow,          // this CPU's clock for an op
	input  logic [15:0] res_a, res_s, res_w,
	input  logic        issue,
	input  logic [4:0]  op,             // ppc_fpu_pkg::fop_t, not F_DIV(S) / F_SQRT(S) / F_RES / F_RSQRTE / F_CMP
	input  logic [4:0]  rd,
	input  logic [4:0]  rb,             // b's FPR (a multiply-add's addend, taken late)
	output logic        ok,             // op can issue this clock
	output logic        dok,            // ... as far as rd goes
	output logic        busy,           // an op of this CPU's is in flight
	output logic [2:0]  bw,             // a multiply-add's addend still to come: the clocks until it leaves its last stage
	output logic [31:0] pe, pw, pn,     // FPRs not written by this clock's end: with ev, with wv, at all
	output logic [31:0] lb              // FPRs a multiply-add's addend may be made in, b taken late
);
	import ppc_fpu_pkg::*;

	logic [3:0]  cnt [0:31];            // the clocks until the last op writing the FPR has its wv (1: this clock)
	cls_t        ik;
	logic [3:0]  a_w;
	always_comb
	begin
		ik = cls(op);
		a_w = at_w(ik);
		ok = allow && !(ik.add && res_a[at_a(ik)]) && !((ik.rs || ik.cv) && res_s[at_s(ik)]) && !res_w[a_w];
		dok = cnt[rd] < a_w + 4'd2;
		for (int f = 0; f < 32; f++)
		begin
			pe[f] = cnt[f] > 4'd2;
			pw[f] = cnt[f] > 4'd1;
			pn[f] = cnt[f] != 4'd0;
			lb[f] = cnt[f] <= 4'(LM + 2);
		end
	end
	assign busy = pn != 32'h0;
	assign bw = ik.mul && ik.add && cnt[rb] > 4'd2 ? 3'(cnt[rb] - 4'd2) : 3'd0;

	always_ff @(posedge clk)
		for (int f = 0; f < 32; f++)
			cnt[f] <= rst ? 4'd0 : issue && rd == 5'(f) ? a_w + 4'd1 : cnt[f] == 4'd0 ? 4'd0 : cnt[f] - 4'd1;
endmodule

module ppc_fpp_dp (
	input  logic        clk,
	input  logic        rst,
	input  logic        issue,
	input  logic        cpu,            // whose
	input  logic [4:0]  op,
	input  logic [1:0]  rn,
	input  logic [63:0] a, b, c,
	input  logic [4:0]  rd,
	input  logic [2:0]  i_bw,           // a multiply-add's addend: the clocks until it comes (evl), 0 if it's in b
	output logic [15:0] res_a, res_s, res_w, // the reservations: bit j, the clock j from now
	output logic        ev,             // a result leaving its last stage (for the operands): FPR erd = evl
	output logic        ecpu,
	output logic [4:0]  erd,
	output logic [63:0] evl,
	output logic        wv,             // a result: FPR wrd = wval at the clock's end
	output logic        wcpu,
	output logic [4:0]  wrd,
	output logic [63:0] wval
);
	import ppc_fpu_pkg::*;

	// what an op does
	typedef struct packed { logic v; logic cpu; cls_t k; logic [4:0] rd; logic [1:0] rn; } meta_t;

	// ---- issue: the stages the op takes ---------------------------------------------------------------------------------
	cls_t        ik;
	logic        need_s;
	assign ik = cls(op);
	assign need_s = ik.rs || ik.cv;
	meta_t im;
	assign im = '{1'b1, cpu, ik, rd, rn};

	// ---- M: a * c --------------------------------------------------------------------------------------------------
	meta_t        m0, m1, m2, m3, m4;
	logic [63:0]  m0_a, m0_c;
	logic [63:0]  m0_b, m1_b, m2_b, m3_b, m4_b;     // the add's operand, carried along ...
	logic [2:0]   m0_bw, m1_bw, m2_bw, m3_bw, m4_bw; // ... or the clocks until it comes (ev)
	logic         m1_sp, m2_sp, m3_sp, m4_sp;      // a special result (NaN, infinity, zero) ...
	logic [63:0]  m1_spv, m2_spv, m3_spv, m4_spv;  // ... this one
	logic         m1_s, m2_s, m3_s, m4_s;
	logic signed [13:0] m1_e, m2_e, m3_e, m4_e;
	logic [52:0]  m1_ma, m1_mc;                    // unnormalized, ...
	logic [5:0]   m1_ka, m1_kc;                    // ... and their shifts
	logic [51:0]  m2_hh;
	logic [52:0]  m2_hl, m2_lh;
	logic [53:0]  m2_ll;
	logic [105:0] m3_p;
	logic [55:0]  m4_sig;
	logic         m4_st;

	// M0: unpack (a denormal's shift to normalize it, and its exponent); the special cases
	logic        m0_sp;
	logic [63:0] m0_spv;
	logic [5:0]  m0_ka, m0_kc;
	logic signed [13:0] m0_e;
	always_comb
	begin
		logic sg, ai, ci, az, cz;
		logic signed [13:0] ea, ec;
		sg = m0_a[63] ^ m0_c[63];
		ai = m0_a[62:52] == 11'h7ff && m0_a[51:0] == 0;
		ci = m0_c[62:52] == 11'h7ff && m0_c[51:0] == 0;
		az = m0_a[62:0] == 0;
		cz = m0_c[62:0] == 0;
		m0_sp = 1'b1;
		if (isnan(m0_a)) m0_spv = quiet(m0_a);
		else if (isnan(m0_c)) m0_spv = quiet(m0_c);
		else if ((ai && cz) || (az && ci)) m0_spv = DNAN;
		else if (ai || ci) m0_spv = {sg, 63'h7ff0000000000000};
		else if (az || cz) m0_spv = {sg, 63'h0};
		else begin m0_sp = 1'b0; m0_spv = 64'h0; end
		m0_ka = m0_a[62:52] == 0 ? lzc56({1'b0, m0_a[51:0], 3'b000}) : 6'd0;
		m0_kc = m0_c[62:52] == 0 ? lzc56({1'b0, m0_c[51:0], 3'b000}) : 6'd0;
		ea = m0_a[62:52] == 0 ? -14'sd1022 - 14'($signed({1'b0, m0_ka})) : 14'($signed({3'b0, m0_a[62:52]}) - 1023);
		ec = m0_c[62:52] == 0 ? -14'sd1022 - 14'($signed({1'b0, m0_kc})) : 14'($signed({3'b0, m0_c[62:52]}) - 1023);
		m0_e = ea + ec;
	end
	// M1: normalized
	wire [52:0] m1_na = m1_ma << m1_ka, m1_nc = m1_mc << m1_kc;

	// M3: the product's top 56 bits, normalized, or shifted down into a denormal
	logic [55:0] m3_sig;
	logic        m3_st;
	logic signed [13:0] m3_ee;
	always_comb
	begin
		logic signed [13:0] n;
		logic [56:0] sh;
		if (m3_p[105]) begin m3_sig = m3_p[105:50]; m3_st = m3_p[49:0] != 0; m3_ee = m3_e + 14'sd1; end
		else begin m3_sig = m3_p[104:49]; m3_st = m3_p[48:0] != 0; m3_ee = m3_e; end
		n = -14'sd1022 - m3_ee;
		sh = shr_st(m3_sig, n > 14'sd63 ? 6'd63 : n[5:0]);
		if (m3_ee < -14'sd1022)
		begin
			m3_sig = sh[56:1];
			m3_st = m3_st || sh[0];
			m3_ee = -14'sd1022;
		end
	end

	// M4: the round
	wire [63:0] m_out = m4_sp ? m4_spv : rnd_d(m4_s, m4_e, m4_sig, m4_st, m4.rn);

	// ---- A: x + y (x - y) ------------------------------------------------------------------------------------------
	meta_t       a0, a1, a2, a3;
	logic [63:0] a0_x, a0_y;
	logic        a1_sp, a2_sp, a3_sp;
	logic [63:0] a1_spv, a2_spv, a3_spv;
	logic        a1_s, a2_s, a3_s;          // the result's sign (the larger operand's)
	logic        a1_sub;                    // the signs differ
	logic [52:0] a1_mb, a1_ms;              // the larger and smaller operand's significands (a denormal's unnormalized)
	logic [10:0] a1_eb, a1_d;               // the larger's exponent (1 for a denormal), the difference
	logic [56:0] a2_sum;
	logic signed [13:0] a2_e, a3_e;
	logic [10:0] a2_lim;                    // the most the sum can shift left (to a denormal, no further)
	logic [55:0] a3_sig;
	logic        a3_st;

	// A0: the special cases; the larger operand by magnitude (the raw bits compare as the magnitudes do)
	logic        a0_sp;
	logic [63:0] a0_spv;
	// verilator lint_off UNUSEDSIGNAL
	logic [63:0] a0_big, a0_sml;           // (not the smaller's sign)
	// verilator lint_on UNUSEDSIGNAL
	always_comb
	begin
		logic sy, xi, yi, xz, yz;
		logic [63:0] y;
		sy = a0_y[63] ^ a0.k.sub;
		y = {sy, a0_y[62:0]};
		xi = a0_x[62:52] == 11'h7ff && a0_x[51:0] == 0;
		yi = a0_y[62:52] == 11'h7ff && a0_y[51:0] == 0;
		xz = a0_x[62:0] == 0;
		yz = a0_y[62:0] == 0;
		a0_sp = 1'b1;
		if (isnan(a0_x)) a0_spv = quiet(a0_x);
		else if (isnan(a0_y)) a0_spv = quiet(a0_y);
		else if (xi && yi) a0_spv = a0_x[63] != sy ? DNAN : a0_x;
		else if (xi) a0_spv = a0_x;
		else if (yi) a0_spv = y;
		else if (xz && yz) a0_spv = {(a0_x[63] && sy) || (a0_x[63] != sy && a0.rn == 2'd3), 63'h0};
		else if (xz) a0_spv = y;
		else if (yz) a0_spv = a0_x;
		else begin a0_sp = 1'b0; a0_spv = 64'h0; end
		if (a0_x[62:0] >= a0_y[62:0]) begin a0_big = a0_x; a0_sml = y; end
		else begin a0_big = y; a0_sml = a0_x; end
	end
	wire [10:0] a0_eb = a0_big[62:52] == 0 ? 11'd1 : a0_big[62:52];
	wire [10:0] a0_es = a0_sml[62:52] == 0 ? 11'd1 : a0_sml[62:52];

	// A1: the smaller aligned (the bits shifted out in the last), and the sum
	logic [56:0] a1_sum;
	always_comb
	begin
		logic [56:0] sh;
		logic [55:0] sm;
		sh = shr_st({a1_ms, 3'b000}, a1_d > 11'd63 ? 6'd63 : a1_d[5:0]);
		sm = {sh[56:2], sh[1] | sh[0]};
		a1_sum = a1_sub ? {1'b0, a1_mb, 3'b000} - {1'b0, sm} : {1'b0, a1_mb, 3'b000} + {1'b0, sm};
	end

	// A2: normalize
	logic [55:0] a2_sig;
	logic        a2_st, a2_zero;
	logic signed [13:0] a2_ee;
	always_comb
	begin
		logic [5:0] lz, l;
		lz = lzc56(a2_sum[55:0]);
		l = {5'h0, lz} > a2_lim ? a2_lim[5:0] : lz;
		a2_zero = a2_sum == 0;
		if (a2_sum[56]) begin a2_sig = a2_sum[56:1]; a2_st = a2_sum[0]; a2_ee = a2_e + 14'sd1; end
		else begin a2_sig = a2_sum[55:0] << l; a2_st = 1'b0; a2_ee = a2_e - 14'($signed({1'b0, l})); end
	end

	// A3: the round (fnmadd: then negated)
	wire [63:0] a3_r = a3_sp ? a3_spv : rnd_d(a3_s, a3_e, a3_sig, a3_st, a3.rn);
	wire [63:0] a_out = a3.k.neg ? a3_r ^ 64'h8000000000000000 : a3_r;

	// ---- S: the round to single, or the conversion to an integer ---------------------------------------------------
	meta_t       s0, s1, s2;
	logic [63:0] s0_v;
	rsb_t        s2_rs;
	logic        s1_cvsp, s2_cvsp;          // fctiw: a special result (0, 0x80000000) ...
	logic [31:0] s1_cvspv, s2_cvspv;
	logic        s1_cvs, s2_cvs;
	logic        s1_tiny;                   // ... under 2^-2: 0 and the sticky bit
	logic [52:0] s1_cvm;
	logic [5:0]  s1_cvsh;                   // ... the right shift to the integer
	logic [33:0] s2_mag;
	logic        s2_inc;
	rsa_t        s1_rs;

	// S0
	rsa_t        s0_rs;
	logic        s0_cvsp, s0_tiny;
	logic [31:0] s0_cvspv;
	logic [5:0]  s0_cvsh;
	always_comb
	begin
		logic signed [13:0] e;
		s0_rs = rs_d(s0_v, s0.rn);
		e = 14'($signed({3'b0, s0_v[62:52]}) - 1023);
		s0_cvsp = 1'b1; s0_cvspv = 32'h80000000; s0_tiny = 1'b0;
		s0_cvsh = 6'(14'sd52 - e);
		if (s0_v[62:52] == 11'h7ff) ;
		else if (s0_v[62:0] == 0) s0_cvspv = 32'h0;
		else if (e >= 14'sd32) ;
		else
		begin
			s0_cvsp = 1'b0;
			s0_tiny = s0_v[62:52] == 0 || e < -14'sd2;
		end
	end

	// S1
	rsb_t        s1_rsb;
	logic [33:0] s1_mag;
	logic        s1_inc;
	always_comb
	begin
		logic r, st;
		logic [1:0] md;
		logic [63:0] m;
		s1_rsb = rs_b(s1_rs, s1.rn);
		m = {11'h0, s1_cvm};
		if (s1_tiny) begin s1_mag = 34'h0; r = 1'b0; st = 1'b1; end
		else
		begin
			s1_mag = 34'(m >> s1_cvsh);
			r = m[s1_cvsh - 6'd1];
			st = 1'b0;
			for (int i = 0; i < 63; i++) if (i < int'(s1_cvsh) - 1 && m[i]) st = 1'b1;
		end
		md = s1.k.cvz ? 2'd1 : s1.rn;
		case (md)
			2'd0: s1_inc = r && (st || s1_mag[0]);
			2'd1: s1_inc = 1'b0;
			2'd2: s1_inc = !s1_cvs && (r || st);
			default: s1_inc = s1_cvs && (r || st);
		endcase
	end

	// S2
	logic [63:0] s_out;
	always_comb
	begin
		logic [33:0] mag;
		logic [31:0] iv;
		mag = s2_mag + 34'(s2_inc);
		if (s2_cvsp) iv = s2_cvspv;
		else if (s2_cvs) iv = mag > 34'h80000000 ? 32'h80000000 : 32'(-mag);
		else iv = mag >= 34'h80000000 ? 32'h80000000 : mag[31:0];
		s_out = s2.k.cv ? {32'h0, iv} : rs_c(s2_rs, s2.rn);
	end

	// the result: the op whose last stage this is
	always_comb
	begin
		ev = 1'b0; ecpu = s2.cpu; erd = s2.rd; evl = s_out;
		if (s2.v) ev = 1'b1;
		else if (a3.v && !a3.k.rs && !a3.k.cv) begin ev = 1'b1; ecpu = a3.cpu; erd = a3.rd; evl = a_out; end
		else if (m4.v && !m4.k.add && !m4.k.rs && !m4.k.cv) begin ev = 1'b1; ecpu = m4.cpu; erd = m4.rd; evl = m_out; end
	end

	always_ff @(posedge clk)
	begin
		if (rst)
		begin
			m0.v <= 1'b0; m1.v <= 1'b0; m2.v <= 1'b0; m3.v <= 1'b0; m4.v <= 1'b0;
			a0.v <= 1'b0; a1.v <= 1'b0; a2.v <= 1'b0; a3.v <= 1'b0;
			s0.v <= 1'b0; s1.v <= 1'b0; s2.v <= 1'b0;
			wv <= 1'b0;
			res_a <= '0; res_s <= '0; res_w <= '0;
			m0_bw <= 3'd0;
		end
		else
		begin
			// M
			m0.v <= 1'b0;
			if (issue && ik.mul) begin m0 <= im; m0_a <= a; m0_c <= c; m0_b <= b; m0_bw <= i_bw; end
			m1 <= m0; m1_sp <= m0_sp; m1_spv <= m0_spv;
			m1_s <= m0_a[63] ^ m0_c[63]; m1_e <= m0_e;
			m1_ma <= {m0_a[62:52] != 0, m0_a[51:0]}; m1_mc <= {m0_c[62:52] != 0, m0_c[51:0]}; m1_ka <= m0_ka; m1_kc <= m0_kc;
			m2 <= m1; m2_sp <= m1_sp; m2_spv <= m1_spv; m2_s <= m1_s; m2_e <= m1_e;
			m2_hh <= m1_na[52:27] * m1_nc[52:27];
			m2_hl <= m1_na[52:27] * m1_nc[26:0];
			m2_lh <= m1_na[26:0] * m1_nc[52:27];
			m2_ll <= m1_na[26:0] * m1_nc[26:0];
			m3 <= m2; m3_sp <= m2_sp; m3_spv <= m2_spv; m3_s <= m2_s; m3_e <= m2_e;
			m3_p <= {m2_hh, 54'h0} + ({52'h0, {1'b0, m2_hl} + {1'b0, m2_lh}} << 27) + {52'h0, m2_ll};
			m4 <= m3; m4_sp <= m3_sp; m4_spv <= m3_spv; m4_s <= m3_s;
			m4_e <= m3_ee; m4_sig <= m3_sig; m4_st <= m3_st;
			// the addend through M: taken from ev on the clock it comes
			m1_b <= m0_bw == 3'd1 ? evl : m0_b; m1_bw <= m0_bw == 3'd0 ? 3'd0 : m0_bw - 3'd1;
			m2_b <= m1_bw == 3'd1 ? evl : m1_b; m2_bw <= m1_bw == 3'd0 ? 3'd0 : m1_bw - 3'd1;
			m3_b <= m2_bw == 3'd1 ? evl : m2_b; m3_bw <= m2_bw == 3'd0 ? 3'd0 : m2_bw - 3'd1;
			m4_b <= m3_bw == 3'd1 ? evl : m3_b; m4_bw <= m3_bw == 3'd0 ? 3'd0 : m3_bw - 3'd1;

			// A0: from M4 (after a product), or issued
			a0.v <= 1'b0;
			if (m4.v && m4.k.add)
			begin
				logic [63:0] bv;
				bv = m4_bw == 3'd1 ? evl : m4_b;
				a0 <= m4;
				a0_x <= m4.k.swap ? bv : m_out;
				a0_y <= m4.k.swap ? m_out : bv;
			end
			else if (issue && ik.add && !ik.mul)
			begin
				a0 <= im; a0_x <= a; a0_y <= b;
			end
			a1 <= a0; a1_sp <= a0_sp; a1_spv <= a0_spv; a1_s <= a0_big[63]; a1_sub <= a0_x[63] != (a0_y[63] ^ a0.k.sub);
			a1_mb <= {a0_big[62:52] != 0, a0_big[51:0]}; a1_ms <= {a0_sml[62:52] != 0, a0_sml[51:0]};
			a1_eb <= a0_eb; a1_d <= a0_eb - a0_es;
			a2 <= a1; a2_sp <= a1_sp; a2_spv <= a1_spv; a2_s <= a1_s; a2_sum <= a1_sum;
			a2_e <= 14'($signed({3'b0, a1_eb}) - 1023); a2_lim <= a1_eb - 11'd1;
			a3 <= a2; a3_s <= a2_s; a3_e <= a2_ee; a3_sig <= a2_sig; a3_st <= a2_st;
			a3_sp <= a2_sp || a2_zero;
			a3_spv <= a2_sp ? a2_spv : {a2.rn == 2'd3, 63'h0};

			// S0: from A3, M4 or issued
			s0.v <= 1'b0;
			if (a3.v && (a3.k.rs || a3.k.cv)) begin s0 <= a3; s0_v <= a_out; end
			else if (m4.v && !m4.k.add && (m4.k.rs || m4.k.cv)) begin s0 <= m4; s0_v <= m_out; end
			else if (issue && !ik.mul && !ik.add && need_s) begin s0 <= im; s0_v <= b; end
			s1 <= s0; s1_rs <= s0_rs;
			s1_cvsp <= s0_cvsp; s1_cvspv <= s0_cvspv; s1_cvs <= s0_v[63]; s1_tiny <= s0_tiny;
			s1_cvm <= {1'b1, s0_v[51:0]}; s1_cvsh <= s0_cvsh;
			s2 <= s1; s2_rs <= s1_rsb;
			s2_cvsp <= s1_cvsp; s2_cvspv <= s1_cvspv; s2_cvs <= s1_cvs; s2_mag <= s1_mag; s2_inc <= s1_inc;

			wv <= ev; wcpu <= ecpu; wrd <= erd; wval <= evl;

			// the reservations move a clock on
			res_a <= (res_a | (issue && ik.add ? 16'h1 << at_a(ik) : 16'h0)) >> 1;
			res_s <= (res_s | (issue && need_s ? 16'h1 << at_s(ik) : 16'h0)) >> 1;
			res_w <= (res_w | (issue ? 16'h1 << at_w(ik) : 16'h0)) >> 1;
		end
	end
endmodule

// the two together, for one CPU
module ppc_fpp (
	input  logic        clk,
	input  logic        rst,
	input  logic        issue,
	input  logic [4:0]  op,
	input  logic [1:0]  rn,
	input  logic [63:0] a, b, c,
	input  logic [4:0]  rd,
	input  logic [4:0]  rb,
	output logic        ok,
	output logic        dok,
	output logic        busy,
	output logic        ev,
	output logic [4:0]  erd,
	output logic [63:0] evl,
	output logic        wv,
	output logic [4:0]  wrd,
	output logic [63:0] wval,
	output logic [31:0] pe, pw, pn,
	output logic [31:0] lb
);
	logic [15:0] res_a, res_s, res_w;
	logic [2:0]  bw;
	// verilator lint_off UNUSEDSIGNAL
	logic        ecpu, wcpu;
	// verilator lint_on UNUSEDSIGNAL
	ppc_fpp_ctl ctl (.clk, .rst, .allow(1'b1), .res_a, .res_s, .res_w, .issue, .op, .rd, .rb, .ok, .dok, .busy, .bw, .pe, .pw, .pn, .lb);
	ppc_fpp_dp dp (.clk, .rst, .issue, .cpu(1'b0), .op, .rn, .a, .b, .c, .rd, .i_bw(bw), .res_a, .res_s, .res_w,
		.ev, .ecpu, .erd, .evl, .wv, .wcpu, .wrd, .wval);
endmodule
