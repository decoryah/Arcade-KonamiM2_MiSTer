// m2_guns: Evil Night's three light guns, MAME 0.289's konami_io0_r and INPUT_PORTS (evilngt); taken from the owner's Slap Shot core (rtl/ss_guns.sv, itself after
// the owner's Seta 2 core and ppriest's gx_guns.sv), the ports' scale, a third player and the reload differ.
//
// Each player's aim is a held position v = 0..255 per axis across the picture, moved by
//   the left stick   absolutely, past a dead zone of 8: -128..127 across the picture, which is what Sinden and GUN4IR guns present
//   the d-pad        two units a frame while held
//   the mouse        relatively, for the player the OSD gives it; its left button is the trigger, its right the reload
// Each player's stick has a mode (OSD): Auto (an axis pushed to 96 or more moves as the d-pad does: arcade sticks on gamepad encoders; below that, absolutely), Aim (always
// absolute) or D-pad (any deflection moves as the d-pad).
//
// The ports: X 0..639, Y 0..239, as MAME's. A gun at the left or right edge is off the screen, X and Y reading 0. To reload, P1's and P3's guns are aimed up (a mercury
// switch, in MAME the top edge of the picture), P2's has a button: Button 2 does each of these.
`default_nettype none
module m2_guns (
	input  logic        clk,
	input  logic        rst,                // the guns to the centre
	input  logic        vblank,
	input  logic [31:0] joy [0:2],          // joystick_0..2: right, left, down, up, B1, B2 from bit 0
	input  logic [15:0] ana [0:2],          // joystick_l_analog_0..2: { Y, X }, signed
	input  logic [24:0] mouse,              // hps_io's ps2_mouse: bit 24 toggles a packet, Y positive up
	input  logic [1:0]  mode [0:2],         // each player's stick: 0 Auto, 1 Aim, 2 D-pad
	input  logic [1:0]  ms_who,             // the mouse: 0 P1, 1 P2, 2 P3, 3 off
	input  logic        off_fire,           // Total Vice: Button 2 fires with the gun off the screen, for every player

	output logic [9:0]  gun_x [0:2],
	output logic [7:0]  gun_y [0:2],
	output logic [15:0] p5,                 // MAME's P5, the switches, as it's read

	input  logic [2:0]  show,               // the crosshairs: bit 0 P1, bit 1 P2, bit 2 P3
	input  logic [9:0]  hpos,
	input  logic [8:0]  vpos,
	input  logic [23:0] rgb_in,
	output logic [23:0] rgb_out
);
	logic [31:0] j [0:2];
	logic [15:0] a [0:2];
	logic [24:0] ms;
	logic        ms_t, vbl_l;
	always_ff @(posedge clk)
	begin
		for (int g = 0; g < 3; g++) begin j[g] <= joy[g]; a[g] <= ana[g]; end
		ms <= mouse; ms_t <= ms[24]; vbl_l <= vblank;
	end
	wire       ms_ev = ms[24] ^ ms_t;
	wire       frame = vblank && !vbl_l;
	wire [2:0] ms_sel = {ms_who == 2'd2, ms_who == 2'd1, ms_who == 2'd0};

	localparam logic [7:0] DEAD = 8'd8;     // below this the axis is at rest
	localparam logic [7:0] FULL = 8'd96;    // at or above it, Auto moves as the d-pad

	function automatic logic [7:0] mag(input logic [7:0] v);
		return v[7] ? 8'd0 - v : v;
	endfunction
	function automatic logic [7:0] step(input logic [7:0] v, input logic signed [9:0] d);
		logic signed [10:0] t;
		t = $signed({3'b000, v}) + {d[9], d};
		return t < 11'sd0 ? 8'd0 : t > 11'sd255 ? 8'd255 : t[7:0];
	endfunction

	logic [7:0] vx [0:2];
	logic [7:0] vy [0:2];
	always_ff @(posedge clk)
		for (int g = 0; g < 3; g++)
		begin
			logic [7:0] ax, ay;
			logic       lx, ly, sx, sy;
			logic [3:0] dir;
			ax = a[g][7:0]; ay = a[g][15:8];
			lx = mag(ax) >= DEAD; ly = mag(ay) >= DEAD;
			sx = mode[g] == 2'd2 ? lx : mode[g] == 2'd1 ? 1'b0 : mag(ax) >= FULL;
			sy = mode[g] == 2'd2 ? ly : mode[g] == 2'd1 ? 1'b0 : mag(ay) >= FULL;
			dir = {j[g][3] | (ay[7] & sy), j[g][2] | (!ay[7] & sy), j[g][1] | (ax[7] & sx), j[g][0] | (!ax[7] & sx)};
			if (rst) begin vx[g] <= 8'h80; vy[g] <= 8'h80; end
			else if (ms_ev && ms_sel[g])
			begin
				vx[g] <= step(vx[g], $signed({{2{ms[4]}}, ms[15:8]}));
				vy[g] <= step(vy[g], -$signed({{2{ms[5]}}, ms[23:16]}));
			end
			else
			begin
				if (dir[1:0] != 2'b00) begin if (frame) vx[g] <= step(vx[g], dir[0] ? 10'sd2 : -10'sd2); end
				else if (lx) vx[g] <= ax ^ 8'h80;
				if (dir[3:2] != 2'b00) begin if (frame) vy[g] <= step(vy[g], dir[2] ? 10'sd2 : -10'sd2); end
				else if (ly) vy[g] <= ay ^ 8'h80;
			end
		end

	logic [2:0]  trig, reload, aim_up;
	logic [17:0] xm [0:2];
	logic [15:0] ym [0:2];
	wire  [9:0]  xr [0:2] = '{xm[0][17:8], xm[1][17:8], xm[2][17:8]};      // 0..639
	wire  [7:0]  yr [0:2] = '{ym[0][15:8], ym[1][15:8], ym[2][15:8]};      // 0..239
	always_ff @(posedge clk)
	begin
		for (int g = 0; g < 3; g++)
		begin
			logic off;
			xm[g] <= {10'd0, vx[g]} * 18'd642;
			ym[g] <= {8'd0, vy[g]} * 16'd240;
			trig[g] <= j[g][4] | (ms_sel[g] & ms[0]) | (off_fire & reload[g]);
			reload[g] <= j[g][5] | (ms_sel[g] & ms[1]);
			off = xr[g] == 10'd0 || xr[g] == 10'd639 || (reload[g] && (g != 1 || off_fire));
			gun_x[g] <= off ? 10'd0 : xr[g];
			gun_y[g] <= off ? 8'd0 : yr[g];
			aim_up[g] <= yr[g] == 8'd0 || reload[g];
		end
		// (aimed up reads 0: MAME's field is IP_ACTIVE_LOW, and a port's read inverts its custom fields as it does its buttons)
		p5 <= {1'b1, !aim_up[2], !reload[1], !aim_up[0], 1'b1, ~trig, 8'hff};
	end

	// ---- the crosshairs ----------------------------------------------------------------------------------------------------
	function automatic logic on_cross(input logic [9:0] x, input logic [8:0] y, input logic [9:0] cx, input logic [8:0] cy);
		logic [9:0] dx;
		logic [8:0] dy;
		dx = x >= cx ? x - cx : cx - x;
		dy = y >= cy ? y - cy : cy - y;
		return (dx == 10'd0 && dy <= 9'd6 && dy >= 9'd2) || (dy == 9'd0 && dx <= 10'd12 && dx >= 10'd4);   // (a line's two pixels are as wide as one is high)
	endfunction
	logic c0, c1, c2;
	always_ff @(posedge clk)
	begin
		c0 <= show[0] && on_cross(hpos, vpos, xr[0], {1'b0, yr[0]});
		c1 <= show[1] && on_cross(hpos, vpos, xr[1], {1'b0, yr[1]});
		c2 <= show[2] && on_cross(hpos, vpos, xr[2], {1'b0, yr[2]});
	end
	assign rgb_out = c0 ? 24'hff2020 : c1 ? 24'h20ff20 : c2 ? 24'hffff20 : rgb_in;
endmodule
`default_nettype wire
