// m2_dspp: the BDA's audio DSP ("Don's Super Performing Processor"), as MAME 0.289's dspp.cpp has it: a program of 16-bit words, 1K of
// them, working on 1K of 16-bit data with registers in it, FIFOs of samples filled by DMA, and two words a frame to the DACs. It doesn't
// need MAME's speed: the OS's program spends 90 % of its time waiting for room in the output FIFO, so a word takes a few clocks here.
// Not here, as nothing uses them: DMA out of a FIFO, SQXD samples, channels above 15 (a program can only reach 16), the consumed interrupt,
// the host's writes to a FIFO.
//
// The host's reads are ready a clock after the address: pre_a is the address of the access coming up, a the access itself.
`default_nettype none
module m2_dspp #(parameter logic FROZEN = 1'b0) (   // FROZEN: the counter and the noise stay put (the bench)
	input  logic        clk,
	input  logic        rst,

	input  logic [9:0]  pre_a,
	input  logic [13:0] a,
	input  logic        we,
	input  logic [31:0] wd,
	output logic [31:0] rd,
	output logic        intr,

	output logic        m_rd,           // one word
	output logic [31:3] m_a,
	input  logic        m_busy,
	input  logic        m_ready,
	input  logic [63:0] m_dout,

	input  logic        dac_tick,       // 44.1 kHz: the next two words to the DACs
	output logic [15:0] dac_l,
	output logic [15:0] dac_r
);
	// ---- memories: code and data have a copy for the host's reads -------------------------------------------------------
	logic [9:0]  pc, pc_n, ra, ra_n;
	logic [15:0] c_q, d_q, hc_q, hd_q, c_r, d_r;
	logic        d_we;
	logic [9:0]  d_wa;
	logic [15:0] d_wd;
	wire         h_code = a[13:10] == 4'h0;
	wire         h_data = a[13:10] == 4'h1;
	wire         h_dma = a[13:10] == 4'h5;
	wire [14:0]  h_off = {a[12:0], 2'b00};
	ppc_ram #(.W(16), .AW(10)) code  (.clk, .we(we && h_code), .wa(a[9:0]), .wd(wd[15:0]), .ra(pc_n), .rd(c_r));
	ppc_ram #(.W(16), .AW(10)) hcode (.clk, .we(we && h_code), .wa(a[9:0]), .wd(wd[15:0]), .ra(pre_a), .rd(hc_q));
	ppc_ram #(.W(16), .AW(10)) data  (.clk, .we(d_we), .wa(d_wa), .wd(d_wd), .ra(ra_n), .rd(d_r));
	ppc_ram #(.W(16), .AW(10)) hdata (.clk, .we(d_we), .wa(d_wa), .wd(d_wd), .ra(pre_a), .rd(hd_q));
	// the RAMs' answer to a read of the word being written is undefined, and the OS patches the program as it runs (a jump, at each voice's start)
	logic        c_by, d_by;
	logic [15:0] c_bw, d_bw;
	assign c_q = c_by ? c_bw : c_r;
	assign d_q = d_by ? d_bw : d_r;
	always_ff @(posedge clk)
	begin
		c_by <= we && h_code && a[9:0] == pc_n;
		c_bw <= wd[15:0];
		d_by <= d_we && d_wa == ra_n;
		d_bw <= d_wd;
	end

	// the FIFOs: 8 words a channel, and slot 8 the last the program had
	logic [7:0]  fa_n, fa;
	logic        f_we;
	logic [7:0]  f_wa;
	logic [15:0] f_wd, f_q;
	ppc_ram #(.W(16), .AW(8)) fifo (.clk, .we(f_we), .wa(f_wa), .wd(f_wd), .ra(fa_n), .rd(f_q));
	logic [2:0]  dspi [0:15];
	logic [3:0]  depth [0:15];

	// the DMA registers: current address, current count, next address, next count, by channel
	logic        r_we;
	logic [5:0]  r_wa, r_ra;
	logic [31:0] r_wd, r_q, hr_q, r_r, hr_r, r_bw;
	logic        r_by, hr_by;
	ppc_ram #(.W(32), .AW(6)) dregs  (.clk, .we(r_we), .wa(r_wa), .wd(r_wd), .ra(r_ra), .rd(r_r));
	ppc_ram #(.W(32), .AW(6)) hdregs (.clk, .we(r_we), .wa(r_wa), .wd(r_wd), .ra(pre_a[5:0]), .rd(hr_r));
	assign r_q = r_by ? r_bw : r_r;
	assign hr_q = hr_by ? r_bw : hr_r;
	always_ff @(posedge clk)
	begin
		r_by <= r_we && r_wa == r_ra;
		hr_by <= r_we && r_wa == pre_a[5:0];
		r_bw <= r_wd;
	end

	// the output FIFO, in pairs
	logic [15:0] out0, out1;
	logic [1:0]  o_start;
	logic [2:0]  o_count;
	logic        o_we;
	wire [1:0]   o_end = o_start + o_count[1:0];    // (full: the oldest, which goes)
	wire [1:0]   o_ra = dac_tick && o_count != 3'd0 ? o_start + 2'd1 : o_start;
	logic [31:0] o_q;
	ppc_ram #(.W(32), .AW(2)) ofifo (.clk, .we(o_we), .wa(o_end), .wd({out1, out0}), .ra(o_ra), .rd(o_q));

	// ---- registers ----------------------------------------------------------------------------------------------------
	logic        gwilling, audlock;
	logic [31:0] partial_int, int_enable;
	logic [15:0] ch_enable, ch_8bit, dmanext_int, dmanext_en, underover_int, next_valid, go_forever;
	logic [15:0] duration;
	logic [31:0] up_time;
	logic [31:0] sh_ca, sh_cc, sh_na, sh_nc;
	logic [15:0] tclock, noise;
	logic [15:0] osc_phase;
	logic [1:0]  last_osc;
	wire [31:0]  host_int = partial_int | 32'((dmanext_int & dmanext_en) != 16'h0);

	// ---- the program --------------------------------------------------------------------------------------------------
	typedef enum logic [4:0] {
		S_OP,       // c_q is the word at pc, always
		S_PW,       // an operand word
		S_PA,       // an indirect address operand, read
		S_PR,       // the registers of an operand word
		S_PRD,      // an indirect one, read
		S_X,        // the operands are parsed
		S_MI,       // MOVEI: its address, read
		S_MR,       // the multiplier's answer
		S_MW,       // a move: write it
		S_A0, S_A1, S_A2, S_A3, S_A4, S_A5, S_A6, S_A7, S_A8, S_A9,
		S_W,        // write wv to wa
		S_RN,       // read the next operand, on to s_ret
		S_R,        // d_q is at ra
		S_F,        // f_q is the FIFO's word
		S_O0, S_O1  // the oscillator's pops
	} st_t;
	st_t         s, s_n, s_ret, s_ret_n;
	logic [15:0] op, op_n, opw, opw_n;
	logic [9:0]  stack [0:3];
	logic [2:0]  sp, sp_n;
	logic [9:0]  rbase [0:3];
	logic        rb_we;
	logic [19:0] acc, acc_n;
	logic        f_c, f_z, f_n, f_v, f_x, flags_we;
	logic        wb_v, wb_v_n;
	logic [9:0]  wb_a, wb_a_n;
	logic [15:0] o_v [0:4];             // the operands: a value or an address
	logic [4:0]  o_imm;
	logic [2:0]  o_n, o_n_n, o_i, o_i_n, n_ops, n_ops_n;
	logic        o_we_p, o_imm_w;
	logic [15:0] o_wv;
	logic [1:0]  r_left, r_left_n, r_tot, r_tot_n;
	logic [15:0] rv, rv_n, mul_a, mul_a_n, mv_a, mv_a_n, wv, wv_n;
	logic [9:0]  wa, wa_n;
	logic [19:0] alu_a, alu_a_n, alu_b, alu_b_n, mul_res, mul_res_n, res, res_n;
	logic [3:0]  barrel, barrel_n;
	logic        f_empty, f_empty_n, f_pop, f_pop_n;
	logic [3:0]  osc_c, osc_c_n;
	logic [1:0]  osc_k, osc_k_n;

	logic        p_w;                   // this clock's write
	logic        pop_ev;
	logic [3:0]  pop_ch;
	logic [1:0]  pop_k;
	logic        p_fw;
	logic [15:0] p_fwd;
	logic [7:0]  p_fwa;
	logic        push_ev;
	logic        stk_push;
	logic        under;
	logic        osc_we;
	logic [15:0] osc_phase_n;
	logic [1:0]  last_osc_n;

	wire [1:0]   muxa = op[11:10];
	wire [1:0]   muxb = op[9:8];
	wire [3:0]   alu_op = op[7:4];
	wire         has_mul = muxa == 2'd3 || muxb == 2'd3;

	function automatic logic [9:0] reg_a(input logic [3:0] r);
		return rbase[r[3:2]] + 10'(r[1:0]);
	endfunction

	// the place being read, the special ones
	wire         ra_fifo = ra[9:7] == 3'b110;
	wire [3:0]   ra_ch = ra[6:3];
	wire [3:0]   ra_depth = depth[ra_ch];
	wire [2:0]   ra_dspi = dspi[ra_ch];
	logic [15:0] ra_spec;
	always_comb
	begin
		ra_spec = 16'h0;
		if (ra < 10'h2e0) ra_spec = d_q;
		else if (ra_fifo)
			case (ra[2:0])
				3'd2: ra_spec = 16'(last_osc);
				3'd3: ra_spec = osc_phase;
				3'd5: ra_spec = 16'(ra_depth);
				default: ;
			endcase
		else
			case (ra)
				10'h3de: ra_spec = 16'h1;
				10'h3df: ra_spec = 16'({o_count, 1'b0});
				10'h3ee: ra_spec = 16'(pc);
				10'h3f6: ra_spec = 16'(audlock);
				10'h3f7: ra_spec = tclock;
				10'h3ff: ra_spec = noise;
				default: ;
			endcase
	end
	wire         ra_needs_f = ra_fifo && (ra[2:0] == 3'd0 || ra[2:0] == 3'd1 || ra[2:0] == 3'd4);

	// the branches
	logic        branch;
	always_comb
	begin
		logic f0, f1;
		f0 = c_q[12] ? f_c : f_n;
		f1 = c_q[12] ? f_z : f_v;
		branch = (f0 || !c_q[11]) && (f1 || !c_q[10]);
		if (c_q[14:13] == 2'd2) branch = !branch;
		if (c_q[14:13] == 2'd3)
			case (c_q[12:10])
				3'd0: branch = f_n != f_v;
				3'd1: branch = f_n != f_v || f_z;
				3'd2: branch = f_n == f_v;
				3'd3: branch = f_n == f_v && !f_z;
				3'd4: branch = f_c && !f_z;
				3'd5: branch = !f_c || f_z;
				3'd6: branch = f_x;
				default: branch = !f_x;
			endcase
	end

	// the ALU
	logic [20:0] alu_r;
	logic        alu_v, alu_c;
	always_comb
	begin
		alu_v = 1'b0; alu_c = 1'b0; alu_r = {1'b0, alu_a};
		case (alu_op)
			4'd0, 4'd8: ;
			4'd1: alu_r = 21'd0 - {1'b0, alu_b};
			4'd2:
			begin
				alu_r = {1'b0, alu_a} + {1'b0, alu_b};
				alu_v = alu_a[19] == alu_b[19] && alu_a[19] != alu_r[19];
				alu_c = alu_r[20];
			end
			4'd3:
			begin
				alu_r = {1'b0, alu_a} + 21'({f_c, 4'h0});
				alu_c = alu_r[20];
			end
			4'd4:
			begin
				alu_r = {1'b0, alu_a} - {1'b0, alu_b};
				alu_v = alu_a[19] != alu_b[19] && alu_a[19] != alu_r[19];
				alu_c = alu_r[20];
			end
			4'd5:
			begin
				alu_r = {1'b0, alu_a} - 21'({f_c, 4'h0});
				alu_c = alu_r[20];
			end
			4'd6:
			begin
				alu_r = {1'b0, alu_a} + 21'd1;
				alu_v = !alu_a[19] && alu_r[19];
			end
			4'd7:
			begin
				alu_r = {1'b0, alu_a} - 21'd1;
				alu_v = alu_a[19] && !alu_r[19];
			end
			4'd9: alu_r = ~{1'b0, alu_a};
			4'd10: alu_r = {1'b0, alu_a & alu_b};
			4'd11: alu_r = ~{1'b0, alu_a & alu_b};
			4'd12: alu_r = {1'b0, alu_a | alu_b};
			4'd13: alu_r = ~{1'b0, alu_a | alu_b};
			4'd14: alu_r = {1'b0, alu_a ^ alu_b};
			default: alu_r = ~{1'b0, alu_a ^ alu_b};
		endcase
	end

	// the barrel
	logic [4:0]  shift_n;
	always_comb
		case (barrel[3] ? 3'(4'd0 - barrel) : barrel[2:0])
			3'd0: shift_n = 5'd0;
			3'd1: shift_n = 5'd1;
			3'd2: shift_n = 5'd2;
			3'd3: shift_n = 5'd3;
			3'd4: shift_n = 5'd4;
			3'd5: shift_n = 5'd5;
			3'd6: shift_n = 5'd8;
			default: shift_n = 5'd16;
		endcase
	logic [19:0] shifted;
	always_comb
		if (barrel[3]) shifted = alu_op < 4'd8 ? 20'($signed(res) >>> shift_n) : res >> shift_n;
		else if (shift_n == 5'd16) shifted = !f_v ? res : f_n ? 20'h7ffff : 20'h80000;
		else shifted = res << shift_n;

	// the multiplier
	// verilator lint_off UNUSEDSIGNAL
	logic signed [31:0] mul_q;
	// verilator lint_on UNUSEDSIGNAL
	always_ff @(posedge clk) mul_q <= $signed(mul_a) * $signed(rv);

	wire         hw = we && h_data;     // the host's write to the data space: it goes first, the program waits a clock
	wire [9:0]   w_a = hw ? a[9:0] : wa;
	wire [15:0]  w_v = hw ? wd[15:0] : wv;
	assign       p_w = s == S_W && !hw;
	wire         w_do = hw || p_w;
	assign d_we = w_do && w_a < 10'h2e0;
	assign d_wa = w_a;
	assign d_wd = w_v;
	wire [3:0]   wa_ch = wa[6:3];
	wire [16:0]  osc_sum = {1'b0, osc_phase} + {1'b0, wv};
	wire [3:0]   osc_want = 4'(osc_sum[16:15]);
	wire [3:0]   wa_depth = depth[wa_ch];
	wire         w_frame = w_do && w_a == 10'h3d7 && w_v[0];
	assign o_we = w_frame;
	wire         w_pc = w_do && w_a == 10'h3ee;
	wire         dev_reset = rst || (w_frame && audlock) || (we && !h_code && !h_data && !h_dma && h_off == 15'h6074 && wd[0]);

	// where an instruction goes when its operands are parsed: arithmetic straight to its first read (s_ret is then S_A1), or to A
	st_t         s_ops_end;
	assign       s_ops_end = op[15] ? S_X : has_mul ? S_RN : S_A3;
	// a write that can fetch the next instruction in its own clock: not the FIFOs' places, whose writes do more, nor the PC, which moves,
	// nor a frame that resets the DSP
	wire         w_then_op = s == S_W && wa[9:7] != 3'b110 && wa != 10'h3ee && !(wa == 10'h3d7 && audlock);
	wire [9:0]   o_cur = o_v[o_i[2:0]][9:0];
	wire         o_there = o_i < o_n;
	wire         o_is_imm = o_there && o_imm[o_i[2:0]];

	// after the operands of an operand word, more?
	always_comb
	begin
		s_n = s; s_ret_n = s_ret; pc_n = pc; ra_n = ra; fa_n = fa;
		op_n = op; opw_n = opw; sp_n = sp; rb_we = 1'b0;
		acc_n = acc; flags_we = 1'b0; wb_v_n = wb_v; wb_a_n = wb_a;
		o_n_n = o_n; o_i_n = o_i; n_ops_n = n_ops; o_we_p = 1'b0; o_imm_w = 1'b0; o_wv = 16'h0;
		r_left_n = r_left; r_tot_n = r_tot;
		rv_n = rv; mul_a_n = mul_a; mv_a_n = mv_a; wv_n = wv; wa_n = wa;
		alu_a_n = alu_a; alu_b_n = alu_b; mul_res_n = mul_res; res_n = res; barrel_n = barrel;
		f_empty_n = f_empty; f_pop_n = f_pop; osc_c_n = osc_c; osc_k_n = osc_k;
		pop_ev = 1'b0; pop_ch = ra_ch; pop_k = 2'd1;
		p_fw = 1'b0; p_fwd = f_q; p_fwa = {ra_ch, 4'd8};
		push_ev = 1'b0; stk_push = 1'b0; under = 1'b0;
		osc_we = 1'b0; osc_phase_n = osc_phase; last_osc_n = last_osc;
		if (!hw && (s == S_OP || w_then_op))
		begin
			s_n = S_OP;
				if (gwilling)
				begin
					op_n = c_q;
					pc_n = pc + 10'd1;
					o_n_n = 3'd0; o_i_n = 3'd0;
					if (!c_q[15])
					begin
						// how many operands
						n_ops_n = 3'(c_q[14:13]);
						if (c_q[14:13] == 2'd0 && (c_q[11:10] == 2'd1 || c_q[11:10] == 2'd2 || c_q[9:8] == 2'd1 || c_q[9:8] == 2'd2)) n_ops_n = 3'd4;
						if (c_q[3:0] == 4'd8) n_ops_n = n_ops_n + 3'd1;
						s_n = n_ops_n == 3'd0 ? S_X : S_PW;
					end
					else
						case (c_q[14:13])
							2'd0:
								case (c_q[12:10])
									3'd0:
										case (c_q[9:7])
											3'd1: pc_n = acc[13:4];
											3'd4: begin pc_n = stack[sp == 3'd0 ? 2'd0 : 2'(sp - 3'd1)]; if (sp != 3'd0) sp_n = sp - 3'd1; end
											3'd7: pc_n = pc;
											default: ;
										endcase
									3'd1: pc_n = c_q[9:0];
									3'd2: begin stk_push = sp != 3'd4; if (sp != 3'd4) sp_n = sp + 3'd1; pc_n = c_q[9:0]; end
									3'd3: ;
									3'd4:   // MOVEREG: the address first
									begin
										n_ops_n = 3'd1;
										mv_a_n = 16'(reg_a(c_q[3:0]));
										if (c_q[4]) begin ra_n = reg_a(c_q[3:0]); s_ret_n = S_MI; s_n = S_R; end
										else s_n = S_PW;
									end
									3'd5: rb_we = 1'b1;
									3'd6: begin n_ops_n = 3'd1; mv_a_n = 16'(c_q[9:0]); s_n = S_PW; end
									default: begin n_ops_n = 3'd1; s_n = S_PW; end
								endcase
							default: if (branch) pc_n = c_q[9:0];
						endcase
				end
		end
		else if (!hw)
		case (s)
			S_PW:
			begin
				opw_n = c_q;
				pc_n = pc + 10'd1;
				if (c_q[15:14] == 2'b11)    // a value
				begin
					o_we_p = 1'b1; o_imm_w = 1'b1;
					o_wv = c_q[13] ? {c_q[12:0], 3'b000} : {{3{c_q[12]}}, c_q[12:0]};
					o_n_n = o_n + 3'd1;
					s_n = o_n + 3'd1 >= n_ops ? s_ops_end : S_PW;
					s_ret_n = S_A1;
				end
				else if (c_q[15:13] == 3'b100)  // an address
				begin
					if (c_q[10]) begin ra_n = c_q[9:0]; s_ret_n = S_PA; s_n = S_R; end
					else
					begin
						o_we_p = 1'b1; o_wv = 16'(c_q[9:0]);
						if (c_q[11]) begin wb_v_n = 1'b1; wb_a_n = c_q[9:0]; end
						o_n_n = o_n + 3'd1;
						s_n = o_n + 3'd1 >= n_ops ? s_ops_end : S_PW;
						s_ret_n = S_A1;
					end
				end
				else
				begin
					r_tot_n = !c_q[15] ? 2'd3 : c_q[10] ? 2'd2 : 2'd1;
					r_left_n = r_tot_n;
					s_n = S_PR;
				end
			end
			S_PA:
			begin
				o_we_p = 1'b1; o_wv = 16'(rv[9:0]);
				if (opw[11]) begin wb_v_n = 1'b1; wb_a_n = rv[9:0]; end
				o_n_n = o_n + 3'd1;
				s_n = o_n + 3'd1 >= n_ops ? s_ops_end : S_PW;
				s_ret_n = S_A1;
			end
			S_PR:
			begin
				logic [4:0] regdi;
				logic [9:0] ad;
				regdi = r_left == 2'd3 ? opw[14:10] : r_left == 2'd2 ? opw[9:5] : opw[4:0];
				ad = reg_a(regdi[3:0]);
				if (regdi[4]) begin ra_n = ad; s_ret_n = S_PRD; s_n = S_R; end
				else
				begin
					o_we_p = 1'b1; o_wv = 16'(ad);
					if (r_tot == 2'd2 ? (r_left == 2'd2 ? opw[12] : opw[11]) : r_tot == 2'd1 && opw[11]) begin wb_v_n = 1'b1; wb_a_n = ad; end
					o_n_n = o_n + 3'd1;
					r_left_n = r_left - 2'd1;
					s_n = r_left != 2'd1 ? S_PR : o_n + 3'd1 >= n_ops ? s_ops_end : S_PW;
					if (r_left == 2'd1) s_ret_n = S_A1;
				end
			end
			S_PRD:
			begin
				o_we_p = 1'b1; o_wv = 16'(rv[9:0]);
				if (r_tot == 2'd2 ? (r_left == 2'd2 ? opw[12] : opw[11]) : r_tot == 2'd1 && opw[11]) begin wb_v_n = 1'b1; wb_a_n = rv[9:0]; end
				o_n_n = o_n + 3'd1;
				r_left_n = r_left - 2'd1;
				s_n = r_left != 2'd1 ? S_PR : o_n + 3'd1 >= n_ops ? s_ops_end : S_PW;
				if (r_left == 2'd1) s_ret_n = S_A1;
			end
			S_X:
				if (!op[15]) s_n = S_A0;
				else if (op[12:10] == 3'd7) begin ra_n = op[9:0]; s_ret_n = S_MI; s_n = S_R; end    // MOVEI
				else begin s_ret_n = S_MW; s_n = S_RN; end
			S_MI:   // an address that was read: MOVEREG's, before its operands; MOVEI's, after
			begin
				mv_a_n = rv;
				if (op[12:10] == 3'd4) s_n = S_PW;
				else begin s_ret_n = S_MW; s_n = S_RN; end
			end
			S_MW:
			begin
				wa_n = mv_a[9:0]; wv_n = rv;
				s_n = S_W;
			end
			// arithmetic: the multiplier's operands, A, B, the ALU, the barrel, the result
			S_A0:
				if (has_mul) begin s_ret_n = S_A1; s_n = S_RN; end
				else s_n = S_A3;
			S_A1:
			begin
				mul_a_n = rv;
				if (op[12]) begin s_ret_n = S_A2; s_n = S_RN; end
				else begin rv_n = acc[19:4]; s_n = S_A2; end
			end
			S_A2: s_n = S_MR;
			// (A, then B, each without a clock of its own unless it has to read)
			S_MR, S_A3:
			begin
				if (s == S_MR) mul_res_n = mul_q[30:11];
				case (muxa)
					2'd0: alu_a_n = acc;
					2'd3: alu_a_n = mul_res_n;
					default: begin s_ret_n = S_A4; s_n = S_RN; end
				endcase
				if (muxa == 2'd0 || muxa == 2'd3)
					case (muxb)
						2'd0: begin alu_b_n = acc; s_n = S_A7; end
						2'd3: begin alu_b_n = mul_res_n; s_n = S_A7; end
						default: begin s_ret_n = S_A6; s_n = S_RN; end
					endcase
			end
			S_A4:
			begin
				alu_a_n = {rv, 4'h0};
				case (muxb)
					2'd0: begin alu_b_n = acc; s_n = S_A7; end
					2'd3: begin alu_b_n = mul_res; s_n = S_A7; end
					default: begin s_ret_n = S_A6; s_n = S_RN; end
				endcase
			end
			S_A6: begin alu_b_n = {rv, 4'h0}; s_n = S_A7; end
			S_A7:
			begin
				res_n = alu_r[19:0];
				flags_we = 1'b1;
				barrel_n = op[3:0];
				if (op[3:0] == 4'd8) begin s_ret_n = S_A8; s_n = S_RN; end
				else s_n = S_A9;
			end
			S_A8: begin barrel_n = rv[3:0]; s_n = S_A9; end
			S_A9:
			begin
				acc_n = shifted;
				s_n = S_OP;
				if (wb_v)
				begin
					wa_n = wb_a; wv_n = shifted[19:4]; wb_v_n = 1'b0;
					s_n = S_W;
				end
				else if (o_i < n_ops)
				begin
					o_i_n = o_i + 3'd1;
					if (!o_imm[o_i[2:0]])
					begin
						wa_n = o_cur; wv_n = shifted[19:4];
						s_n = S_W;
					end
				end
			end
			S_W:
			begin
				s_n = S_OP;
				if (wa[9:7] == 3'b110)
					case (wa[2:0])
						3'd2:   // the oscillator
						begin
							osc_c_n = osc_want > wa_depth ? wa_depth : osc_want;
							osc_k_n = osc_c_n[1:0];
							osc_phase_n = {1'b0, osc_sum[14:0]};
							osc_we = 1'b1;
							last_osc_n = osc_c_n[1:0];
							if (osc_c_n != 4'd0)
							begin
								fa_n = {wa_ch, 1'b0, dspi[wa_ch] + 3'(osc_c_n) - 3'd1};
								s_n = S_O0;
							end
						end
						3'd3: begin osc_phase_n = wv; osc_we = 1'b1; end
						3'd4:   // written at the place it's read from, as MAME
						begin
							p_fw = 1'b1; p_fwd = wv; p_fwa = {wa_ch, 1'b0, dspi[wa_ch]};
							push_ev = wa_depth != 4'd8;
						end
						default: ;
					endcase
			end
			S_O0:
			begin
				p_fw = 1'b1; p_fwd = f_q; p_fwa = {wa_ch, 4'd8};
				pop_ev = 1'b1; pop_ch = wa_ch; pop_k = osc_k;
				s_n = S_OP;
			end
			// the next operand: a value now, or a read
			S_RN:
			begin
				o_i_n = o_i + 3'd1;
				if (o_is_imm) begin rv_n = o_v[o_i[2:0]]; s_n = s_ret; end
				else begin ra_n = o_there ? o_cur : 10'h3ff; s_n = S_R; end
			end
			S_R:
			begin
				rv_n = ra_spec;
				s_n = s_ret;
				if (s_ret == S_A1 && !ra_needs_f)   // S_A1 without its clock, and the next read
				begin
					mul_a_n = ra_spec;
					if (!op[12]) begin rv_n = acc[19:4]; s_n = S_A2; end
					else
					begin
						s_ret_n = S_A2;
						o_i_n = o_i + 3'd1;
						if (o_is_imm) begin rv_n = o_v[o_i[2:0]]; s_n = S_A2; end
						else begin ra_n = o_there ? o_cur : 10'h3ff; s_n = S_R; end
					end
				end
				else if (ra_needs_f)
				begin
					f_empty_n = ra_depth == 4'd0;
					f_pop_n = ra[2:0] == 3'd4;
					fa_n = {ra_ch, ra_depth == 4'd0 ? 4'd8 : {1'b0, ra_dspi + 3'(ra[2:0] == 3'd1 && ra_depth != 4'd1)}};
					s_n = S_F;
				end
			end
			S_F:
			begin
				rv_n = f_q;
				s_n = s_ret;
				if (f_pop)
				begin
					if (f_empty) under = 1'b1;
					else begin pop_ev = 1'b1; p_fw = 1'b1; end
				end
			end
			default: s_n = S_OP;
		endcase
		if (w_pc) pc_n = w_v[9:0];
		if (dev_reset) pc_n = 10'h0;
	end


	// ---- DMA: into the FIFOs, a word of memory at a go ----------------------------------------------------------------
	typedef enum logic [3:0] { D_IDLE, D_A0, D_A1, D_C, D_M, D_R, D_P, D_WA, D_WC, D_N0, D_N1, D_N2, D_N3, D_N4 } ds_t;
	ds_t         d;
	logic [3:0]  dc;
	logic [31:0] d_addr, d_cnt;
	logic [63:0] d_w;
	logic [2:0]  d_left;
	logic        d_dirty;
	logic        pick_v;
	logic [3:0]  pick;
	always_comb
	begin
		pick_v = 1'b0; pick = 4'd0;
		for (int i = 0; i < 16; i++)
			if (ch_enable[i] && depth[i] <= 4'd4) begin pick_v = 1'b1; pick = 4'(i); end
	end
	// the host's commit of a channel's address and count takes two clocks, and goes first; the channel's round in hand is then dropped
	wire         h_ctl = we && h_dma && a[9:7] == 3'b001 && !a[6];
	wire         h_cmt = h_ctl && wd[31];
	logic        cmt2;
	logic [5:0]  cmt_a;
	logic [31:0] cmt_c;
	wire         r_host = h_cmt || cmt2;
	wire [7:0]   d_byte = d_w[8 * d_addr[2:0] +: 8];
	wire [15:0]  d_word = {d_w[16 * d_addr[2:1] +: 8], d_w[16 * d_addr[2:1] + 8 +: 8]};     // (big-endian, and on an even address)
	wire [15:0]  d_sample = ch_8bit[dc] ? {d_byte, 8'h00} : d_word;
	wire         dm_push = d == D_P && !p_fw && !d_dirty;
	wire         d_8 = ch_8bit[dc];
	wire [3:0]   d_room = d_8 ? 4'd8 - 4'(d_addr[2:0]) : 4'd4 - 4'(d_addr[2:1]);
	wire         d_cnt_big = d_cnt[31] || d_cnt >= 32'd4;
	wire [3:0]   d_max = d_cnt_big ? 4'd4 : 4'(d_cnt[2:0]);
	wire [2:0]   d_n = 3'(d_max < d_room ? d_max : d_room);
	assign m_rd = d == D_M;
	assign m_a = d_addr[31:3];

	always_comb
	begin
		f_we = p_fw || dm_push;
		f_wa = p_fw ? p_fwa : {dc, 1'b0, dspi[dc] + 3'(depth[dc])};
		f_wd = p_fw ? p_fwd : d_sample;
		r_we = r_host || (!d_dirty && (d == D_WA || d == D_WC || d == D_N3 || d == D_N4));
		r_wa = {dc, 2'b00}; r_wd = d_addr;
		if (d == D_WC || d == D_N4) begin r_wa = {dc, 2'b01}; r_wd = d_cnt; end
		if (r_host) begin r_wa = h_cmt ? {a[5:2], a[1], 1'b0} : cmt_a; r_wd = h_cmt ? (a[1] ? sh_na : sh_ca) : cmt_c; end
		case (d)
			D_IDLE, D_A0: r_ra = {d == D_IDLE ? pick : dc, 2'b00};
			D_A1: r_ra = {dc, 2'b01};
			D_N0: r_ra = {dc, 2'b10};
			default: r_ra = {dc, 2'b11};
		endcase
	end

	always_ff @(posedge clk)
	begin
		s <= s_n; s_ret <= s_ret_n;
		pc <= pc_n; ra <= ra_n; fa <= fa_n;
		op <= op_n; opw <= opw_n; sp <= sp_n;
		wb_v <= wb_v_n; wb_a <= wb_a_n;
		acc <= acc_n;
		o_n <= o_n_n; o_i <= o_i_n; n_ops <= n_ops_n;
		if (o_we_p && o_n < 3'd5) begin o_v[o_n[2:0]] <= o_wv; o_imm[o_n[2:0]] <= o_imm_w; end
		r_left <= r_left_n; r_tot <= r_tot_n;
		rv <= rv_n; mul_a <= mul_a_n; mv_a <= mv_a_n; wv <= wv_n; wa <= wa_n;
		alu_a <= alu_a_n; alu_b <= alu_b_n; mul_res <= mul_res_n; res <= res_n; barrel <= barrel_n;
		f_empty <= f_empty_n; f_pop <= f_pop_n; osc_c <= osc_c_n; osc_k <= osc_k_n;
		if (stk_push) stack[sp[1:0]] <= pc + 10'd1;
		if (flags_we)
		begin
			f_c <= alu_c; f_v <= alu_v;
			f_n <= alu_r[19]; f_z <= alu_r[19:4] == 16'h0; f_x <= alu_r[3:0] == 4'h0;
		end
		if (rb_we)      // RBASE
		begin
			if (op_n[1:0] == 2'd1) rbase[1] <= op_n[9:0] & 10'h3fc;
			else
			begin
				if (op_n[1:0] == 2'd0)
				begin
					rbase[0] <= op_n[9:0] & 10'h3fc;
					rbase[1] <= (op_n[9:0] & 10'h3fc) + 10'd4;
				end
				if (op_n[1:0] != 2'd3) rbase[2] <= (op_n[9:0] & 10'h3fc) + (op_n[1:0] == 2'd0 ? 10'd8 : 10'd0);
				rbase[3] <= (op_n[9:0] & 10'h3fc) + (op_n[1:0] == 2'd0 ? 10'd12 : op_n[1:0] == 2'd2 ? 10'd4 : 10'd0);
			end
		end
		if (osc_we) osc_phase <= osc_phase_n;
		last_osc <= last_osc_n;
		noise <= FROZEN ? 16'h0 : {noise[14:0], noise[15] ^ noise[13] ^ noise[12] ^ noise[10]};
		if (!FROZEN) tclock <= tclock - 16'd1;

		// the channels' FIFO state
		if (push_ev) dspi[wa_ch] <= dspi[wa_ch] + 3'd1;
		if (pop_ev) dspi[pop_ch] <= dspi[pop_ch] + 3'(pop_k);
		if (dm_push) depth[dc] <= depth[dc] + 4'd1;     // (it waits for the FIFO's write port, so never with the program's)
		if (pop_ev) depth[pop_ch] <= depth[pop_ch] - 4'(pop_k);
		if (push_ev) depth[wa_ch] <= depth[wa_ch] + 4'd1;

		// the frame: outputs, the timer
		if (w_do)
		begin
			if (w_a == 10'h2e0) out0 <= w_v;
			if (w_a == 10'h2e1) out1 <= w_v;
			if (w_a == 10'h3f6) audlock <= w_v[0];
			if (w_a == 10'h3f7) tclock <= w_v;
		end

		// the DACs
		if (w_frame && o_count == 3'd4) o_start <= o_start + 2'd1;
		else if (dac_tick && o_count != 3'd0)
		begin
			o_start <= o_start + 2'd1;
			if (!w_frame) o_count <= o_count - 3'd1;
		end
		else if (w_frame) o_count <= o_count + 3'd1;
		if (dac_tick && o_count != 3'd0) begin dac_l <= o_q[15:0]; dac_r <= o_q[31:16]; end

		// ---- the host's registers
		if (w_frame)
		begin
			up_time <= up_time + 32'd1;
			duration <= duration - 16'd1;
		end
		if (under) underover_int[ra_ch] <= 1'b1;
		if (we && !h_code && !h_data && !h_dma)
			case (h_off)
				15'h4000: partial_int <= partial_int | (wd & ~32'h0000000b);
				15'h4004: partial_int <= partial_int & ~(wd & ~32'h0000000b);
				15'h4008: int_enable <= int_enable | wd;
				15'h400c: int_enable <= int_enable & ~wd;
				15'h4010: dmanext_int <= dmanext_int | wd[15:0];
				15'h4014: dmanext_int <= dmanext_int & ~wd[15:0];
				15'h4018: dmanext_en <= dmanext_en | wd[15:0];
				15'h4030: underover_int <= underover_int | wd[15:0];
				15'h4034: underover_int <= underover_int & ~wd[15:0];
				15'h6000: ch_enable <= ch_enable | wd[15:0];
				15'h6004: ch_enable <= ch_enable & ~wd[15:0];
				15'h6010: ch_8bit <= ch_8bit | wd[15:0];
				15'h6014: ch_8bit <= ch_8bit & ~wd[15:0];
				15'h6030:
					for (int i = 0; i < 16; i++)
						if (wd[i]) begin dspi[i] <= 3'd0; depth[i] <= 4'd0; end
				15'h6040: duration <= wd[15:0];
				15'h6044: up_time <= wd;
				15'h6070: gwilling <= wd[0];
				default: ;
			endcase
		if (we && h_dma && a[9:7] == 3'b000)
			case (a[1:0])
				2'd0: sh_ca <= wd;
				2'd1: sh_cc <= wd;
				2'd2: sh_na <= wd;
				default: sh_nc <= wd;
			endcase
		// (after the host's, so that neither is lost)
		if (w_do && w_a == 10'h3e6) partial_int[31:16] <= (we && !h_code && !h_data && !h_dma && h_off == 15'h4004 ? partial_int[31:16] & ~wd[31:16] : partial_int[31:16]) | w_v;
		if (w_frame && duration == 16'h0) partial_int[8] <= 1'b1;
		if (h_ctl)
		begin
			if (wd[16]) next_valid[a[5:2]] <= wd[0];
			if (wd[17]) go_forever[a[5:2]] <= wd[1];
			if (wd[18]) dmanext_en[a[5:2]] <= wd[2];
		end
		cmt2 <= h_cmt;
		cmt_a <= {a[5:2], a[1], 1'b1};
		cmt_c <= a[1] ? sh_nc : sh_cc;

		// ---- DMA
		if (h_cmt && !a[1] && a[5:2] == dc) d_dirty <= 1'b1;
		if (d == D_IDLE) d_dirty <= 1'b0;
		case (d)
			D_IDLE: if (pick_v && !r_host) begin dc <= pick; d <= D_A0; end
			D_A0: d <= D_A1;
			D_A1: begin d_addr <= r_q; d <= D_C; end
			D_C:
			begin
				d_cnt <= r_q;
				d <= r_q == 32'h0 ? D_IDLE : D_M;
			end
			D_M:
			begin
				if (!m_busy) d <= D_R;
				d_left <= d_n;
			end
			D_R: if (m_ready) begin d_w <= m_dout; d <= D_P; end
			D_P:
				if (d_dirty) d <= D_IDLE;
				else if (dm_push)
				begin
					d_addr <= d_addr + (d_8 ? 32'd1 : 32'd2);
					d_cnt <= d_cnt - 32'd1;
					d_left <= d_left - 3'd1;
					if (d_left == 3'd1) d <= D_WA;
				end
			D_WA: if (d_dirty) d <= D_IDLE; else if (!r_host) d <= D_WC;
			D_WC:
				if (d_dirty) d <= D_IDLE;
				else if (!r_host)
				begin
					if (d_cnt[31] || d_cnt == 32'h0)
					begin
						if (next_valid[dc])
						begin
							if (!go_forever[dc]) next_valid[dc] <= 1'b0;
							dmanext_int[dc] <= 1'b1;
							d <= D_N0;
						end
						else begin ch_enable[dc] <= 1'b0; d <= D_IDLE; end
					end
					else d <= D_IDLE;
				end
			D_N0: d <= D_N1;
			D_N1: begin d_addr <= r_q; d <= D_N2; end
			D_N2: begin d_cnt <= r_q; d <= D_N3; end
			D_N3: if (d_dirty) d <= D_IDLE; else if (!r_host) d <= D_N4;
			D_N4:
				if (d_dirty) d <= D_IDLE;
				else if (!r_host) d <= D_IDLE;
			default: d <= D_IDLE;
		endcase

		if (dev_reset)
		begin
			s <= S_OP; pc <= 10'h0; sp <= 3'd0; wb_v <= 1'b0;
			o_start <= 2'd0; o_count <= 3'd0; audlock <= 1'b0;
			for (int i = 0; i < 4; i++) rbase[i] <= 10'(4 * i);
			partial_int <= 32'h0;
		end
		if (rst)
		begin
			d <= D_IDLE; d_dirty <= 1'b0; cmt2 <= 1'b0;
			gwilling <= 1'b0; int_enable <= 32'h0;
			ch_enable <= 16'h0; ch_8bit <= 16'h0; dmanext_int <= 16'h0; dmanext_en <= 16'h0; underover_int <= 16'h0;
			next_valid <= 16'h0; go_forever <= 16'h0;
			duration <= 16'h0; up_time <= 32'h0;
			tclock <= 16'h0; noise <= 16'hace1; osc_phase <= 16'h0; last_osc <= 2'd0;
			f_c <= 1'b0; f_z <= 1'b0; f_n <= 1'b0; f_v <= 1'b0; f_x <= 1'b0; acc <= 20'h0;
			dac_l <= 16'h0; dac_r <= 16'h0;
			for (int i = 0; i < 16; i++) begin dspi[i] <= 3'd0; depth[i] <= 4'd0; end
		end
	end

	// ---- the host's reads ---------------------------------------------------------------------------------------------
	always_comb
	begin
		rd = 32'h0;
		if (h_code) rd = 32'(hc_q);
		else if (h_data)
		begin
			logic [9:0] x;
			x = a[9:0];
			if (x < 10'h2e0) rd = 32'(hd_q);
			else
				case (x)
					10'h3de: rd = 32'h1;
					10'h3df: rd = 32'({o_count, 1'b0});
					10'h3ee: rd = 32'(pc);
					10'h3f6: rd = 32'(audlock);
					10'h3f7: rd = 32'(tclock);
					10'h3ff: rd = 32'(noise);
					default: ;
				endcase
		end
		else if (h_dma)
		begin
			if (a[9:7] == 3'b000 && !a[6]) rd = hr_q;
			else if (a[9:7] == 3'b001 && !a[6]) rd = {30'h0, go_forever[a[5:2]], next_valid[a[5:2]]};
		end
		else
			case (h_off)
				15'h4000, 15'h4004: rd = host_int;
				15'h4008, 15'h400c: rd = int_enable;
				15'h4010, 15'h4014: rd = 32'(dmanext_int);
				15'h4018: rd = 32'(dmanext_en);
				15'h4030, 15'h4034: rd = 32'(underover_int);
				15'h6000, 15'h6004: rd = 32'(ch_enable);
				15'h6010, 15'h6014: rd = 32'(ch_8bit);
				15'h6040: rd = 32'(duration);
				15'h6044: rd = up_time;
				15'h6070: rd = 32'(gwilling);
				default: ;
			endcase
	end
	always_ff @(posedge clk) intr <= !rst && (host_int & int_enable) != 32'h0;
endmodule
