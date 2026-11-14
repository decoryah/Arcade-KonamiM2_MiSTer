// m2_vtiming: the raster: 857 x 262 at 59.39 Hz, 640 x 240 shown from (172, 20), the pixel clock (13.333 MHz) the 66.67 MHz
// machine clock divided by 5. Near MAME's konamim2 set_ntsc() (768 x 262 at 59.36 Hz, a pixel clock of 11.944 MHz), but an even
// divide: the first build's fractional clock enable (pixels 5 or 6 clocks apart) made the letters' edges jitter on the board.
// The line's the length of a TV's, with a TV's blanking: 3.5 us of front porch, 4.7 us of sync, 8 us of back porch, in which a CRT
// finds black (dividing by 6 left 6.7 us for all three, and a picture with a bright left edge went dark on a CRT)
//
// With arc (the board byte's bit 4: Hell Night's), the arcade monitor's raster, MAME's set_arcres() (684 x 416, 512 x 384 shown from
// (104, 26), a pixel clock of 16.93 MHz, 24.8 kHz): here 684 x 416 at 58.6 Hz, 512 x 384 shown from (104, 26), the machine clock
// divided by 4 (16.67 MHz, 24.4 kHz). 3.4 us of sync from the line's start, as above.
module m2_vtiming (
	input  logic       clk,
	input  logic       rst,
	input  logic       arc,       // the arcade monitor's raster, not the TV's
	output logic       ce_pix,
	output logic [9:0] hpos,      // 0 .. 639 while shown (0 .. 511 with arc)
	output logic [8:0] vpos,      // 0 .. 239 while shown (0 .. 383 with arc)
	output logic       hblank,
	output logic       vblank,
	output logic       hsync,
	output logic       vsync
);
	localparam int HTOT = 857, HVIS0 = 172, HVIS1 = 172 + 640, HS0 = 2, HS1 = 65;
	// 240p's lines as CEA-861 has them (format 8): 4 after the picture, 3 of sync, 15 before the next. The sync used to start a line after the
	// picture, and the board's HDMI (the RetroTINK 4K's DV1 too) lost the picture's last lines
	localparam int VTOT = 262, VVIS0 = 20, VVIS1 = 20 + 240, VS0 = 2, VS1 = 5;
	// the arcade monitor's (arc)
	localparam int A_HTOT = 684, A_HVIS0 = 104, A_HVIS1 = 104 + 512, A_HS1 = 58;
	localparam int A_VTOT = 416, A_VVIS0 = 26, A_VVIS1 = 26 + 384;

	wire   [2:0] div_n  = arc ? 3'd3 : 3'd4;
	wire   [9:0] htot1  = arc ? 10'(A_HTOT - 1) : 10'(HTOT - 1);
	wire   [9:0] hvis0  = arc ? 10'(A_HVIS0) : 10'(HVIS0);
	wire   [9:0] hvis1  = arc ? 10'(A_HVIS1) : 10'(HVIS1);
	wire   [9:0] hs1    = arc ? 10'(A_HS1) : 10'(HS1);
	wire   [8:0] vtot1  = arc ? 9'(A_VTOT - 1) : 9'(VTOT - 1);
	wire   [8:0] vvis0  = arc ? 9'(A_VVIS0) : 9'(VVIS0);
	wire   [8:0] vvis1  = arc ? 9'(A_VVIS1) : 9'(VVIS1);

	logic  [2:0] div;
	logic  [9:0] h;
	logic  [8:0] v;
	logic        tick;

	always_ff @(posedge clk)
	begin
		div <= (div >= div_n) ? 3'd0 : div + 3'd1;
		tick <= (div >= div_n);
		ce_pix <= tick;
		if (rst)
		begin
			div <= 3'd0;
			h <= 10'd0;
			v <= 9'd0;
		end
		else if (tick)
		begin
			// (>=: the raster can change under the counters, when the board byte does)
			if (h >= htot1)
			begin
				h <= 10'd0;
				v <= (v >= vtot1) ? 9'd0 : v + 9'd1;
			end
			else
				h <= h + 10'd1;
			hblank <= (h < hvis0) || (h >= hvis1);
			vblank <= (v < vvis0) || (v >= vvis1);
			hsync <= (h >= 10'(HS0)) && (h < hs1);
			vsync <= (v >= 9'(VS0)) && (v < 9'(VS1));
			hpos <= h - hvis0;
			vpos <= v - vvis0;
		end
	end
endmodule
