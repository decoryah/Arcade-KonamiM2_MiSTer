// m2_atapi: the CD drive: enough of an ATAPI drive for what MAME's boot asks of its CR-589 (work/atad2.py decodes a capture). The
// disc is an image in memory (tools/cdimage.py): its first 2048 bytes hold the answers that aren't sectors, then the sectors of
// the data track, 2048 bytes each.
//
//   0x000 IDENTIFY PACKET's 512 bytes; 0x200 REQUEST SENSE's 14; 0x220 MODE SENSE's 24; 0x240 READ CAPACITY's 8;
//   0x400 + 16 * n: READ TOC's 12 for track n (0: the first track, 0xaa's slot is 0x3f)
//
// Whatever a command answers (a sector, or a piece of the first) is read into the buffer, then the host reads it from the data
// port, a word at a time, the first byte in bits 15:8, by the CDE's DMA or itself. Registers are in bits 15:8 too.
// Status: BSY while reading, DRQ for a packet or data; the interrupt (intrq, polled) comes with data and at the end, and goes when
// status is read.
//
// With stream (the board's byte from the MRA asks for it: Battle Tryst's data track is 367 MB) and an image mounted, a data sector comes from the
// image MiSTer has mounted instead (the whole disc raw, 2352 bytes a sector, the data track first: its 2048 bytes at 16 in), through the SD
// port it shares with the audio; the answers that aren't sectors stay in memory (the image's first 2048 bytes). As a real drive's buffer
// does, it reads ahead: a 32 KB ring holds the image from the last sector read on, fetched 4 KB at a time while there's room, so a game that
// reads a sector a command (Battle Tryst streams that way, 30 to 1,300 a second) isn't waiting on a round trip to MiSTer for each.
// A data READ stops the audio, as MAME's drive (t10mmc abort_audio).
//
// PLAY AUDIO (rtl/m2_cdda.sv plays it) looks for its track in that table, for READ SUB-CHANNEL's answers; those are made up in the
// buffer's end, and as MAME's drive gives them. MODE SELECT's volumes fade the music; PAUSE stops it where it is; REQUEST SENSE says how the
// play goes, as MAME's.
`default_nettype none
module m2_atapi #(
	parameter logic [31:0] IMAGE = 32'h50000000
) (
	input  logic        clk,
	input  logic        rst,

	// the registers, 16-bit: a read's value in the clock of its address, a write in that clock
	input  logic [4:1]  a,
	input  logic        re,
	input  logic        we,
	input  logic [15:0] wd,
	output logic [15:0] rd,
	output logic        intrq,

	// the CDE's DMA: the data port
	input  logic        ata_rd,
	output logic        ata_valid,
	output logic [15:0] ata_d,

	// memory: lines
	output logic        m_rd,
	output logic [31:3] m_a,
	input  logic        m_busy,
	input  logic        m_ready,
	input  logic [63:0] m_dout,

	// the mounted image (MiSTer's SD port): 4 KB from a 512-byte block, its bytes in order while ack
	input  logic        stream,
	output logic [31:0] sd_lba,
	output logic        sd_rd,
	input  logic        sd_ack,
	input  logic        sd_wr,
	// verilator lint_off UNUSEDSIGNAL
	input  logic [7:0]  sd_d,           // (not used in a build without CD_STREAM)
	// verilator lint_on UNUSEDSIGNAL

	// the audio
	output logic        play,
	output logic        play_stop,
	output logic [23:0] play_lba,
	output logic [23:0] play_len,
	input  logic [23:0] pos,
	input  logic        playing,
	output logic        paused,
	output logic [7:0]  vol_l,          // MODE SELECT's audio page: the game fades the music with it
	output logic [7:0]  vol_r,
	input  logic        finished
);
	localparam logic [7:0] ST_BSY = 8'h80, ST_DRQ = 8'h08;
	localparam logic [10:0] O_SENSE = 11'h200, O_MODE = 11'h220, O_CAP = 11'h240, O_TOC = 11'h400;

	logic [7:0]  err, cnt, sec, bcl, bch, drv, st;
	logic [7:0]  pk [0:11];
	logic [3:0]  pk_n;
	logic        in_pk;
	logic [10:0] ptr;                   // the next byte of the buffer
	logic [11:0] left;                  // bytes left of this phase
	logic [31:0] lba, more;             // the next sector, and how many after this
	logic [9:0]  out_n;                 // bytes of data still to come from the host
	logic [5:0]  t_n;                   // the track that's playing, and where it starts
	logic [5:0]  trk;
	logic [23:0] t_start;

	// ---- the buffer -----------------------------------------------------------------------------------------------------
	logic [63:0] bq;
	logic        bw;
	logic [7:0]  bwa;
	logic [63:0] bd;
	ppc_ram #(.W(64), .AW(8)) buffer (.clk, .we(bw), .wa(bwa), .wd(bd), .ra(ptr[10:3]), .rd(bq));
	logic       sn;                     // the answer's REQUEST SENSE's
	logic [7:0] a_sense, a_sense_q;     // its ASCQ: the audio's state
	wire [15:0] cur = sn && ptr == O_SENSE + 11'd12 ? {8'h00, a_sense_q} : {bq[8 * ptr[2:0] +: 8], bq[8 * (ptr[2:0] + 3'd1) +: 8]};
	wire [15:0] dcur = left != 12'd0 ? cur : 16'h0;

	// ---- reading a sector ------------------------------------------------------------------------------------------------
	typedef enum logic [3:0] { F_IDLE, F_REQ, F_WAIT, F_DONE, F_Q0, F_Q1, F_W0, F_W1, F_CHK, F_COPY } fst_t;
	fst_t       f_st;
	// verilator lint_off UNUSEDSIGNAL
	logic [31:0] f_sec;                 // the image's sector
	// verilator lint_on UNUSEDSIGNAL
	logic [5:0]  f_line;
	logic [1:0]  f_beat;
	logic [10:0] f_ptr;
	logic [11:0] f_len;
	assign m_rd = f_st == F_REQ;
	assign m_a = IMAGE[31:3] + 29'({f_sec[17:0], f_line, 2'b00});
	// from the image: the read-ahead ring (c_*), filled by the fetcher (g_*) from the image's block c_base on, c_fill bytes of it from c_head;
	// a sector's 2048 bytes are copied from there to the buffer, eight at a time
	localparam int CW = 15;                 // the ring: 2^CW bytes
	logic          c_v;
	logic [22:0]   c_base;
	logic [CW-1:0] c_head;
	logic [CW:0]   c_fill;
	typedef enum logic [1:0] { G_IDLE, G_REQ, G_DATA } gst_t;
	gst_t          g_st;
	logic [22:0]   g_lba;
	logic [CW-1:0] g_wa, g_end;             // where the fetch's next byte goes; where its 4 KB end
	logic [12:0]   g_n;
	logic          g_drop, g_ack;           // (a fetch for a place that's been let go: its bytes land outside the ring's new place)
	logic [31:0]   s_o;                     // the sector's data's place in the image (bytes)
	logic [CW-1:0] s_r;                     // the ring's next byte to read
	logic [11:0]   s_q, s_n;                // bytes asked of the ring, and come
	logic          s_rv;
	logic [55:0]   s_w;
	logic [7:0]    cq;
	// verilator lint_off UNUSEDSIGNAL
	wire           c_we = g_st == G_DATA && sd_wr && !g_n[12] && !g_drop;   // (the ring's: CD_STREAM)
	// verilator lint_on UNUSEDSIGNAL
`ifdef CD_STREAM
	ppc_ram #(.W(8), .AW(CW)) cache (.clk, .we(c_we), .wa(g_wa), .wd(sd_d), .ra(s_r), .rd(cq));
