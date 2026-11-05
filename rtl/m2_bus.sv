// m2_bus: who has DDR3: the caches (rtl/ppc_cache.sv) in turn, and the others between them when they want it, the VDU first, then
// the CDE's DMA, the CD drive, the DSP, the Triangle Engine; none while hold (the download). DDR3 answers reads in order, so a queue says whose the next answer is;
// each master has one read out at most but the Triangle Engine, three, so nine in all, and the queue has room for them. Every write taken is told to the other caches (sn_v, sn_a: a clock after), so memory stays
// coherent.
`default_nettype none
module m2_bus (
	input  logic        clk,
	input  logic        rst,
	input  logic        hold,

	input  logic [1:0]  c_rd,
	input  logic [1:0]  c_we,
	input  logic [31:3] c_a [0:1],
	input  logic [7:0]  c_burst [0:1],
	input  logic [63:0] c_wd [0:1],
	input  logic [7:0]  c_be [0:1],
	output logic [1:0]  c_busy,
	output logic [1:0]  c_ready,

	input  logic        dma_rd,
	input  logic        dma_we,
	input  logic [31:3] dma_a,
	input  logic [63:0] dma_wd,
	input  logic [7:0]  dma_be,
	output logic        dma_busy,
	output logic        dma_ready,

	input  logic        ata_rd,         // (4 words)
	input  logic [31:3] ata_a,
	output logic        ata_busy,
	output logic        ata_ready,

	input  logic        dsp_rd,         // (one)
	input  logic [31:3] dsp_a,
	output logic        dsp_busy,
	output logic        dsp_ready,

	input  logic        vdu_rd,
	input  logic        vdu_four,       // 4 words, else one
	input  logic [31:3] vdu_a,
	output logic        vdu_busy,
	output logic        vdu_ready,

	input  logic        te_rd,          // (4 words)
	input  logic        te_we,          // (one)
	input  logic [31:3] te_a,
	input  logic [63:0] te_wd,
	input  logic [7:0]  te_be,
	output logic        te_busy,
	output logic        te_ready,

	input  logic        ddr_busy,
	input  logic        ddr_dout_ready,

	output logic        g_rd,
	output logic        g_we,
	output logic [31:3] g_a,
	output logic [7:0]  g_burst,
	output logic [63:0] g_wd,
	output logic [7:0]  g_be,

	output logic [1:0]  sn_v,
	output logic        sn_t,           // the same for the Triangle Engine
	output logic [31:5] sn_a,

	output logic [2:0]  q_own [0:11],   // the reads out, whose
	output logic [3:0]  q_n
);
	localparam logic [2:0] M_DMA = 3'd2, M_ATA = 3'd3, M_VDU = 3'd4, M_TE = 3'd5, M_DSP = 3'd6;
	logic        last_c;                // the cache that went last
	logic        io_turn;               // a cache went last: the others', if they want it
	logic [2:0]  who;
	logic        any;
	wire         w0 = c_rd[0] || c_we[0];
	wire         w1 = c_rd[1] || c_we[1];
	// (the Triangle Engine's texture load asks ahead: it leaves room in the list of reads out)
	logic        q_room;
	wire         te_rd_ok = te_rd && q_room;
	wire         wio = vdu_rd || te_rd_ok || te_we || dma_rd || dma_we || ata_rd || dsp_rd;
	always_comb
	begin
		any = !hold;
		if (wio && (io_turn || !(w0 || w1))) who = vdu_rd ? M_VDU : (dma_rd || dma_we) ? M_DMA : ata_rd ? M_ATA : dsp_rd ? M_DSP : M_TE;
		else if (w0 && (!w1 || last_c)) who = 3'd0;
		else if (w1) who = 3'd1;
		else begin who = 3'd0; any = 1'b0; end
	end
	assign c_busy[0] = ddr_busy || !any || who != 3'd0;
	assign c_busy[1] = ddr_busy || !any || who != 3'd1;
	assign dma_busy = ddr_busy || !any || who != M_DMA;
	assign ata_busy = ddr_busy || !any || who != M_ATA;
	assign vdu_busy = ddr_busy || !any || who != M_VDU;
	assign te_busy = ddr_busy || !any || who != M_TE;
	assign dsp_busy = ddr_busy || !any || who != M_DSP;

	logic        rd, we;
	always_comb
	begin
		g_a = c_a[who[0]]; rd = c_rd[who[0]]; we = c_we[who[0]]; g_burst = c_burst[who[0]]; g_wd = c_wd[who[0]]; g_be = c_be[who[0]];
		case (who)
			M_DMA: begin g_a = dma_a; rd = dma_rd; we = dma_we; g_burst = 8'd1; g_wd = dma_wd; g_be = dma_be; end
			M_ATA: begin g_a = ata_a; rd = 1'b1; we = 1'b0; g_burst = 8'd4; end
			M_VDU: begin g_a = vdu_a; rd = 1'b1; we = 1'b0; g_burst = vdu_four ? 8'd4 : 8'd1; end
			M_DSP: begin g_a = dsp_a; rd = 1'b1; we = 1'b0; g_burst = 8'd1; end
			M_TE: begin g_a = te_a; rd = te_rd; we = te_we; g_burst = te_rd ? 8'd4 : 8'd1; g_wd = te_wd; g_be = te_be; end
			default: ;
		endcase
	end
	assign g_rd = any && rd;
	assign g_we = any && we;
	wire   took = any && !ddr_busy;

	logic [2:0] q_beats [0:11];
	wire        q_last = ddr_dout_ready && q_beats[0] == 3'd1;
	wire        q_push = took && rd;
	wire [3:0]  q_n1 = q_n - 4'(q_last);    // (where the pushed one goes)
	assign c_ready[0] = ddr_dout_ready && q_own[0] == 3'd0;
	assign c_ready[1] = ddr_dout_ready && q_own[0] == 3'd1;
	assign dma_ready = ddr_dout_ready && q_own[0] == M_DMA;
	assign ata_ready = ddr_dout_ready && q_own[0] == M_ATA;
	assign vdu_ready = ddr_dout_ready && q_own[0] == M_VDU;
	assign te_ready = ddr_dout_ready && q_own[0] == M_TE;
	assign dsp_ready = ddr_dout_ready && q_own[0] == M_DSP;
	always_ff @(posedge clk)
		if (rst) begin q_n <= 4'd0; last_c <= 1'b0; io_turn <= 1'b0; q_room <= 1'b1; end
		else
		begin
			if (took && !who[2] && !who[1]) last_c <= who[0];
			if (took) io_turn <= !who[2] && !who[1];
			if (q_last)
			begin
				for (int i = 0; i < 11; i++) begin q_own[i] <= q_own[i + 1]; q_beats[i] <= q_beats[i + 1]; end
			end
			else if (ddr_dout_ready) q_beats[0] <= q_beats[0] - 3'd1;
			if (q_push) begin q_own[q_n1] <= who; q_beats[q_n1] <= g_burst[2:0]; end
			q_n <= q_n1 + 4'(q_push);
`ifdef VERILATOR
			if (q_n1 + 4'(q_push) > 4'd6) $display("BUSQ %d reads out", q_n1 + 4'(q_push));
`endif
			q_room <= q_n1 + 4'(q_push) < 4'd4;
		end

	always_ff @(posedge clk)
	begin
		sn_a <= g_a[31:5];
		sn_v[0] <= !rst && took && we && who != 3'd0;
		sn_v[1] <= !rst && took && we && who != 3'd1;
		sn_t <= !rst && took && we && who != M_TE;
	end
endmodule
