// m2_mpeg: the BDA's MPEG unit, its control only, as the M2 emulator's (3dom2.cpp m2_mpeg_device) without the pictures: the registers, the
// video bitstream's DMA (the current and next buffers), the start codes, and the interrupts. The driver (M2 SDK devices/mpegvideo/M2MPEGUnit.c)
// parses the sequence and picture headers itself and gives the unit a picture's slice data; at the first start code that isn't a slice's the
// unit takes two more bytes (its read-ahead), says the picture's done, and the driver gets the start code and those bytes back through the
// parser status registers, stepping the parser a byte at a time. Nothing's decoded: a game's videos are black, the rest of it runs on time.
//
// The bitstream's read from memory a 32-byte line at a time into block RAM, then a word of it into registers (a clock), and a byte a clock
// from that. The emulator takes a buffer 10 us after it's given one.
`default_nettype none

module m2_mpeg (
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
	assign m_rd = ps == P_FETCH;
	assign m_a = {cur_a[31:5], 2'b00};

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
				P_IDLE: if (kick) begin kick <= 1'b0; wait_n <= 10'd666; ps <= P_WAIT; end
				P_WAIT: if (wait_n == 10'd0) ps <= P_TAKE; else wait_n <= wait_n - 10'd1;
				P_TAKE:
				begin
					if (cur_n == 32'h0 && nxt_n != 32'h0) begin cur_a <= nxt_a; cur_n <= nxt_n; nxt_n <= 32'h0; used <= 32'h0; end
					ps <= P_RUN;
				end
				P_RUN:
					if (cur_n != 32'h0 && taking)
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
										int_st <= int_st | I_DONE;
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
									int_st <= int_st | I_DONE;
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
				P_FETCH: if (!m_busy) begin lb_v <= 1'b0; w_v <= 1'b0; lb_a <= cur_a[31:5]; lb_n <= 2'd0; ps <= P_FILL; end
				P_FILL:
					if (m_ready)
					begin
						lb_n <= lb_n + 2'd1;
						if (lb_n == 2'd3) begin lb_v <= 1'b1; ps <= P_RUN; end
					end
				P_WORD: begin w <= lb_q; w_a <= cur_a[31:3]; w_v <= 1'b1; ps <= P_RUN; end   // (lb_q: the word at cur_a, read last clock)
				default: ps <= P_IDLE;
			endcase

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
					R_INTSTATUS:    int_st <= int_st & ~wd;
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
