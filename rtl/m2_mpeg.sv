// m2_mpeg: the BDA's MPEG unit, its control only, as the M2 emulator's (3dom2.cpp m2_mpeg_device) without the pictures: the registers, the
// video bitstream's DMA (the current and next buffers), the start codes, and the interrupts. The driver (M2 SDK devices/mpegvideo/M2MPEGUnit.c)
// parses the sequence and picture headers itself and gives the unit a picture's slice data; at the first start code that isn't a slice's the
// unit takes two more bytes (its read-ahead), says the picture's done, and the driver gets the start code and those bytes back through the
// parser status registers, stepping the parser a byte at a time. Nothing's decoded: a game's videos are black, the rest of it runs on time.
//
// The bitstream's read from memory a 32-byte line at a time into block RAM, then a word of it into registers (a clock), and a byte a clock
// from that. The emulator takes a buffer 10 us after it's given one.
//
// MPEG_HPS: the pictures are decoded by a program on the MiSTer's ARM (m2mpegd; hps/m2mpegd/PROTOCOL.md, version 1), which this
// unit tells what to decode through a block of DDR3 (at the bus's addresses 0x58000000 +: rtl/m2_boot.sv puts the block there):
// - each register write's an entry in a log there, in order (a queue of 16: hold asks m2_boot to start no register access while
//   it's nearly full);
// - each byte of a picture's data (the bytes taken looking for the start code that ends it) goes into a ring there, a byte a write
//   (the parser waits for it: eight to a write took about 90 registers more, and the build has no room);
// - where a picture ends, an entry says so, after its last bytes; then the line the program writes (it's there, it's alive, the
//   last picture it's done) is read, and if a program is there the end-of-picture interrupts wait, the line read again every 2^14
//   clocks, until it says this picture's pixels are in memory, or it stops moving for 50 ms, or 120 ms have gone;
// - a reset clears the log and that line, then writes the header; a count goes up there every 2^20 clocks.
// The memory port then writes too (a word; never with a read).
`default_nettype none

module m2_mpeg
`ifdef MPEG_HPS
#(
	parameter int BEAT_LOG2 = 20        // the count for the ARM goes up every 2^BEAT_LOG2 clocks (a bench makes it less; 14 at least)
)
`endif
(
	input  logic        clk,
	input  logic        rst,

	// the registers, 0x00080000 +: a read's value in the clock of its address
	input  logic [9:2]  a,
	input  logic        we,
	input  logic [31:0] wd,
	output logic [31:0] rd,
	output logic        intr,

	// memory: a line of 4 words
	output logic        m_rd,
	output logic [31:3] m_a,
`ifdef MPEG_HPS
	output logic        m_we,           // a word of the block
	output logic [63:0] m_wd,
	output logic [7:0]  m_be,
	output logic        hold,           // the log's queue is nearly full: no register access may start