`else
	assign cq = 8'h00;              // (no ring: stream is 0 in such a build, rtl/m2_boot.sv)
`endif
	wire           s_take = f_st == F_COPY && s_rv;
	// a fetch starts this clock (F_CHK's restart must count it as on its way: it's for the ring's old place)
	wire           g_go = g_st == G_IDLE && stream && c_v && !playing && c_fill <= (CW + 1)'(2 ** CW - 4096);
	wire [CW-1:0]  g_go_end = c_head + CW'(c_fill) + CW'(4096);
	assign sd_rd = g_st == G_REQ;
	assign sd_lba = {9'h0, g_lba};
	assign bw = (f_st == F_WAIT && m_ready) || f_st == F_Q0 || f_st == F_Q1 || (s_take && s_n[2:0] == 3'd7);
	assign bwa = f_st == F_Q0 ? 8'hfe : f_st == F_Q1 ? 8'hff : f_st == F_COPY ? s_n[10:3] : {f_line, f_beat};
	// READ SUB-CHANNEL's 16 bytes, the first in bits 7:0
	wire        q_on = playing;         // (past the end, position 0 and the first track, as MAME's)
	wire [23:0] q_abs = q_on ? pos : 24'h0;
	wire [23:0] q_rel = q_on ? pos - t_start : 24'h0;
	always_comb
		case (f_st)
			F_Q0: bd = {8'h01, 2'b00, q_on ? trk : 6'd1, q_on ? 8'h10 : 8'h14, 8'h01, 8'h0c, 8'h00, playing ? (paused ? 8'h12 : 8'h11) : finished ? 8'h13 : 8'h15, 8'h00};
			F_Q1: bd = {q_rel[7:0], q_rel[15:8], q_rel[23:16], 8'h00, q_abs[7:0], q_abs[15:8], q_abs[23:16], 8'h00};
			F_COPY: bd = {cq, s_w};
			default: bd = m_dout;
		endcase
	wire [23:0] t_e = {bq[15:8], bq[23:16], bq[31:24]};   // (a track's start, in the buffer's word)
	logic       f_walk;

	always_comb
		case ({a, 1'b0})
			5'h00: rd = dcur;
			5'h02: rd = {err, 8'h0};
			5'h04: rd = {cnt, 8'h0};
			5'h06: rd = {sec, 8'h0};
			5'h08: rd = {bcl, 8'h0};
			5'h0a: rd = {bch, 8'h0};
			5'h0c: rd = {drv, 8'h0};
			5'h0e: rd = {st, 8'h0};
			5'h1c: rd = {st, 8'h0};
			default: rd = 16'h0;
		endcase

	// the DMA's read waits for data (it doesn't look at DRQ), and for the buffer to read the place: a clock after left is set
	logic [1:0] a_s;
	wire ata_take = a_s == 2'd2;
	wire data_rd = (re && a == 4'd0) || ata_take;

	always_ff @(posedge clk)
	begin
		// what the clock's events ask for, done at the end
		logic        do_end, do_fetch;
		logic [CW:0] nf;
		logic [31:0] fs;
		logic [10:0] fo;
		logic [11:0] fn;
		do_end = 1'b0; do_fetch = 1'b0; fs = 32'd0; fo = 11'd0; fn = 12'd2048;
		ata_valid <= 1'b0;
		play <= 1'b0; play_stop <= 1'b0;
		if (rst || play || play_stop) paused <= 1'b0;
		if (rst) begin sn <= 1'b0; a_sense <= 8'h00; end
		else if (play) a_sense <= 8'h11;
		else if (play_stop && playing) a_sense <= 8'h14;
		if (rst) begin vol_l <= 8'hff; vol_r <= 8'hff; end
		if (rst)
		begin
			err <= 8'h01; cnt <= 8'h01; sec <= 8'h01; bcl <= 8'h14; bch <= 8'heb; drv <= 8'h00; st <= 8'h00;
			intrq <= 1'b0; in_pk <= 1'b0; left <= 12'd0; more <= 32'd0; f_st <= F_IDLE; ptr <= 11'd0; pk_n <= 4'd0; a_s <= 2'd0;
			out_n <= 10'd0; f_walk <= 1'b0;
			c_v <= 1'b0; c_fill <= '0; g_st <= G_IDLE; g_drop <= 1'b0;
		end
		else
		begin
			case (a_s)
				2'd0: if (ata_rd) a_s <= 2'd1;
				2'd1:
					if (left != 12'd0) a_s <= 2'd2;
					else if (f_st == F_IDLE && !ata_rd) begin ata_valid <= 1'b1; ata_d <= 16'h0; a_s <= 2'd0; end  // nothing to come
				default: begin ata_valid <= 1'b1; ata_d <= dcur; a_s <= 2'd0; end
			endcase
			if (re && a == 4'd7) intrq <= 1'b0;

			// the data port
			if (data_rd && left != 12'd0)
			begin
				ptr <= ptr + 11'd2;
				left <= left - 12'd2;
				if (left <= 12'd2)
				begin
					if (more != 32'd0)
					begin
						more <= more - 32'd1;
						lba <= lba + 32'd1;
						do_fetch = 1'b1; fs = lba + 32'd2;
					end
					else do_end = 1'b1;
				end
			end

			// the fetcher: 4 KB at a time from the ring's end while there's room (not while the audio plays: it has the SD port then; a READ
			// stops the audio, as MAME's drive)
			nf = c_fill;
			if (!stream) c_v <= 1'b0;
			case (g_st)
				G_IDLE:
					if (g_go)
					begin
						g_lba <= c_base + 23'(c_fill[CW:9]);
						g_wa <= c_head + CW'(c_fill);
						g_end <= g_go_end;
						g_n <= 13'd0; g_drop <= 1'b0;
						g_st <= G_REQ;
					end
				G_REQ: if (sd_ack) begin g_ack <= 1'b1; g_st <= G_DATA; end
				G_DATA:
				begin
					if (sd_wr && !g_n[12]) begin g_wa <= g_wa + CW'(1); g_n <= g_n + 13'd1; end
					g_ack <= sd_ack;
					if (g_ack && !sd_ack)
					begin
						if (!g_drop) nf = nf + (CW + 1)'(4096);
						g_st <= G_IDLE;
					end
				end
				default: g_st <= G_IDLE;
			endcase

			// the sector's read
			case (f_st)
				F_REQ: if (!m_busy) f_st <= F_WAIT;
				F_WAIT:
					if (m_ready)
					begin
						f_beat <= f_beat + 2'd1;
						if (f_beat == 2'd3)
						begin
							f_line <= f_line + 6'd1;
							f_st <= f_line == 6'd63 ? F_DONE : F_REQ;
						end
					end
				F_CHK:  // (the ring as the fetcher leaves it this clock is nf)
				begin
					logic [31:0] bb, rel;
					bb = {c_base, 9'h0};
					rel = s_o - bb;
					if (!c_v || s_o < bb || rel > 32'(nf) + 32'd4096)
					begin
						// not in it nor on its way: the ring starts again at the sector (past where a fetch on its way writes)
						// (a fetch on its way, or starting this clock, is for the old place: dropped, and the ring starts past
						// where it writes)
						c_v <= 1'b1;
						c_base <= s_o[31:9];
						c_head <= g_go ? g_go_end : g_st != G_IDLE ? g_end : c_head;
						nf = '0;
						if (g_go || g_st != G_IDLE) g_drop <= 1'b1;
					end
					else if (rel[31:9] != 23'd0 && nf[CW:9] != '0)
					begin
						// what's before the sector's block is let go (as much as is fetched), for room ahead
						logic [CW:9] k;
						k = rel[31:9] > 23'(nf[CW:9]) ? nf[CW:9] : rel[CW:9];
						c_base <= c_base + 23'(k);
						c_head <= c_head + CW'({k, 9'h0});
						nf = nf - {k, 9'h0};
					end
					else if (32'(rel[8:0]) + 32'd2048 <= 32'(nf))
					begin
						s_r <= c_head + CW'(rel[8:0]);
						s_q <= 12'd0; s_n <= 12'd0; s_rv <= 1'b0;
						f_st <= F_COPY;
					end
				end
				F_COPY:
				begin
					s_rv <= !s_q[11];
					if (!s_q[11]) begin s_r <= s_r + CW'(1); s_q <= s_q + 12'd1; end
					if (s_take)
					begin
						s_w[8 * s_n[2:0] +: 8] <= cq;
						s_n <= s_n + 12'd1;
						if (s_n == 12'd2047) f_st <= F_DONE;
					end
				end
				F_Q0: f_st <= F_Q1;
				F_Q1: f_st <= F_DONE;
				F_W0: f_st <= F_W1;
				F_W1:   // the table, in order, to the first track past this one
					if (t_n == 6'd63 || (t_n != 6'd1 && t_e == 24'h0) || t_e > play_lba)
					begin
						f_st <= F_IDLE;
						play <= 1'b1;
						do_end = 1'b1;
					end
					else
					begin
						trk <= t_n; t_start <= t_e;
						t_n <= t_n + 6'd1;
						ptr <= ptr + 11'd16;
						f_st <= F_W0;
					end
				F_DONE:
				if (f_walk)
				begin
					f_walk <= 1'b0;
					t_n <= 6'd1;
					ptr <= O_TOC + 11'd24;
					f_st <= F_W0;
				end
				else
				begin
					f_st <= F_IDLE;
					ptr <= f_ptr;
					left <= f_len;
					st <= ST_DRQ; err <= 8'h00; cnt <= 8'h02;
					bch <= {4'h0, f_len[11:8]};
					bcl <= f_len[7:0];
					intrq <= 1'b1;
				end
				default: ;
			endcase

			if (we)
				case (a)
					4'd0:
						if (out_n != 10'd0)
						begin
							out_n <= out_n <= 10'd2 ? 10'd0 : out_n - 10'd2;
							// (24 bytes: 8 of header, then the page, its volumes in the low bytes of its 5th and 6th words)
							if (out_n == 10'd8) vol_l <= wd[7:0];
							if (out_n == 10'd6) vol_r <= wd[7:0];
							if (out_n <= 10'd2) do_end = 1'b1;
						end
						else if (in_pk)
						begin
							pk[pk_n] <= wd[15:8];
							pk[pk_n + 4'd1] <= wd[7:0];
							pk_n <= pk_n + 4'd2;
							if (pk_n == 4'd10)
							begin
								in_pk <= 1'b0;
								st <= 8'h00;
								sn <= pk[0] == 8'h03;
								case (pk[0])
									8'h03:
									begin
										do_fetch = 1'b1; fo = O_SENSE; fn = pk[4] < 8'd14 ? {4'h0, pk[4]} : 12'd14;
										a_sense_q <= a_sense == 8'h11 && !playing ? 8'h13 : a_sense;
										if (a_sense != 8'h11 || !playing) a_sense <= 8'h00;
									end
									8'h25: begin do_fetch = 1'b1; fo = O_CAP; fn = 12'd8; end
									8'h42:
									begin
										f_st <= F_Q0;
										f_ptr <= 11'h7f0;
										f_len <= {pk[7], pk[8]} < 16'd16 ? 12'(pk[8]) : 12'd16;
										st <= ST_BSY; intrq <= 1'b0;
									end
									8'h45:
									begin
										play_lba <= {pk[3], pk[4], pk[5]};
										play_len <= {8'h0, pk[7], pk[8]};
										if ({pk[7], pk[8]} != 16'h0) begin do_fetch = 1'b1; fn = 12'd2048; f_walk <= 1'b1; end
										else do_end = 1'b1;
									end
									8'h4b: begin paused <= !pk[8][0]; do_end = 1'b1; end
									8'h4e: begin play_stop <= 1'b1; do_end = 1'b1; end
									8'h55:
										if ({pk[7], pk[8]} != 16'h0)
										begin
											out_n <= 10'({pk[7], pk[8]});
											st <= ST_DRQ; err <= 8'h00; cnt <= 8'h00;
											bch <= pk[7]; bcl <= pk[8];
											intrq <= 1'b1;
										end
										else do_end = 1'b1;
									8'h43:
									begin
										do_fetch = 1'b1; fn = 12'd12;
										fo = O_TOC + {1'b0, pk[6] == 8'haa ? 6'h3f : pk[6] == 8'h00 ? 6'h01 : pk[6][5:0], 4'h0};
									end
									8'h5a: begin do_fetch = 1'b1; fo = O_MODE; fn = pk[8] < 8'd24 ? {4'h0, pk[8]} : 12'd24; end
									8'h28:
									begin
										if (playing) play_stop <= 1'b1;
										lba <= {pk[2], pk[3], pk[4], pk[5]};
										more <= {16'h0, pk[7], pk[8]} - 32'd1;
										if ({pk[7], pk[8]} != 16'h0) begin do_fetch = 1'b1; fs = {pk[2], pk[3], pk[4], pk[5]} + 32'd1; end
										else do_end = 1'b1;
									end
									8'ha8:
									begin
										if (playing) play_stop <= 1'b1;
										lba <= {pk[2], pk[3], pk[4], pk[5]};
										more <= {pk[6], pk[7], pk[8], pk[9]} - 32'd1;
										if ({pk[6], pk[7], pk[8], pk[9]} != 32'h0) begin do_fetch = 1'b1; fs = {pk[2], pk[3], pk[4], pk[5]} + 32'd1; end
										else do_end = 1'b1;
									end
									default: do_end = 1'b1;
								endcase
							end
						end
					4'd1: err <= wd[15:8];
					4'd2: cnt <= wd[15:8];
					4'd3: sec <= wd[15:8];
					4'd4: bcl <= wd[15:8];
					4'd5: bch <= wd[15:8];
					4'd6: drv <= wd[15:8];
					4'd7:
						case (wd[15:8])
							8'ha0:
							begin
								in_pk <= 1'b1; pk_n <= 4'd0; left <= 12'd0;
								st <= ST_DRQ; cnt <= 8'h01; err <= 8'h00;
							end
							8'ha1: begin do_fetch = 1'b1; fn = 12'd512; end
							default: do_end = 1'b1;
						endcase
					default: ;
				endcase

			c_fill <= nf;
			if (do_end)
			begin
				st <= 8'h00; err <= 8'h00; cnt <= 8'h03; bch <= 8'h00; bcl <= 8'h00; intrq <= 1'b1;
			end
			if (do_fetch)
			begin
				f_sec <= fs; f_line <= 6'd0; f_beat <= 2'd0; f_ptr <= fo; f_len <= fn; f_st <= F_REQ;
				if (stream && fs != 32'd0)
				begin
					// (the data track's sector fs - 1, its data at 16 in: (fs - 1) * 2352 + 16)
					logic [31:0] o;
					o = {fs[20:0] - 21'd1, 11'h0} + {fs[23:0] - 24'd1, 8'h0} + {fs[26:0] - 27'd1, 5'h0} + {fs[27:0] - 28'd1, 4'h0} + 32'd16;
					s_o <= o;
					f_st <= F_CHK;
				end
				st <= ST_BSY; intrq <= 1'b0;
			end
		end
	end
endmodule
