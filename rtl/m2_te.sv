// m2_te: the BDA's Triangle Engine, what MAME 0.289 makes of it (3dom2_te.cpp), the same sums wherever they show in the pixels:
//
//   the list      instructions from memory at IRP: register writes (a line buffer's worth of memory at a time) and vertices
//   setup         a triangle's slopes in single precision, the same order of operations as MAME's C (te_fadd, te_fmul); X and Y are whole
//                 numbers from the start, so the edge steps are integers
//   the walk      edges, then spans, handing pixels to a pipeline: Z first, as nothing else matters if it fails
//   texture       perspective (the ROM's first guess, one Newton-Raphson step), TRAM and the palette (PIP), point or bilinear, the blend
//                 with the iterated colour
//   destination   source and Z through write-back caches (te_cache), the blend, the discards, the writes; a list that stops flushes them
//
// Only the texture loads that the game's lists use: MMDMA, PIPLOAD. No compressed load (not seen in a list so far). A value that a span's
// first pixel has made negative goes to the texture sums as if 0, where MAME's are unsigned.
`default_nettype none

// The Z buffer's size in 8 KB blocks, from the block a game's Z starts in (a qsf VERILOG_MACRO can change it). At 16 bits a pixel: Polystars 320 x 224,
// Total Vice and Evil Night 320 x 240, all within 20. Heat of Eleven's Low Res 640 x 240 takes 38, Hell Night's 512 x 384 takes 48.
`ifndef Z_BLOCKS
`define Z_BLOCKS 20
`endif
module m2_te (
	input  logic        clk,
	input  logic        rst,

	// the registers, 0x00040000 +: a read's value in the clock of its address
	input  logic [15:2] a,
	input  logic        we,
	input  logic [31:0] wd,
	output logic [31:0] rd,

	output logic [4:0]  intr,           // the lines' levels: general, deferred, immediate, list end, window clip

	// memory
	output logic        m_rd,           // (4 words)
	output logic        m_we,           // (one)
	output logic [31:3] m_a,
	output logic [63:0] m_wd,
	output logic [7:0]  m_be,
	input  logic        m_busy,
	input  logic        m_ready,
	input  logic [63:0] m_dout,

	output logic        busy
);
	// verilator lint_off UNUSEDSIGNAL
	typedef logic signed [26:0] val_t;
	localparam int A_R = 0, A_G = 1, A_B = 2, A_A = 3, A_UW = 4, A_VW = 5, A_W = 6;

	typedef enum logic [6:0] {
		I_STOP, I_FLUSH, I_FETCH, I_REGS, I_REGW, I_AFTER, T_LOAD, T_MM,
		V_NEXT, V_FIELD, V_DONE,
		S_SORT, S_AR, S_FD, S_FDE, S_DIV0, S_DIV1, S_DIV2, S_XYS, S_FC,
		S_ATTR, S_Q1, S_Q2, S_Q3, S_Q4, S_OP, S_FX1, S_JOB,
		E_START, E_NEXT,
		P_RUN
	} st_t;
	st_t         st;
	assign busy = st != I_STOP;

	// ---- the registers --------------------------------------------------------------------------------------------------
	logic [31:0] gc_master, gc_idata, gc_ddata, gc_dcntl, gc_iwp, gc_irp, gc_ien, gc_ist;
	logic [2:0]  es_cntl;
	logic [31:0] tm_cntl, tm_ldcntl, tm_addr, tm_pip, tm_tab, tm_lod0, tm_src, tm_count, tm_uvmax, tm_uvmask, tm_exp;
	logic [31:0] tm_c0, tm_c1, tm_c2, tm_c3;
	logic [31:0] db_super, db_user, db_discard, db_fbclip, db_xwin, db_ywin, db_dctl, db_dbase, db_dstride, db_sctl, db_sbase, db_sstride,
		db_soff, db_zctl, db_zbase, db_zoff, db_zclip, db_ssb, db_constin, db_tmul, db_tc0, db_tc1, db_smul, db_sc0, db_sc1, db_alu,
		db_sa, db_da, db_dac, db_dma, db_dmb;

	function automatic logic [31:0] md(input logic [31:0] r, input logic [31:0] d, input logic [1:0] m);
		case (m)
			2'd0: return d;
			2'd2: return r | d;
			2'd3: return r & ~d;
			default: return r;
		endcase
	endfunction

	logic        ls_we;                 // the list's register write (a CPU's in the same clock is lost: it doesn't write while a list runs)
	logic [15:2] ls_a;
	logic [31:0] ls_d;
	wire         r_we = ls_we || we;
	wire  [15:2] r_a = ls_we ? ls_a : a;
	wire  [31:0] r_d = ls_we ? ls_d : wd;
	wire  [2:0]  r_unit = r_a[15:13];
	wire  [1:0]  r_mode = r_a[12:11];
	wire  [8:0]  r_reg = r_a[10:2];
	wire  [31:0] ic_new = md(32'h0, r_d, r_mode);

	always_comb
	begin
		rd = 32'h0;
		if (a[15:13] == 3'd0)
			case (a[10:2])
				9'd0: rd = gc_master;
				9'd2: rd = gc_idata;
				9'd4: rd = gc_ddata;
				9'd5: rd = gc_dcntl;
				9'd6: rd = gc_iwp;
				9'd7: rd = gc_irp;
				9'd8: rd = gc_ien;
				9'd9: rd = gc_ist;
				default: ;
			endcase
	end

	assign intr = {gc_ist[11], gc_ist[10], gc_ist[9], gc_ist[8], (gc_ist[15:8] & gc_ien[15:8]) != 8'h0};

	wire         m_dtext = gc_master[1];
	wire         m_dshade = gc_master[2];
	wire         m_dblend = gc_master[3];
	wire         m_dzbuf = gc_master[4];
	wire         m_ddith = gc_master[5];   // DDith: no dither, whatever DBUSERGENCTL asks (BDA spec 6.10)
	wire         dith_on = db_user[4] && !m_ddith;

	// ---- TRAM and the palette --------------------------------------------------------------------------------------------
	logic        ld_tram, ld_pip;
	logic [11:0] ld_ta;
	logic [7:0]  ld_pa;
	logic [31:0] ld_d, ld_d2;
	logic        ld_two;
	wire         r_pip = r_we && r_unit == 3'd3 && !r_reg[8];
	logic        pe, pu;                // the pixel pipeline moves; so do the stages before the texels
	logic        t_hold, p_any, serial;

	// ---- memory: the list's line buffer and the cache, never both at once ------------------------------------------------
	logic        z_wn, c_rn, c_wn, c_rs32, c_wwait;
	logic [27:0] z_wa, c_ra, c_wa;
	logic [15:0] z_wd;
	logic [31:0] c_wd, c_q;
	logic [3:0]  c_wbe;
	logic        z_rn;
	logic [31:0] z_ra_full;
	logic        zw_stall, cr_stall, cw_stall;
	logic        c_flush, cc_flushed, c_fdone;
	logic        c_req, m_owned;
	logic        cm_rd, cm_we;
	logic [31:3] cm_a;
	logic [63:0] cm_wd;
	logic [7:0]  cm_be;
	assign pe = !(zw_stall || cr_stall || cw_stall);
	assign pu = pe && !t_hold;
	// The Z buffer's here and nowhere else: nothing but this engine looks at one (the CPUs store only past its end), so memory needn't hear of it, and Z never waits.
	// A list clearing it draws in its place through the colour cache: what that has for there comes here instead of going to memory
	logic        cc_sink, x_v;
	logic [27:3] x_a;
	logic [63:0] x_wd;
	logic [7:0]  x_be;
	wire         cc_sinks = db_dbase == db_zbase && 15'(cm_a[27:13] - db_zbase[27:13]) < 15'(`Z_BLOCKS);
	always_ff @(posedge clk)
	begin
		x_v <= cc_sink;
		x_a <= cm_a[27:3]; x_wd <= cm_wd; x_be <= cm_be;
	end
	logic [15:0] z_q;
	te_z zb_ram (.clk, .rst, .z_base(db_zbase[27:13]), .x_v, .x_a, .x_wd, .x_be, .r_na(z_ra_full[27:1]), .r_adv(pu), .q(z_q),
		.w_n(z_wn), .w_na(z_wa[27:1]), .w_adv(pe), .wd(z_wd), .w_stall(zw_stall));
	te_cache cc (.clk, .rst, .sink_in(cc_sinks), .m_sink(cc_sink), .r_n(c_rn), .r_na(c_ra[27:1]), .r_ns32(c_rs32), .r_adv(pe), .q(c_q), .r_stall(cr_stall),
		.w_n(c_wn), .w_na(c_wa[27:1]), .w_ns32(db_dctl[0]), .w_nfour(fc_q[74]), .w_adv(pe), .w_wait(c_wwait && cr_stall), .wd(c_wd), .be(c_wbe), .w_stall(cw_stall),
		.flush(c_flush), .flushed(cc_flushed), .m_req(c_req), .m_gnt(m_owned),
		.m_rd(cm_rd), .m_we(cm_we), .m_a(cm_a), .m_wd(cm_wd), .m_be(cm_be), .m_busy, .m_ready, .m_dout);

	// the port goes to one of them until it's finished. A write-back can outlast the pixels, so the list's fetches and a texture load take turns with them
	logic        m_other, lb_go;
	always_ff @(posedge clk)
		if (rst) m_owned <= 1'b0;
		else if (!m_owned)
		begin
			if (!m_other && !lb_go && c_req) m_owned <= 1'b1;
		end
		else if (!c_req) m_owned <= 1'b0;

	// the list's two lines, one for each value of address bit 5: while the engine's busy with what it has read and no pixel wants memory, the next line comes in
	logic [63:0] lb [0:7];
	logic [31:5] lb_tag [0:1];
	logic [31:5] lb_a, f_nx;
	logic [1:0]  lb_ok;
	logic        lb_rd, lb_wait, lb_inv, lb_dead, pf_need;
	logic [1:0]  lb_n;
	logic [31:0] mm_src;
	logic [27:0] mm_n;
	logic [3:0]  vf_i;
	logic [4:0]  v_fl;                  // shaded, textured, perspective, new, replace
	wire         f_shad = v_fl[0], f_text = v_fl[1], f_prsp = v_fl[2], f_new = v_fl[3], f_rm = v_fl[4];
	wire         v_have = vf_i < 4'd2 || (vf_i < 4'd6 ? f_shad : vf_i == 4'd6 ? f_prsp : f_text);
	wire  [31:0] f_a = gc_irp;
	wire         f_ok = lb_ok[f_a[5]] && lb_tag[f_a[5]] == f_a[31:5];
	wire         f_want = st == I_FETCH || st == I_REGS || (st == V_FIELD && vf_i != 4'd9 && v_have);
	wire         pf_st = (st >= V_NEXT && st <= E_START) || st == I_FETCH || st == I_REGS || st == I_REGW;
	wire  [63:0] f_w64 = lb[f_a[5:3]];
	wire  [31:0] f_raw = f_a[2] ? f_w64[63:32] : f_w64[31:0];
	wire  [31:0] f_w = {f_raw[7:0], f_raw[15:8], f_raw[23:16], f_raw[31:24]};

	// a texture load streams: lines asked for ahead of what's taken, a word a clock when they keep up. A beat's readable the clock after next
	logic [26:0] ms_a;
	logic [28:0] ms_left;               // bytes still to ask for, from the first line's start
	logic        ms_more;               // some (ms_left above 0: set with it, so the memory request doesn't wait on the compare)
	logic [4:0]  ms_req, ms_wp, ms_wpd, ms_rp;
	logic [1:0]  ms_skip;               // beats of the first line before the source
	wire [28:0]  ml_ld = 29'(tm_count[27:0]) + 29'(tm_src[4:0]), ml_dn = ms_left - 29'd32;
	wire [4:0]   ms_out = ms_req - ms_rp;
	wire         ms_rd = st == T_MM && ms_more && ms_out <= 5'd12 && !m_owned;   // (a write-back asking waits for the load: m_other)
`ifdef VERILATOR
	always_ff @(posedge clk) if (ms_more != (!ms_left[28] && ms_left != 29'd0)) $display("TE ms_more wrong");
`endif
	wire         ms_have = ms_wpd != ms_rp;
	wire         ms_take = st == T_MM && mm_n != 28'd0 && ms_have;
	// (a whole word in one clock, when source and place are in step and it's the texture memory)
	wire         ms_two = ms_skip == 2'd0 && !mm_pip && mm_src[2:0] == 3'd0 && !mm_dst[2] && mm_n >= 28'd8;
	wire         ms_pop = ms_take && (ms_skip != 2'd0 || mm_src[2] || ms_two);
	wire [4:0]   ms_rn = ms_rp + 5'(ms_pop);
	logic [63:0] ms_q;
	te_ram #(.W(64), .AW(4)) ms_f (.clk, .we(st == T_MM && m_ready), .wa(ms_wp[3:0]), .wd(m_dout), .re(1'b1), .ra(ms_rn[3:0]), .rd(ms_q));
	wire [31:0]  ms_raw = mm_src[2] ? ms_q[63:32] : ms_q[31:0];
	// a source not on a word boundary: each word out is the end of one read and the start of the next (the first byte's in bits 7:0)
	logic        ms_arm;
	logic [31:0] ms_prev;
	logic [31:0] ms_w;
	always_comb
		case (mm_src[1:0])
			2'd1: ms_w = {ms_raw[7:0], ms_prev[31:8]};
			2'd2: ms_w = {ms_raw[15:0], ms_prev[31:16]};
			2'd3: ms_w = {ms_raw[23:0], ms_prev[31:24]};
			default: ms_w = ms_raw;
		endcase

	assign m_other = lb_rd || lb_wait || st == T_MM;
	// (the list goes before the caches' write-backs, between their lines)
	assign lb_go = !lb_rd && !lb_wait && !m_owned && !lb_inv && ((f_want && !f_ok) || (pf_need && pf_st));
	assign m_rd = lb_rd || cm_rd || ms_rd;
	assign m_we = cm_we;
	assign m_a = ms_rd ? {ms_a, 2'b00} : lb_rd ? {lb_a, 2'b00} : cm_a;
	assign m_wd = cm_wd;
	assign m_be = cm_be;

	always_ff @(posedge clk)
		if (rst) begin lb_ok <= 2'b00; lb_rd <= 1'b0; lb_wait <= 1'b0; lb_dead <= 1'b0; pf_need <= 1'b0; end
		else
		begin
			f_nx <= f_a[31:5] + 27'd1;
			pf_need <= !lb_rd && !lb_wait && f_ok && f_nx[5] != f_a[5] && !(lb_ok[f_nx[5]] && lb_tag[f_nx[5]] == f_nx);
			if (lb_inv)
			begin
				lb_ok <= 2'b00;
				lb_dead <= lb_rd || lb_wait;
			end
			else if (lb_go)
			begin
				if (f_want && !f_ok) begin lb_rd <= 1'b1; lb_ok[f_a[5]] <= 1'b0; lb_a <= f_a[31:5]; lb_dead <= 1'b0; end
				else begin lb_rd <= 1'b1; lb_ok[f_nx[5]] <= 1'b0; lb_a <= f_nx; lb_dead <= 1'b0; end
			end
			if (lb_rd && !m_busy) begin lb_rd <= 1'b0; lb_wait <= 1'b1; lb_n <= 2'd0; lb_tag[lb_a[5]] <= lb_a; end
			if (lb_wait && m_ready)
			begin
				lb[{lb_a[5], lb_n}] <= m_dout;
				lb_n <= lb_n + 2'd1;
				if (lb_n == 2'd3) begin lb_wait <= 1'b0; if (!lb_dead && !lb_inv) lb_ok[lb_a[5]] <= 1'b1; end
			end
		end

	// ---- floats ------------------------------------------------------------------------------------------------------------
	logic [31:0] fa, fb, fadd_r, fmul_r;
	logic        fsub;
	te_fadd fadd (.clk, .a(fa), .b(fb), .sub(fsub), .r(fadd_r));
	te_fmul fmul (.clk, .a(fa), .b(fb), .r(fmul_r));

	function automatic logic [31:0] ftrunc(input logic [31:0] f);
		// toward zero, to a whole number
		logic [7:0] e;
		logic [31:0] m;
		e = f[30:23];
		if (e < 8'd127) return 32'h0;
		if (e >= 8'd150) return f;
		m = 32'hffffffff << (8'd150 - e);
		return f & m;
	endfunction
	function automatic logic signed [13:0] ftoi(input logic [31:0] f);
		logic [7:0] e;
		logic [23:0] m;
		logic [13:0] v;
		e = f[30:23];
		m = {1'b1, f[22:0]};
		if (e < 8'd127 || e >= 8'd140) return 14'sh0;       // (off every screen, as far as this goes)
		v = 14'(m >> (8'd150 - e));
		return f[31] ? -$signed(v) : $signed(v);
	endfunction
	function automatic logic [31:0] utof(input logic neg, input logic [29:0] u);
		// a sign and magnitude's (not 0); exact below 2^24, then to nearest, ties to even
		logic [29:0] s;
		logic [4:0] n;
		logic [24:0] m;
		logic [7:0] e;
		logic rnd;
		n = 5'd0;
		for (int b = 0; b < 30; b++) if (u[b]) n = 5'(b);
		s = u << (5'd29 - n);
		rnd = s[5] && (s[6] || s[4:0] != 5'd0);
		m = {1'b0, s[29:6]} + 25'(rnd);
		e = 8'd127 + 8'(n);
		if (m[24]) begin e = e + 8'd1; m = m >> 1; end
		return {neg, e, m[22:0]};
	endfunction
	function automatic logic [31:0] itof(input logic signed [29:0] i);
		return i == 30'sh0 ? 32'h0 : utof(i < 0, i < 0 ? 30'(-i) : 30'(i));
	endfunction

	// ---- vertices: 3 of 16: 2-5 r g b a (scaled, whole), 6 w, 7 uw, 8 vw. X, Y and W's exponent are registers --------------
	logic        vw_e;
	logic [5:0]  vw_a, vr_a;
	logic [31:0] vw_d, vr_q;
	ppc_ram_s #(.W(32), .AW(6)) vram (.clk, .we(vw_e), .wa(vw_a), .wd(vw_d), .ra(vr_a), .rd(vr_q));
	logic signed [13:0] xi [0:2];
	logic signed [13:0] yi [0:2];
	logic [7:0]  wexp [0:2];

	logic [15:0] vn;
	logic [2:0]  tsort;
	logic [1:0]  vcnt, vslot;
	logic [31:0] fw_q;
	logic        vf_v;
	logic [3:0]  vf_d;
	logic [3:0]  vm_v, vm_c;
	logic [5:0]  vm_a [0:3];

	// ---- the triangle ------------------------------------------------------------------------------------------------------
	val_t        e_v [0:6];             // the edge's
	val_t        ddx [0:6];
	val_t        slope [0:6];
	val_t        s_v [0:6];             // the pixel's
	logic signed [13:0] x1, x2, x3, y1, y2, y3;
	logic [1:0]  v_top, v_mid, v_bot;
	logic [1:0]  wrange;
	logic signed [29:0] aria;
	logic [29:0] ar_u;                      // |aria|, and its sign, for its float a clock later
	logic        ar_n;
	logic        scan_lr;
	logic [31:0] fa_aria;
	logic signed [13:0] fc_c;
	logic signed [13:0] xstep0, xstep1, xstepl, dy0, dy1, dyl;
	logic signed [13:0] xys0, xys1, xysl;
	logic [2:0]  fc_i;
	wire signed [13:0] x12 = x1 - x2, x23 = x2 - x3, x31 = x3 - x1, y12 = y1 - y2, y23 = y2 - y3, y31 = y3 - y1;

	// one multiplier, for the setup's and the rows' products: two clocks
	logic signed [17:0] mx_a, mx_b;
	logic signed [35:0] mx_r;
	always_ff @(posedge clk) mx_r <= mx_a * mx_b;
	logic [3:0]  ss;

	// whole-number divide
	logic [13:0] dv_n, dv_d, dv_q;
	logic [14:0] dv_r;
	logic [3:0]  dv_i;
	logic [1:0]  div_i;
	logic signed [13:0] dv_nm, dv_dn;
	logic        dv_flr;
	wire  [13:0] dv_nabs = dv_nm < 0 ? 14'(-dv_nm) : 14'(dv_nm);
	always_comb
		case (div_i)
			2'd0: begin dv_nm = -x12; dv_dn = y12; dv_flr = !scan_lr; end
			2'd1: begin dv_nm = -x23; dv_dn = y23; dv_flr = !scan_lr; end
			default: begin dv_nm = x31; dv_dn = y31; dv_flr = scan_lr; end
		endcase

	// 1 / aria
	logic [26:0] fd_q;
	logic [25:0] fd_r;
	logic [4:0]  fd_i;
	logic        fd_run;
	wire  [25:0] fd_m = {2'b01, fa_aria[22:0], 1'b0} >> 1;
	wire         fd_ge = fd_r >= fd_m;

	// an attribute
	logic [2:0]  at_i;
	logic [31:0] q1f, q2f, q3f;
	function automatic logic [3:0] af(input logic [2:0] i);
		case (i)
			3'd0: return 4'd2;
			3'd1: return 4'd3;
			3'd2: return 4'd4;
			3'd3: return 4'd5;
			3'd4: return 4'd7;
			3'd5: return 4'd8;
			default: return 4'd6;
		endcase
	endfunction
	wire         at_have = at_i < 3'd4 ? f_shad : at_i < 3'd6 ? f_text : f_prsp;
	// (Quartus 17 dies elaborating a case inside a function inside a cast, so no case here)
	wire signed [5:0] af_w = wrange == 2'd0 ? 6'sd0 : wrange == 2'd1 ? -6'sd3 : wrange == 2'd2 ? -6'sd6 : -6'sd9;
	function automatic logic signed [5:0] af_bits(input logic [2:0] i);
		return i < 3'd4 ? 6'sd8 : i < 3'd6 ? af_w + 6'sd10 : af_w;
	endfunction

	// The slopes (calculate_slope), in C's order wherever the order shows:
	//   P1 = q1 * fc0   P2 = q2 * fc1   S1 = P1 + P2   P3 = q3 * fc2   detx = S1 + P3
	//   P4 = q1 * fc3   P5 = q2 * fc4   S2 = P4 + P5   P6 = q3 * fc5   dety = S2 + P6
	//   P7 = fc6 * detx   S3 = P7 - dety   slope = S3 * iaria   ddx = detx * iaria
	// The multiplier and the adder are pipelines, so an attribute starts every 14 clocks, up to four under way: a schedule that repeats (work/te_sched.py), an op asked
	// each clock and a result written each clock. A product's ready 4 clocks after it's asked for, a sum 5. What's waiting is in a memory, each attribute's own
	// and the triangle's fc0-6 and iaria, written from a register, and so read for an op 3 clocks after its result at the soonest.
	logic [3:0]  j_m;
	logic [3:0]  j_v;
	logic [2:0]  j_a [0:3];
	logic [6:0]  at_mask;
	logic        rf_we;
	logic [6:0]  rf_wa, ra_a, ra_b;
	logic [31:0] rf_wd, rfa_q, rfb_q;
	function automatic logic [6:0] rf_ad(input logic [2:0] i, input logic [4:0] t);
		return t[4] ? {3'd7, t[3:0]} : {i, t[3:0]};
	endfunction
	ppc_ram #(.W(32), .AW(7)) rf_a (.clk, .we(rf_we), .wa(rf_wa), .wd(rf_wd), .ra(ra_a), .rd(rfa_q));
	ppc_ram #(.W(32), .AW(7)) rf_b (.clk, .we(rf_we), .wa(rf_wa), .wd(rf_wd), .ra(ra_b), .rd(rfb_q));
	always_comb
	begin
		ra_a = 7'd0; ra_b = 7'd0;
		case (j_m)
			4'd0: begin ra_a = rf_ad(j_a[2], 5'd22); ra_b = rf_ad(j_a[2], 5'd9); end
			4'd1: begin ra_b = rf_ad(j_a[0], 5'd20); end
			4'd2: begin ra_b = rf_ad(j_a[0], 5'd19); end
			4'd3: begin ra_b = rf_ad(j_a[0], 5'd17); end
			4'd4: begin ra_b = rf_ad(j_a[0], 5'd16); end
			4'd5: begin ra_b = rf_ad(j_a[0], 5'd18); end
			4'd6: begin ra_a = rf_ad(j_a[1], 5'd7); ra_b = rf_ad(j_a[1], 5'd2); end
			4'd7: begin ra_a = rf_ad(j_a[3], 5'd11); ra_b = rf_ad(j_a[3], 5'd23); end
			4'd8: begin ra_b = rf_ad(j_a[0], 5'd21); end
			4'd9: begin ra_a = rf_ad(j_a[0], 5'd3); ra_b = rf_ad(j_a[0], 5'd4); end
			4'd10: begin ra_a = rf_ad(j_a[1], 5'd8); ra_b = rf_ad(j_a[1], 5'd5); end
			4'd11: begin ra_a = rf_ad(j_a[0], 5'd0); ra_b = rf_ad(j_a[0], 5'd1); end
			4'd12: begin ra_a = rf_ad(j_a[2], 5'd6); ra_b = rf_ad(j_a[2], 5'd10); end
			4'd13: begin ra_a = rf_ad(j_a[2], 5'd9); ra_b = rf_ad(j_a[2], 5'd23); end
			default: ;
		endcase
	end
	logic [2:0]  j_nx;
	always_comb
	begin
		j_nx = 3'd6;
		for (int i = 5; i >= 0; i--) if (at_mask[i]) j_nx = 3'(i);
	end

	// ieee754_to_tefix: |f| * 2^(23 - bits), to nearest, modulo 2^24, with f's sign; a colour then >> 4
	logic [31:0] fx_f;
	logic signed [10:0] fx_sh;
	logic [1:0]  fx_to;                 // the value after this one's fx_o: 0 a slope, 1 ddx, 2 the edge's, 3 none
	logic [2:0]  fx_at;
	val_t        fx_o;
	always_comb
	begin
		logic [47:0] v;
		logic [23:0] r;
		logic signed [25:0] s;
		v = 48'd0;
		r = 24'd0;
		if (fx_f[30:23] != 8'd0 && fx_sh < 11'sd24 && fx_sh >= -11'sd25)
		begin
			if (fx_sh >= 0)
			begin
				v = 48'({1'b1, fx_f[22:0]}) << fx_sh[4:0];
				r = v[23:0];
			end
			else
			begin
				v = {1'b1, fx_f[22:0], 24'h0} >> 5'(-fx_sh);
				r = v[47:24] + 24'(v[23] && (v[24] || v[22:0] != 23'h0));
			end
		end
		s = fx_f[31] ? -$signed({2'b00, r}) : $signed({2'b00, r});
		fx_o = fx_at < 3'd4 ? 27'(s >>> 4) : 27'(s);
	end

	// ---- the walk --------------------------------------------------------------------------------------------------------
	logic signed [13:0] y, xs, xe, cf_short, cf_long, xystep, xstep, dy;
	logic signed [13:0] px, pxe;
	logic        omit_right, step_back;
	// the next line's worked out while this one's pixels run, and taken up as soon as they're out
	typedef enum logic [2:0] { NX_N1, NX_N2, NX_A1, NX_A2, NX_LINE, NX_ROW, NX_DONE } nx_t;
	nx_t         nx;
	logic        nx_last;
	logic signed [13:0] y_n;
	logic signed [27:0] row_dn, row_zn, row_sn;
	wire         dsp_off = es_cntl[0];
	wire         du_scan = es_cntl[1];
	wire         persp_off = es_cntl[2];

	function automatic val_t clamp19(input val_t v);
		if (v < 0) return '0;
		if (v > 27'sh007ffff) return 27'sh007ffff;
		return v;
	endfunction
	function automatic val_t clamp23(input val_t v);
		if (v < 0) return '0;
		if (v > 27'sh07fffff) return 27'sh07fffff;
		return v;
	endfunction

	wire         ins_long = scan_lr ? cf_long <= 0 : cf_long >= 0;
	wire         ins_short = scan_lr ? cf_short <= 0 : cf_short >= 0;
	wire         ein_long = scan_lr ? cf_long < 0 : cf_long > 0;
	wire         ein_short = scan_lr ? cf_short < 0 : cf_short > 0;

	// the rows' products, for the addresses
	logic signed [27:0] row_d, row_z, row_s;
	wire signed [14:0] z_xo = 15'($signed(db_zoff[27:16])) + 15'(px);
	wire signed [14:0] z_yo = 15'($signed(db_zoff[11:0])) + 15'(y);
	wire signed [14:0] z_yn = 15'($signed(db_zoff[11:0])) + 15'(y_n);
	wire signed [14:0] s_xo = 15'($signed(db_soff[27:16])) + 15'(px);
	wire signed [14:0] s_yo = 15'($signed(db_soff[11:0])) + 15'(y);
	wire signed [14:0] s_yn = 15'($signed(db_soff[11:0])) + 15'(y_n);

	// what's clipped
	wire         fbclipdis = px < 0 || y < 0 || px >= $signed({3'b000, db_fbclip[26:16]}) || y >= $signed({3'b000, db_fbclip[10:0]});
	wire         win_in = px >= $signed({3'b000, db_xwin[26:16]}) && px < $signed({3'b000, db_xwin[10:0]})
		&& y >= $signed({3'b000, db_ywin[26:16]}) && y < $signed({3'b000, db_ywin[10:0]});
	wire         winclipdis = (db_user[8] && win_in) || (db_user[7] && !win_in);
	wire         zon = !m_dzbuf && db_user[10];
	wire         zclip = zon && (z_xo < 0 || z_yo < 0 || z_xo >= $signed({4'b0000, db_zclip[26:16]}) || z_yo >= $signed({4'b0000, db_zclip[10:0]}));
	wire         zclipdis = zclip && db_discard[3];
	wire signed [27:0] z_off = row_z + 28'(z_xo);
	wire signed [27:0] d_off = row_d + 28'(px);
	wire signed [27:0] s_off = row_s + 28'(s_xo);
	wire  [31:0] z_addr = db_zbase + {3'(z_off[27] ? 3'b111 : 3'b000), z_off, 1'b0};
	wire  [31:0] d_addr = db_dbase + (db_dctl[0] ? {2'(d_off[27] ? 2'b11 : 2'b00), d_off, 2'b00} : {3'(d_off[27] ? 3'b111 : 3'b000), d_off, 1'b0});
	wire  [31:0] s_addr = db_sbase + (db_sctl[0] ? {2'(s_off[27] ? 2'b11 : 2'b00), s_off, 2'b00} : {3'(s_off[27] ? 3'b111 : 3'b000), s_off, 1'b0});

	logic [22:0] w16_s;
	always_comb
		case (wrange)
			2'd0: w16_s = s_v[A_W][22:0];
			2'd1: w16_s = 23'(s_v[A_W][22:0] >> 3);
			2'd2: w16_s = 23'(s_v[A_W][22:0] >> 6);
			default: w16_s = 23'(s_v[A_W][22:0] >> 9);
		endcase
	wire [15:0]  w16 = w16_s[22:7];

	wire         v0_go = st == P_RUN && px != pxe && pu && !(serial && p_any);
	wire         v0_ok = v0_go && !(fbclipdis || winclipdis || zclipdis);
	// The list that clears the Z buffer, drawing into the Z buffer itself, wanting nothing but its one colour in 16 bits: where four pixels make a word of memory, they go as one. Only
	// there: on the board other flat triangles drawn this way lost pixels at the picture's lower left, which the bench doesn't show
	logic        tri_flat, v1_four;
	wire         f4_on = tri_flat && db_dbase == db_zbase && !db_dctl[0] && db_user[10:5] == 6'd0 && !dith_on && db_user[3:0] == 4'hf && db_discard[2:0] == 3'd0 && !t_look && db_dbase[2:1] == 2'd0 && row_d[1:0] == 2'd0;
	wire         v0_four = f4_on && px[1:0] == (scan_lr ? 2'd0 : 2'd3) && px[13:2] != pxe[13:2] && $signed(px[13:2]) < $signed({3'b000, db_fbclip[26:18]});
	assign       z_rn = v0_ok && zon && !zclip;
	assign       z_ra_full = z_addr;

	// ---- the texture's coordinates ---------------------------------------------------------------------------------------
	function automatic logic [7:0] nr_rom(input logic [6:0] i);
		case (i)
			7'd0: return 8'd127; 7'd1: return 8'd125; 7'd2: return 8'd123; 7'd3: return 8'd121; 7'd4: return 8'd119; 7'd5: return 8'd118;
			7'd6: return 8'd116; 7'd7: return 8'd114; 7'd8: return 8'd112; 7'd9: return 8'd110; 7'd10: return 8'd109; 7'd11: return 8'd107;
			7'd12: return 8'd105; 7'd13: return 8'd104; 7'd14: return 8'd102; 7'd15: return 8'd100; 7'd16: return 8'd99; 7'd17: return 8'd97;
			7'd18: return 8'd96; 7'd19: return 8'd94; 7'd20: return 8'd93; 7'd21: return 8'd91; 7'd22: return 8'd90; 7'd23: return 8'd88;
			7'd24: return 8'd87; 7'd25: return 8'd86; 7'd26: return 8'd84; 7'd27: return 8'd83; 7'd28: return 8'd81; 7'd29: return 8'd80;
			7'd30: return 8'd79; 7'd31: return 8'd78; 7'd32: return 8'd76; 7'd33: return 8'd75; 7'd34: return 8'd74; 7'd35: return 8'd73;
			7'd36: return 8'd71; 7'd37: return 8'd70; 7'd38: return 8'd69; 7'd39: return 8'd68; 7'd40: return 8'd67; 7'd41: return 8'd65;
			7'd42: return 8'd64; 7'd43: return 8'd63; 7'd44: return 8'd62; 7'd45: return 8'd61; 7'd46: return 8'd60; 7'd47: return 8'd59;
			7'd48: return 8'd58; 7'd49: return 8'd57; 7'd50: return 8'd56; 7'd51: return 8'd55; 7'd52: return 8'd54; 7'd53: return 8'd53;
			7'd54: return 8'd52; 7'd55: return 8'd51; 7'd56: return 8'd50; 7'd57: return 8'd49; 7'd58: return 8'd48; 7'd59: return 8'd47;
			7'd60: return 8'd46; 7'd61: return 8'd45; 7'd62: return 8'd44; 7'd63: return 8'd43; 7'd64: return 8'd42; 7'd65: return 8'd41;
			7'd66: return 8'd40; 7'd67: return 8'd40; 7'd68: return 8'd39; 7'd69: return 8'd38; 7'd70: return 8'd37; 7'd71: return 8'd36;
			7'd72: return 8'd35; 7'd73: return 8'd35; 7'd74: return 8'd34; 7'd75: return 8'd33; 7'd76: return 8'd32; 7'd77: return 8'd31;
			7'd78: return 8'd31; 7'd79: return 8'd30; 7'd80: return 8'd29; 7'd81: return 8'd28; 7'd82: return 8'd28; 7'd83: return 8'd27;
			7'd84: return 8'd26; 7'd85: return 8'd25; 7'd86: return 8'd25; 7'd87: return 8'd24; 7'd88: return 8'd23; 7'd89: return 8'd23;
			7'd90: return 8'd22; 7'd91: return 8'd21; 7'd92: return 8'd21; 7'd93: return 8'd20; 7'd94: return 8'd19; 7'd95: return 8'd19;
			7'd96: return 8'd18; 7'd97: return 8'd17; 7'd98: return 8'd17; 7'd99: return 8'd16; 7'd100: return 8'd15; 7'd101: return 8'd15;
			7'd102: return 8'd14; 7'd103: return 8'd13; 7'd104: return 8'd13; 7'd105: return 8'd12; 7'd106: return 8'd12; 7'd107: return 8'd11;
			7'd108: return 8'd11; 7'd109: return 8'd10; 7'd110: return 8'd9; 7'd111: return 8'd9; 7'd112: return 8'd8; 7'd113: return 8'd8;
			7'd114: return 8'd7; 7'd115: return 8'd7; 7'd116: return 8'd6; 7'd117: return 8'd5; 7'd118: return 8'd5; 7'd119: return 8'd4;
			7'd120: return 8'd4; 7'd121: return 8'd3; 7'd122: return 8'd3; 7'd123: return 8'd2; 7'd124: return 8'd2; 7'd125: return 8'd1;
			7'd126: return 8'd1; default: return 8'd0;
		endcase
	endfunction
	function automatic logic [2:0] nsh(input logic [22:0] v);
		for (int b = 0; b < 7; b++) if (v[22 - b]) return 3'(b);
		return 3'd7;
	endfunction

	// ---- the pixel pipeline: the walker hands in a pixel a clock, two for one that needs four texels (two a clock), each stage a clock behind
	// the last, everything waiting when a cache does:
	//
	//   V0 the walker (P_RUN)  V1 Z's read, compared; V1-V6 1/W, U, V  V7 T: two texels' sums, twice over  ...the texels' stages...
	//   E1-E4 bilinear, two channels a clock  E4 T1, T2 the texture blend  T2 the source's address, T3 its value  T4 the blend's operands  T5 products
	//   T6 ALU, dither  T7 discards; the writes' addresses  T8 the writes
	//
	// Only one triangle's pixels are ever in it, and those at different places: they can't see each other's writes. What a pixel would see of
	// the one before is taken care of by serial: one in the pipeline at a time.
	logic [23:0] w_shf;
	logic [8:0]  w_fg, w_fg2, w_fg3;
	logic [15:0] w_sh1;
	logic        w_z1, w_z2, w_z3;
	logic [23:0] w_m1;
	logic [20:0] w_m2;
	logic [20:0] w_inv;
	logic [15:0] u_c [0:5];
	logic [15:0] v_c [0:5];
	logic [2:0]  us_c [0:5];
	logic [2:0]  vs_c [0:5];
	logic [4:0]  ws_c [0:5];
	logic [36:0] u_r, v_r;
	logic [13:0] tu, tv;                // 10.4

	wire  [22:0] w_in = s_v[A_W] < 0 ? 23'd0 : s_v[A_W][22:0];
	wire  [22:0] uw_in = s_v[A_UW] < 0 ? 23'd0 : s_v[A_UW][22:0];
	wire  [22:0] vw_in = s_v[A_VW] < 0 ? 23'd0 : s_v[A_VW][22:0];
	logic [4:0]  w_lz;
	always_comb
	begin
		w_lz = 5'd0;
		for (int b = 0; b < 23; b++) if (w_in[b]) w_lz = 5'(23 - b);
	end
	wire  [2:0]  u_ns = nsh(uw_in), v_ns = nsh(vw_in);
	wire  [22:0] u_nv = uw_in << u_ns, v_nv = vw_in << v_ns;
	logic [4:0]  np_sh;
	always_comb
		case (wrange)
			2'd0: np_sh = 5'd9;
			2'd1: np_sh = 5'd12;
			2'd2: np_sh = 5'd15;
			default: np_sh = 5'd18;
		endcase
	// (ur shifted by w's normalising less uw's, kept to the bits that matter: 7 up, so as not to shift right)
	wire  [5:0]  u_ls = 6'd7 + 6'(ws_c[5]) - 6'(us_c[5]), v_ls = 6'd7 + 6'(ws_c[5]) - 6'(vs_c[5]);
	wire  [66:0] u_sh = 67'(u_r) << u_ls, v_sh = 67'(v_r) << v_ls;

	wire  [9:0]  umask = tm_uvmask[25:16], vmask = tm_uvmask[9:0];
	// LOD 0's size, less 1 (the largest U and V): UVMAX is the coarsest level's (LODMAX's), each finer one twice it, and no more than UVMASK
	// (the M2 emulator's addr_calc)
	wire  [1:0]  lodmax = tm_addr[3:0] > 4'd3 ? 2'd3 : tm_addr[1:0];
	wire  [13:0] u_full = 14'({1'b0, tm_uvmax[25:16]} + 11'd1) << lodmax, v_full = 14'({1'b0, tm_uvmax[9:0]} + 11'd1) << lodmax;
	wire  [9:0]  umax = u_full > 14'({1'b0, umask} + 11'd1) ? umask : 10'(u_full - 14'd1);
	wire  [9:0]  vmax = v_full > 14'({1'b0, vmask} + 11'd1) ? vmask : 10'(v_full - 14'd1);
	// The filter: the magnify one, or with more than a texel between this pixel and the next, the minify one (the BDA spec's; MAME 0.289 only ever
	// read the magnify filter). No level of detail yet: LOD 0 only.
	logic        t_min;
	wire         t_bil = t_min ? tm_addr[11] : tm_addr[5];
	wire         t_look = tm_addr[13] && !m_dtext;
	wire         blen = db_user[6] && !m_dblend;
	wire         sren = db_user[5] && blen;
	wire  [3:0]  d_mask = db_user[3:0];

	// the walker's pixel
	logic        v1_v, v2_v, v3_v, v4_v, v5_v, v6_v, v7_v, v8_v, v9_v;
	logic [9:1]  wk;                    // these stages hold a pixel the walker stepped to, kept or not: in a row, the next pixel along the span
	logic [13:0] t0_u, t0_v, t1_u, t1_v;
	wire  [14:0] t_du = {1'b0, t0_u} - {1'b0, t1_u}, t_dv = {1'b0, t0_v} - {1'b0, t1_v};
	logic        v1_zc;
	logic [15:0] v1_w16;
	logic [27:0] v1_z, v1_d, v1_s;
	logic [31:0] v1_c;
	logic [3:0]  v1_dx;

	// Z's answer. (MAME's comparison: its names for the bits are the other way round)
	logic        zp, zb;
	always_comb
		if (!v1_zc) begin zp = 1'b1; zb = 1'b0; end
		else if (v1_w16 > z_q) begin zp = db_zctl[0]; zb = db_zctl[1]; end
		else if (v1_w16 == z_q) begin zp = db_zctl[2]; zb = db_zctl[3]; end
		else begin zp = db_zctl[4]; zb = db_zctl[5]; end
	wire         v1_ok = v1_v && (zp || zb);

	// what later stages want of the walker's, in order: the iterated colour; the source's address and the dither's place; the rest
	logic [4:0]  fw, fa_r, fb_r, fc_r;
	wire         f_push = v1_ok && pu;
	logic [31:0] fa_q, fb_q;
	logic [74:0] fc_q;
	te_ram #(.W(32), .AW(5)) fifo_a (.clk, .we(f_push), .wa(fw), .wd(v1_c), .re(pe), .ra(fa_r), .rd(fa_q));
	te_ram #(.W(32), .AW(5)) fifo_b (.clk, .we(f_push), .wa(fw), .wd({v1_dx, v1_s}), .re(pe), .ra(fb_r), .rd(fb_q));
	te_ram #(.W(75), .AW(5)) fifo_c (.clk, .we(f_push), .wa(fw), .wd({v1_four, zp, zb, v1_w16, v1_d, v1_z}), .re(pe), .ra(fc_r), .rd(fc_q));

	always_ff @(posedge clk)
		if (pu)
		begin
			v1_zc <= zon && !zclip;
			v1_four <= v0_four;
			v1_w16 <= w16;
			v1_z <= z_addr[27:0]; v1_d <= d_addr[27:0]; v1_s <= s_addr[27:0];
			v1_c <= {m_dshade ? 8'hff : s_v[A_R][18:11], m_dshade ? 8'hff : s_v[A_G][18:11], m_dshade ? 8'hff : s_v[A_B][18:11], m_dshade ? 8'hff : s_v[A_A][18:11]};
			v1_dx <= {y[1:0], px[1:0]};

			w_shf <= 24'(w_in) << w_lz;
			w_fg <= 9'(nr_rom(w_shf[22:16])) + 9'd128;
			w_sh1 <= w_shf[23:8];
			w_z1 <= w_shf == 24'd0;
			w_m1 <= 24'(w_fg) * 24'(w_sh1);
			w_fg2 <= w_fg; w_z2 <= w_z1;
			w_m2 <= 21'((25'h1000000 - 25'(w_m1)) >> 3);
			w_fg3 <= w_fg2; w_z3 <= w_z2;
			w_inv <= w_z3 ? 21'd0 : 21'((30'(w_fg3) * 30'(w_m2)) >> 8);
			u_r <= 37'(u_c[4]) * 37'(w_inv);
			v_r <= 37'(v_c[4]) * 37'(w_inv);
			t0_u <= persp_off ? u_c[5][13:0] : u_sh[42:29];
			t0_v <= persp_off ? v_c[5][13:0] : v_sh[42:29];
			t1_u <= t0_u; t1_v <= t0_v;
			tu <= t1_u; tv <= t1_v;
			// the texel step to the next pixel; a span's last pixel has none, so keeps the one before's
			if (wk[8] && wk[7])
				t_min <= $signed(t_du) > 15'sd16 || $signed(t_du) < -15'sd16 || $signed(t_dv) > 15'sd16 || $signed(t_dv) < -15'sd16;
			wk <= {wk[8:1], v0_go};

			u_c[0] <= persp_off ? 16'(uw_in >> np_sh) : u_nv[22:7];
			v_c[0] <= persp_off ? 16'(vw_in >> np_sh) : v_nv[22:7];
			us_c[0] <= u_ns; vs_c[0] <= v_ns; ws_c[0] <= w_lz;
			for (int i = 1; i < 6; i++)
			begin
				u_c[i] <= u_c[i - 1]; v_c[i] <= v_c[i - 1];
				us_c[i] <= us_c[i - 1]; vs_c[i] <= vs_c[i - 1]; ws_c[i] <= ws_c[i - 1];
			end
		end

	// ---- texels: four asked for in T, a stage a clock from there -----------------------------------------------------------
	logic        tk_i;
	// (a sample with no fractions, or a point sample, is its one texel: much of what's drawn is copied, one to one)
	wire         t_one = !t_bil || (tu[3:0] == 4'd0 && tv[3:0] == 4'd0);
	assign       t_hold = v9_v && t_look && !t_one && !tk_i;
	logic        a1_o, a2_o, a3_o, a4_o, a5_o, d0_o, d1_o, d2_o, e1_o, e2_o, e3_o;
	logic        a1_v, a2_v, a3_v, a4_v, a5_v, d0_v, d1_v, d2_v;
	logic        a1_e, a2_e, a3_e, a4_e, a5_e, d0_e, d1_e, d2_e;    // the pixel's last, or a pixel without any
	logic [7:0]  a1_f, a2_f, a3_f, a4_f, a5_f, d0_f, d1_f, d2_f;    // its fractions
	logic [9:0]  a2_v0;
	logic [20:0] a3_vo;
	wire  [13:0] ku = tu + 14'h10;
	wire  [13:0] kv = tv + (tk_i ? 14'h10 : 14'h0);
	wire  [9:0]  k_u0 = tu[13:4] & umask, k_u1 = ku[13:4] & umask, k_v0 = kv[13:4] & vmask;
	logic [32:0] d3_a, d3_b;
	te_fetch fetch_a (.clk, .pe, .ld_tram, .ld_two, .ld_ta, .ld_pip, .ld_pa, .ld_d, .ld_d2, .r_pip, .r_a(r_reg[7:0]), .r_d,
		.u(k_u0), .umax, .vo(a3_vo), .lod0(tm_lod0[23:0]), .exp(tm_exp), .pip_c(tm_pip), .c0(tm_c0), .c1(tm_c1), .o(d3_a));
	te_fetch fetch_b (.clk, .pe, .ld_tram, .ld_two, .ld_ta, .ld_pip, .ld_pa, .ld_d, .ld_d2, .r_pip, .r_a(r_reg[7:0]), .r_d,
		.u(k_u1), .umax, .vo(a3_vo), .lod0(tm_lod0[23:0]), .exp(tm_exp), .pip_c(tm_pip), .c0(tm_c0), .c1(tm_c1), .o(d3_b));

	// the first two, then all four for the channels to work through while the next pixel's arrive
	logic [32:0] tx [0:1];
	logic [32:0] bk [0:3];              // s a r g b
	logic [3:0]  bk_uf, bk_vf;

	always_ff @(posedge clk)
		if (pe)
		begin
			// (each valid is a clock behind the data it's named beside)
			a1_f <= t_bil ? {tu[3:0], tv[3:0]} : 8'h00;
			a2_v0 <= k_v0 < vmax ? k_v0 : vmax;
			a2_f <= a1_f;
			a3_vo <= 21'(a2_v0) * 21'({1'b0, umax} + 11'd1);
			a3_f <= a2_f;
			a4_f <= a3_f;
			a5_f <= a4_f;
			d0_f <= a5_f;
			d1_f <= d0_f;
			d2_f <= d1_f;
			if (d2_v && !d2_e) begin tx[0] <= d3_a; tx[1] <= d3_b; end
			if (d2_e && !d2_o)
			begin
				bk[0] <= tx[0]; bk[1] <= tx[1]; bk[2] <= d3_a; bk[3] <= d3_b;
				bk_uf <= d2_f[7:4];
				bk_vf <= d2_f[3:0];
			end
		end

	// ---- bilinear: two channels a clock, r and g first; with a point sample the fractions are 0 ------------------------------
	logic        bl_c;
	wire  [7:0]  bl_0a = bl_c ? bk[0][7:0] : bk[0][23:16], bl_1a = bl_c ? bk[1][7:0] : bk[1][23:16], bl_2a = bl_c ? bk[2][7:0] : bk[2][23:16], bl_3a = bl_c ? bk[3][7:0] : bk[3][23:16];
	wire  [7:0]  bl_0b = bl_c ? bk[0][31:24] : bk[0][15:8], bl_1b = bl_c ? bk[1][31:24] : bk[1][15:8], bl_2b = bl_c ? bk[2][31:24] : bk[2][15:8], bl_3b = bl_c ? bk[3][31:24] : bk[3][15:8];
	wire  [4:0]  bl_uf = {1'b0, bk_uf};
	logic [12:0] bl_la, bl_ua, bl_lb, bl_ub;
	logic [3:0]  bl_vf;
	logic [17:0] bl_oa, bl_ob;
	logic [7:0]  bx_r, bx_g;
	// (the same sum on all-or-nothing bits: it comes to at least 1024 from 5/256ths)
	wire  [4:0]  bs_l = (bk[0][32] ? 5'd16 - bl_uf : 5'd0) + (bk[1][32] ? bl_uf : 5'd0);
	wire  [4:0]  bs_u = (bk[2][32] ? 5'd16 - bl_uf : 5'd0) + (bk[3][32] ? bl_uf : 5'd0);
	wire  [8:0]  bs_o = 9'(bs_l) * (9'd16 - 9'(bk_vf)) + 9'(bs_u) * 9'(bk_vf);
	logic [2:0]  ts_c;
	// a one-texel sample's way round all that, the same number of clocks; whichever pixels are near it, it's between what they use
	logic [2:0]  one_ra;
	wire  [2:0]  one_wa = one_ra + 3'd2;
	logic [32:0] one_q;
	te_ram #(.W(33), .AW(3)) one_d (.clk, .we(pe), .wa(one_wa), .wd(d3_a), .re(pe), .ra(one_ra), .rd(one_q));
	always_ff @(posedge clk)
		if (pe)
		begin
			bl_c <= d2_e && !d2_o ? 1'b0 : !bl_c;
			bl_la <= 13'(bl_0a) * (13'd16 - 13'(bl_uf)) + 13'(bl_1a) * 13'(bl_uf);
			bl_ua <= 13'(bl_2a) * (13'd16 - 13'(bl_uf)) + 13'(bl_3a) * 13'(bl_uf);
			bl_lb <= 13'(bl_0b) * (13'd16 - 13'(bl_uf)) + 13'(bl_1b) * 13'(bl_uf);
			bl_ub <= 13'(bl_2b) * (13'd16 - 13'(bl_uf)) + 13'(bl_3b) * 13'(bl_uf);
			bl_vf <= bk_vf;
			bl_oa <= e3_o ? {2'b00, one_q[7:0], 8'h0} : 18'(bl_la) * (18'd16 - 18'(bl_vf)) + 18'(bl_ua) * 18'(bl_vf);
			bl_ob <= e3_o ? {2'b00, one_q[31:24], 8'h0} : 18'(bl_lb) * (18'd16 - 18'(bl_vf)) + 18'(bl_ub) * 18'(bl_vf);
			bx_r <= e3_o ? one_q[23:16] : bl_oa[15:8];
			bx_g <= e3_o ? one_q[15:8] : bl_ob[15:8];
			ts_c <= {ts_c[1:0], bs_o >= 9'd5};
			if (e3_o) ts_c[2] <= one_q[32];
			one_ra <= one_ra + 3'd1;
		end
	wire  [7:0]  rt = t_look ? bx_r : 8'h0;
	wire  [7:0]  gt = t_look ? bx_g : 8'h0;
	wire  [7:0]  bt = t_look ? bl_oa[15:8] : 8'h0;
	wire  [7:0]  at = t_look ? bl_ob[15:8] : 8'h0;
	wire         ts = t_look && ts_c[2];

	// ---- the texture blend: T1, T2 ------------------------------------------------------------------------------------------
	logic        e1_v, e2_v, e3_v, e4_v, t2_v, t3_v, t4_v, t5_v, t6_v, t7_v, t8_v;
	wire  [7:0]  ri = fa_q[31:24], gi = fa_q[23:16], bi = fa_q[15:8], ai = fa_q[7:0];
	wire  [31:0] tcst = ts ? tm_c3 : tm_c2;
	wire  [7:0]  tcst_a = {tcst[30:24], tcst[30]};
	logic [23:0] tb_a, tb_b, tb_t;
	function automatic logic [23:0] tsel(input logic [2:0] s, input logic [23:0] i, input logic [7:0] aiv, input logic [23:0] t, input logic [7:0] atv,
		input logic [23:0] c, input logic [7:0] ca);
		case (s)
			3'd0: return {3{aiv}};
			3'd1: return i;
			3'd2: return {3{atv}};
			3'd3: return t;
			3'd4: return {3{ca}};
			3'd5: return c;
			default: return 24'h0;
		endcase
	endfunction
	function automatic logic [7:0] asel(input logic [1:0] s, input logic [7:0] aiv, input logic [7:0] atv, input logic [7:0] ca);
		case (s)
			2'd0: return aiv;
			2'd1: return atv;
			2'd2: return ca;
			default: return 8'h0;
		endcase
	endfunction
	assign tb_a = tsel(tm_tab[2:0], {ri, gi, bi}, ai, {rt, gt, bt}, at, tcst[23:0], tcst_a);
	assign tb_b = tsel(tm_tab[5:3], {ri, gi, bi}, ai, {rt, gt, bt}, at, tcst[23:0], tcst_a);
	assign tb_t = tsel(tm_tab[8:6], {ri, gi, bi}, ai, {rt, gt, bt}, at, tcst[23:0], tcst_a);
	wire  [7:0]  ta_a = asel(tm_tab[12:11], ai, at, tcst_a), ta_b = asel(tm_tab[14:13], ai, at, tcst_a);
	wire         t_mul = tm_tab[17];
	// lerp: ((255 - t) * a >> 8) + (t * b >> 8), t 255 b, t 0 a. Multiply: a * b >> 8, either 255 the other
	logic [15:0] tp1_r, tp1_g, tp1_b, tp1_a, tp2_r, tp2_g, tp2_b;
	logic [23:0] tq_a, tq_b, tq_t;
	logic [7:0]  tq_aa, tq_ab;
	function automatic logic [7:0] tbl(input logic mul, input logic [7:0] x, input logic [7:0] z, input logic [7:0] t, input logic [15:0] p1, input logic [15:0] p2);
		if (mul) return z == 8'd255 ? x : x == 8'd255 ? z : p2[15:8];
		return t == 8'd255 ? z : t == 8'd0 ? x : p1[15:8] + p2[15:8];
	endfunction
	wire  [7:0]  tbl_r = tbl(t_mul, tq_a[23:16], tq_b[23:16], tq_t[23:16], tp1_r, tp2_r);
	wire  [7:0]  tbl_g = tbl(t_mul, tq_a[15:8], tq_b[15:8], tq_t[15:8], tp1_g, tp2_g);
	wire  [7:0]  tbl_b = tbl(t_mul, tq_a[7:0], tq_b[7:0], tq_t[7:0], tp1_b, tp2_b);
	wire  [7:0]  tbl_a = tq_ab == 8'd255 ? tq_aa : tq_aa == 8'd255 ? tq_ab : tp1_a[15:8];
	logic [31:0] i_d, t_d;              // ri.. and rt.., for T2
	logic [7:0]  ti_r, ti_g, ti_b, ti_a;
	logic [7:0]  td_r, td_g, td_b, td_a;// a clock on
	logic        ts2, ts3, ts4, ts5, ts6, ts7;

	// ---- the destination ------------------------------------------------------------------------------------------------
	logic [7:0]  sr, sg, sb, sa;        // the source pixel
	logic        dsb_s;                 // its destination bit
	logic [7:0]  tp_a;                  // MAME's texpath.a and blend.r keep what they had when they aren't set
	logic        taz5, taz6, taz7, tcz5, tcz6, tcz7;    // the texture unit's alpha (after the clamp controls), its colour: zero, for the discards

	logic [7:0]  tp_an;
	always_comb
	begin
		logic [1:0] cn;
		if (td_a == 8'd0) cn = db_sa[5:4];
		else if (td_a == 8'd255) cn = db_sa[1:0];
		else cn = db_sa[3:2];
		case (cn)
			2'd0: tp_an = td_a;
			2'd1: tp_an = 8'd255;
			2'd2: tp_an = 8'd0;
			default: tp_an = tp_a;
		endcase
	end

	function automatic logic [7:0] tin(input logic [1:0] s, input logic [7:0] ti, input logic [7:0] cst, input logic [7:0] src, input logic [7:0] tia, input logic rj);
		logic [7:0] v;
		case (s)
			2'd0: v = ti;
			2'd1: v = cst;
			2'd2: v = ~src;
			default: v = tia;
		endcase
		return rj ? v >> 3 : v;
	endfunction
	function automatic logic [7:0] sin(input logic [1:0] s, input logic [7:0] src, input logic [7:0] cst, input logic [7:0] ti, input logic [7:0] srca, input logic rj);
		logic [7:0] v;
		case (s)
			2'd0: v = src;
			2'd1: v = cst;
			2'd2: v = ~ti;
			default: v = srca;
		endcase
		return rj ? v >> 3 : v;
	endfunction
	function automatic logic [7:0] coef(input logic [1:0] s, input logic [7:0] tpa, input logic [7:0] sra, input logic [7:0] c, input logic [7:0] o, input logic cmp);
		logic [7:0] v;
		case (s)
			2'd0: v = tpa;
			2'd1: v = sra;
			2'd2: v = c;
			default: v = o;
		endcase
		return cmp ? ~v : v;
	endfunction

	// the alpha's constant and the destination bit
	wire         da_sel = db_da[3:2] == 2'd0 ? ts4 : db_da[3:2] == 2'd1 ? dsb_s : 1'b0;
	wire  [7:0]  da_const = da_sel ? db_dac[7:0] : db_dac[23:16];
	logic        dsb_n;
	always_comb
		if (blen)
			case (db_ssb[1:0])
				2'd0: dsb_n = ts4;
				2'd1: dsb_n = db_ssb[2];
				default: dsb_n = dsb_s;
			endcase
		else dsb_n = ts4;
	// (the colour coefficients' constants go by the source pixel's destination bit, not the one to be written: BDA spec)
	wire         tcs = db_tmul[3:2] == 2'd0 ? ts4 : db_tmul[3:2] == 2'd1 ? dsb_s : 1'b0;
	wire         scs = db_smul[3:2] == 2'd0 ? ts4 : db_smul[3:2] == 2'd1 ? dsb_s : 1'b0;
	wire  [31:0] tcc = tcs ? db_tc1 : db_tc0;
	wire  [31:0] scc = scs ? db_sc1 : db_sc0;

	// operands (without the blend, the colour by 255), then their products
	logic [7:0]  o_tr, o_tg, o_tb, o_sr, o_sg, o_sb, o_cr, o_cg, o_cb, o_dr, o_dg, o_db;
	logic [7:0]  b_tr, b_tg, b_tb, b_sr, b_sg, b_sb;
	function automatic logic [7:0] pick(input logic [7:0] c, input logic [7:0] v, input logic [15:0] p);
		return c == 8'd255 ? v : v == 8'd255 ? c : p[15:8];
	endfunction
	function automatic logic [7:0] alu(input logic [7:0] x, input logic [7:0] z, input logic [2:0] cn, input logic [2:0] fd);
		logic [8:0] r9;
		logic [11:0] bo;
		logic borrow;
		borrow = 1'b0;
		if (!cn[2]) r9 = 9'(x) + 9'(z);
		else if (cn[1]) begin r9 = 9'(z) - 9'(x); borrow = z < x; end
		else begin r9 = 9'(x) - 9'(z); borrow = x < z; end
		case (fd)
			3'd1: bo = 12'(r9) << 1;
			3'd2: bo = 12'(r9) << 2;
			3'd3: bo = 12'(r9) << 3;
			3'd7: bo = 12'(r9) >> 1;
			3'd6: bo = 12'(r9) >> 2;
			3'd5: bo = 12'(r9) >> 3;
			default: bo = 12'(r9);
		endcase
		if (!cn[0] || cn[1])
		begin
			if (bo > 12'd255) bo = 12'd255;
			if (borrow) bo = 12'd0;
		end
		return bo[7:0];
	endfunction
	wire  [7:0]  bl_ro = blen ? alu(b_tr, b_sr, db_alu[7:5], db_alu[2:0]) : b_tr;
	wire  [7:0]  bl_go = blen ? alu(b_tg, b_sg, db_alu[7:5], db_alu[2:0]) : b_tg;
	wire  [7:0]  bl_bo = blen ? alu(b_tb, b_sb, db_alu[7:5], db_alu[2:0]) : b_tb;

	logic [3:0]  dx3, dx4, dx5, dx6;    // y, x
	wire  [31:0] dith_m = dx6[3] ? db_dmb : db_dma;
	wire  [2:0]  dith_i = 3'd7 ^ dx6[2:0];
	wire  [3:0]  dith_v = dith_m[{dith_i, 2'b00} +: 4];
	function automatic logic [7:0] dith(input logic [7:0] c, input logic [3:0] d);
		logic signed [9:0] r;
		r = $signed({2'b00, c}) + 10'($signed(d));
		if (r > 10'sd255) return 8'd255;
		if (r < 10'sd0) return 8'd0;
		return r[7:0];
	endfunction

	logic [7:0]  ds_r, ds_g, ds_b, ds8_r, ds8_g, ds8_b;
	logic [7:0]  da5, da6, da7, da8;
	logic        dsb5, dsb6, dsb7, dsb8;
	logic [15:0] w16_8;
	logic        old8;

	wire         c_zp = fc_q[73], c_zb = fc_q[72];
	wire         ssbdis = db_discard[2] && !ts7;
	// (the texture unit's output, not the blend's: BDA spec)
	wire         adis = db_discard[0] && taz7;
	wire         rgbdis = db_discard[1] && tcz7;
	wire         dis = ssbdis || adis || rgbdis;
	wire         c_wr = t7_v && !dis && c_zp && db_super[0];
	wire         old7 = c_wr && !db_dctl[0] && d_mask != 4'hf;

	assign z_wn = t7_v && !dis && c_zb && db_user[9];
	assign z_wa = fc_q[27:0];
	assign c_wn = c_wr;
	assign c_wa = fc_q[55:28];
	assign c_rn = (t2_v && sren) || old7;
	assign c_ra = old7 ? fc_q[55:28] : fb_q[27:0];
	assign c_rs32 = !old7 && db_sctl[0];
	assign z_wd = w16_8;
	assign c_wd = db_dctl[0] ? {dsb8, da8[7:1], ds8_r, ds8_g, ds8_b}
		: {16'h0, d_mask[3] ? dsb8 : c_q[15], d_mask[2] ? ds8_r[7:3] : c_q[14:10], d_mask[1] ? ds8_g[7:3] : c_q[9:5], d_mask[0] ? ds8_b[7:3] : c_q[4:0]};
	assign c_wbe = d_mask;
	assign c_wwait = old8;

	// a source other than the place written, or something handed from pixel to pixel later than it's taken, or both of the colour RAM's
	// reads: a pixel at a time
	assign       serial = (sren && (db_sbase != db_dbase || db_soff[27:16] != 12'd0 || db_soff[11:0] != 12'd0 || db_sstride != db_dstride
		|| db_sctl[0] != db_dctl[0] || (!db_dctl[0] && d_mask != 4'hf))) || (blen && db_da[1:0] == 2'd3);

	// valids
	assign       p_any = v1_v || v2_v || v3_v || v4_v || v5_v || v6_v || v7_v || v8_v || v9_v || a1_e || a2_e || a3_e || a4_e || a5_e || d0_e || d1_e || d2_e
		|| e1_v || e2_v || e3_v || e4_v || t2_v || t3_v || t4_v || t5_v || t6_v || t7_v || t8_v;

	always_ff @(posedge clk)
		if (rst)
		begin
			v1_v <= 1'b0; v2_v <= 1'b0; v3_v <= 1'b0; v4_v <= 1'b0; v5_v <= 1'b0; v6_v <= 1'b0; v7_v <= 1'b0; v8_v <= 1'b0; v9_v <= 1'b0;
			a1_v <= 1'b0; a2_v <= 1'b0; a3_v <= 1'b0; a4_v <= 1'b0; a5_v <= 1'b0; d0_v <= 1'b0; d1_v <= 1'b0; d2_v <= 1'b0;
			a1_e <= 1'b0; a2_e <= 1'b0; a3_e <= 1'b0; a4_e <= 1'b0; a5_e <= 1'b0; d0_e <= 1'b0; d1_e <= 1'b0; d2_e <= 1'b0;
			e1_v <= 1'b0; e2_v <= 1'b0; e3_v <= 1'b0; e4_v <= 1'b0;
			t2_v <= 1'b0; t3_v <= 1'b0; t4_v <= 1'b0; t5_v <= 1'b0; t6_v <= 1'b0; t7_v <= 1'b0; t8_v <= 1'b0;
			tk_i <= 1'b0;
			a1_o <= 1'b0; a2_o <= 1'b0; a3_o <= 1'b0; a4_o <= 1'b0; a5_o <= 1'b0; d0_o <= 1'b0; d1_o <= 1'b0; d2_o <= 1'b0;
			e1_o <= 1'b0; e2_o <= 1'b0; e3_o <= 1'b0;
			fw <= 5'd0; fa_r <= 5'd0; fb_r <= 5'd0; fc_r <= 5'd0;
		end
		else
		begin
			if (pu)
			begin
				v1_v <= v0_ok; v2_v <= v1_ok; v3_v <= v2_v; v4_v <= v3_v; v5_v <= v4_v; v6_v <= v5_v; v7_v <= v6_v; v8_v <= v7_v; v9_v <= v8_v;
				if (f_push) fw <= fw + 5'd1;
			end
			if (pe)
			begin
				a1_v <= v9_v && t_look;
				a1_e <= v9_v && (!t_look || t_one || tk_i);
				a1_o <= v9_v && t_look && t_one;
				if (v9_v && t_look && !t_one) tk_i <= !tk_i;
				a2_o <= a1_o; a3_o <= a2_o; a4_o <= a3_o; a5_o <= a4_o; d0_o <= a5_o; d1_o <= d0_o; d2_o <= d1_o;
				e1_o <= d2_o; e2_o <= e1_o; e3_o <= e2_o;
				a2_v <= a1_v; a3_v <= a2_v; a4_v <= a3_v; a5_v <= a4_v; d0_v <= a5_v; d1_v <= d0_v; d2_v <= d1_v;
				a2_e <= a1_e; a3_e <= a2_e; a4_e <= a3_e; a5_e <= a4_e; d0_e <= a5_e; d1_e <= d0_e; d2_e <= d1_e;
				e1_v <= d2_e; e2_v <= e1_v; e3_v <= e2_v; e4_v <= e3_v;
				t2_v <= e4_v; t3_v <= t2_v; t4_v <= t3_v; t5_v <= t4_v; t6_v <= t5_v; t7_v <= t6_v; t8_v <= t7_v;
				if (e3_v) fa_r <= fa_r + 5'd1;
				if (e4_v) fb_r <= fb_r + 5'd1;
				if (t6_v) fc_r <= fc_r + 5'd1;
			end
		end

	always_ff @(posedge clk)
		if (pe)
		begin
			// E6: T1 (255 - t: a cast would widen t before the ~, so the 8 bits are taken first)
			tp1_r <= {8'h00, ~tb_t[23:16]} * 16'(tb_a[23:16]);
			tp1_g <= {8'h00, ~tb_t[15:8]} * 16'(tb_a[15:8]);
			tp1_b <= {8'h00, ~tb_t[7:0]} * 16'(tb_a[7:0]);
			tp2_r <= 16'(t_mul ? tb_a[23:16] : tb_t[23:16]) * 16'(tb_b[23:16]);
			tp2_g <= 16'(t_mul ? tb_a[15:8] : tb_t[15:8]) * 16'(tb_b[15:8]);
			tp2_b <= 16'(t_mul ? tb_a[7:0] : tb_t[7:0]) * 16'(tb_b[7:0]);
			tp1_a <= ta_a * ta_b;
			tq_a <= tb_a; tq_b <= tb_b; tq_t <= tb_t; tq_aa <= ta_a; tq_ab <= ta_b;
			i_d <= {ri, gi, bi, ai};
			t_d <= {rt, gt, bt, at};
			ts2 <= ts;
			// T2
			case (tm_tab[10:9])
				2'd0: begin ti_r <= i_d[31:24]; ti_g <= i_d[23:16]; ti_b <= i_d[15:8]; end
				2'd1: begin ti_r <= t_d[31:24]; ti_g <= t_d[23:16]; ti_b <= t_d[15:8]; end
				2'd2: begin ti_r <= tbl_r; ti_g <= tbl_g; ti_b <= tbl_b; end
				default: begin ti_r <= 8'h0; ti_g <= 8'h0; ti_b <= 8'h0; end
			endcase
			case (tm_tab[16:15])
				2'd0: ti_a <= i_d[7:0];
				2'd1: ti_a <= t_d[7:0];
				2'd2: ti_a <= tbl_a;     // (its own multiplier, whichever the colours' function)
				default: ti_a <= 8'h0;
			endcase
			ts3 <= ts2;
			dx3 <= fb_q[31:28];
			// T3: the source
			td_r <= ti_r; td_g <= ti_g; td_b <= ti_b; td_a <= ti_a;
			ts4 <= ts3;
			dx4 <= dx3;
			if (!sren) begin sr <= 8'h0; sg <= 8'h0; sb <= 8'h0; sa <= 8'h0; dsb_s <= 1'b0; end
			else if (db_sctl[0])
			begin
				sr <= c_q[23:16]; sg <= c_q[15:8]; sb <= c_q[7:0];
				sa <= {c_q[30:24], db_sctl[1] && c_q[30]};
				dsb_s <= c_q[31];
			end
			else
			begin
				sr <= {c_q[14:10], db_sctl[1] ? c_q[14:12] : 3'b000};
				sg <= {c_q[9:5], db_sctl[1] ? c_q[9:7] : 3'b000};
				sb <= {c_q[4:0], db_sctl[1] ? c_q[4:2] : 3'b000};
				sa <= 8'h0;
				dsb_s <= c_q[15];
			end
			// T4: the operands
			if (t4_v) tp_a <= tp_an;
			if (blen)
				case (db_da[1:0])
					2'd0: da5 <= tp_an;
					2'd1: da5 <= da_const;
					2'd2: da5 <= sa;
					default: da5 <= 8'h0;   // (this pixel's red ALU, T6)
				endcase
			else da5 <= tp_an;
			dsb5 <= dsb_n;
			taz5 <= tp_an == 8'd0;
			tcz5 <= td_r == 8'd0 && td_g == 8'd0 && td_b == 8'd0;
			ts5 <= ts4;
			dx5 <= dx4;
			o_tr <= blen ? tin(db_tmul[7:6], td_r, db_constin[23:16], sr, tp_an, db_tmul[0]) : td_r;
			o_tg <= blen ? tin(db_tmul[7:6], td_g, db_constin[15:8], sg, tp_an, db_tmul[0]) : td_g;
			o_tb <= blen ? tin(db_tmul[7:6], td_b, db_constin[7:0], sb, tp_an, db_tmul[0]) : td_b;
			o_sr <= sin(db_smul[7:6], sr, db_constin[23:16], td_r, sa, db_smul[0]);
			o_sg <= sin(db_smul[7:6], sg, db_constin[15:8], td_g, sa, db_smul[0]);
			o_sb <= sin(db_smul[7:6], sb, db_constin[7:0], td_b, sa, db_smul[0]);
			o_cr <= blen ? coef(db_tmul[5:4], tp_an, sa, tcc[23:16], sr, db_tmul[1]) : 8'd255;
			o_cg <= blen ? coef(db_tmul[5:4], tp_an, sa, tcc[15:8], sg, db_tmul[1]) : 8'd255;
			o_cb <= blen ? coef(db_tmul[5:4], tp_an, sa, tcc[7:0], sb, db_tmul[1]) : 8'd255;
			o_dr <= coef(db_smul[5:4], tp_an, sa, scc[23:16], td_r, db_smul[1]);
			o_dg <= coef(db_smul[5:4], tp_an, sa, scc[15:8], td_g, db_smul[1]);
			o_db <= coef(db_smul[5:4], tp_an, sa, scc[7:0], td_b, db_smul[1]);
			// T5: the products
			b_tr <= pick(o_cr, o_tr, o_cr * o_tr);
			b_tg <= pick(o_cg, o_tg, o_cg * o_tg);
			b_tb <= pick(o_cb, o_tb, o_cb * o_tb);
			b_sr <= pick(o_dr, o_sr, o_dr * o_sr);
			b_sg <= pick(o_dg, o_sg, o_dg * o_sg);
			b_sb <= pick(o_db, o_sb, o_db * o_sb);
			da6 <= da5; dsb6 <= dsb5; ts6 <= ts5; dx6 <= dx5;
			taz6 <= taz5; tcz6 <= tcz5;
			// T6: the ALU, the dither
			ds_r <= dith_on ? dith(bl_ro, dith_v) : bl_ro;
			ds_g <= dith_on ? dith(bl_go, dith_v) : bl_go;
			ds_b <= dith_on ? dith(bl_bo, dith_v) : bl_bo;
			da7 <= blen && db_da[1:0] == 2'd3 ? bl_ro : da6; dsb7 <= dsb6; ts7 <= ts6;
			taz7 <= taz6; tcz7 <= tcz6;
			// T7: on to the writes
			ds8_r <= ds_r; ds8_g <= ds_g; ds8_b <= ds_b;
			da8 <= da7; dsb8 <= dsb7;
			w16_8 <= fc_q[71:56];
			old8 <= old7;
		end

	// ---- the machine ---------------------------------------------------------------------------------------------------
	logic [7:0]  rcnt;
	logic [15:0] roffs;
	logic [31:0] end_set, ist_set;
	logic        run_stop, start_p;
	logic [13:0] mm_dst;
	logic        mm_pip;
	wire  [31:0] dc_new = md(gc_dcntl, ls_d, ls_a[12:11]);
	wire         regs_end = rcnt == 8'hff;  // (once it's been counted down past the last)

	always_ff @(posedge clk)
	begin
		ls_we <= 1'b0;
		ld_tram <= 1'b0;
		ld_pip <= 1'b0;
		vw_e <= 1'b0;
		lb_inv <= 1'b0;
		c_flush <= 1'b0;
		c_fdone <= !c_flush && (c_fdone || cc_flushed);
		ist_set <= 32'h0;
		rf_we <= 1'b0;
		// the fixed-point value of the last clock's float
		fx_to <= 2'd3;
		case (fx_to)
			2'd0: slope[fx_at] <= fx_o;
			2'd1: ddx[fx_at] <= fx_o;
			2'd2: e_v[fx_at] <= fx_o;
			default: ;
		endcase

		if (rst)
		begin
			st <= I_STOP;
			gc_master <= 32'h0; gc_idata <= 32'h0; gc_ddata <= 32'h0; gc_dcntl <= 32'h0; gc_iwp <= 32'h0; gc_irp <= 32'h0; gc_ien <= 32'h0; gc_ist <= 32'h0;
			fd_run <= 1'b0; vf_v <= 1'b0; vm_v <= 4'd0;
			es_cntl <= 3'd0; vcnt <= 2'd0; tsort <= 3'd0; run_stop <= 1'b0; start_p <= 1'b0; end_set <= 32'h0;
			db_super <= 32'h0; db_user <= 32'h0; db_discard <= 32'h0; tm_cntl <= 32'h0; tm_addr <= 32'h0;
		end
		else
		begin
			// ---- the state machine ----
			case (st)
				I_STOP: ;
				I_FLUSH:
					if (!c_flush && c_fdone)
					begin
						ist_set <= end_set;
						end_set <= 32'h0;
						lb_inv <= 1'b1;
						run_stop <= 1'b0;
						st <= start_p ? I_FETCH : I_STOP;
						start_p <= 1'b0;
					end

				// ---- the list ----
				I_FETCH:
					if (f_ok)
					begin
						gc_irp <= gc_irp + 32'd4;
						if (f_w[31:28] == 4'h1)
						begin
							roffs <= f_w[15:0]; rcnt <= f_w[23:16];
							st <= I_REGS;
						end
						else if (f_w[31:28] == 4'h2 && f_w[27:24] == 4'h0)
						begin
							vn <= f_w[15:0];
							v_fl <= f_w[20:16];
							st <= V_NEXT;
						end
						else
						begin
							end_set <= end_set | 32'h00002000 | (32'(gc_master[0]) << 9);
							c_flush <= 1'b1;
							st <= I_FLUSH;
						end
					end
				I_REGS:
					if (f_ok)
					begin
						gc_irp <= gc_irp + 32'd4;
						ls_we <= 1'b1;
						ls_a <= roffs[15:2];
						ls_d <= f_w;
						st <= I_REGW;
					end
				I_REGW:
				begin
					// the write lands in this clock
					rcnt <= rcnt - 8'd1;
					roffs <= roffs + 16'd4;
					st <= rcnt == 8'd0 ? I_AFTER : I_REGS;
					if (ls_a[15:13] == 3'd0 && ls_a[10:2] == 9'd5)
					begin
						if (dc_new[5]) ;
						else if (dc_new[4]) begin run_stop <= 1'b1; st <= I_AFTER; end
						else if (dc_new[3]) ist_set <= 32'h00080000;
						else if (dc_new[2]) gc_irp <= gc_irp + gc_ddata;
						else if (dc_new[1]) gc_irp <= gc_ddata;
						else if (dc_new[0]) st <= T_LOAD;
					end
				end
				T_LOAD:
				if (!lb_rd && !lb_wait)
				begin
					st <= regs_end ? I_AFTER : I_REGS;
					mm_src <= tm_src; mm_dst <= tm_lod0[13:0]; mm_n <= tm_count[27:0];
					ms_a <= tm_src[31:5]; ms_left <= ml_ld; ms_more <= !ml_ld[28] && ml_ld != 29'd0; ms_skip <= tm_src[4:3];
					ms_req <= 5'd0; ms_wp <= 5'd0; ms_wpd <= 5'd0; ms_rp <= 5'd0;
					ms_arm <= tm_src[1:0] != 2'd0;
					if (tm_ldcntl[9:8] == 2'd1)
					begin
						mm_pip <= !tm_cntl[2];
						if (tm_cntl[3:2] != 2'd0) st <= T_MM;
					end
					else if (tm_ldcntl[9:8] == 2'd2)
					begin
						mm_pip <= 1'b1;
						st <= T_MM;
					end
				end
				T_MM:
				begin
					ms_wpd <= ms_wp;
					ms_rp <= ms_rn;
					if (m_ready) ms_wp <= ms_wp + 5'd1;
					if (ms_rd && !m_busy)
					begin
						ms_a <= ms_a + 27'd1;
						ms_left <= ml_dn; ms_more <= !ml_dn[28] && ml_dn != 29'd0;
						ms_req <= ms_req + 5'd4;
					end
					if (mm_n == 28'd0 && !ms_more && ms_req == ms_wp) st <= regs_end ? I_AFTER : I_REGS;
					else if (ms_take)
					begin
						if (ms_skip != 2'd0) ms_skip <= ms_skip - 2'd1;
						else if (ms_arm)
						begin
							ms_arm <= 1'b0;
							ms_prev <= ms_raw;
							mm_src <= mm_src + 32'd4;
						end
						else
						begin
							ms_prev <= ms_raw;
							ld_d <= mm_pip ? {ms_w[7:0], ms_w[15:8], ms_w[23:16], ms_w[31:24]} : ms_w;
							ld_d2 <= ms_q[63:32];
							ld_two <= ms_two;
							ld_ta <= mm_dst[13:2];
							ld_pa <= mm_dst[9:2];
							ld_tram <= !mm_pip;
							ld_pip <= mm_pip;
							mm_src <= mm_src + (ms_two ? 32'd8 : 32'd4);
							mm_dst <= mm_dst + (ms_two ? 14'd8 : 14'd4);
							mm_n <= ms_two ? mm_n - 28'd8 : mm_n < 28'd4 ? 28'd0 : mm_n - 28'd4;
						end
					end
				end
				I_AFTER:
					if (gc_irp == gc_iwp)
					begin
						end_set <= end_set | 32'h00000400 | (32'(gc_master[0]) << 9);
						c_flush <= 1'b1;
						st <= I_FLUSH;
					end
					else if (run_stop || gc_master[3] || gc_master[1])
					begin
						end_set <= end_set | (32'(gc_master[0]) << 9);
						c_flush <= 1'b1;
						st <= I_FLUSH;
					end
					else st <= I_FETCH;

				// ---- a vertex ----
				V_NEXT:
				begin
					// where it goes (add_vertex)
					vf_i <= 4'd0;
					st <= V_FIELD;
					if (f_new || vcnt != 2'd3)
					begin
						vslot <= f_new ? 2'd0 : vcnt;
						vcnt <= f_new ? 2'd1 : vcnt + 2'd1;
						tsort <= (!f_new && vcnt == 2'd2) ? 3'd1 : f_new ? 3'd0 : tsort;
					end
					else if (f_rm)
						case (tsort)
							3'd1: begin vslot <= 2'd1; tsort <= 3'd3; end
							3'd2: begin vslot <= 2'd0; tsort <= 3'd6; end
							3'd3: begin vslot <= 2'd2; tsort <= 3'd1; end
							3'd4: begin vslot <= 2'd2; tsort <= 3'd5; end
							3'd5: begin vslot <= 2'd0; tsort <= 3'd4; end
							default: begin vslot <= 2'd1; tsort <= 3'd2; end
						endcase
					else
						case (tsort)
							3'd1: begin vslot <= 2'd0; tsort <= 3'd4; end
							3'd2: begin vslot <= 2'd2; tsort <= 3'd1; end
							3'd3: begin vslot <= 2'd0; tsort <= 3'd6; end
							3'd4: begin vslot <= 2'd1; tsort <= 3'd2; end
							3'd5: begin vslot <= 2'd1; tsort <= 3'd3; end
							default: begin vslot <= 2'd2; tsort <= 3'd5; end
						endcase
				end
				V_FIELD:
				begin
					// a field a clock; it goes on through the multiplier by itself (below)
					vf_v <= 1'b0;
					if (vf_i == 4'd9) st <= V_DONE;
					else if (!v_have) begin fw_q <= 32'h0; vf_d <= vf_i; vf_v <= 1'b1; vf_i <= vf_i + 4'd1; end
					else if (f_ok)
					begin
						fw_q <= f_w;
						vf_d <= vf_i;
						vf_v <= 1'b1;
						vf_i <= vf_i + 4'd1;
						gc_irp <= gc_irp + 32'd4;
					end
				end
				V_DONE:
				begin
					v_fl[3] <= 1'b0;
					st <= vcnt == 2'd3 ? S_SORT : E_NEXT;
				end

				// ---- setup ----
				S_SORT:
				begin
					logic [1:0] t1, t2, t3;
					logic [7:0] wm;
					st <= S_AR;
					ss <= 4'd0;
					aria <= 30'sh0;
					t1 = 2'd0; t2 = 2'd0; t3 = 2'd0;
					case ({yi[0] < yi[1], yi[1] < yi[2], yi[2] < yi[0]})
						3'd1: begin t1 = 2'd2; t2 = 2'd1; t3 = 2'd0; end
						3'd2: begin t1 = 2'd1; t2 = 2'd0; t3 = 2'd2; end
						3'd3: begin t1 = 2'd1; t2 = 2'd2; t3 = 2'd0; end
						3'd4: begin t1 = 2'd0; t2 = 2'd2; t3 = 2'd1; end
						3'd5: begin t1 = 2'd2; t2 = 2'd0; t3 = 2'd1; end
						3'd6: begin t1 = 2'd0; t2 = 2'd1; t3 = 2'd2; end
						default: st <= E_NEXT;
					endcase
					v_top <= t1; v_mid <= t2; v_bot <= t3;
					x1 <= xi[t1]; x2 <= xi[t2]; x3 <= xi[t3];
					y1 <= yi[t1]; y2 <= yi[t2]; y3 <= yi[t3];
					wm = wexp[0];
					if (wexp[1] > wm) wm = wexp[1];
					if (wexp[2] > wm) wm = wexp[2];
					if (!f_prsp || wm >= 8'd124) wrange <= 2'd0;
					else if (wm >= 8'd121) wrange <= 2'd1;
					else if (wm >= 8'd118) wrange <= 2'd2;
					else wrange <= 2'd3;
				end
				S_AR:
				begin
					// x1 * y23 + x2 * y31 + x3 * y12
					ss <= ss + 4'd1;
					case (ss)
						4'd0: begin mx_a <= 18'(x1); mx_b <= 18'(y23); end
						4'd1: begin mx_a <= 18'(x2); mx_b <= 18'(y31); end
						4'd2: begin mx_a <= 18'(x3); mx_b <= 18'(y12); aria <= 30'(mx_r); end
						4'd3, 4'd4: aria <= aria + 30'(mx_r);
						4'd5:
						begin
							// (the magnitude a clock before the float: the negation was much of a long path)
							ar_u <= aria < 0 ? 30'(-aria) : 30'(aria);
							ar_n <= aria < 0;
							scan_lr <= aria > 0;
							if (aria == 30'sh0) st <= E_NEXT;
						end
						default:
						begin
							fa_aria <= utof(ar_n, ar_u);
							fd_i <= 5'd0;
							fd_r <= 26'h0800000;
							fd_q <= 27'd0;
							fd_run <= 1'b1;
							div_i <= 2'd0;
							st <= S_DIV0;
						end
					endcase
				end
				S_FD: if (!fd_run) st <= S_FDE;
				S_FDE:
				begin
					logic [7:0] e;
					logic [24:0] mt;
					if (fd_q[26])
					begin
						e = 8'd254 - fa_aria[30:23];
						mt = 25'h0800000;
					end
					else
					begin
						e = 8'd253 - fa_aria[30:23];
						mt = {1'b0, fd_q[25:2]} + 25'(fd_q[1] && (fd_q[2] || fd_q[0] || fd_r != 26'd0));
						if (mt[24]) begin e = e + 8'd1; mt = 25'h0800000; end
					end
					rf_we <= 1'b1; rf_wa <= rf_ad(3'd0, 5'd23); rf_wd <= {fa_aria[31], e, mt[22:0]};
					st <= S_XYS;
				end
				S_DIV0:
				begin
					dv_n <= dv_nabs;
					dv_d <= dv_dn < 0 ? 14'(-dv_dn) : 14'(dv_dn);
					dv_q <= 14'd0; dv_r <= 15'd0;
					dv_i <= 4'd0;
					for (int b = 1; b < 14; b++) if (dv_nabs[b]) dv_i <= 4'(b);
					st <= S_DIV1;
				end
				S_DIV1:
				begin
					logic [14:0] t;
					t = {dv_r[13:0], dv_n[dv_i]};
					if (t >= 15'(dv_d)) begin dv_r <= t - 15'(dv_d); dv_q[dv_i] <= 1'b1; end
					else dv_r <= t;
					dv_i <= dv_i - 4'd1;
					if (dv_i == 4'd0) st <= S_DIV2;
				end
				S_DIV2:
				begin
					// (the divide is by |y|, so the sign's the numerator's)
					logic signed [13:0] res;
					if (dv_dn == 0) res = 14'sd0;
					else if (dv_nm < 0) res = (dv_flr && dv_r != 15'd0) ? -$signed(dv_q) - 14'sd1 : -$signed(dv_q);
					else res = (!dv_flr && dv_r != 15'd0) ? $signed(dv_q) + 14'sd1 : $signed(dv_q);
					case (div_i)
						2'd0: xstep0 <= res;
						2'd1: xstep1 <= res;
						default: xstepl <= res;
					endcase
					div_i <= div_i + 2'd1;
					ss <= 4'd0;
					st <= div_i == 2'd2 ? S_FD : S_DIV0;
				end
				S_XYS:
				begin
					// x12 - xstep0 * y12, and so on
					ss <= ss + 4'd1;
					case (ss)
						4'd0: begin mx_a <= 18'(xstep0); mx_b <= 18'(y12); end
						4'd1: begin mx_a <= 18'(xstep1); mx_b <= 18'(y23); end
						4'd2: begin mx_a <= 18'(xstepl); mx_b <= 18'(y31); xys0 <= x12 - 14'(mx_r); end
						4'd3: xys1 <= x23 - 14'(mx_r);
						default:
						begin
							xysl <= x31 - 14'(mx_r);
							dy0 <= -y12; dy1 <= -y23; dyl <= -y31;
							fc_i <= 3'd0;
							st <= S_FC;
						end
					endcase
				end
				S_FC:
				begin
					// the value a clock, its conversion the next
					case (fc_i)
						3'd0: fc_c <= y23;
						3'd1: fc_c <= y31;
						3'd2: fc_c <= y12;
						3'd3: fc_c <= x23;
						3'd4: fc_c <= x31;
						3'd5: fc_c <= x12;
						default: fc_c <= xstepl;
					endcase
					if (fc_i != 3'd0)
					begin
						rf_we <= 1'b1; rf_wa <= rf_ad(3'd0, 5'd16 + 5'(fc_i - 3'd1)); rf_wd <= itof(30'(fc_c));
					end
					fc_i <= fc_i + 3'd1;
					if (fc_i == 3'd7) begin at_i <= 3'd0; at_mask <= 7'd0; tri_flat <= 1'b1; st <= S_ATTR; end
				end
				S_ATTR:
					if (at_i == 3'd7)
					begin
						if (at_mask == 7'd0) st <= E_START;
						else begin j_m <= 4'd13; j_v <= 4'd0; st <= S_JOB; end
					end
					else if (!at_have)
					begin
						e_v[at_i] <= '0; ddx[at_i] <= '0; slope[at_i] <= '0;
						at_i <= at_i + 3'd1;
					end
					else if (at_i[2])
					begin
						at_mask[at_i] <= 1'b1;
						at_i <= at_i + 3'd1;
					end
					else
					begin
						vr_a <= {v_top, af(at_i)};
						st <= S_Q1;
					end
				S_Q1: begin vr_a <= {v_mid, af(at_i)}; st <= S_Q2; end
				S_Q2: begin q1f <= vr_q; vr_a <= {v_bot, af(at_i)}; st <= S_Q3; end
				S_Q3: begin q2f <= vr_q; st <= S_Q4; end
				S_Q4: begin q3f <= vr_q; st <= S_OP; end
				S_OP:
					// (a colour the same at all three corners: whole numbers up to 255, so nothing rounds, and the slopes come to nothing)
					if (q1f == q2f && q1f == q3f)
					begin
						slope[at_i] <= '0; ddx[at_i] <= '0;
						fx_f <= q1f; fx_sh <= 11'(q1f[30:23]) - 11'sd127 - 11'(af_bits(at_i)); fx_at <= at_i; fx_to <= 2'd2;
						st <= S_FX1;
					end
					else
					begin
						at_mask[at_i] <= 1'b1;
						tri_flat <= 1'b0;
						at_i <= at_i + 3'd1;
						st <= S_ATTR;
					end
				S_FX1:
				begin
					at_i <= at_i + 3'd1;
					st <= S_ATTR;
				end
				S_JOB:
				begin
					fsub <= 1'b0;
					j_m <= j_m == 4'd13 ? 4'd0 : j_m + 4'd1;
					case (j_m)
						4'd0: begin vr_a <= {v_mid, af(j_a[0])}; fa <= rfa_q; fb <= rfb_q; end
						4'd1: begin vr_a <= {v_top, af(j_a[0])}; rf_we <= j_v[1]; rf_wa <= rf_ad(j_a[1], 5'd8); rf_wd <= fadd_r; fa <= rfa_q; fb <= rfb_q; end
						4'd2: begin vr_a <= {v_mid, af(j_a[0])}; fa <= vr_q; fb <= rfb_q; rf_we <= j_v[2]; rf_wa <= rf_ad(j_a[2], 5'd10); rf_wd <= fadd_r; end
						4'd3: begin vr_a <= {v_top, af(j_a[0])}; fa <= vr_q; fb <= rfb_q; rf_we <= j_v[1]; rf_wa <= rf_ad(j_a[1], 5'd7); rf_wd <= fadd_r; end
						4'd4: begin fa <= vr_q; fb <= rfb_q; vr_a <= {v_bot, af(j_a[0])}; rf_we <= j_v[3]; rf_wa <= rf_ad(j_a[3], 5'd11); rf_wd <= fadd_r; fx_f <= fmul_r; fx_sh <= 11'(fmul_r[30:23]) - 11'sd127 - 11'(af_bits(j_a[3])); fx_at <= j_a[3]; fx_to <= j_v[3] ? 2'd1 : 2'd3; end
						4'd5: begin fa <= vr_q; fb <= rfb_q; rf_we <= j_v[2]; rf_wa <= rf_ad(j_a[2], 5'd6); rf_wd <= fmul_r; vr_a <= {v_top, af(j_a[0])}; end
						4'd6: begin fa <= vr_q; fb <= rfb_q; rf_we <= j_v[0]; rf_wa <= rf_ad(j_a[0], 5'd4); rf_wd <= fmul_r; end
						4'd7: begin rf_we <= j_v[0]; rf_wa <= rf_ad(j_a[0], 5'd3); rf_wd <= fmul_r; vr_a <= {v_bot, af(j_a[0])}; fa <= rfa_q; fb <= rfb_q; fx_f <= vr_q; fx_sh <= 11'(vr_q[30:23]) - 11'sd127 - 11'(af_bits(j_a[0])); fx_at <= j_a[0]; fx_to <= j_v[0] ? 2'd2 : 2'd3; end
						4'd8: begin rf_we <= j_v[0]; rf_wa <= rf_ad(j_a[0], 5'd1); rf_wd <= fmul_r; fa <= rfa_q; fb <= rfb_q; end
						4'd9: begin rf_we <= j_v[0]; rf_wa <= rf_ad(j_a[0], 5'd0); rf_wd <= fmul_r; fa <= vr_q; fb <= rfb_q; end
						4'd10: begin rf_we <= j_v[0]; rf_wa <= rf_ad(j_a[0], 5'd2); rf_wd <= fmul_r; fa <= rfa_q; fb <= rfb_q; end
						4'd11: begin fa <= rfa_q; fb <= rfb_q; end
						4'd12: begin fa <= rfa_q; fb <= rfb_q; rf_we <= j_v[1]; rf_wa <= rf_ad(j_a[1], 5'd9); rf_wd <= fadd_r; fx_f <= fmul_r; fx_sh <= 11'(fmul_r[30:23]) - 11'sd127 - 11'(af_bits(j_a[3])); fx_at <= j_a[3]; fx_to <= j_v[3] ? 2'd0 : 2'd3; end
						4'd13: begin rf_we <= j_v[0]; rf_wa <= rf_ad(j_a[0], 5'd5); rf_wd <= fmul_r; fa <= rfa_q; fb <= rfb_q; fsub <= 1'b1; end
						default: ;
					endcase
					if (j_m == 4'd13)
					begin
						j_v <= {j_v[2:0], at_mask != 7'd0};
						j_a[0] <= j_nx; j_a[1] <= j_a[0]; j_a[2] <= j_a[1]; j_a[3] <= j_a[2];
						if (at_mask != 7'd0) at_mask[j_nx] <= 1'b0;
						else if (j_v[2:0] == 3'd0) st <= E_START;
					end
				end

				// ---- the walk ----
				E_START:
				if (!p_any)
				begin
					y <= y1;
					cf_short <= 14'sd0; cf_long <= 14'sd0;
					omit_right <= 1'b1;
					xs <= x1;
					if (y1 == y2)
					begin
						xystep <= xys1; xstep <= xstep1; dy <= dy1;
						xe <= x2;
					end
					else
					begin
						xystep <= xys0; xstep <= xstep0; dy <= dy0;
						xe <= x1;
					end
					y_n <= y1;
					nx_last <= 1'b0;
					px <= 14'sd0; pxe <= 14'sd0;
					ss <= 4'd0;
					nx <= NX_ROW;
					st <= P_RUN;
				end

				// ---- a pixel ----
				P_RUN:
					if (px == pxe)
					begin
						if (nx == NX_DONE)
						begin
							if (nx_last) st <= E_NEXT;
							else
							begin
								// a line's start (walk_span's copies of the edge's)
								y <= y_n;
								row_d <= row_dn; row_z <= row_zn; row_s <= row_sn;
								for (int i = 0; i < 7; i++) s_v[i] <= (omit_right && !scan_lr) ? e_v[i] - ddx[i] : e_v[i];
								px <= (omit_right && !scan_lr) ? xs - 14'sd1 : xs;
								pxe <= omit_right ? (scan_lr ? xe : xe - 14'sd1) : (scan_lr ? xe + 14'sd1 : xe - 14'sd1);
								nx <= NX_N1;
							end
						end
					end
					else if (v0_go)
					begin
						for (int i = 0; i < 4; i++) s_v[i] <= clamp19(scan_lr ? s_v[i] + ddx[i] : s_v[i] - ddx[i]);
						for (int i = 4; i < 7; i++) s_v[i] <= clamp23(scan_lr ? s_v[i] + ddx[i] : s_v[i] - ddx[i]);
						px <= scan_lr ? px + (v0_four ? 14'sd4 : 14'sd1) : px - (v0_four ? 14'sd4 : 14'sd1);
					end

				// ---- the triangle's done, or there wasn't one: the next vertex, or the list ----
				E_NEXT:
					if (!p_any || vn != 16'd0)
					begin
						vn <= vn - 16'd1;
						st <= vn == 16'd0 ? I_AFTER : V_NEXT;
					end
				default: st <= I_STOP;
			endcase

			// 1.0 / the mantissa, a bit a clock: 27, the first being whether it's 1 exactly
			if (fd_run)
			begin
				fd_q <= {fd_q[25:0], fd_ge};
				fd_r <= (fd_ge ? fd_r - fd_m : fd_r) << 1;
				fd_i <= fd_i + 5'd1;
				if (fd_i == 5'd26) fd_run <= 1'b0;
			end

			// a vertex's field, from the list: X, Y and W's exponent are registers; the colours are scaled and made whole; all but X and Y go to the vertices' memory
			// (by 1, the rest: the same number), when the multiplier's done. S_SORT reads none till long after
			vm_v <= {vm_v[2:0], vf_v && vf_d >= 4'd2};
			vm_c <= {vm_c[2:0], vf_d < 4'd6};
			vm_a[0] <= {vslot, vf_d};
			vm_a[1] <= vm_a[0]; vm_a[2] <= vm_a[1]; vm_a[3] <= vm_a[2];
			if (vm_v[3])
			begin
				vw_e <= 1'b1;
				vw_a <= vm_a[3];
				vw_d <= vm_c[3] ? ftrunc(fmul_r) : fmul_r;
			end
			if (vf_v && st != V_DONE)
			begin
				if (vf_d == 4'd0) xi[vslot] <= ftoi(fw_q);
				if (vf_d == 4'd1) yi[vslot] <= ftoi(fw_q);
				if (vf_d == 4'd6) wexp[vslot] <= fw_q[30:23];
			end
			if (vf_v)
			begin
				fa <= fw_q;
				fb <= vf_d < 4'd6 ? 32'h437f0000 : 32'h3f800000;     // 255, 1
			end

			// ---- the next line ----
			if (st == P_RUN)
			case (nx)
				NX_N1:
				begin
					omit_right <= 1'b0;
					cf_short <= cf_short + xystep;
					cf_long <= cf_long + xysl;
					xs <= xs + xstepl;
					xe <= xe + xstep;
					nx <= NX_N2;
				end
				NX_N2:
				begin
					step_back <= 1'b0;
					if (scan_lr)
					begin
						if (!ins_long) begin step_back <= 1'b1; cf_long <= cf_long + dyl; xs <= xs + 14'sd1; end
						if (dsp_off ? !ins_short : !ein_short) begin cf_short <= cf_short - dy; xe <= xe - 14'sd1; end
					end
					else
					begin
						if (!ins_short) begin cf_short <= cf_short + dy; xe <= xe + 14'sd1; end
						if (dsp_off ? !ins_long : !ein_long) begin step_back <= 1'b1; cf_long <= cf_long - dyl; xs <= xs - 14'sd1; end
					end
					nx <= NX_A1;
				end
				NX_A1:
				begin
					// slope, then, if it stepped back, ddx; clamped at the end of that
					for (int i = 0; i < 7; i++)
						if ((i < 4 && !m_dshade) || ((i == A_UW || i == A_VW) && !es_cntl[1]) || (i == A_W && !persp_off))
						begin
							if (step_back) e_v[i] <= e_v[i] + slope[i];
							else e_v[i] <= i < 4 ? clamp19(e_v[i] + slope[i]) : clamp23(e_v[i] + slope[i]);
						end
					nx <= step_back ? NX_A2 : NX_LINE;
				end
				NX_A2:
				begin
					for (int i = 0; i < 7; i++)
						if ((i < 4 && !m_dshade) || ((i == A_UW || i == A_VW) && !es_cntl[1]) || (i == A_W && !persp_off))
							e_v[i] <= i < 4 ? clamp19(scan_lr ? e_v[i] + ddx[i] : e_v[i] - ddx[i]) : clamp23(scan_lr ? e_v[i] + ddx[i] : e_v[i] - ddx[i]);
					nx <= NX_LINE;
				end
				NX_LINE:
				begin
					logic signed [13:0] ny;
					ny = du_scan ? y_n - 14'sd1 : y_n + 14'sd1;
					if (ny == y2)
					begin
						cf_short <= 14'sd0;
						xystep <= xys1; xstep <= xstep1; dy <= dy1;
						xe <= x2;
						if (scan_lr) omit_right <= 1'b1;
					end
					y_n <= ny;
					ss <= 4'd0;
					// (the rows' products, a line on from the last's)
					row_dn <= du_scan ? row_dn - 28'(db_dstride[10:0]) : row_dn + 28'(db_dstride[10:0]);
					row_zn <= du_scan ? row_zn - 28'(db_dstride[10:0]) : row_zn + 28'(db_dstride[10:0]);
					row_sn <= du_scan ? row_sn - 28'(db_sstride[10:0]) : row_sn + 28'(db_sstride[10:0]);
					nx <= NX_DONE;
					if (ny == y3) nx_last <= 1'b1;
				end
				NX_ROW:
				begin
					// the rows' products, three, one after another
					ss <= ss + 4'd1;
					case (ss)
						4'd0: begin mx_a <= 18'(y_n); mx_b <= 18'({1'b0, db_dstride[10:0]}); end
						4'd1: begin mx_a <= 18'(z_yn); mx_b <= 18'({1'b0, db_dstride[10:0]}); end
						4'd2: begin mx_a <= 18'(s_yn); mx_b <= 18'({1'b0, db_sstride[10:0]}); row_dn <= mx_r[27:0]; end
						4'd3: row_zn <= mx_r[27:0];
						default: begin row_sn <= mx_r[27:0]; nx <= NX_DONE; end
					endcase
				end
				default: ;
			endcase

			// ---- the register writes, last: a start wins ----
			if (r_we)
				case (r_unit)
					3'd0:
						case (r_reg)
							9'd0: gc_master <= md(gc_master, r_d, r_mode);
							9'd2: gc_idata <= md(gc_idata, r_d, r_mode);
							9'd3:
							begin
								// (TEICNTL lands on the master mode as well, in MAME; list ends and so on test it there)
								gc_master <= md(gc_master, r_d, r_mode);
								if (ic_new[5] || ic_new[4])
								begin
									if (ic_new[5]) gc_irp <= gc_idata;
									lb_inv <= 1'b1;
									run_stop <= 1'b0;
									if (st == I_FLUSH) start_p <= 1'b1;
									else st <= I_FETCH;
								end
							end
							9'd4: gc_ddata <= md(gc_ddata, r_d, r_mode);
							9'd5: gc_dcntl <= md(gc_dcntl, r_d, r_mode);
							9'd6: gc_iwp <= md(gc_iwp, r_d, r_mode);
							9'd7: gc_irp <= md(gc_irp, r_d, r_mode);
							9'd8: gc_ien <= md(gc_ien, r_d, r_mode);
							default: ;
						endcase
					3'd2: if (r_reg == 9'd0) es_cntl <= 3'(md(32'(es_cntl), r_d, r_mode));
					3'd3:
						if (r_reg[8])
							case (r_reg[7:0])
								8'd0: tm_cntl <= md(tm_cntl, r_d, r_mode);
								8'd1: tm_ldcntl <= md(tm_ldcntl, r_d, r_mode);
								8'd2: tm_addr <= md(tm_addr, r_d, r_mode);
								8'd3: tm_pip <= md(tm_pip, r_d, r_mode);
								8'd4: tm_tab <= md(tm_tab, r_d, r_mode);
								8'd5: tm_lod0 <= md(tm_lod0, r_d, r_mode);
								8'd9: tm_src <= md(tm_src, r_d, r_mode);
								8'd10: tm_count <= md(tm_count, r_d, r_mode);
								8'd11: tm_uvmax <= md(tm_uvmax, r_d, r_mode);
								8'd12: tm_uvmask <= md(tm_uvmask, r_d, r_mode);
								8'd15: tm_exp <= md(tm_exp, r_d, r_mode);
								8'd16: tm_c0 <= md(tm_c0, r_d, r_mode);
								8'd17: tm_c1 <= md(tm_c1, r_d, r_mode);
								8'd18: tm_c2 <= md(tm_c2, r_d, r_mode);
								8'd19: tm_c3 <= md(tm_c3, r_d, r_mode);
								default: ;
							endcase
					3'd4:
						case (r_reg)
							9'd1: db_super <= md(db_super, r_d, r_mode);
							9'd2: db_user <= md(db_user, r_d, r_mode);
							9'd3: db_discard <= md(db_discard, r_d, r_mode);
							9'd6: db_fbclip <= md(db_fbclip, r_d, r_mode);
							9'd7: db_xwin <= md(db_xwin, r_d, r_mode);
							9'd8: db_ywin <= md(db_ywin, r_d, r_mode);
							9'd9: db_dctl <= md(db_dctl, r_d, r_mode);
							9'd10: db_dbase <= md(db_dbase, r_d, r_mode);
							9'd11: db_dstride <= md(db_dstride, r_d, r_mode);
							9'd12: db_sctl <= md(db_sctl, r_d, r_mode);
							9'd13: db_sbase <= md(db_sbase, r_d, r_mode);
							9'd14: db_sstride <= md(db_sstride, r_d, r_mode);
							9'd15: db_soff <= md(db_soff, r_d, r_mode);
							9'd16: db_zctl <= md(db_zctl, r_d, r_mode);
							9'd17: db_zbase <= md(db_zbase, r_d, r_mode);
							9'd18: db_zoff <= md(db_zoff, r_d, r_mode);
							9'd19: db_zclip <= md(db_zclip, r_d, r_mode);
							9'd20: db_ssb <= md(db_ssb, r_d, r_mode);
							9'd21: db_constin <= md(db_constin, r_d, r_mode);
							9'd22: db_tmul <= md(db_tmul, r_d, r_mode);
							9'd23: db_tc0 <= md(db_tc0, r_d, r_mode);
							9'd24: db_tc1 <= md(db_tc1, r_d, r_mode);
							9'd25: db_smul <= md(db_smul, r_d, r_mode);
							9'd26: db_sc0 <= md(db_sc0, r_d, r_mode);
							9'd27: db_sc1 <= md(db_sc1, r_d, r_mode);
							9'd28: db_alu <= md(db_alu, r_d, r_mode);
							9'd29: db_sa <= md(db_sa, r_d, r_mode);
							9'd30: db_da <= md(db_da, r_d, r_mode);
							9'd31: db_dac <= md(db_dac, r_d, r_mode);
							9'd32: db_dma <= md(db_dma, r_d, r_mode);
							9'd33: db_dmb <= md(db_dmb, r_d, r_mode);
							default: ;
						endcase
					default: ;
				endcase
			gc_ist <= ((r_we && r_unit == 3'd0 && r_reg == 9'd9) ? md(gc_ist, r_d, r_mode) : gc_ist) | ist_set;
		end
	end
	// verilator lint_on UNUSEDSIGNAL
endmodule

// a write-back cache, direct mapped, 128 lines of 32 bytes, one each for Z and the colours. One read and one write a clock, the answer or
// a stall in the clock after the address (in *_n); a stalled port's address stays. A write allocates without reading: each byte has a bit
// for whether it's been written, and a line goes back as those alone; a read of a line that's only been written sends them, then fills it.
// A write goes as soon as it hits, in case the read waiting for the same line index would take it away; it's done with then
module te_cache (
	input  logic        clk,
	input  logic        rst,

	input  logic        sink_in,        // the line in hand needn't go to memory
	output logic        m_sink,         // it isn't: its word's on m_wd for the copy

	input  logic        r_n,
	input  logic [27:1] r_na,
	input  logic        r_ns32,         // 32 bits, else 16
	input  logic        r_adv,
	output logic [31:0] q,
	output logic        r_stall,

	input  logic        w_n,
	input  logic [27:1] w_na,
	input  logic        w_ns32,
	input  logic        w_nfour,        // the whole 64
	input  logic        w_adv,
	input  logic        w_wait,         // what it writes needs the read's answer
	input  logic [31:0] wd,             // in the clock after the address
	input  logic [3:0]  be,             // of the 32: bit 3 the byte first in memory
	output logic        w_stall,

	input  logic        flush,
	output logic        flushed,

	output logic        m_req,          // it wants the memory port until this falls
	input  logic        m_gnt,
	output logic        m_rd,
	output logic        m_we,
	output logic [31:3] m_a,
	output logic [63:0] m_wd,
	output logic [7:0]  m_be,
	input  logic        m_busy,
	input  logic        m_ready,
	input  logic [63:0] m_dout
);
	typedef enum logic [3:0] { C_INIT, C_IDLE, C_EVW, C_FILL, C_FILLW, C_REARM, C_FWALK, C_FLOOK, C_FEND } cst_t;
	cst_t        st;
	logic [6:0]  walk;
	logic        walking;               // the eviction's the flush's
	logic        fill;                  // what comes after the eviction: a fill, or the line just cleared

	logic        r_v, w_v, w_done, r_s32, w_s32, w_go, w_four;
	logic [27:1] r_a, w_a;
	always_ff @(posedge clk)
		if (rst) begin r_v <= 1'b0; w_v <= 1'b0; w_done <= 1'b0; end
		else
		begin
			if (r_adv) begin r_v <= r_n; r_a <= r_na; r_s32 <= r_ns32; end
			if (w_adv) begin w_v <= w_n; w_a <= w_na; w_s32 <= w_ns32; w_four <= w_nfour; w_done <= 1'b0; end
			else if (w_go) w_done <= 1'b1;
		end

	// the tags, a RAM for each port and one for the write-back: the bytes written, valid, filled, dirty, tag; a read of what's being written gets what's written
	logic        t_we;
	logic [6:0]  t_wa, t1_ra, t2_ra, t3_ra;
	logic [50:0] t_wd, t1_m, t2_m, t3_m, t_wr;
	logic        t1_f, t2_f, t3_f;
	ppc_ram #(.W(51), .AW(7)) tags1 (.clk, .we(t_we), .wa(t_wa), .wd(t_wd), .ra(t1_ra), .rd(t1_m));
	ppc_ram #(.W(51), .AW(7)) tags2 (.clk, .we(t_we), .wa(t_wa), .wd(t_wd), .ra(t2_ra), .rd(t2_m));
	ppc_ram #(.W(51), .AW(7)) tags3 (.clk, .we(t_we), .wa(t_wa), .wd(t_wd), .ra(t3_ra), .rd(t3_m));
	always_ff @(posedge clk)
	begin
		t1_f <= t_we && t_wa == t1_ra;
		t2_f <= t_we && t_wa == t2_ra;
		t3_f <= t_we && t_wa == t3_ra;
		t_wr <= t_wd;
	end
	wire  [50:0] t1_q = t1_f ? t_wr : t1_m;
	wire  [50:0] t2_q = t2_f ? t_wr : t2_m;
	wire  [50:0] t3_q = t3_f ? t_wr : t3_m;
	wire  [15:0] r_t = r_a[27:12], w_t = w_a[27:12];
	// (each port's compares on the RAM's word and on the word just written, the choice after them: the RAM's word is late,
	// and its hit goes on to the stalls and everything they hold)
	wire         r_hit = t1_f ? t_wr[18] && t_wr[17] && t_wr[15:0] == r_t : t1_m[18] && t1_m[17] && t1_m[15:0] == r_t;
	wire         w_hit = t2_f ? t_wr[18] && t_wr[15:0] == w_t : t2_m[18] && t2_m[15:0] == w_t;
	wire         idle = st == C_IDLE;

	// the write-back: a dirty line goes to memory from its own read of the data while the pixels go on. It's the line after the one
	// in use, the way the pixels are going; or what a miss or a flush asks for, which then waits
	typedef enum logic [2:0] { B_IDLE, B_LOOK, B_RD, B_WR, B_TAG } bst_t;
	bst_t        b_st;
	logic [6:0]  b_i, b_ti, b_last;
	logic        b_pend, b_inv, b_f;
	logic [15:0] b_t;
	logic [31:0] b_mask;
	logic [1:0]  b_n;
	wire         b_busy = b_st != B_IDLE;
	wire         b_tw = b_st == B_TAG;
	wire         b_go = b_st == B_WR;
	// a queue of such lines, 16 of them, so that memory being busy holds up no pixel. A fill waits for it to empty: what it reads may be in it
	typedef enum logic [1:0] { Q_IDLE, Q_LOOK, Q_WR } qst_t;
	qst_t        q_st;
	logic [3:0]  q_wp, q_rp;
	logic [4:0]  q_cnt;
	logic [1:0]  q_n;
	logic [54:0] q_m;
	logic [63:0] q_d;
	wire         q_e = q_cnt == 5'd0;
	wire         q_room = !q_cnt[4];
	wire  [15:0] q_t = q_m[54:39];
	wire  [6:0]  q_i = q_m[38:32];
	wire  [31:0] q_mask = q_m[31:0];
	wire  [7:0]  q_be = q_n == 2'd0 ? q_mask[7:0] : q_n == 2'd1 ? q_mask[15:8] : q_n == 2'd2 ? q_mask[23:16] : q_mask[31:24];
	logic        q_sink;
	wire         q_go = q_st == Q_WR && (q_be == 8'h0 || q_sink || (m_gnt && !m_busy));
	wire         q_end = q_go && q_n == 2'd3;
	wire         q_push = b_go && b_n == 2'd3;
	te_ram #(.W(64), .AW(6)) q_data (.clk, .we(b_go), .wa({q_wp, b_n}), .wd(d2_q), .re(1'b1), .ra({q_rp, q_n + 2'(q_go)}), .rd(q_d));
	te_ram #(.W(55), .AW(4)) q_meta (.clk, .we(q_push), .wa(q_wp), .wd({b_t, b_i, b_mask}), .re(1'b1), .ra(q_rp), .rd(q_m));
	// (a write takes a line that nothing needs at once: a clean one's just replaced)
	wire         w_clean = t2_f ? !(t_wr[18] && t_wr[16]) : !(t2_m[18] && t2_m[16]);
	wire         w_ok = idle && (w_hit || w_clean) && !w_wait && !b_tw && !(b_busy && w_a[11:5] == b_i);
	assign r_stall = r_v && !(idle && r_hit);
	assign       w_stall = w_v && !w_done && !w_ok;
	assign       w_go = w_v && !w_done && w_ok;

	// the data, the bytes of a word
	logic        d_we;
	logic [7:0]  d_be;
	logic [8:0]  d_wa, d_ra, d2_ra;
	logic [63:0] d_wd, d_q, d2_q;
	genvar i;
	generate
	for (i = 0; i < 8; i++)
	begin : g_b
		ppc_ram #(.W(8), .AW(9)) b (.clk, .we(d_we && d_be[i]), .wa(d_wa), .wd(d_wd[8 * i +: 8]), .ra(d_ra), .rd(d_q[8 * i +: 8]));
		ppc_ram #(.W(8), .AW(9)) b2 (.clk, .we(d_we && d_be[i]), .wa(d_wa), .wd(d_wd[8 * i +: 8]), .ra(d2_ra), .rd(d2_q[8 * i +: 8]));
	end
	endgenerate

	logic [1:0]  n;
	logic [22:0] l_a;                   // [27:5]

	// the answer to a read, from the 64
	wire  [31:0] q32 = r_a[2] ? d_q[63:32] : d_q[31:0];
	wire  [31:0] q32be = {q32[7:0], q32[15:8], q32[23:16], q32[31:24]};
	assign q = r_s32 ? q32be : {16'h0, r_a[1] ? q32be[15:0] : q32be[31:16]};

	// a write's bytes in the 64
	logic [31:0] w32;
	logic [3:0]  wbe;
	always_comb
		if (w_s32)
		begin
			w32 = {wd[7:0], wd[15:8], wd[23:16], wd[31:24]};
			wbe = {be[0], be[1], be[2], be[3]};
		end
		else
		begin
			w32 = {2{wd[7:0], wd[15:8]}};
			wbe = w_a[1] ? 4'b1100 : 4'b0011;
		end
	wire  [7:0]  w_be = w_four ? 8'hff : w_a[2] ? {wbe, 4'h0} : {4'h0, wbe};

	assign m_req = st == C_FILL || st == C_FILLW || (q_st != Q_IDLE && !(q_st == Q_WR && q_sink));
	assign m_rd = st == C_FILL && q_e && m_gnt;
	assign m_we = q_st == Q_WR && m_gnt && q_be != 8'h0 && !q_sink;
	assign m_sink = q_st == Q_WR && q_sink;
	assign m_a = q_st != Q_IDLE ? {4'h4, q_t, q_i, q_n} : {4'h4, l_a, 2'b00};
	assign m_wd = q_d;
	assign m_be = q_be;

	always_comb
	begin
		// reads
		t1_ra = r_adv ? r_na[11:5] : r_a[11:5];
		t2_ra = w_adv ? w_na[11:5] : w_a[11:5];
		t3_ra = b_st == B_IDLE ? b_ti : b_i;
		d_ra = r_adv ? r_na[11:3] : r_a[11:3];
		d2_ra = {b_i, b_n + 2'(b_go)};
		case (st)
			C_FWALK, C_FLOOK: t1_ra = walk;
			default: ;
		endcase
		// writes
		t_we = 1'b0; t_wa = l_a[6:0]; t_wd = {32'h0, 1'b1, fill, 1'b0, l_a[22:7]};
		d_we = 1'b0; d_be = 8'hff; d_wa = {l_a[6:0], n}; d_wd = m_dout;
		case (st)
			C_INIT: begin t_we = 1'b1; t_wa = walk; t_wd = 51'h0; end
			C_IDLE:
				if (w_go)
				begin
					d_we = 1'b1;
					d_wa = w_a[11:3];
					d_wd = {2{w32}};
					d_be = w_be;
					t_we = 1'b1; t_wa = w_a[11:5]; t_wd = {(w_hit ? t2_q[50:19] : 32'h0) | (32'(w_be) << {w_a[4:3], 3'b000}), 1'b1, w_hit && t2_q[17], 1'b1, w_t};
				end
			C_FILLW:
				if (m_ready && m_gnt)
				begin
					d_we = 1'b1;
					if (n == 2'd3) t_we = 1'b1;
				end
			C_FLOOK:
				if (!(t1_q[18] && t1_q[16])) begin t_we = 1'b1; t_wa = walk; t_wd = 51'h0; end
			default: ;
		endcase
		if (b_tw) begin t_we = 1'b1; t_wa = b_i; t_wd = b_inv ? 51'h0 : {32'h0, 1'b1, b_f, 1'b0, b_t}; end
	end

	wire         w_miss = w_v && !w_done && !w_hit && !w_clean;
	wire         r_miss = r_v && !r_hit;

	// the line the pixels are on, the read ahead of the write
	wire         lead_v = r_v || (w_v && !w_done);
	wire  [6:0]  lead_i = r_v ? r_a[11:5] : w_a[11:5];
	wire         lead_back = lead_i == b_last - 7'd1;
	logic        flush_p;

	always_ff @(posedge clk)
	begin
		flushed <= 1'b0;
		if (rst) begin st <= C_INIT; walk <= 7'd0; walking <= 1'b0; b_st <= B_IDLE; b_pend <= 1'b0; b_n <= 2'd0; flush_p <= 1'b0; q_st <= Q_IDLE; q_wp <= 4'd0; q_rp <= 4'd0; q_cnt <= 5'd0; q_n <= 2'd0; end
		else
		begin
			if (flush) flush_p <= 1'b1;     // (it's a clock long, and a write-back may be under way)
			if (lead_v && lead_i != b_last)
			begin
				b_last <= lead_i;
				b_ti <= lead_back ? lead_i - 7'd1 : lead_i + 7'd1;
				b_pend <= 1'b1;
			end
			case (b_st)
				B_IDLE:
					if (b_pend && idle && !flush && !flush_p && !w_miss && !r_miss)
					begin
						b_i <= b_ti;
						b_pend <= lead_v && lead_i != b_last;
						b_st <= B_LOOK;
					end
				B_LOOK:
					if (t3_q[18] && t3_q[16])
					begin
						b_t <= t3_q[15:0]; b_f <= t3_q[17]; b_mask <= t3_q[50:19]; b_inv <= 1'b0; b_n <= 2'd0;
						b_st <= B_RD;
					end
					else b_st <= B_IDLE;
				B_RD: if (q_room) b_st <= B_WR; // (a clock for the RAM)
				B_WR:
					if (b_go)
					begin
						b_n <= b_n + 2'd1;
						if (b_n == 2'd3) b_st <= B_TAG;
					end
				B_TAG: begin b_st <= B_IDLE; b_n <= 2'd0; end
				default: b_st <= B_IDLE;
			endcase
			if (q_push) q_wp <= q_wp + 4'd1;
			q_cnt <= q_cnt + 5'(q_push) - 5'(q_end);
			case (q_st)
				Q_IDLE: if (!q_e) q_st <= Q_LOOK;
				Q_LOOK: begin q_sink <= sink_in; q_st <= Q_WR; end
				default:
					if (q_go)
					begin
						q_n <= q_n + 2'd1;
						if (q_n == 2'd3) begin q_rp <= q_rp + 4'd1; q_st <= Q_IDLE; end
					end
			endcase
			case (st)
				C_INIT:
				begin
					walk <= walk + 7'd1;
					if (walk == 7'h7f) st <= C_IDLE;
				end
				C_IDLE:
					if (!b_busy)
					begin
						if (flush || flush_p) begin flush_p <= 1'b0; walk <= 7'd0; walking <= 1'b1; st <= C_FWALK; end
						else if (w_miss)
						begin
							fill <= 1'b0;
							b_i <= w_a[11:5]; b_t <= t2_q[15:0]; b_f <= t2_q[17]; b_mask <= t2_q[50:19]; b_inv <= 1'b0; b_n <= 2'd0;
							b_st <= B_RD;
							st <= C_EVW;
						end
						else if (r_miss && !w_go)   // (a write this clock isn't in the bytes the tag has yet)
						begin
							l_a <= r_a[27:5]; fill <= 1'b1;
							if (t1_q[18] && t1_q[16])
							begin
								b_i <= r_a[11:5]; b_t <= t1_q[15:0]; b_f <= t1_q[17]; b_mask <= t1_q[50:19]; b_inv <= 1'b0; b_n <= 2'd0;
								b_st <= B_RD;
								st <= C_EVW;
							end
							else st <= C_FILL;
						end
					end
				C_EVW:
					if (!b_busy)
					begin
						if (walking)
						begin
							walk <= walk + 7'd1;
							st <= walk == 7'h7f ? C_FEND : C_FWALK;
						end
						else st <= fill ? C_FILL : C_REARM;
					end
				C_FILL:
					if (q_e && m_gnt && !m_busy) begin n <= 2'd0; st <= C_FILLW; end
				C_FILLW:
					if (m_ready && m_gnt)
					begin
						n <= n + 2'd1;
						if (n == 2'd3) st <= C_REARM;
					end
				C_REARM: st <= C_IDLE;          // (a clock for the RAMs, on the waiting ports' addresses)
				C_FWALK: st <= C_FLOOK;
				C_FLOOK:
					if (t1_q[18] && t1_q[16])
					begin
						b_i <= walk; b_t <= t1_q[15:0]; b_f <= t1_q[17]; b_mask <= t1_q[50:19]; b_inv <= 1'b1; b_n <= 2'd0;
						b_st <= B_RD;
						st <= C_EVW;
					end
					else
					begin
						walk <= walk + 7'd1;
						st <= walk == 7'h7f ? C_FEND : C_FWALK;
					end
				C_FEND:
					if (q_e) begin flushed <= 1'b1; walking <= 1'b0; st <= C_IDLE; end
				default: st <= C_IDLE;
			endcase
		end
	end
endmodule

// the Z buffer: 8 KB blocks from the one it starts in, Z_BLOCKS of them, read and written a pixel a clock. (64 bits wide for what a clearing list sends, a word of four pixels a clock)
module te_z (
	input  logic        clk,
	input  logic        rst,
	input  logic [27:13] z_base,
	input  logic        x_v,
	input  logic [27:3] x_a,
	input  logic [63:0] x_wd,
	input  logic [7:0]  x_be,
	input  logic [27:1] r_na,
	input  logic        r_adv,
	output logic [15:0] q,
	input  logic        w_n,
	input  logic [27:1] w_na,
	input  logic        w_adv,
	input  logic [15:0] wd,             // in the clock after the address
	output logic        w_stall
);
	function automatic logic [5:0] blk(input logic [27:13] a);
		return a[18:13] - z_base[18:13];
	endfunction
	logic        w_v, w_done, w_win;
	logic [27:1] w_a;
	logic [2:1]  r_a;
	wire         w_go = w_v && !w_done && !x_v;
	assign w_stall = w_v && !w_done && x_v;
	always_ff @(posedge clk)
		if (rst) begin w_v <= 1'b0; w_done <= 1'b0; end
		else
		begin
			if (r_adv) r_a <= r_na[2:1];
			if (w_adv)
			begin
				w_v <= w_n; w_a <= w_na; w_done <= 1'b0;
				w_win <= 15'(w_na[27:13] - z_base) < 15'(`Z_BLOCKS);
			end
			else if (w_go) w_done <= 1'b1;
		end
	logic [15:0] ra_r;
	wire  [15:0] ra = r_adv ? {blk(r_na[27:13]), r_na[12:3]} : ra_r;
	always_ff @(posedge clk) ra_r <= ra;
	wire  [7:0]  wbe = {w_a[2] && w_a[1], w_a[2] && w_a[1], w_a[2] && !w_a[1], w_a[2] && !w_a[1], !w_a[2] && w_a[1], !w_a[2] && w_a[1], !w_a[2] && !w_a[1], !w_a[2] && !w_a[1]};
	wire  [15:0] wa = x_v ? {blk(x_a[27:13]), x_a[12:3]} : {blk(w_a[27:13]), w_a[12:3]};
	wire  [63:0] d = x_v ? x_wd : {4{wd[7:0], wd[15:8]}};
	wire  [7:0]  be = x_v ? x_be : (w_go && w_win) ? wbe : 8'h00;
	logic [63:0] m;
	genvar i;
	generate
	for (i = 0; i < 8; i++)
	begin : g_b
		te_sh s (.clk, .we(be[i]), .wa, .wd(d[8 * i +: 8]), .ra, .rd(m[8 * i +: 8]));
	end
	endgenerate
	wire  [31:0] m32 = r_a[2] ? m[63:32] : m[31:0];
	assign q = r_a[1] ? {m32[23:16], m32[31:24]} : {m32[7:0], m32[15:8]};
endmodule

// a lane of the Z buffer: the blocks it spans, not a power of two
module te_sh (
	input  logic        clk,
	input  logic        we,
	input  logic [15:0] wa,
	input  logic [7:0]  wd,
	input  logic [15:0] ra,
	output logic [7:0]  rd
);
`ifdef VERILATOR
	logic [7:0] mem [0:`Z_BLOCKS * 1024 - 1];
	always_ff @(posedge clk)
	begin
		if (we) mem[wa] <= wd;
		rd <= mem[ra];
	end
`else
	// (instantiated: Quartus turns what it infers past about 510 blocks into registers, and a big Z takes it there)
	localparam int AW = $clog2(`Z_BLOCKS * 1024);
	altsyncram #(
		.operation_mode("DUAL_PORT"), .width_a(8), .widthad_a(AW), .numwords_a(`Z_BLOCKS * 1024), .width_b(8), .widthad_b(AW), .numwords_b(`Z_BLOCKS * 1024),
		.address_reg_b("CLOCK0"), .outdata_reg_b("UNREGISTERED"), .ram_block_type("M10K"),
		.read_during_write_mode_mixed_ports("DONT_CARE"), .power_up_uninitialized("TRUE")
	) ram (.clock0(clk), .wren_a(we), .address_a(wa[AW-1:0]), .data_a(wd), .address_b(ra[AW-1:0]), .q_b(rd));
`endif
endmodule

// a texel from its U, the row's offset given (T+3): its own memories, so a pixel's four take two clocks
module te_fetch (
	input  logic        clk,
	input  logic        pe,
	input  logic        ld_tram,
	input  logic        ld_two,         // ld_d at ld_ta, even, and ld_d2 after it
	input  logic [11:0] ld_ta,
	input  logic        ld_pip,
	input  logic [7:0]  ld_pa,
	input  logic [31:0] ld_d,
	input  logic [31:0] ld_d2,
	input  logic        r_pip,
	input  logic [7:0]  r_a,
	input  logic [31:0] r_d,
	input  logic [9:0]  u,              // masked
	input  logic [9:0]  umax,
	input  logic [20:0] vo,
	input  logic [23:0] lod0,
	input  logic [31:0] exp,
	input  logic [31:0] pip_c,
	input  logic [31:0] c0,
	input  logic [31:0] c1,
	output logic [32:0] o               // s a r g b
);
	wire  [3:0]  texp_c = exp[3:0];
	wire  [3:0]  texp_a = exp[7:4];
	wire         texp_ssb = exp[9], texp_col = exp[10], texp_alp = exp[11], texp_lit = exp[12];
	// (a literal texel's colour is three components)
	wire  [5:0]  tdepth = (texp_col ? (texp_lit ? 6'(texp_c) * 6'd3 : 6'(texp_c)) : 6'd0) + (texp_alp ? {2'b00, texp_a} : 6'd0) + (texp_ssb ? 6'd1 : 6'd0);
	logic [11:0] t_ra;
	logic [10:0] t_ra0;                 // (the even half's word: t_ra's, or after an odd t_ra the next)
	logic [31:0] t_qa, t_qb;            // the texel's word and the next (a texel can run on into it: 6 bits, 24, ...)
	logic [7:0]  p_ra;
	logic [31:0] p_q;
	// (in halves, the even words and the odd, for ld_two; and so a word and the next are read together)
	logic [31:0] t_q0, t_q1;
	logic        t_sel;
	te_ram #(.W(32), .AW(11)) tram0 (.clk, .we(ld_tram && (ld_two || !ld_ta[0])), .wa(ld_ta[11:1]), .wd(ld_d), .re(pe), .ra(t_ra0), .rd(t_q0));
	te_ram #(.W(32), .AW(11)) tram1 (.clk, .we(ld_tram && (ld_two || ld_ta[0])), .wa(ld_ta[11:1]), .wd(ld_two ? ld_d2 : ld_d), .re(pe), .ra(t_ra[11:1]), .rd(t_q1));
	assign t_qa = t_sel ? t_q1 : t_q0;
	assign t_qb = t_sel ? t_q0 : t_q1;
	te_ram #(.W(32), .AW(8)) pip (.clk, .we(r_pip || ld_pip), .wa(r_pip ? r_a : ld_pa), .wd(r_pip ? r_d : ld_d), .re(pe), .ra(p_ra), .rd(p_q));

	logic [9:0]  a2_u, a3_u;
	logic [20:0] a4_off;
	logic [4:0]  a5_bit, d1_bit;
	logic [7:0]  d2_r, d2_g, d2_b, d3_r, d3_g, d3_b;
	logic [7:0]  d2_at, d3_at;
	logic        d2_st, d3_st;
	wire  [23:0] a3_sum = 24'(vo) + 24'(a3_u);
	wire  [26:0] a4_ad = 27'({lod0, 3'b000}) + 27'(a4_off) * 27'(tdepth);

	logic [31:0] d1_tx, d1_sh;
	logic [7:0]  d1_rt, d1_gt, d1_bt;
	logic [7:0]  d1_idx;
	logic [7:0]  d1_at;
	logic        d1_st;
	always_comb
	begin
		logic [7:0] mk;
		mk = 8'((9'd1 << texp_c) - 9'd1);
		d1_tx = d1_sh;
		d1_rt = 8'h0; d1_gt = 8'h0; d1_bt = 8'h0;
		if (texp_lit && texp_col)
		begin
			d1_bt = 8'(d1_tx) & mk; d1_tx = d1_tx >> texp_c;
			d1_gt = 8'(d1_tx) & mk; d1_tx = d1_tx >> texp_c;
			d1_rt = 8'(d1_tx) & mk; d1_tx = d1_tx >> texp_c;
		end
		d1_idx = 8'h0;
		if (texp_col)
		begin
			d1_idx = 8'(d1_tx) & 8'((9'd1 << texp_c) - 9'd1);
			d1_tx = d1_tx >> texp_c;
		end
		d1_at = 8'h0;
		if (texp_alp)
		begin
			d1_at = 8'(d1_tx) & 8'((9'd1 << texp_a) - 9'd1);
			if (texp_a == 4'd4) d1_at = {d1_at[4:0], 3'b000} | {1'b0, d1_at[7:1]};
			d1_tx = d1_tx >> texp_a;
		end
		d1_st = texp_ssb && d1_tx[0];
	end

	// a texel, the palette's entry to hand
	logic [7:0]  d3_or, d3_og, d3_ob, d3_oa;
	logic        d3_os;
	always_comb
	begin
		logic [31:0] c;
		logic [31:0] pv;
		logic [6:0] a7;
		pv = texp_col ? p_q : 32'h0;
		case (pip_c[16:14])
			3'd0: d3_os = d3_st ? c1[31] : c0[31];
			3'd1: d3_os = d3_st;
			3'd2: d3_os = pv[31];
			default: d3_os = 1'b0;
		endcase
		c = d3_st ? c1 : c0;
		case (pip_c[10:8])
			3'd0: begin d3_or = c[23:16]; d3_og = c[15:8]; d3_ob = c[7:0]; end
			3'd1: begin d3_or = d3_r; d3_og = d3_g; d3_ob = d3_b; end
			3'd2: begin d3_or = pv[23:16]; d3_og = pv[15:8]; d3_ob = pv[7:0]; end
			default: begin d3_or = 8'h0; d3_og = 8'h0; d3_ob = 8'h0; end
		endcase
		case (pip_c[13:11])
			3'd0: a7 = c[30:24];
			3'd1: a7 = d3_at[6:0];
			3'd2: a7 = pv[30:24];
			default: a7 = 7'h0;
		endcase
		d3_oa = {a7, a7[6]};
	end
	assign o = {d3_os, d3_oa, d3_or, d3_og, d3_ob};

	always_ff @(posedge clk)
		if (pe)
		begin
			a2_u <= u < umax ? u : umax;
			a3_u <= a2_u;
			a4_off <= 21'(a3_sum);
			t_ra <= a4_ad[16:5];
			t_ra0 <= 11'(a4_ad[16:6]) + 11'(a4_ad[5]);
			t_sel <= t_ra[0];
			a5_bit <= a4_ad[4:0];
			d1_bit <= a5_bit;
			// (the word's big-endian: a texel's bits run from its first bit down, whatever its size, and it ends in bit 0)
			d1_sh <= 32'({t_qa[7:0], t_qa[15:8], t_qa[23:16], t_qa[31:24], t_qb[7:0], t_qb[15:8], t_qb[23:16], t_qb[31:24]} >> (7'd64 - 7'(d1_bit) - 7'(tdepth)));
			d2_r <= d1_rt; d2_g <= d1_gt; d2_b <= d1_bt; d2_at <= d1_at; d2_st <= d1_st;
			p_ra <= pip_c[7:0] + d1_idx;
			d3_r <= d2_r; d3_g <= d2_g; d3_b <= d2_b; d3_at <= d2_at; d3_st <= d2_st;
		end
endmodule

// a memory with a read enable: a stalled stage keeps what it read
module te_ram #(
	parameter int W = 32,
	parameter int AW = 8
) (
	input  logic          clk,
	input  logic          we,
	input  logic [AW-1:0] wa,
	input  logic [W-1:0]  wd,
	input  logic          re,
	input  logic [AW-1:0] ra,
	output logic [W-1:0]  rd
);
	(* ramstyle = "M10K, no_rw_check" *) logic [W-1:0] mem [0:(1 << AW) - 1];
	always_ff @(posedge clk)
	begin
		if (we) mem[wa] <= wd;
		if (re) rd <= mem[ra];
	end
endmodule

// single precision add: to nearest, ties to even; denormals are 0. r is 4 clocks after a, b, sub
module te_fadd (
	input  logic        clk,
	input  logic [31:0] a,
	input  logic [31:0] b,
	input  logic        sub,
	output logic [31:0] r
);
	wire         bs = b[31] ^ sub;
	wire         swap = b[30:0] > a[30:0];
	wire  [7:0]  el = swap ? b[30:23] : a[30:23];
	wire  [22:0] fl = swap ? b[22:0] : a[22:0];
	wire         sl = swap ? bs : a[31];
	wire         ss = swap ? a[31] : bs;
	// the smaller one aligned, with a sticky bit: which is shifted and by how much from the exponents alone (swap only
	// chooses when they're the same, unshifted), the sticky bit from the bits a mask says are shifted out (from swap
	// through the exponents' difference and two shifts was a long path)
	wire  [7:0]  ea = a[30:23], eb = b[30:23];
	wire         e_b = eb > ea;
	wire  [7:0]  d = e_b ? eb - ea : ea - eb;
	wire  [26:0] ma = ea == 8'd0 ? 27'd0 : {1'b1, a[22:0], 3'b000};
	wire  [26:0] mb = eb == 8'd0 ? 27'd0 : {1'b1, b[22:0], 3'b000};
	wire  [26:0] ms = e_b ? ma : mb;
	wire  [26:0] mst = ms >> d[4:0];
	logic [26:0] msk, msd;
	always_comb
	begin
		for (int i = 0; i < 27; i++) msk[i] = 5'(i) < d[4:0];
		if (ea == eb) msd = swap ? ma : mb;
		else if (d >= 8'd27) msd = 27'(ms != 27'd0);
		else msd = {mst[26:1], mst[0] | ((ms & msk) != 27'd0)};
	end

	logic [26:0] p1_l, p1_s;
	logic [7:0]  p1_e;
	logic        p1_sg, p1_sub, p1_lz;
	always_ff @(posedge clk)
	begin
		p1_l <= {1'b1, fl, 3'b000};
		p1_s <= msd;
		p1_e <= el;
		p1_sg <= sl;
		p1_sub <= sl != ss;
		p1_lz <= el == 8'd0;
	end
	logic [27:0] p2_v;
	logic [7:0]  p2_e;
	logic        p2_sg;
	always_ff @(posedge clk)
	begin
		p2_v <= p1_lz ? 28'd0 : p1_sub ? 28'(p1_l) - 28'(p1_s) : 28'(p1_l) + 28'(p1_s);
		p2_e <= p1_e;
		p2_sg <= p1_sg;
	end
	// normalise: the top bit to 27
	logic [4:0]  lz;
	always_comb
	begin
		lz = 5'd0;
		for (int i = 0; i < 28; i++) if (p2_v[i]) lz = 5'(27 - i);
	end
	logic [27:0] p3_v;
	logic [8:0]  p3_e;
	logic        p3_sg, p3_z;
	always_ff @(posedge clk)
	begin
		p3_v <= p2_v << lz;
		p3_e <= 9'(p2_e) + 9'd1 - 9'(lz);
		p3_sg <= p2_sg;
		p3_z <= p2_v == 28'd0;
	end
	wire         rnd = p3_v[3] && (p3_v[4] || p3_v[2:0] != 3'd0);
	wire  [24:0] mr = {1'b0, p3_v[27:4]} + 25'(rnd);
	// verilator lint_off UNUSEDSIGNAL
	wire  [8:0]  er = mr[24] ? p3_e + 9'd1 : p3_e;
	// verilator lint_on UNUSEDSIGNAL
	always_ff @(posedge clk)
		if (p3_z || p3_e[8] || p3_e == 9'd0) r <= 32'h0;
		else r <= {p3_sg, er[7:0], mr[24] ? mr[23:1] : mr[22:0]};
endmodule

// single precision multiply: to nearest, ties to even; denormals are 0. r is 3 clocks after a, b
module te_fmul (
	input  logic        clk,
	input  logic [31:0] a,
	input  logic [31:0] b,
	output logic [31:0] r
);
	logic [47:0] p1_m;
	logic [9:0]  p1_e;
	logic        p1_s, p1_z;
	wire  [23:0] ma = {1'b1, a[22:0]}, mb = {1'b1, b[22:0]};
	always_ff @(posedge clk)
	begin
		p1_m <= 48'(ma) * 48'(mb);
		p1_e <= 10'(a[30:23]) + 10'(b[30:23]) - 10'd127;
		p1_s <= a[31] ^ b[31];
		p1_z <= a[30:23] == 8'd0 || b[30:23] == 8'd0;
	end
	logic [23:0] p2_m;
	logic        p2_g, p2_t, p2_s, p2_z;
	logic [9:0]  p2_e;
	always_ff @(posedge clk)
	begin
		if (p1_m[47]) begin p2_m <= p1_m[47:24]; p2_g <= p1_m[23]; p2_t <= p1_m[22:0] != 23'd0; p2_e <= p1_e + 10'd1; end
		else begin p2_m <= p1_m[46:23]; p2_g <= p1_m[22]; p2_t <= p1_m[21:0] != 22'd0; p2_e <= p1_e; end
		p2_s <= p1_s;
		p2_z <= p1_z;
	end
	wire  [24:0] mr = {1'b0, p2_m} + 25'(p2_g && (p2_m[0] || p2_t));
	wire  [9:0]  er = mr[24] ? p2_e + 10'd1 : p2_e;
	always_ff @(posedge clk)
		if (p2_z || er[9] || er == 10'd0) r <= 32'h0;
		else r <= {p2_s, er[7:0], mr[24] ? mr[23:1] : mr[22:0]};
endmodule
