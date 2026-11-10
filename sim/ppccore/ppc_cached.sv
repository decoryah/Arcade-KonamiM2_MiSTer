// The bench's top for tb_ppccore with CACHE: rtl/ppc_pipe.sv with rtl/ppc_cache.sv, memory answered by the bench (mem_a the
// physical address, one to one). The data accesses at addresses with bit 14 set aren't cached, to try that way as well.
// The float units are shared, with sim/ppccore/fp_noise.sv as the other CPU; sn_v is the other masters' writes, as the bench likes.
`default_nettype none
module ppc_cached (
	input  logic        clk,
	input  logic        rst,
	input  logic        sn_v,
	input  logic [31:5] sn_a,

	// (the bench watches the core's sides)
	output logic        if_req,
	output logic        if_kill,
	output logic [31:0] if_pa,
	output logic        if_valid,
	output logic        d_req,
	output logic        d_rdy,
	output logic        d_kill,
	output logic        d_we,
	output logic [31:0] d_pa,
	output logic [3:0]  d_size,
	output logic [63:0] d_wdata,
	output logic        d_valid,
	output logic [63:0] d_rdata,

	output logic        mem_rd,
	output logic        mem_we,
	output logic [28:0] mem_a,
	output logic [7:0]  mem_burst,
	output logic [63:0] mem_wd,
	output logic [7:0]  mem_be,
	input  logic        mem_busy,
	input  logic        mem_ready,
	input  logic [63:0] mem_dout,

	input  logic        int_ext,
	input  logic        dec_tick,
	input  logic        tb_tick,
	output logic        retire,
	output logic        retire2,
	output logic [31:0] ipc0_o,
	output logic [31:0] iop0_o,
	output logic [31:0] ipc_o,
	output logic [31:0] iop_o,
	output logic [4:0]  exc_o,
	output logic        timer_read_o,
	output logic [31:0] pc_o,
	output logic [32*32-1:0] gpr_o,
	output logic [64*32-1:0] fpr_o,
	output logic [31:0] cr_o, lr_o, ctr_o, xer_o, msr_o, srr0_o, srr1_o, fpscr_o,
	output logic [31:0] gpr_pend_o,
	output logic [31:0] fpr_pend_o,
	input  logic        dbg_hold,
	output logic        dbg_idle,
	input  logic        dbg_we,
	input  logic [10:0] dbg_idx,
	input  logic [63:0] dbg_val,
	input  logic [1:0]  dbg_int
);
	logic        if_rdy;
	logic [31:0] if_va, if_data, d_va;
	logic [63:0] u_rdata;
	assign u_rdata = 64'h0;

	ppc_fpu_pkg::fp_req_t fp_req, fp_noi;
	ppc_fpu_pkg::fp_res_t fp_res;
	ppc_fpx #(.TWO(1'b1)) fpx (.clk, .rst, .req0(fp_req), .req1(fp_noi), .res(fp_res));
	fp_noise noise (.clk, .rst, .res(fp_res), .req(fp_noi));

	ppc_pipe #(.FP_EXT(1'b1), .FP_ID(1'b0)) cpu
	(
		.clk, .rst,
		.if_req, .if_va, .if_rdy, .if_pa, .if_kill, .if_valid, .if_data,
		.d_req, .d_va, .d_kill, .d_we, .d_pa, .d_size, .d_wdata, .d_rdy, .d_valid, .d_rdata,
		.int_ext, .dec_tick, .tb_tick,
		.retire, .retire2, .ipc0_o, .iop0_o, .ipc_o, .iop_o, .exc_o, .timer_read_o, .pc_o, .gpr_o, .fpr_o,
		.cr_o, .lr_o, .ctr_o, .xer_o, .msr_o, .srr0_o, .srr1_o, .fpscr_o, .gpr_pend_o, .fpr_pend_o,
		.perf_o(), .perf_pc_o(),
		.dbg_hold, .dbg_idle, .dbg_we, .dbg_idx, .dbg_val, .dbg_int, .fp_req, .fp_res
	);

	ppc_cache cache
	(
		.clk, .rst, .sn_v, .sn_a,
		.if_req, .if_va, .if_rdy, .if_pa, .if_kill, .if_valid, .if_data, .i_mem(1'b1),
		.d_req, .d_va, .d_kill, .d_we, .d_pa, .d_size, .d_wdata, .d_rdy, .d_valid, .d_rdata,
		.d_mem(1'b1), .d_cacheable(!d_pa[14]), .d_writable(1'b1),
		.u_req(), .u_pa(), .u_we(), .u_size(), .u_wdata(), .u_ack(1'b0), .u_rdata,
		.mem_rd, .mem_we, .mem_a, .mem_burst, .mem_wd, .mem_be, .mem_busy, .mem_ready, .mem_dout, .pf()
	);
endmodule
