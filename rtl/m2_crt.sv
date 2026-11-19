// m2_crt: CRT Adjust, the size, horizontal position and vertical position of the picture on an analog CRT (rmonic79's
// MiSTer-CRT-Adjust, modules/crt-adjust), on the M2's raster (rtl/m2_vtiming.sv): 857 x 262, the pixel every 5 clocks, or with
// arc (Hell Night's) 673 x 416, every 4 clocks.
//
// The picture goes through a line buffer and is read out at another rate (H-Size) or from another place in the line
// (H-Position), and the vertical sync is delayed by whole lines (V-Shift); the sync pulses keep their rate, so the monitor stays
// locked. The picture is read a line after it's written, so the vsync is delayed a line to keep its place. Off, everything
// passes straight through, as before (no register, no delay). HDMI follows the adjustment too, as in the other cores with it.
//
// The menu's values: H-Size 0 .. +5, then -16 .. -1; H-Position 0 .. +16, then -48 .. -1, steps of 2 pixels (the M2's pixel
// is about half the width of a 6 MHz core's); V-Shift -16 .. +15 lines.
module m2_crt #(
	parameter int VTOTAL = 262,   // the most lines a frame has: 262, or 416 in a build with Hell Night's raster
	parameter bit CLAMP  = 1'b1   // (0: no limits on the H-Position, for the bench to find them: sim/crt)
)
(
	input  logic        clk,
	input  logic        arc,         // Hell Night's raster
	input  logic        on,          // the menu's CRT Adjust
	input  logic  [4:0] osd_size,    // CRT H-Size, as the menu counts
	input  logic  [6:0] osd_pos,     // CRT H-Position
	input  logic  [4:0] osd_vshift,  // CRT V-Shift (signed)
	input  logic        ce_in,
	input  logic [23:0] rgb_in,
	input  logic        hs_in, vs_in, hb_in, vb_in,
	output logic        ce_out,
	output logic [23:0] rgb_out,
	output logic        hs_out, vs_out, hb_out, vb_out
);
	localparam logic signed [8:0] HBIAS = -9'sd1;   // cancels the module's own delay of the picture, a pixel (the bench's)

	// H-Size: one step is 1/80 of a pixel's time (1/64 with arc), about 8 pixels across the picture
	wire signed [5:0] hsz = (osd_size <= 5'd5) ? $signed({1'b0, osd_size}) : $signed({1'b0, osd_size}) - 6'sd22;
	wire signed [7:0] hps = (osd_pos <= 7'd16) ? $signed({1'b0, osd_pos}) : $signed({1'b0, osd_pos}) - 8'sd65;
	// the H-Positions (the menu's steps) at which the picture is whole: its first pixel after the hsync pulse, its last before the
	// next line's pulse (the module reads from the pulse on, so H-Size moves the picture's ends too). The bench's (sim/crt/run.sh
	// limits); further values stop there. The TV raster's picture starts 170 pixels after the pulse rises and ends 47 before the
	// line's end; Hell Night's, 102 and 57
	logic signed [7:0] pmin, pmax;
	always_comb
	begin
		pmin = -8'sd48;
		pmax = 8'sd16;
		if (!arc)
		begin
			if      (hsz <= -6'sd15) pmin = -8'sd46;
			else if (hsz <= -6'sd13) pmin = -8'sd47;
			case (hsz)
				6'sd2:   pmax = 8'sd13;
				6'sd3:   pmax = 8'sd8;
				6'sd4:   pmax = 8'sd3;
				6'sd5:   pmax = -8'sd2;
				default: ;
			endcase
		end
		else
		begin
			case (hsz)
				-6'sd16, -6'sd15: pmin = -8'sd14;
				-6'sd14:          pmin = -8'sd15;
				-6'sd13:          pmin = -8'sd16;
				-6'sd12, -6'sd11: pmin = -8'sd17;
				-6'sd10, -6'sd9:  pmin = -8'sd18;
				-6'sd8:           pmin = -8'sd19;
				-6'sd7,  -6'sd6:  pmin = -8'sd20;
				-6'sd5,  -6'sd4:  pmin = -8'sd21;
				-6'sd3,  -6'sd2:  pmin = -8'sd22;
				6'sd2,   6'sd3:   pmin = -8'sd24;
				6'sd4,   6'sd5:   pmin = -8'sd25;
				default:          pmin = -8'sd23;   // -1 .. +1
			endcase
			case (hsz)
				6'sd3:   pmax = 8'sd14;
				6'sd4:   pmax = 8'sd9;
				6'sd5:   pmax = 8'sd5;
				default: ;
			endcase
		end
	end
	wire signed [7:0] hpc = !CLAMP ? hps : (hps < pmin) ? pmin : (hps > pmax) ? pmax : hps;
	// a positive V-Shift moves the picture down: the vsync comes earlier
	wire signed [5:0] vs_t = 6'sd1 - $signed({osd_vshift[4], osd_vshift});   // (-14 .. +17)

	logic              crt_on;
	logic signed [4:0] hsize;
	logic signed [8:0] hoff;
	logic signed [5:0] voff;
	always_ff @(posedge clk) if (ce_in)
	begin
		crt_on <= on;
		hsize  <= hsz[4:0];
		hoff   <= {hpc, 1'b0} + HBIAS;   // steps of 2 pixels
		voff   <= vs_t;
	end

	// the read enable: one every (80 + H-Size) sixteenths of a clock (64 + H-Size with arc), counted from the module's line
	// reference; at H-Size 0 every 5th clock (4th), as the raster's own
	wire       hs_ref;
	logic      hs_ref_d;
	wire [7:0] period = (arc ? 8'd64 : 8'd80) + {{3{hsize[4]}}, hsize};
	logic [7:0] acc;
	wire       tick = (acc + 8'd16) >= period;
	always_ff @(posedge clk)
	begin
		hs_ref_d <= hs_ref;
		if (hs_ref & ~hs_ref_d) acc <= 8'd0;
		else if (tick)          acc <= acc + 8'd16 - period;
		else                    acc <= acc + 8'd16;
	end
	wire rd_en = crt_on ? tick : ce_in;

	wire [7:0] r, g, b;
	wire       c_hs, c_vs, c_hb, c_vb_unused;
	crt_adjust #(.VTOTAL(VTOTAL), .HTOTAL(857), .HPOS_MODE(1), .AW(11)) u_crt
	(
		.clk(clk), .pxl_cen(ce_in), .pxl2_cen(rd_en), .active(crt_on),
		.hsize(hsize), .hoffset(hoff), .voffset(voff), .vtotal((arc && VTOTAL >= 416) ? 9'd416 : 9'd262),
		.r_in(rgb_in[23:16]), .g_in(rgb_in[15:8]), .b_in(rgb_in[7:0]),
		.hs_in(hs_in), .vs_in(vs_in), .hb_in(hb_in), .vb_in(vb_in),
		.r_out(r), .g_out(g), .b_out(b),
		.hs_out(c_hs), .vs_out(c_vs), .hb_out(c_hb), .vb_out(c_vb_unused),
		.hs_ref_out(hs_ref)
	);

	assign ce_out  = crt_on ? rd_en : ce_in;
	assign rgb_out = crt_on ? {r, g, b} : rgb_in;
	assign hs_out  = crt_on ? c_hs : hs_in;
	assign vs_out  = crt_on ? c_vs : vs_in;
	assign hb_out  = crt_on ? (c_hb | c_hs) : hb_in;   // on: nothing of the picture inside the hsync pulse
	assign vb_out  = crt_on ? 1'b0 : vb_in;            // on: the module's blank has the vertical one in it
endmodule
