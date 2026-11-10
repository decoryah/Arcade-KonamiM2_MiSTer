// ppc_fpx: the float units (rtl/ppc_fps.sv), for one CPU or shared by two.
//
// Shared, each clock is one CPU's (allow): an op can go only in its CPU's clock, so neither CPU's stall depends on the other's
// that clock and nothing long runs between them. A clock is the CPU's that wanted the units the clock before (an op waiting in
// its X), the CPUs' in turn if both did (or neither): so a CPU alone takes an op a clock, two about half a clock each. The
// iterative unit takes one op at a time (ffree), which then goes wherever its CPU is. Each result says whose it is.
// A CPU's reset leaves its ops to finish: their results land in its FPRs, which reset doesn't define.
`default_nettype none
module ppc_fpx #(
	parameter bit TWO = 1'b1
) (
	input  logic clk,
	input  logic rst,
	input  ppc_fpu_pkg::fp_req_t req0,
	input  ppc_fpu_pkg::fp_req_t req1,
	output ppc_fpu_pkg::fp_res_t res
);
	import ppc_fpu_pkg::*;

	logic turn;
	always_ff @(posedge clk)
		if (rst || !TWO) turn <= 1'b0;
		else turn <= req0.want == req1.want ? !turn : req1.want;
	assign res.allow = TWO ? {turn, !turn} : 2'b11;

	// an op comes only in its CPU's clock
	// verilator lint_off UNUSEDSIGNAL
	fp_req_t r;                         // (want: turn's)
	// verilator lint_on UNUSEDSIGNAL
	assign r = turn ? req1 : req0;

	ppc_fps_dp dp (
		.clk, .rst, .issue(r.issue), .cpu(turn), .op(r.op), .rn(r.rn), .a(r.a), .b(r.b), .c(r.c), .rd(r.rd),
		.i_bw(r.bw), .i_fe(r.fe), .i_fw(r.fw),
		.res_a(res.res_a), .res_s(res.res_s), .res_w(res.res_w),
		.ev(res.ev), .ecpu(res.ecpu), .erd(res.erd), .evl(res.evl), .wv(res.wv), .wcpu(res.wcpu), .wrd(res.wrd), .wval(res.wval)
	);

	logic f_busy, f_cpu;
	ppc_fps_it fpu (
		.clk, .rst, .start(r.start), .op(r.op), .rn(r.rn), .a(r.a), .b(r.b), .done(res.fdone), .res(res.fres)
	);
	always_ff @(posedge clk)
		if (rst) f_busy <= 1'b0;
		else if (r.start) begin f_busy <= 1'b1; f_cpu <= turn; end
		else if (res.fdone) f_busy <= 1'b0;
	assign res.fcpu = f_cpu;
	assign res.ffree = !f_busy || res.fdone;
endmodule
