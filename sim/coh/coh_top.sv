// The bench's top for sim/coh: two rtl/ppc_cache.sv and the DMA's port on rtl/m2_bus.sv, the caches' core sides and DDR3 the bench's.
`default_nettype none
module coh_top (
	input  logic        clk,
	input  logic        rst,

	input  logic [1:0]  if_req,
	input  logic [31:0] if_va [0:1],
	output logic [1:0]  if_rdy,
	input  logic [31:0] if_pa [0:1],
	input  logic [1:0]  if_kill,
	output logic [1:0]  if_valid,
	output logic [31:0] if_data [0:1],

	input  logic [1:0]  d_req,
	input  logic [31:0] d_va [0:1],
	input  logic [1:0]  d_kill,
	input  logic [1:0]  d_we,
	input  logic [31:0] d_pa [0:1],
	input  logic [3:0]  d_size [0:1],
	input  logic [63:0] d_wdata [0:1],
	output logic [1:0]  d_rdy,
	output logic [1:0]  d_valid,
	output logic [63:0] d_rdata [0:1],

	input  logic        dma_we,
	input  logic [31:3] dma_a,
	input  logic [63:0] dma_wd,
	input  logic [7:0]  dma_be,
	output logic        dma_busy,

	input  logic        ddr_busy,
	input  logic        ddr_dout_ready,
	input  logic [63:0] ddr_dout,
	output logic        g_rd,
	output logic        g_we,
	output logic [31:3] g_a,
	output logic [7:0]  g_burst,
	output logic [63:0] g_wd,
	output logic [7:0]  g_be
);
	logic [1:0]  c_rd, c_we, c_busy, c_ready, sn_v;
	logic [31:3] c_a [0:1];
	logic [7:0]  c_burst [0:1];
	logic [63:0] c_wd [0:1];
	logic [7:0]  c_be [0:1];
	logic [31:5] sn_a;
	// verilator lint_off UNUSEDSIGNAL
	logic        dma_ready;
	logic [2:0]  q_own [0:11];
	logic [3:0]  q_n;
	// verilator lint_on UNUSEDSIGNAL

	genvar g;
	generate
	for (g = 0; g < 2; g++)
	begin : g_c
		// verilator lint_off PINCONNECTEMPTY
		ppc_cache cache
		(
			.clk, .rst, .sn_v(sn_v[g]), .sn_a,
			.if_req(if_req[g]), .if_va(if_va[g]), .if_rdy(if_rdy[g]), .if_pa(if_pa[g]), .if_kill(if_kill[g]), .if_valid(if_valid[g]), .if_data(if_data[g]), .i_mem(1'b1),
			.d_req(d_req[g]), .d_va(d_va[g]), .d_kill(d_kill[g]), .d_we(d_we[g]), .d_pa(d_pa[g]), .d_size(d_size[g]), .d_wdata(d_wdata[g]),
			.d_rdy(d_rdy[g]), .d_valid(d_valid[g]), .d_rdata(d_rdata[g]),
			.d_mem(1'b1), .d_cacheable(1'b1), .d_writable(1'b1),
			.u_req(), .u_pa(), .u_we(), .u_size(), .u_wdata(), .u_ack(1'b0), .u_rdata(64'h0),
			.mem_rd(c_rd[g]), .mem_we(c_we[g]), .mem_a(c_a[g]), .mem_burst(c_burst[g]), .mem_wd(c_wd[g]), .mem_be(c_be[g]),
			.mem_busy(c_busy[g]), .mem_ready(c_ready[g]), .mem_dout(ddr_dout)
		);
		// verilator lint_on PINCONNECTEMPTY
	end
	endgenerate

	m2_bus bus
	(
		.clk, .rst, .hold(1'b0),
		.c_rd, .c_we, .c_a, .c_burst, .c_wd, .c_be, .c_busy, .c_ready,
		.dma_rd(1'b0), .dma_we, .dma_a, .dma_wd, .dma_be, .dma_busy, .dma_ready,
		.ata_rd(1'b0), .ata_a(29'h0), .ata_busy(), .ata_ready(),
		.vdu_rd(1'b0), .vdu_four(1'b0), .vdu_a(29'h0), .vdu_busy(), .vdu_ready(),
		.te_rd(1'b0), .te_we(1'b0), .te_a(29'h0), .te_wd(64'h0), .te_be(8'h0), .te_busy(), .te_ready(),
		.ddr_busy, .ddr_dout_ready,
		.g_rd, .g_we, .g_a, .g_burst, .g_wd, .g_be,
		.sn_v, .sn_a, .q_own, .q_n
	);
endmodule
