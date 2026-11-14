// m2_fps: a debug build's frame rate (M2_FPS), for MiSTer's Linux to read (/dev/mem): once a second, an entry in a ring of 4096
// 64-bit entries at DDR3 0x30800000 (where an M2_TRACE build keeps its trace; nothing else uses it), written in a clock DDR3 is free
// (wr / wr_ok, as rtl/m2_trace.sv's).
//
// An entry, little-endian as written: [63:56] 0xF5, [55:48] the second (mod 256), [47:40] frames the VDU started, [39:32] flips (frames
// whose shown buffers differ from the frame before's: rtl/m2_vdu.sv), [31:16] CPU 1's instructions retired / 4096, [15:0] CPU 2's.
// The ring's next entry overwrites the oldest; a reader takes the entries in order of their seconds (tools: the board's fps.py).
`default_nettype none
module m2_fps #(
	parameter int SECOND = 66_666_667   // the machine clock
) (
	input  logic        clk,
	input  logic        rst,
	input  logic        frame,
	input  logic        flip,
	input  logic [1:0]  ret1,           // instructions CPU 1 retired this clock (0-2)
	input  logic [1:0]  ret2,           // CPU 2's

	output logic        wr,             // the entry's write, when wr_ok
	input  logic        wr_ok,
	output logic [28:0] wr_a,           // DDR3's word address (byte address bits 31:3)
	output logic [63:0] wr_d
);
	logic [25:0] t;
	logic [7:0]  sec, frames, flips;
	logic [27:0] r1, r2;
	logic [11:0] idx;
	always_ff @(posedge clk)
		if (rst)
		begin
			t <= 26'd0; sec <= 8'd0; frames <= 8'd0; flips <= 8'd0; r1 <= 28'd0; r2 <= 28'd0; idx <= 12'd0; wr <= 1'b0;
		end
		else
		begin
			if (wr && wr_ok) begin wr <= 1'b0; idx <= idx + 12'd1; end
			if (t == 26'(SECOND - 1))
			begin
				t <= 26'd0;
				wr_d <= {8'hf5, sec, frames, flips, r1[27:12], r2[27:12]};
				wr <= 1'b1;
				sec <= sec + 8'd1;
				frames <= 8'(frame); flips <= 8'(flip); r1 <= 28'(ret1); r2 <= 28'(ret2);
			end
			else
			begin
				t <= t + 26'd1;
				if (frame) frames <= frames + 8'd1;
				if (flip) flips <= flips + 8'd1;
				r1 <= r1 + 28'(ret1);
				r2 <= r2 + 28'(ret2);
			end
		end
	assign wr_a = {4'b0011, 5'b00001, 8'h00, idx};
endmodule
