// m2_prof: the board's own profile, for a debug build only (M2_HWPROF): how much of the time each of 14 things is happening, as
// bars over the picture's top. Each event is counted over a window of 2^24 clocks (a quarter of a second, about 15 frames) and
// shown as a bar 512 pixels long at 100 %, with marks at 25, 50, 75 and 100 %; a row of 8 lines each, from the top:
//
//   0 the Triangle Engine busy
//   1-5 CPU 1: retiring, instruction miss, data line fill, write FIFO full, uncached / drain
//   6-13 CPU 1's pipe not taking an instruction (rtl/ppc_pipe.sv's perf_o 1-8): nothing to take, a GPR from a load, an FPR from
//        a load, an FPR from the float unit, the float unit busy, an access out, a multi-clock instruction, held
// (rtl/m2_boot.sv's ev)
`default_nettype none
module m2_prof (
	input  logic        clk,
	input  logic        rst,
	input  logic [13:0] ev,             // bit i: event i this clock
	input  logic [9:0]  hpos,
	input  logic [8:0]  vpos,
	input  logic [23:0] rgb_in,
	output logic [23:0] rgb
);
	localparam int N = 14;
	logic [23:0] t;
	logic [24:0] acc [0:N-1];
	logic [8:0]  bar [0:N-1];
	always_ff @(posedge clk)
	begin
		t <= t + 24'd1;
		for (int i = 0; i < N; i++)
			if (rst || t == 24'hffffff)
			begin
				acc[i] <= 25'(ev[i]);
				if (!rst) bar[i] <= acc[i][24] ? 9'h1ff : acc[i][23:15];
			end
			else acc[i] <= acc[i] + 25'(ev[i]);
		if (rst) t <= 24'd0;
	end

	wire  [3:0] row = vpos[6:3];
	wire        in_rows = vpos < 9'(8 * N) && hpos < 10'd520;
	wire        on_bar = vpos[2:0] != 3'd0 && vpos[2:0] != 3'd7 && hpos < {1'b0, bar[row]};
	wire        mark = hpos[6:0] == 7'd0 && hpos <= 10'd512;
	logic [23:0] col;
	always_comb
		case (row)
			4'd0: col = 24'hffd000;
			4'd1, 4'd2, 4'd3, 4'd4, 4'd5: col = 24'h30ff30;
			default: col = 24'h30d0ff;
		endcase
	always_ff @(posedge clk)
		rgb <= !in_rows ? rgb_in : on_bar ? col : mark ? 24'hff3030 : 24'h101820;
endmodule
