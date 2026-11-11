// m2_ymz280b: the Yamaha YMZ280B of Evil Night's sub board, MAME 0.289's device (sound/ymz280b.cpp, BSD-3): eight voices of ADPCM or PCM from a ROM, each
// resampled by a linear interpolator to the chip's 88.2 kHz (its 16.9344 MHz / 192). One voice at a time, a round for each tick: the 756 clocks between ticks
// are about 94 a voice, and a voice takes 20 to 60, more when its word of the ROM has to come from DDR3 (a word for each voice, in its cache: 16 ADPCM samples).
//
// As MAME's stream, with a sample at a time: what's written between two ticks is acted on before the next tick's round. What MAME does for the rest of a stream
// update once a voice has ended (it ramps down, by 15/16 a sample, as far as that update goes) is done here until it reaches zero: the update's length is MAME's.
// The IRQ isn't here: nothing on the board has it. The DSP registers aren't in MAME either.
//
// Voices' state and registers in the logic's small memories, the block RAM being what the machine runs out of.
`default_nettype none
module m2_ymz_mem #(
	parameter int W = 8,
	parameter int AW = 3
) (
	input  logic          clk,
	input  logic          we,
	input  logic [AW-1:0] wa,
	input  logic [W-1:0]  wd,
	input  logic [AW-1:0] ra,
	output logic [W-1:0]  rd
);
	(* ramstyle = "MLAB, no_rw_check" *) logic [W-1:0] mem [0:(1 << AW) - 1];
	always_ff @(posedge clk)
	begin
		if (we) mem[wa] <= wd;
		rd <= mem[ra];
	end
endmodule

module m2_ymz280b (
	input  logic         clk,
	input  logic         rst,
	input  logic         tick,          // 88.2 kHz, a clock

	input  logic         sel_we,        // offset 0: which register
	input  logic [7:0]   sel_d,
	input  logic         dat_we,        // offset 1: its data
	input  logic [7:0]   dat_d,
	input  logic         ext_rd,        // a read of offset 0: ext_q is what it reads, the next byte follows
	input  logic         st_rd,         // a read of offset 1: st_q is what it reads, and that clears it
	output logic [7:0]   ext_q,
	output logic [7:0]   st_q,

	output logic         m_rd,          // the ROM, in DDR3: 64-bit words, the byte at address n in bits 8n+7:8n
	output logic [21:3]  m_a,
	input  logic         m_busy,
	input  logic         m_ready,
	input  logic [63:0]  m_dout,

	output logic signed [15:0] out_l,   // at 44.1 kHz: the mean of two rounds, at MAME's route of 0.5
	output logic signed [15:0] out_r,
	output logic         rnd_done,      // a clock, the round's end: the bench's
	output logic signed [26:0] rnd_l,   // what the round added up: MAME's stream, times 32768 * 256
	output logic signed [26:0] rnd_r
);
	localparam logic [1:0] C_NONE = 2'd0, C_KON = 2'd1, C_KOFF = 2'd2, C_RES = 2'd3;

	typedef enum logic [4:0] {
		S_INIT, S_IDLE, S_LOAD, S_APPLY, S_KON, S_CHK, S_I1, S_I2, S_I3, S_P1, S_P2, S_P3, S_V1, S_CHK2, S_ADV, S_RB, S_RW, S_GOT,
		S_AD2, S_AD3, S_LP, S_L1, S_L2, S_L3, S_STOP, S_ST1, S_DONE, S_SAVE, S_EXT, S_EXTW
	} st_t;
	st_t         st;
	logic [2:0]  v;

	// ---- the CPU's side ------------------------------------------------------------------------------------------------------
	logic [7:0]  cur;                   // the register chosen
	logic [1:0]  cmd [0:7];             // what's been asked of the voice since its last round
	logic [7:0]  keyon, looping, fnum8;
	logic [1:0]  mode [0:7];
	logic        keyon_en, ext_en;
	logic [7:0]  status;
	logic [7:0]  ad_hi, ad_mi;          // the external memory address, as written
	logic [23:0] ext_a, ext_b;          // the next read's address; the byte the latch wants
	logic [7:0]  ext_latch;
	logic        ext_want;

	wire [2:0]   wv = cur[4:2];
	wire         wlow = !cur[7];
	wire [7:0]   wreg = cur & 8'he3;
	wire         w_ad = dat_we && wlow && cur[6:5] != 2'b00;    // 0x20..0x63
	wire [7:0]   d7 = dat_d[6:5] == 2'b00 ? {1'b0, dat_d[6:0]} : dat_d;

	// a voice's four addresses (start, loop start, loop end, stop), a byte of each in its own memory, as they're written
	logic [1:0]  asel;
	logic [23:0] aq;
	wire [4:0]   a_ra = {v, asel};
	wire [4:0]   a_wa = {wv, cur[1:0]};
	m2_ymz_mem #(.W(8), .AW(5)) a_hi (.clk, .we(w_ad && cur[6:5] == 2'd1), .wa(a_wa), .wd(dat_d), .ra(a_ra), .rd(aq[23:16]));
	m2_ymz_mem #(.W(8), .AW(5)) a_mi (.clk, .we(w_ad && cur[6:5] == 2'd2), .wa(a_wa), .wd(dat_d), .ra(a_ra), .rd(aq[15:8]));
	m2_ymz_mem #(.W(8), .AW(5)) a_lo (.clk, .we(w_ad && cur[6:5] == 2'd3), .wa(a_wa), .wd(dat_d), .ra(a_ra), .rd(aq[7:0]));

	// pitch, level and pan
	logic [7:0]  c_fnum, c_level;
	logic [3:0]  c_pan;
	m2_ymz_mem #(.W(8), .AW(3)) c_f (.clk, .we(dat_we && wlow && wreg == 8'h00), .wa(wv), .wd(dat_d), .ra(v), .rd(c_fnum));
	m2_ymz_mem #(.W(8), .AW(3)) c_l (.clk, .we(dat_we && wlow && wreg == 8'h02), .wa(wv), .wd(dat_d), .ra(v), .rd(c_level));
	m2_ymz_mem #(.W(4), .AW(3)) c_p (.clk, .we(dat_we && wlow && wreg == 8'h03), .wa(wv), .wd(dat_d[3:0]), .ra(v), .rd(c_pan));

	// ---- a voice's state ------------------------------------------------------------------------------------------------------
	typedef struct packed {
		logic [24:0]        pos;        // in nibbles
		logic signed [15:0] sig;
		logic [14:0]        stp;
		logic signed [15:0] lsig;       // the decoder's state at the loop's start
		logic [14:0]        lstp;
		logic [9:0]         opos;       // the interpolator's
		logic signed [15:0] prev;
		logic signed [15:0] curr;
		logic               playing;
		logic               ramp;       // it has ended: on down to zero
		logic               lseen;      // the first time round the loop is over
	} voice_t;
	voice_t      w, w_q;
	logic [63:0] cw, cw_q;              // the voice's word of the ROM
	logic [19:0] ct, ct_q;              // valid, and its address
	logic        init_n;

	wire         save = st == S_SAVE || st == S_INIT;
	voice_t      w_init;
	always_comb
	begin
		w_init = '0;
		w_init.opos = 10'd512;
	end
	m2_ymz_mem #(.W($bits(voice_t)), .AW(3)) vs (.clk, .we(save), .wa(v), .wd(st == S_INIT ? w_init : w), .ra(v), .rd(w_q));
	m2_ymz_mem #(.W(64), .AW(3)) cd (.clk, .we(st == S_SAVE), .wa(v), .wd(cw), .ra(v), .rd(cw_q));
	m2_ymz_mem #(.W(20), .AW(3)) ctag (.clk, .we(save), .wa(v), .wd(st == S_INIT ? 20'd0 : ct), .ra(v), .rd(ct_q));

	// ---- the one multiplier: two clocks from its inputs to its product --------------------------------------------------------
	logic signed [17:0] ma, mb;
	logic signed [35:0] mp;
	logic               mw;             // wait a clock (the small memories, too)
	always_ff @(posedge clk) mp <= ma * mb;

	logic               pend;
	logic [9:0]         fstep_q;
	logic               emitted;
	logic signed [26:0] sl, sr;
	logic signed [25:0] acc;
	logic signed [15:0] interp;
	logic signed [15:0] newp;
	logic [7:0]         att;
	logic [23:0]        ba;
	logic [7:0]         rb, lo;
	logic               hi_phase;
	logic [3:0]         nib;
	logic signed [16:0] sig_n;
	logic               avg;            // the first of the two rounds is in avg_*
	logic signed [26:0] avg_l, avg_r;

	assign st_q = status;
	assign ext_q = ext_en ? ext_latch : 8'hff;

	// the C code's x / 2, toward zero
	function automatic logic signed [26:0] halve(input logic signed [35:0] x);
		logic signed [26:0] y;
		y = 27'(x) + 27'(x[35] ? 1 : 0);
		return y >>> 1;
	endfunction
	function automatic logic signed [15:0] decay(input logic signed [15:0] t);
		logic [16:0] m, r;
		m = t[15] ? 17'd0 - {t[15], t} : {t[15], t};
		r = 17'(({4'd0, m, 4'd0} - {8'd0, m}) >> 4);
		return t[15] ? 16'd0 - r[15:0] : r[15:0];
	endfunction
	function automatic logic [9:0] scale(input logic [2:0] i);
		case (i)
			3'd4: return 10'h133;
			3'd5: return 10'h199;
			3'd6: return 10'h200;
			3'd7: return 10'h266;
			default: return 10'h0e6;
		endcase
	endfunction
	function automatic logic signed [15:0] sat(input logic signed [27:0] x);
		if (x > 28'sd32767) return 16'sd32767;
		if (x < -28'sd32768) return 16'sh8000;
		return x[15:0];
	endfunction

	wire [8:0]  sub_k = c_pan == 4'd0 ? 9'd0 : c_pan <= 4'd8 ? 9'(c_pan - 4'd1) : 9'(4'd15 - c_pan);
	wire        left_full = c_pan <= 4'd8;
	wire [24:0] aq_n = {aq, 1'b0};
	wire signed [27:0] mean_l = 28'(avg_l) + 28'(sl);   // (the mean of two, at /512: the sum / 1024)
	wire signed [27:0] mean_r = 28'(avg_r) + 28'(sr);

	always_ff @(posedge clk)
	begin
		rnd_done <= 1'b0;
		if (st_rd) status <= 8'h00;     // (a voice ending in the same clock isn't lost)
		if (tick) pend <= 1'b1;
		if (rst)
		begin
			st <= S_INIT; v <= 3'd0; mw <= 1'b0; pend <= 1'b0; m_rd <= 1'b0; out_l <= 16'd0; out_r <= 16'd0; avg <= 1'b0;
		end
		else if (mw) mw <= 1'b0;
		else
			case (st)
				S_INIT:
				begin
					v <= v + 3'd1;
					if (v == 3'd7) st <= S_IDLE;
				end
				S_IDLE:
					if (pend) begin pend <= tick; v <= 3'd0; sl <= '0; sr <= '0; st <= S_LOAD; end
					else if (ext_want) begin ba <= ext_b; st <= S_EXT; end
				// the external memory's byte, read for the CPU between rounds
				S_EXT:
				begin
					m_rd <= 1'b1; m_a <= ba[21:3]; st <= S_EXTW;
				end
				S_EXTW:
				begin
					if (m_rd && !m_busy) m_rd <= 1'b0;
					if (m_ready)
					begin
						ext_latch <= m_dout[8 * ba[2:0] +: 8];
						st <= S_IDLE;
					end
				end
				S_LOAD: st <= S_APPLY;
				S_APPLY:
				begin
					w <= w_q;
					cw <= cw_q; ct <= ct_q;
					emitted <= 1'b0;
					fstep_q <= (mode[v] == 2'd1 ? {2'b00, c_fnum} : {1'b0, fnum8[v], c_fnum}) + 10'd1;
					cmd[v] <= C_NONE;
					st <= S_CHK;
					case (cmd[v])
						C_KON:
						begin
							w.playing <= 1'b1; w.ramp <= 1'b0; w.sig <= 16'd0; w.lsig <= 16'd0; w.stp <= 15'h7f; w.lstp <= 15'h7f; w.lseen <= 1'b0;
							asel <= 2'd0; mw <= 1'b1; st <= S_KON;
						end
						C_KOFF: begin w.playing <= 1'b0; w.ramp <= 1'b0; end
						C_RES: w.playing <= 1'b1;
						default: ;
					endcase
				end
				S_KON:
				begin
					w.pos <= aq_n;
					st <= S_CHK;
				end
				S_CHK:
					if (!w.playing && w.curr == 16'd0 && w.prev == 16'd0)
					begin
						w.opos <= 10'd512;
						st <= S_SAVE;
					end
					else if (w.opos[9]) st <= S_ADV;
					else st <= S_I1;
				// the interpolator and the volumes
				S_I1:
				begin
					ma <= 18'(w.prev); mb <= 18'(10'd512 - w.opos); mw <= 1'b1; st <= S_I2;
				end
				S_I2:
				begin
					acc <= mp[25:0]; ma <= 18'(w.curr); mb <= 18'(w.opos); mw <= 1'b1; st <= S_I3;
				end
				S_I3:
				begin
					logic signed [26:0] s;
					s = 27'(acc) + 27'(signed'(mp[25:0]));
					interp <= 16'(s >>> 9);
					ma <= 18'(c_level); mb <= 18'(sub_k); mw <= 1'b1; st <= S_P1;
				end
				S_P1:   // (level * k) / 7: exact, for what this can be
				begin
					ma <= 18'(mp); mb <= 18'd9363; mw <= 1'b1; st <= S_P2;
				end
				S_P2:
				begin
					att <= 8'(mp >>> 16);
					ma <= 18'(interp); mb <= left_full ? 18'(c_level) : 18'(mp >>> 16); mw <= 1'b1; st <= S_P3;
				end
				S_P3:
				begin
					sl <= sl + halve(mp);
					ma <= 18'(interp); mb <= left_full ? 18'(att) : 18'(c_level); mw <= 1'b1; st <= S_V1;
				end
				S_V1:
				begin
					sr <= sr + halve(mp);
					w.opos <= w.opos + fstep_q;
					emitted <= 1'b1;
					st <= S_CHK2;
				end
				S_CHK2: st <= w.opos[9] ? S_ADV : S_SAVE;
				// the next sample
				S_ADV:
				begin
					w.opos[9] <= 1'b0;
					hi_phase <= 1'b0;
					if (w.playing && mode[v] != 2'd0) begin ba <= w.pos[24:1]; st <= S_RB; end
					else
					begin
						newp <= w.ramp ? decay(w.curr) : 16'd0;
						if (decay(w.curr) == 16'd0) w.ramp <= 1'b0;
						st <= S_DONE;
					end
				end
				S_RB:
					if (ct[19] && ct[18:0] == ba[21:3])
					begin
						rb <= cw[8 * ba[2:0] +: 8];
						st <= S_GOT;
					end
					else
					begin
						m_rd <= 1'b1; m_a <= ba[21:3]; st <= S_RW;
					end
				S_RW:
				begin
					if (m_rd && !m_busy) m_rd <= 1'b0;
					if (m_ready)
					begin
						cw <= m_dout; ct <= {1'b1, ba[21:3]};
						st <= S_RB;
					end
				end
				S_GOT:
					case (mode[v])
						2'd1:   // ADPCM
						begin
							logic [3:0] n;
							n = w.pos[0] ? rb[3:0] : rb[7:4];
							nib <= n;
							ma <= 18'(w.stp); mb <= 18'({n[2:0], 1'b1}); mw <= 1'b1; st <= S_AD2;
						end
						2'd2:   // 8-bit PCM
						begin
							newp <= {rb, 8'h00};
							w.pos <= w.pos + 25'd2;
							st <= S_LP;
						end
						default:    // 16-bit PCM: the low byte first
							if (!hi_phase) begin lo <= rb; hi_phase <= 1'b1; ba <= ba + 24'd1; st <= S_RB; end
							else
							begin
								newp <= {rb, lo};
								w.pos <= w.pos + 25'd4;
								st <= S_LP;
							end
					endcase
				S_AD2:
				begin
					logic signed [17:0] n, d;
					d = 18'(mp >>> 3);
					n = nib[3] ? 18'(w.sig) - d : 18'(w.sig) + d;
					n = n > 18'sd32767 ? 18'sd32767 : n < -18'sd32768 ? -18'sd32768 : n;
					w.sig <= n[15:0];
					newp <= n[15:0];
					ma <= 18'(w.stp); mb <= 18'(scale(nib[2:0])); mw <= 1'b1; st <= S_AD3;
				end
				S_AD3:
				begin
					logic [17:0] t;
					t = mp[25:8];
					w.stp <= t > 18'h6000 ? 15'h6000 : t < 18'h7f ? 15'h7f : t[14:0];
					w.pos <= w.pos + 25'd1;
					st <= S_LP;
				end
				// the loop and the end
				S_LP:
					if (looping[v]) begin asel <= 2'd1; mw <= 1'b1; st <= S_L1; end
					else st <= S_STOP;
				S_L1:
				begin
					if (mode[v] == 2'd1 && w.pos == aq_n && !w.lseen) begin w.lsig <= w.sig; w.lstp <= w.stp; end
					asel <= 2'd2; mw <= 1'b1; st <= S_L2;
				end
				S_L2:
					if (w.pos >= aq_n && keyon[v]) begin asel <= 2'd1; mw <= 1'b1; st <= S_L3; end
					else st <= S_STOP;
				S_L3:
				begin
					w.pos <= aq_n;
					if (mode[v] == 2'd1) begin w.sig <= w.lsig; w.stp <= w.lstp; w.lseen <= 1'b1; end
					st <= S_STOP;
				end
				S_STOP:
				begin
					asel <= 2'd3; mw <= 1'b1; st <= S_ST1;
				end
				S_ST1:
				begin
					if (w.pos >= aq_n)
					begin
						w.playing <= 1'b0;
						w.ramp <= 1'b1;
						status[v] <= 1'b1;
					end
					st <= S_DONE;
				end
				S_DONE:
				begin
					w.prev <= w.curr;
					w.curr <= newp;
					st <= emitted ? S_SAVE : S_I1;
				end
				S_SAVE:
				begin
					v <= v + 3'd1;
					st <= S_LOAD;
					if (v == 3'd7)
					begin
						st <= S_IDLE;
						rnd_done <= 1'b1; rnd_l <= sl; rnd_r <= sr;
						avg <= !avg;
						if (avg)
						begin
							out_l <= sat(mean_l >>> 10);
							out_r <= sat(mean_r >>> 10);
						end
						else begin avg_l <= sl; avg_r <= sr; end
					end
				end
				default: st <= S_IDLE;
			endcase

		// ---- the CPU's writes: after the rounds' clearing of cmd, so a write isn't lost ----------------------------------------
		if (sel_we) cur <= sel_d;
		if (st_rd) status <= 8'h00;
		if (rst)
		begin
			keyon <= 8'h00; looping <= 8'h00; fnum8 <= 8'h00; keyon_en <= 1'b0; ext_en <= 1'b0; status <= 8'h00; ext_want <= 1'b0;
			for (int i = 0; i < 8; i++) begin cmd[i] <= C_NONE; mode[i] <= 2'd0; end
		end
		else
		begin
			if (st == S_IDLE && !pend) ext_want <= 1'b0;
			if (dat_we && wlow && wreg == 8'h01)
			begin
				fnum8[wv] <= dat_d[0];
				looping[wv] <= dat_d[4];
				if (dat_d[6:5] != 2'b00) mode[wv] <= dat_d[6:5];
				if (!keyon[wv] && d7[7] && keyon_en) cmd[wv] <= C_KON;
				else if (keyon[wv] && !d7[7]) cmd[wv] <= C_KOFF;
				keyon[wv] <= d7[7];
			end
			if (dat_we && !wlow)
				case (cur)
					8'h84: ad_hi <= dat_d;
					8'h85: ad_mi <= dat_d;
					8'h86:
					begin
						ext_a <= {ad_hi, ad_mi, dat_d};
						ext_b <= {ad_hi, ad_mi, dat_d};
						if (ext_en) ext_want <= 1'b1;
					end
					8'hff:
					begin
						ext_en <= dat_d[6];
						if (keyon_en && !dat_d[7]) for (int i = 0; i < 8; i++) cmd[i] <= C_KOFF;
						else if (!keyon_en && dat_d[7])
						begin
							for (int i = 0; i < 8; i++) if (keyon[i] && looping[i]) cmd[i] <= C_RES;
						end
						keyon_en <= dat_d[7];
					end
					default: ;
				endcase
			if (ext_rd && ext_en) begin ext_b <= ext_a; ext_a <= ext_a + 24'd1; ext_want <= 1'b1; end   // (MAME's order: the latch from the address, then on)
		end
	end
endmodule
`default_nettype wire
