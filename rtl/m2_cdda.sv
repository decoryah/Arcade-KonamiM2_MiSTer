// m2_cdda: the drive's audio: PLAY AUDIO's sectors, read from a raw image of the whole disc (2352 bytes a sector) that MiSTer has mounted, and
// played at 44.1 kHz. The image is too big for memory, so it streams through a FIFO that holds about 0.18 s. The position goes by the clock
// whether there's an image or not, so a game that polls it carries on without one, and without sound from it.
`default_nettype none
module m2_cdda #(
	parameter logic [23:0] LBA0 = 24'd0     // the disc's sector at the image's start
) (
	input  logic        clk,
	input  logic        rst,
	input  logic        tick,               // 44.1 kHz

	input  logic        play,               // a clock: start at lba, for len sectors
	input  logic [23:0] lba,
	input  logic [23:0] len,
	input  logic        stop,
	input  logic        paused,
	output logic [23:0] pos,
	output logic        playing,
	output logic        finished,           // played to its end

	input  logic        mounted,            // an image is there
	output logic [31:0] sd_lba,
	output logic        sd_rd,
	input  logic        sd_ack,
	input  logic        sd_wr,
	input  logic [7:0]  sd_d,

	output logic [15:0] l,
	output logic [15:0] r
);
	localparam int AW = 15;
	localparam logic [8:0] BLOCKS = 9'd8;       // a request's: 4 KB

	logic [AW-1:0] wp, rp;
	wire  [AW-1:0] used = wp - rp;
	wire           room = used < AW'(2 ** AW - 4096 - 16);
	logic [7:0]    q;
	logic          f_we;
	logic [AW-1:0] rp_n;
	ppc_ram #(.W(8), .AW(AW)) fifo (.clk, .we(f_we), .wa(wp), .wd(sd_d), .ra(rp_n), .rd(q));

	// ---- what's fetched -------------------------------------------------------------------------------------------------
	typedef enum logic [2:0] { G_IDLE, G_REQ, G_ACK, G_END } gst_t;
	gst_t        g;
	logic [8:0]  skip;
	logic        drop;                          // what's on its way is of a play that's over
	logic [31:0] offs;
	logic [22:0] blk;
	logic        start;
	// (a sector's bytes: 2048 + 256 + 32 + 16)
	wire [23:0]  x = lba - LBA0;
	assign offs = {x[20:0], 11'h0} + {3'h0, x, 5'h0} * 32'd9 + {4'h0, x, 4'h0};
	assign f_we = sd_wr && g == G_ACK && !drop && skip == 9'd0;
	assign sd_lba = {9'h0, blk};

	logic [11:0] sect_n;                        // the ticks of this sector
	logic [23:0] left;
	logic [2:0]  rs;
	logic [7:0]  b0, b1, b2;
	logic        was_ack;

	always_comb
	begin
		rp_n = rp;
		if (rs != 3'd0) rp_n = rp + AW'(1);
	end

	always_ff @(posedge clk)
	begin
		was_ack <= sd_ack;
		if (rst)
		begin
			g <= G_IDLE; sd_rd <= 1'b0; playing <= 1'b0; finished <= 1'b0; wp <= '0; rp <= '0; start <= 1'b0; drop <= 1'b0; rs <= 3'd0;
			l <= 16'h0; r <= 16'h0; pos <= 24'h0;
		end
		else
		begin
			if (play || stop)
			begin
				playing <= play;
				finished <= 1'b0;
				start <= play;
				drop <= 1'b1;
				left <= len;
				pos <= lba;
				sect_n <= 12'd0;
				if (stop) begin l <= 16'h0; r <= 16'h0; end
			end
			else if (tick && playing && !paused)
			begin
				sect_n <= sect_n == 12'd587 ? 12'd0 : sect_n + 12'd1;
				if (sect_n == 12'd587)
				begin
					pos <= pos + 24'd1;
					left <= left - 24'd1;
					if (left <= 24'd1)
					begin
						playing <= 1'b0; finished <= 1'b1;
						l <= 16'h0; r <= 16'h0;
					end
				end
			end

			// ---- the fetching
			case (g)
				G_IDLE:
					if (start)
					begin
						start <= play;
						drop <= 1'b0;
						wp <= '0; rp <= '0; rs <= 3'd0;
						blk <= offs[31:9];
						skip <= offs[8:0];
					end
					else if (mounted && playing && !drop && room && !play) begin sd_rd <= 1'b1; g <= G_REQ; end
				G_REQ: if (sd_ack) begin sd_rd <= 1'b0; g <= G_ACK; end
				G_ACK:
				begin
					if (sd_wr)
					begin
						if (skip != 9'd0) skip <= skip - 9'd1;
						else if (!drop) wp <= wp + AW'(1);
					end
					if (was_ack && !sd_ack)
					begin
						blk <= blk + 23'(BLOCKS);
						g <= G_IDLE;
					end
				end
				default: g <= G_IDLE;
			endcase

			// ---- the playing: four bytes, little-endian, left first
			case (rs)
				3'd0: if (tick && playing && !paused && !start && !drop && used >= AW'(4)) rs <= 3'd1;
				3'd1: begin b0 <= q; rs <= 3'd2; rp <= rp_n; end
				3'd2: begin b1 <= q; rs <= 3'd3; rp <= rp_n; end
				3'd3: begin b2 <= q; rs <= 3'd4; rp <= rp_n; end
				default:
				begin
					rs <= 3'd0; rp <= rp_n;
					l <= {b1, b0}; r <= {q, b2};
				end
			endcase
			if (paused) begin l <= 16'h0; r <= 16'h0; end
		end
	end
endmodule