`endif
	input  logic        m_busy,
	input  logic        m_ready,
	input  logic [63:0] m_dout
);
	localparam logic [7:0] R_DEVICEID = 8'h00, R_CONFIG = 8'h01, R_INTENABLE = 8'h02, R_INTSTATUS = 8'h03, R_VBSCURADDR = 8'h04, R_VBSCURLEN = 8'h05,
		R_VBSNEXTADDR = 8'h06, R_VBSNEXTLEN = 8'h07, R_VBSCONFIG = 8'h08, R_PARSERCONFIG = 8'h09, R_PARSERSTATUS0 = 8'h0a, R_IMAGESIZE = 8'h0b,
		R_FORMATCROP = 8'h10, R_PARSERSTATUS1 = 8'h17;
	localparam logic [31:0] I_VBS_DMA = 32'h01, I_DONE = 32'h02 | 32'h10 | 32'h20;   // end of picture, output formatter, everything done

	typedef enum logic [1:0] { M_IDLE, M_SLICES, M_READAHEAD, M_DONE } mst_t;
	mst_t        ms;
	logic [31:0] cfg, int_en, int_st, cur_a, cur_n, nxt_a, nxt_n, parser, isize, crop;
	logic [31:0] shift, used;
	logic [7:0]  last_sc;
	logic [7:0]  ra [0:1];
	logic [1:0]  ra_n;
	logic [2:0]  ev;                    // the parser's place in the read-ahead (it steps a byte at a time, past it too)

	wire         taking = ms == M_SLICES || ms == M_READAHEAD;
	wire  [7:0]  ra0 = ev < 3'(ra_n) ? ra[ev[0]] : 8'h00;
	wire  [7:0]  ra1 = ev + 3'd1 < 3'(ra_n) ? ra[1] : 8'h00;
	always_comb
		case (a)
			R_DEVICEID:      rd = 32'h00010000;     // (not pass 1 silicon)
			R_CONFIG:        rd = cfg;
			R_INTENABLE:     rd = int_en;
			R_INTSTATUS:     rd = int_st;
			R_VBSCURADDR:    rd = cur_a;
			R_VBSCURLEN:     rd = cur_n;
			R_VBSNEXTADDR:   rd = nxt_a;
			R_VBSNEXTLEN:    rd = nxt_n;
			R_PARSERCONFIG:  rd = parser;
			R_IMAGESIZE:     rd = isize;
			R_PARSERSTATUS0: rd = {16'h0, ra0, ra1};   // the next 16 bits the parser would look at
			R_PARSERSTATUS1: rd = {16'h0003, last_sc, 8'h00};   // (3 bits valid: just the two bytes of read-ahead to get back)
			default:         rd = 32'h0;            // (VBSCONFIG: nothing buffered past the read-ahead)
		endcase
	assign intr = (int_st & int_en) != 32'h0;

	// the bitstream: a line, then its bytes
	typedef enum logic [2:0] { P_IDLE, P_WAIT, P_TAKE, P_RUN, P_FETCH, P_FILL, P_WORD } pst_t;
	pst_t        ps;
	logic        kick;                  // a buffer's been given: take it after the wait
	logic [9:0]  wait_n;
	(* ramstyle = "M10K" *) logic [63:0] lb [0:3];   // the line
	logic [63:0] lb_q;                  // (its word at cur_a, the clock after)
	logic [31:5] lb_a;
	logic        lb_v;
	logic [1:0]  lb_n;
	logic [63:0] w;                     // the word the bytes come from
	logic [31:3] w_a;
	logic        w_v;
	wire         lb_hit = lb_v && lb_a == cur_a[31:5];
	wire         w_hit = w_v && w_a == cur_a[31:3];
	wire  [7:0]  byte_in = w[8 * cur_a[2:0] +: 8];
	always_ff @(posedge clk)
	begin
		if (ps == P_FILL && m_ready) lb[lb_n] <= m_dout;
		lb_q <= lb[cur_a[4:3]];
	end
	wire  [31:0] sc = {shift[23:0], byte_in};
	wire         ends = sc[31:8] == 24'h000001 && (byte_in == 8'h00 || byte_in > 8'haf);   // a start code, not a slice's
	// (a B picture cropped vertically is done when the formatter's last row is out: the driver goes on from the DMA's address without the
	// read-ahead, so the start code's left unread)
	wire         cropped_b = parser[2:0] == 3'd3 && 8'(crop[6:0]) + 8'd1 < isize[15:8];
	// a byte's taken this clock; it's a picture's; the picture ends with it
	logic        ring_stall;
	wire         take = ps == P_RUN && !ring_stall && cur_n != 32'h0 && taking && lb_hit && w_hit;
	wire         ring_byte = take && ms == M_SLICES;
	wire         pic_end = take && (ms == M_SLICES ? ends && cropped_b : ra_n == 2'd1);
	wire         cfg_off = we && a == R_CONFIG && !wd[1];
	wire         cfg_start = we && a == R_CONFIG && wd[1] && !cfg[1];
`ifdef MPEG_HPS
	localparam bit HPS = 1'b1;
	localparam logic [63:0] HEADER = {32'h4D324D50, 16'd1, 8'd12, 8'd18};
	localparam logic [31:0] MAGIC_PRESENT = 32'h4D504744;
	localparam logic [8:0] POLLS_TIMEOUT = 9'd487;      // 120 ms of polls (2^14 clocks at 66.67 MHz: 0.246 ms)
	localparam logic [7:0] POLLS_DEAD = 8'd202;         // 50 ms
	// the ring: a picture's byte is written there as the parser takes it (the parser waits for the write), a byte a write
	logic [23:0] sp;                    // the stream's position
	logic [17:0] pl;                    // the picture's length so far (the ring holds no more)
	logic        pl_clr;                // (the bitstream was started again before the last picture's entry was written: pl's cleared after it)
	// the log's queue: [40] a picture's end (its contents are taken from pl and sp when it's written), [39:0] a register write's
	(* ramstyle = "MLAB" *) logic [40:0] ef [0:15];
	logic [40:0] ef_q;
	logic [3:0]  ef_wp, ef_rp;
	logic [4:0]  ef_cnt;
	logic        ef_ok;                 // ef_q is the first entry
	logic [12:0] en;                    // the next entry's number (and the reset clear's count before the first)
	logic        pe_pend;               // a picture's ended: its entry's to be queued
	logic        k1_out;                // ... and isn't written yet (no bitstream is taken meanwhile)
	logic        rel_pend;              // its interrupts are still to come
	// the reset's clear, the count
	logic        c_run;
	logic [BEAT_LOG2-1:0] bt;
	logic [31:0] beat_n;                // (32 bits: the program takes a count that goes down for a reset)
	logic        beat_pend;
	typedef enum logic [2:0] { X_IDLE, X_CLR, X_RING, X_ENT, X_BEAT } xst_t;
	xst_t        xs;
	// the wait for the program
	typedef enum logic [1:0] { H_IDLE, H_RD, H_GET, H_EVAL } hst_t;
	hst_t        h_st;
	logic        holding, h_first, h_due, mg_ok, dn_ok, dead_v;
	logic [12:0] h_seq;
	logic [1:0]  h_n;
	logic [15:0] hb, hb_last;           // (the low half of its count: it moves by one every 5 ms)
	logic [8:0]  to_n;
	logic [7:0]  hb_n;
	wire         hb_dead = hb == hb_last && hb_n == POLLS_DEAD;
	// (a program that stopped moving is known by the count it stopped at, the last one seen)
	wire         h_rel = h_st == H_EVAL && holding &&
		(!mg_ok || dn_ok || (h_first ? dead_v && hb == hb_last : hb_dead || to_n == POLLS_TIMEOUT));

	// the port: the bitstream's read first, then the line's, then a write
	wire         blk_rd = h_st == H_RD && ps != P_FETCH && ps != P_FILL;
	wire         p_rd = ps == P_FETCH && h_st != H_GET;
	wire         ring_req = ps == P_RUN && cur_n != 32'h0 && ms == M_SLICES && lb_hit && w_hit;    // a picture's byte, ready
	logic [15:0] x_a;
	logic [63:0] x_d;
	logic [7:0]  x_be;
	always_comb
	begin
		x_a = 16'h0200 + 16'(en[11:0]); x_be = 8'hff;
		x_d = {1'b1, 1'b0, ef_q[40], en, ef_q[40] ? {6'h00, pl, sp} : {8'h00, ef_q[39:0]}};
		case (xs)
			X_CLR:
			begin
				x_d = en == 13'h1005 ? HEADER : 64'h0;
				x_a = !en[12] ? 16'h0200 + 16'(en[11:0]) : !en[2] ? 16'd8 + 16'(en[1:0]) : en[0] ? 16'd0 : 16'd1;
			end
			X_RING: begin x_a = 16'h2000 + 16'(sp[17:3]); x_d = {8{byte_in}}; x_be = 8'h01 << sp[2:0]; end
			X_BEAT: begin x_a = 16'd1; x_d = {32'h0, beat_n}; end
			default: ;
		endcase
	end
	assign m_rd = p_rd || blk_rd;
	assign m_we = !m_rd && (xs == X_RING ? ring_req : xs != X_IDLE);
	assign m_a = p_rd ? {cur_a[31:5], 2'b00} : {5'b01011, 8'h00, blk_rd ? 16'd8 : x_a};
	assign m_wd = x_d;
	assign m_be = x_be;
	assign hold = ef_cnt >= 5'd11;
	wire         x_tk = m_we && !m_busy;
	assign ring_stall = ring_req && !(xs == X_RING && x_tk);
	wire         ef_push = we || pe_pend;
	wire         ef_pop = xs == X_ENT && x_tk;
	always_ff @(posedge clk)
	begin
		if (ef_push) ef[ef_wp] <= we ? {1'b0, a, wd} : {1'b1, 40'h0};
		ef_q <= ef[ef_rp];
	end
	always_ff @(posedge clk)
		if (rst)
		begin
			sp <= 24'h0; pl <= 18'h0; pl_clr <= 1'b0;
			ef_wp <= 4'd0; ef_rp <= 4'd0; ef_cnt <= 5'd0; ef_ok <= 1'b0; en <= 13'd0; pe_pend <= 1'b0; k1_out <= 1'b0; rel_pend <= 1'b0;
			c_run <= 1'b1; bt <= '0; beat_n <= 32'd0; beat_pend <= 1'b0; xs <= X_IDLE;
			h_st <= H_IDLE; holding <= 1'b0; h_first <= 1'b0; h_due <= 1'b0; dead_v <= 1'b0;
		end
		else
		begin
			bt <= bt + 1'b1;
			if (&bt) begin beat_n <= beat_n + 32'd1; beat_pend <= 1'b1; end

			if (ring_byte) begin sp <= sp + 24'd1; pl <= pl + 18'd1; end
			if (cfg_start) begin if (k1_out) pl_clr <= 1'b1; else pl <= 18'h0; end

			// a picture's end: its entry queued the clock after (a register write goes first)
			if (pic_end) begin pe_pend <= 1'b1; k1_out <= 1'b1; rel_pend <= 1'b1; end
			if (pe_pend && !we) pe_pend <= 1'b0;
			if (ef_push) ef_wp <= ef_wp + 4'd1;
			if (ef_pop) ef_rp <= ef_rp + 4'd1;
			ef_cnt <= ef_cnt + 5'(ef_push) - 5'(ef_pop);
			ef_ok <= ef_cnt != 5'd0 && !ef_pop;

			// the writes, one at a time: the clear, an entry, a picture's byte, the count (a picture's bytes are all written when
			// its end is queued, so its entry comes after them)
			case (xs)
				X_IDLE:
					if (c_run) xs <= X_CLR;
					else if (ef_ok) xs <= X_ENT;
					else if (ring_req) xs <= X_RING;
					else if (beat_pend) xs <= X_BEAT;
				X_CLR:
					if (x_tk)
					begin
						en <= en + 13'd1;
						if (en == 13'h1005) begin c_run <= 1'b0; en <= 13'd0; xs <= X_IDLE; end
					end
				X_RING: if (!ring_req || ef_ok || beat_pend) xs <= X_IDLE;       // (byte after byte while nothing else waits)
				X_ENT:
					if (x_tk)
					begin
						en <= en + 13'd1;
						if (ef_q[40])
						begin
							k1_out <= 1'b0;
							if (pl_clr) begin pl <= 18'h0; pl_clr <= 1'b0; end
							if (rel_pend) begin holding <= 1'b1; h_first <= 1'b1; h_seq <= en; end
						end
						xs <= X_IDLE;
					end
				X_BEAT: if (x_tk) begin beat_pend <= 1'b0; xs <= X_IDLE; end
				default: xs <= X_IDLE;
			endcase

			// the program's line: read at once, then every 2^14 clocks while the picture waits
			if (holding && bt[13:0] == 14'h3fff) h_due <= 1'b1;
			case (h_st)
				H_IDLE: if (holding && (h_first || h_due)) begin h_due <= 1'b0; h_st <= H_RD; end
				H_RD: if (blk_rd && !m_busy) begin h_n <= 2'd0; h_st <= H_GET; end
				H_GET:
					if (m_ready)
					begin
						h_n <= h_n + 2'd1;
						if (h_n == 2'd0) begin mg_ok <= m_dout[63:32] == MAGIC_PRESENT; hb <= m_dout[15:0]; end
						if (h_n == 2'd1) dn_ok <= m_dout[31] && m_dout[30:13] == 18'h0 && m_dout[12:0] == h_seq;
						if (h_n == 2'd3) h_st <= H_EVAL;
					end
				default:
				begin
					h_st <= H_IDLE;
					if (holding && !h_rel)
					begin
						h_first <= 1'b0;
						if (h_first) begin hb_last <= hb; hb_n <= 8'd0; to_n <= 9'd0; dead_v <= 1'b0; end
						else
						begin
							to_n <= to_n + 9'd1;
							if (hb != hb_last) begin hb_last <= hb; hb_n <= 8'd0; end
							else hb_n <= hb_n + 8'd1;
						end
					end
					// (a program that's stopped moving: pictures don't wait for it again until it moves)
					if (holding && !h_first && mg_ok && !dn_ok && hb_dead) dead_v <= 1'b1;
				end
			endcase
			if (h_rel || cfg_off || cfg_start) begin holding <= 1'b0; rel_pend <= 1'b0; end
		end
`else
	localparam bit HPS = 1'b0;
	assign ring_stall = 1'b0;
	wire         k1_out = 1'b0, h_rel = 1'b0;
	wire         p_rd = ps == P_FETCH;
	// verilator lint_off UNUSEDSIGNAL
	wire         unused_hps = &{1'b0, ring_byte, pic_end, cfg_off, cfg_start};
	// verilator lint_on UNUSEDSIGNAL
	assign m_rd = p_rd;
	assign m_a = {cur_a[31:5], 2'b00};
`endif

	always_ff @(posedge clk)
		if (rst)
		begin
			ms <= M_IDLE; ps <= P_IDLE; kick <= 1'b0; lb_v <= 1'b0; w_v <= 1'b0;
			cfg <= 32'h0; int_en <= 32'h0; int_st <= 32'h0; cur_a <= 32'h0; cur_n <= 32'h0; nxt_a <= 32'h0; nxt_n <= 32'h0;
			parser <= 32'h0; isize <= 32'h0; crop <= 32'h0;
			shift <= 32'hffffffff; last_sc <= 8'h00; ra_n <= 2'd0; ev <= 3'd0; used <= 32'h0;
		end
		else
		begin
			case (ps)
				P_IDLE: if (kick && !k1_out) begin kick <= 1'b0; wait_n <= 10'd666; ps <= P_WAIT; end
				P_WAIT: if (wait_n == 10'd0) ps <= P_TAKE; else wait_n <= wait_n - 10'd1;
				P_TAKE:
				begin
					if (cur_n == 32'h0 && nxt_n != 32'h0) begin cur_a <= nxt_a; cur_n <= nxt_n; nxt_n <= 32'h0; used <= 32'h0; end
					// (what's been given now is read from memory: the line read before may be of an address whose bytes have changed
					// since, a buffer used again or one that was still being filled)
					lb_v <= 1'b0; w_v <= 1'b0;
					ps <= P_RUN;
				end
				P_RUN:
					if (ring_stall) ;       // (the ring's word waits to be written)
					else if (cur_n != 32'h0 && taking)
					begin
						if (!lb_hit) ps <= P_FETCH;
						else if (!w_hit) ps <= P_WORD;
						else
						begin
							cur_a <= cur_a + 32'd1; cur_n <= cur_n - 32'd1; used <= used + 32'd1;
							if (ms == M_SLICES)
							begin
								shift <= sc;
								if (ends)
								begin
									last_sc <= byte_in;
									if (cropped_b)
									begin
										if (used + 32'd1 >= 32'd4) begin cur_a <= cur_a - 32'd3; cur_n <= cur_n + 32'd3; used <= used - 32'd3; end
										ms <= M_DONE; ev <= 3'd0; ra_n <= 2'd0;
										if (!HPS) int_st <= int_st | I_DONE;
										ps <= P_IDLE;
									end
									else begin ms <= M_READAHEAD; ra_n <= 2'd0; end
								end
							end
							else
							begin
								ra[ra_n[0]] <= byte_in;
								ra_n <= ra_n + 2'd1;
								if (ra_n == 2'd1)
								begin
									ms <= M_DONE; ev <= 3'd0;
									if (!HPS) int_st <= int_st | I_DONE;
									ps <= P_IDLE;
								end
							end
						end
					end
					else
					begin
						// (out of data: ask for more)
						if (cur_n == 32'h0) int_st <= int_st | I_VBS_DMA;
						ps <= P_IDLE;
					end
				P_FETCH: if (p_rd && !m_busy) begin lb_v <= 1'b0; w_v <= 1'b0; lb_a <= cur_a[31:5]; lb_n <= 2'd0; ps <= P_FILL; end
				P_FILL:
					if (m_ready)
					begin
						lb_n <= lb_n + 2'd1;
						if (lb_n == 2'd3) begin lb_v <= 1'b1; ps <= P_RUN; end
					end
				P_WORD: begin w <= lb_q; w_a <= cur_a[31:3]; w_v <= 1'b1; ps <= P_RUN; end   // (lb_q: the word at cur_a, read last clock)
				default: ps <= P_IDLE;
			endcase

			if (h_rel) int_st <= int_st | I_DONE;     // (MPEG_HPS: the picture's pixels are in memory, or nothing will put them there)

			// the registers
			if (we)
				case (a)
					R_CONFIG:
					begin
						cfg <= wd;
						if (!wd[1]) begin ms <= M_IDLE; kick <= 1'b0; if (ps != P_FETCH && ps != P_FILL) ps <= P_IDLE; end
						else if (!cfg[1])
						begin
							// the bitstream starts
							ms <= M_SLICES; shift <= 32'hffffffff; ra_n <= 2'd0; ev <= 3'd0; used <= 32'h0;
							if (nxt_n != 32'h0) kick <= 1'b1;
						end
						else if (wd[4] && ms == M_DONE && ev != 3'd7) ev <= ev + 3'd1;
					end
					R_INTENABLE:    int_en <= wd;
					R_INTSTATUS:    int_st <= (int_st & ~wd) | (h_rel ? I_DONE : 32'h0);    // (MPEG_HPS: a picture let go in this clock isn't lost)
					R_VBSCURADDR:   cur_a <= wd;
					R_VBSCURLEN:    cur_n <= wd;
					R_VBSNEXTADDR:  nxt_a <= wd;
					R_VBSNEXTLEN:
					begin
						nxt_n <= wd;
						if (wd != 32'h0 && cur_n == 32'h0 && taking) kick <= 1'b1;
					end
					R_PARSERCONFIG: parser <= wd;
					R_IMAGESIZE:    isize <= wd;
					R_FORMATCROP:   crop <= wd;
					default: ;
				endcase
		end
endmodule
