// ppc_fpx: the float units (rtl/ppc_fpp.sv, rtl/ppc_fpu.sv), for one CPU or shared by two.
//
// Shared, the clocks are the CPUs' in turn (allow): an op can go only in its CPU's clock, so neither CPU's stall depends on the
// other's that clock and nothing long runs between them. The pipeline takes an op a clock, so it's about half a clock an op; the
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
	always_ff @(posedge clk) turn <= TWO && !rst && !turn;
	assign res.allow = TWO ? {turn, !turn} : 2'b11;

	// an op comes only in its CPU's clock
	fp_req_t r;
	assign r = turn ? req1 : req0;

	ppc_fpp_dp dp (
		.clk, .rst, .issue(r.issue), .cpu(turn), .op(r.op), .rn(r.rn), .a(r.a), .b(r.b), .c(r.c), .rd(r.rd), .i_bw(r.bw),
		.res_a(res.res_a), .res_s(res.res_s), .res_w(res.res_w),
		.ev(res.ev), .ecpu(res.ecpu), .erd(res.erd), .evl(res.evl), .wv(res.wv), .wcpu(res.wcpu), .wrd(res.wrd), .wval(res.wval)
	);

	logic f_busy, f_cpu;
	// verilator lint_off UNUSEDSIGNAL
	logic [3:0] f_crf;                  // (its compare: fcmpu is X's)
	// verilator lint_on UNUSEDSIGNAL
	ppc_fpu #(.FULL(1'b0)) fpu (
		.clk, .rst, .start(r.start), .op(r.op), .rn(r.rn), .a(r.a), .b(r.b), .c(r.c), .done(res.fdone), .res(res.fres), .crf(f_crf)
	);
	always_ff @(posedge clk)
		if (rst) f_busy <= 1'b0;
		else if (r.start) begin f_busy <= 1'b1; f_cpu <= turn; end
		else if (res.fdone) f_busy <= 1'b0;
	assign res.fcpu = f_cpu;
	assign res.ffree = !f_busy || res.fdone;
endmodule
