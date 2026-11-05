// m2_vtiming: the raster: 857 x 262 at 59.39 Hz, 640 x 240 shown from (172, 20), the pixel clock (13.333 MHz) the 66.67 MHz
// machine clock divided by 5. Near MAME's konamim2 set_ntsc() (768 x 262 at 59.36 Hz, a pixel clock of 11.944 MHz), but an even
// divide: the first build's fractional clock enable (pixels 5 or 6 clocks apart) made the letters' edges jitter on the board.
// The line's the length of a TV's, with a TV's blanking: 3.5 us of front porch, 4.7 us of sync, 8 us of back porch, in which a CRT
// finds black (dividing by 6 left 6.7 us for all three, and a picture with a bright left edge went dark on a CRT)
module m2_vtiming (
	input  logic       clk,
	input  logic       rst,
	output logic       ce_pix,
	output logic [9:0] hpos,      // 0 .. 639 while shown
	output logic [8:0] vpos,      // 0 .. 239 while shown
	output logic       hblank,
	output logic       vblank,
	output logic       hsync,
	output logic       vsync
);
	localparam int HTOT = 857, HVIS0 = 172, HVIS1 = 172 + 640, HS0 = 2, HS1 = 65;
	localparam int VTOT = 262, VVIS0 = 20, VVIS1 = 20 + 240, VS0 = 261, VS1 = 2;   // the sync just after the picture, so a CRT shows it 18 lines below the sync's end

	logic  [2:0] div;
	logic  [9:0] h;
	logic  [8:0] v;
	logic        tick;

	always_ff @(posedge clk)
	begin
		div <= (div == 3'd4) ? 3'd0 : div + 3'd1;
		tick <= (div == 3'd4);
		ce_pix <= tick;
		if (rst)
		begin
			div <= 3'd0;
			h <= 10'd0;
			v <= 9'd0;
		end
		else if (tick)
		begin
			if (h == 10'(HTOT - 1))
			begin
				h <= 10'd0;
				v <= (v == 9'(VTOT - 1)) ? 9'd0 : v + 9'd1;
			end
			else
				h <= h + 10'd1;
			hblank <= (h < 10'(HVIS0)) || (h >= 10'(HVIS1));
			vblank <= (v < 9'(VVIS0)) || (v >= 9'(VVIS1));
			hsync <= (h >= 10'(HS0)) && (h < 10'(HS1));
			vsync <= (v >= 9'(VS0)) || (v < 9'(VS1));
			hpos <= h - 10'(HVIS0);
			vpos <= v - 9'(VVIS0);
		end
	end
endmodule
