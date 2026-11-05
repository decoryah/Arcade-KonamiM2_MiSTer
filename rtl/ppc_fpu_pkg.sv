// The PPC602 float unit's operations (rtl/ppc_fpu.sv), and its arithmetic as functions (rtl/ppc_pipe.sv uses the conversions).
package ppc_fpu_pkg;
	typedef enum logic [4:0] {
		// double: a op b, a * c, a * c op b
		F_ADD, F_SUB, F_MUL, F_DIV, F_SQRT, F_RSQRTE, F_MADD, F_MSUB, F_NMADD, F_NMSUB,
		// the same in double steps, then a round to single (MAME's PPCDRC_ACCURATE_SINGLES); F_RES: 1 / b in single
		F_ADDS, F_SUBS, F_MULS, F_DIVS, F_SQRTS, F_RES, F_MADDS, F_MSUBS, F_NMADDS, F_NMSUBS,
		F_RSP,      // b rounded to single, as a double
		F_CTIW,     // b to a 32-bit integer in the rounding mode (0x80000000 if NaN or out of range), zero-extended
		F_CTIWZ,    // the same, truncating
		F_CMP,      // a against b: crf LT GT EQ UN
		F_D2S,      // a to single (stfs): the single's bits in res[31:0]
		F_S2D       // a[31:0], a single, to double (lfs)
	} fop_t;

	localparam logic [63:0] DNAN = 64'hfff8000000000000, ONE = 64'h3ff0000000000000;

	// ---- the float pipeline's op classes (rtl/ppc_fpp.sv) ---------------------------------------------------------------
	localparam int LM = 5, LA = 4, LS = 3;  // its units' stages
	typedef struct packed {
		logic mul;                      // a * c first
		logic add;                      // then (or only) an add
		logic sub;                      // ... a subtract
		logic swap;                     // ... b - the product (fnmsub)
		logic neg;                      // ... negated (fnmadd)
		logic rs;                       // then a round to single
		logic cv, cvz;                  // or a conversion to an integer (truncating)
	} cls_t;
	function automatic cls_t cls(input logic [4:0] o);
		cls_t k;
		k = '0;
		case (fop_t'(o))
			F_ADD, F_ADDS:     k.add = 1'b1;
			F_SUB, F_SUBS:     begin k.add = 1'b1; k.sub = 1'b1; end
			F_MUL, F_MULS:     k.mul = 1'b1;
			F_MADD, F_MADDS:   begin k.mul = 1'b1; k.add = 1'b1; end
			F_MSUB, F_MSUBS:   begin k.mul = 1'b1; k.add = 1'b1; k.sub = 1'b1; end
			F_NMADD, F_NMADDS: begin k.mul = 1'b1; k.add = 1'b1; k.neg = 1'b1; end
			F_NMSUB, F_NMSUBS: begin k.mul = 1'b1; k.add = 1'b1; k.sub = 1'b1; k.swap = 1'b1; end
			F_CTIW:            k.cv = 1'b1;
			F_CTIWZ:           begin k.cv = 1'b1; k.cvz = 1'b1; end
			default: ;
		endcase
		case (fop_t'(o))
			F_ADDS, F_SUBS, F_MULS, F_MADDS, F_MSUBS, F_NMADDS, F_NMSUBS, F_RSP: k.rs = 1'b1;
			default: ;
		endcase
		return k;
	endfunction
	// the clocks from an op's issue until it enters A0 and S0 and is written
	// verilator lint_off UNUSEDSIGNAL
	function automatic logic [3:0] at_a(input cls_t k);
		return k.mul ? 4'(LM + 1) : 4'd1;
	endfunction
	function automatic logic [3:0] at_s(input cls_t k);
		return 4'd1 + (k.mul ? 4'(LM) : 4'd0) + (k.add ? 4'(LA) : 4'd0);
	endfunction
	function automatic logic [3:0] at_w(input cls_t k);
		return (k.mul ? 4'(LM) : 4'd0) + (k.add ? 4'(LA) : 4'd0) + (k.rs || k.cv ? 4'(LS) : 4'd0);
	endfunction
	// verilator lint_on UNUSEDSIGNAL

	// ---- a CPU and the float units it may share (rtl/ppc_fpx.sv) ---------------------------------------------------------
	typedef struct packed {
		logic        issue;             // to the pipeline
		logic        start;             // to the iterative unit
		logic [4:0]  op;
		logic [1:0]  rn;
		logic [63:0] a, b, c;
		logic [4:0]  rd;
		logic [2:0]  bw;                // a multiply-add's addend: the clocks until it comes (ev), 0 if it's in b
	} fp_req_t;
	typedef struct packed {
		logic [1:0]  allow;             // whose op may go this clock
		logic [15:0] res_a, res_s, res_w; // the pipeline's reservations: bit j, the clock j from now
		logic        ev;                // a result leaving its last stage: FPR erd = evl, ecpu's
		logic        ecpu;
		logic [4:0]  erd;
		logic [63:0] evl;
		logic        wv;                // a result: FPR wrd = wval at the clock's end, wcpu's
		logic        wcpu;
		logic [4:0]  wrd;
		logic [63:0] wval;
		logic        ffree;             // the iterative unit can start one
		logic        fdone;             // it's done, fcpu's
		logic        fcpu;
		logic [63:0] fres;
	} fp_res_t;

	// an unpacked finite value: (-1)^s * m * 2^(e - 52), m normalized (m[52] set) unless zero
	typedef struct packed { logic nan, inf, zero, s; logic signed [13:0] e; logic [52:0] m; } unp_t;

	// the unpacked values' flags aren't all used everywhere
	// verilator lint_off UNUSEDSIGNAL
	function automatic logic isnan(input logic [63:0] x);
		return x[62:52] == 11'h7ff && x[51:0] != 0;
	endfunction
	function automatic logic [63:0] quiet(input logic [63:0] x);
		return x | 64'h0008000000000000;
	endfunction

	function automatic unp_t unpack_d(input logic [63:0] x);
		unp_t u;
		int k;
		u = '0;
		u.s = x[63];
		if (x[62:52] == 11'h7ff)
		begin
			u.nan = x[51:0] != 0;
			u.inf = x[51:0] == 0;
		end
		else if (x[62:52] == 0)
		begin
			if (x[51:0] == 0) u.zero = 1'b1;
			else
			begin
				// a denormal: normalize
				k = 0;
				for (int i = 51; i >= 0; i--) if (x[i] && k == 0) k = 52 - i;
				u.m = {1'b0, x[51:0]} << k;
				u.e = 14'(-1022 - k);
			end
		end
		else
		begin
			u.m = {1'b1, x[51:0]};
			u.e = 14'($signed({3'b0, x[62:52]}) - 1023);
		end
		return u;
	endfunction

	// round (-1)^s * sig * 2^(e - 55) (sig[55] set, or zero with st) to double, or to single ({32'h0, the single})
	function automatic logic [63:0] round_pack(input logic s, input logic signed [13:0] e_in, input logic [55:0] sig_in,
		input logic st_in, input logic sgl, input logic [1:0] mode);
		logic signed [13:0] e, emin, emax;
		logic [55:0] sig;
		logic [53:0] kept;
		logic st, r, inc, ovf;
		int sh;
		e = e_in; sig = sig_in; st = st_in;
		emin = sgl ? -14'sd126 : -14'sd1022;
		emax = sgl ? 14'sd127 : 14'sd1023;
		if (e < emin)
		begin
			// below the normal range: a denormal, shifted down with the bits it loses in the sticky bit
			sh = int'(emin) - int'(e);
			if (sh > 57) sh = 57;
			for (int i = 0; i < 56; i++) if (i < sh && sig[i]) st = 1'b1;
			sig = sh >= 56 ? 56'h0 : sig >> sh;
			e = emin;
		end
		if (sgl)
		begin
			kept = {30'h0, sig[55:32]};
			r = sig[31];
			st = st | (sig[30:0] != 0);
		end
		else
		begin
			kept = {1'b0, sig[55:3]};
			r = sig[2];
			st = st | (sig[1:0] != 0);
		end
		case (mode)
			2'd0: inc = r && (st || kept[0]);
			2'd1: inc = 1'b0;
			2'd2: inc = !s && (r || st);
			default: inc = s && (r || st);
		endcase
		kept = kept + 54'(inc);
		if (sgl ? kept[24] : kept[53])
		begin
			kept = kept >> 1;
			e = e + 14'sd1;
		end
		ovf = e > emax;
		if (sgl)
		begin
			logic [7:0] be;
			if (ovf)
				// overflow: infinity, or the largest finite value when rounding toward zero or away from that sign
				return (mode == 2'd1 || (mode == 2'd2 && s) || (mode == 2'd3 && !s)) ? {32'h0, s, 31'h7f7fffff} :
					{32'h0, s, 31'h7f800000};
			be = kept[23] ? 8'(e + 14'sd127) : 8'h0;
			return {32'h0, s, be, kept[22:0]};
		end
		else
		begin
			logic [10:0] be;
			if (ovf)
				return (mode == 2'd1 || (mode == 2'd2 && s) || (mode == 2'd3 && !s)) ? {s, 63'h7fefffffffffffff} :
					{s, 63'h7ff0000000000000};
			be = kept[52] ? 11'(e + 14'sd1023) : 11'h0;
			return {s, be, kept[51:0]};
		end
	endfunction

	// cvtss2sd: exact; a NaN is quieted
	function automatic logic [63:0] s2d(input logic [31:0] x);
		int k;
		if (x[30:23] == 8'hff)
			return x[22:0] != 0 ? {x[31], 11'h7ff, 1'b1, x[21:0], 29'h0} : {x[31], 63'h7ff0000000000000};
		if (x[30:0] == 0) return {x[31], 63'h0};
		if (x[30:23] == 0)
		begin
			k = 0;
			for (int i = 22; i >= 0; i--) if (x[i] && k == 0) k = 23 - i;
			return round_pack(x[31], 14'(-126 - k), {{1'b0, x[22:0]} << k, 32'h0}, 1'b0, 1'b0, 2'd0);
		end
		return round_pack(x[31], 14'($signed({6'b0, x[30:23]}) - 127), {1'b1, x[22:0], 32'h0}, 1'b0, 1'b0, 2'd0);
	endfunction

	// cvtsd2ss in the rounding mode; a NaN keeps its sign and top payload bits, quieted
	function automatic logic [31:0] d2s(input logic [63:0] x, input logic [1:0] mode);
		unp_t u;
		logic [63:0] p;
		u = unpack_d(x);
		if (u.nan) return {x[63], 8'hff, 1'b1, x[50:29]};
		if (u.inf) return {x[63], 31'h7f800000};
		if (u.zero) return {x[63], 31'h0};
		p = round_pack(u.s, u.e, {u.m, 3'b0}, 1'b0, 1'b1, mode);
		return p[31:0];
	endfunction

	// a + (sub ? -y : y)
	function automatic logic [63:0] add(input logic [63:0] x, input logic [63:0] y, input logic sub, input logic [1:0] mode);
		unp_t ux, uy, big, sml;
		logic [109:0] fb, fs;
		logic [110:0] sum, nrm;
		logic st;
		int d, l;
		if (isnan(x)) return quiet(x);
		if (isnan(y)) return quiet(y);
		ux = unpack_d(x);
		uy = unpack_d(y);
		uy.s = uy.s ^ sub;
		if (ux.inf && uy.inf) return ux.s != uy.s ? DNAN : x;
		if (ux.inf) return x;
		if (uy.inf) return {uy.s, y[62:0]};
		if (ux.zero && uy.zero) return {(ux.s && uy.s) || (ux.s != uy.s && mode == 2'd3), 63'h0};
		if (ux.zero) return {uy.s, y[62:0]};
		if (uy.zero) return x;
		if (ux.e > uy.e || (ux.e == uy.e && ux.m >= uy.m)) begin big = ux; sml = uy; end
		else begin big = uy; sml = ux; end
		d = int'(big.e) - int'(sml.e);
		fb = {big.m, 57'h0};
		fs = {sml.m, 57'h0};
		st = 1'b0;
		if (d >= 110)
		begin
			fs = 110'h0;
			st = 1'b1;
		end
		else
		begin
			for (int i = 0; i < 110; i++) if (i < d && fs[i]) st = 1'b1;
			fs = fs >> d;
		end
		fs[0] = fs[0] | st;
		sum = big.s != sml.s ? {1'b0, fb} - {1'b0, fs} : {1'b0, fb} + {1'b0, fs};
		if (sum == 0) return {mode == 2'd3, 63'h0};
		l = 0;
		for (int i = 0; i < 111; i++) if (sum[i]) l = i;
		nrm = sum << (110 - l);
		return round_pack(big.s, 14'(big.e + 14'(l - 109)), nrm[110:55], nrm[54:0] != 0, 1'b0, mode);
	endfunction

	function automatic logic [63:0] mul(input logic [63:0] x, input logic [63:0] y, input logic [1:0] mode);
		unp_t ux, uy;
		logic [105:0] p;
		logic s;
		if (isnan(x)) return quiet(x);
		if (isnan(y)) return quiet(y);
		ux = unpack_d(x);
		uy = unpack_d(y);
		s = ux.s ^ uy.s;
		if ((ux.inf && uy.zero) || (ux.zero && uy.inf)) return DNAN;
		if (ux.inf || uy.inf) return {s, 63'h7ff0000000000000};
		if (ux.zero || uy.zero) return {s, 63'h0};
		p = ux.m * uy.m;
		if (p[105]) return round_pack(s, ux.e + uy.e + 14'sd1, p[105:50], p[49:0] != 0, 1'b0, mode);
		return round_pack(s, ux.e + uy.e, p[104:49], p[48:0] != 0, 1'b0, mode);
	endfunction

	// the integer conversion (cvtsd2si / cvttsd2si into a 32-bit register): 0x80000000 if NaN or out of range
	function automatic logic [31:0] d2i(input logic [63:0] x, input logic [1:0] mode);
		unp_t u;
		logic [63:0] m;
		logic [33:0] mag;
		logic r, st, inc;
		int sh;
		u = unpack_d(x);
		if (u.nan || u.inf) return 32'h80000000;
		if (u.zero) return 32'h0;
		if (u.e >= 32) return 32'h80000000;
		m = {11'h0, u.m};
		if (u.e < -2)
		begin
			mag = 34'h0;
			r = 1'b0;
			st = 1'b1;
		end
		else
		begin
			sh = 52 - int'(u.e);
			mag = 34'(m >> sh);
			r = m[sh - 1];
			st = 1'b0;
			for (int i = 0; i < 63; i++) if (i < sh - 1 && m[i]) st = 1'b1;
		end
		case (mode)
			2'd0: inc = r && (st || mag[0]);
			2'd1: inc = 1'b0;
			2'd2: inc = !u.s && (r || st);
			default: inc = u.s && (r || st);
		endcase
		mag = mag + 34'(inc);
		if (u.s) return mag > 34'h80000000 ? 32'h80000000 : 32'(-mag);
		return mag >= 34'h80000000 ? 32'h80000000 : mag[31:0];
	endfunction

	// ---- the same arithmetic in steps short enough for a clock (rtl/ppc_fpp.sv, rtl/ppc_fpu.sv) ------------------------
	// leading zeros of a 56-bit value
	function automatic logic [5:0] lzc56(input logic [55:0] v);
		logic [5:0] n;
		n = 6'd56;
		for (int i = 0; i < 56; i++) if (v[i]) n = 6'(55 - i);
		return n;
	endfunction
	// sig >> n, and whether the bits shifted out had a one
	function automatic logic [56:0] shr_st(input logic [55:0] sig, input logic [5:0] n);
		logic st;
		st = 1'b0;
		for (int i = 0; i < 56; i++) if (i < int'(n) && sig[i]) st = 1'b1;
		return {n >= 6'd56 ? 56'h0 : sig >> n, st};
	endfunction

	// an overflow in the mode: infinity, or the largest finite value when rounding toward zero or away from the sign
	function automatic logic ovf_max(input logic s, input logic [1:0] mode);
		return mode == 2'd1 || (mode == 2'd2 && s) || (mode == 2'd3 && !s);
	endfunction
	// round (-1)^s * sig * 2^(e - 55) to double: sig[55] set, or e = -1022 and sig a denormal's (already shifted); st the
	// bits below sig (round_pack without its denormal shift)
	function automatic logic [63:0] rnd_d(input logic s, input logic signed [13:0] e, input logic [55:0] sig, input logic st,
		input logic [1:0] mode);
		logic [53:0] kept;
		logic r, sk, inc;
		logic signed [13:0] ee;
		kept = {1'b0, sig[55:3]};
		r = sig[2];
		sk = st || sig[1:0] != 2'b00;
		case (mode)
			2'd0: inc = r && (sk || kept[0]);
			2'd1: inc = 1'b0;
			2'd2: inc = !s && (r || sk);
			default: inc = s && (r || sk);
		endcase
		kept = kept + 54'(inc);
		ee = e;
		if (kept[53])
		begin
			kept = kept >> 1;
			ee = e + 14'sd1;
		end
		if (ee > 14'sd1023) return ovf_max(s, mode) ? {s, 63'h7fefffffffffffff} : {s, 63'h7ff0000000000000};
		return {s, kept[52] ? 11'(ee + 14'sd1023) : 11'h0, kept[51:0]};
	endfunction

	// the round to single and back (cvtsd2ss then cvtss2sd), in three steps: the value (-1)^s * m * 2^(e - 52), m[52] set,
	// with st the bits below m; the result a double, the single exactly. The single's last bit is m's bit p: 29, or more
	// for a single denormal, so no shift is needed.
	typedef struct packed { logic sp; logic [63:0] spv; logic s; logic signed [13:0] e; logic [52:0] m; logic st;
		logic [5:0] p; } rsa_t;
	typedef struct packed { logic sp; logic [63:0] spv; logic s; logic signed [13:0] e; logic [53:0] mk, inc; } rsb_t;
	function automatic rsa_t rs_a(input logic s, input logic signed [13:0] e, input logic [52:0] m, input logic st,
		input logic [1:0] mode);
		rsa_t x;
		x.sp = 1'b0; x.spv = 64'h0; x.s = s; x.e = e; x.m = m; x.st = st;
		x.p = e >= -14'sd126 ? 6'd29 : e >= -14'sd150 ? 6'(-14'sd97 - e) : 6'd53;
		// below half the least single denormal: 0, or that denormal when rounding away
		if (e < -14'sd150) begin x.sp = 1'b1; x.spv = {s, ovf_max(!s, mode) && mode != 2'd1 ? 63'h36a0000000000000 : 63'h0}; end
		return x;
	endfunction
	// the same from a double (frsp, a single op's last step); a NaN keeps its sign and top payload bits, quieted
	function automatic rsa_t rs_d(input logic [63:0] v, input logic [1:0] mode);
		rsa_t x;
		x = rs_a(v[63], 14'($signed({3'b0, v[62:52]}) - 1023), {1'b1, v[51:0]}, 1'b0, mode);
		if (v[62:52] == 11'h7ff) begin x.sp = 1'b1; x.spv = v[51:0] != 0 ? {v[63], 11'h7ff, 1'b1, v[50:29], 29'h0} : v; end
		else if (v[62:52] == 11'h0)
		begin
			// zero, or a double denormal (far below the singles)
			x.sp = 1'b1;
			x.spv = {v[63], v[51:0] != 0 && ovf_max(!v[63], mode) && mode != 2'd1 ? 63'h36a0000000000000 : 63'h0};
		end
		return x;
	endfunction
	function automatic rsb_t rs_b(input rsa_t x, input logic [1:0] mode);
		rsb_t y;
		logic [53:0] m, mask;
		logic r, sk, lsb, inc;
		m = {1'b0, x.m};
		mask = (54'h1 << x.p) - 54'h1;
		r = m[x.p - 6'd1];
		sk = x.st || (m & (mask >> 1)) != 0;
		lsb = m[x.p];
		case (mode)
			2'd0: inc = r && (sk || lsb);
			2'd1: inc = 1'b0;
			2'd2: inc = !x.s && (r || sk);
			default: inc = x.s && (r || sk);
		endcase
		y.sp = x.sp; y.spv = x.spv; y.s = x.s; y.e = x.e;
		y.mk = m & ~mask;
		y.inc = inc ? 54'h1 << x.p : 54'h0;
		return y;
	endfunction
	function automatic logic [63:0] rs_c(input rsb_t y, input logic [1:0] mode);
		logic [53:0] v;
		logic signed [13:0] e;
		if (y.sp) return y.spv;
		v = y.mk + y.inc;
		e = y.e;
		if (v == 0) return {y.s, 63'h0};
		if (v[53])
		begin
			v = v >> 1;
			e = e + 14'sd1;
		end
		if (e > 14'sd127) return ovf_max(y.s, mode) ? {y.s, 63'h47efffffe0000000} : {y.s, 63'h7ff0000000000000};
		return {y.s, 11'(e + 14'sd1023), v[51:0]};
	endfunction

	function automatic logic [3:0] cmp(input logic [63:0] x, input logic [63:0] y);
		logic signed [64:0] kx, ky;
		if (isnan(x) || isnan(y)) return 4'b0001;
		kx = x[63] ? -$signed({2'b0, x[62:0]}) : $signed({2'b0, x[62:0]});
		ky = y[63] ? -$signed({2'b0, y[62:0]}) : $signed({2'b0, y[62:0]});
		return kx < ky ? 4'b1000 : kx > ky ? 4'b0100 : 4'b0010;
	endfunction

	// verilator lint_on UNUSEDSIGNAL
endpackage
