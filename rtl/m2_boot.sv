// m2_boot: the CPU bring-up machine, until the rest of the board is in. ppc1 and ppc2 (rtl/ppc_pipe.sv, the float units between
// them: rtl/ppc_fpx.sv) run the boot ROM from DDR3, with main RAM in DDR3 too; the CDE (rtl/m2_cde.sv) is there, and the other
// registers the boot ROM touches are plain registers that keep what is written, their reset values what MAME's power-on trace
// reads (work/cap/boot/p1.tr).
//
//   0x20000000-0x201fffff, 0xfff00000-0xffffffff   the boot ROM (DDR3 0x30000000 +), written by the download
//   0x40000000-0x40ffffff                          main RAM (DDR3 0x31000000 +)
//   0x00010000-0x0003ffff                          the BDA's PowerBus, memory and video line registers (rtl/m2_bda.sv)
//   0x04000000-0x0400ffff                          the CDE
//   0x37000000-0x37ffffff                          Konami's I/O (rtl/m2_kio.sv)
//   0x3f000000-0x3fffffff                          the CD drive (rtl/m2_atapi.sv), its disc at DDR3 0x32000000 +
//   anything else                                  the register stubs (32-bit; 16 of them), but the CPU ID (fixed_rd)
//
// Each CPU reaches memory through its caches (rtl/ppc_cache.sv), which see every write the others make, so memory is coherent,
// as MAME's is. The download writes DDR3 directly, under reset.
//
// PPC_CACHE_KB (a build option, default 32): each cache's size, instruction and data sides each (rtl/ppc_cache.sv's KB). 4 is
// the 602's own (4 KB a side, the data side two-way, 32-byte lines; its instruction side is two-way too, here direct-mapped):
// the board's speed and slowdowns, and much less block RAM; 32 runs faster than the board.
`ifndef PPC_CACHE_KB
`define PPC_CACHE_KB 32
`endif
`default_nettype none
module m2_boot #(
	parameter int TICK = 8              // clocks a DEC / TB tick (the bus clock / 4)
) (
	input  logic        clk,
	input  logic        rst,

	// the download: bytes from 0, one a clock at most; ld_wait holds the next. ld_sel: 0 the boot ROM, 1 the CD image, 2 the EEPROM, 4 the YMZ280B's samples,
	// 3 the M48T58's 8 KB then a byte for the board (bit 0: RAM 2 x 8 MB, not 2 x 4 MB); a game without an M48T58 has no index 3
	input  logic        ld_wr,
	input  logic [2:0]  ld_sel,
	input  logic [25:0] ld_addr,
	input  logic [7:0]  ld_data,
	output logic        ld_wait,
	input  logic [6:0]  ee_ua,          // the EEPROM's upload: its byte at ee_ua, a clock later
	output logic [7:0]  ee_ud,
	output logic        ee_chg,         // a clock: the game wrote the EEPROM

	// DDR3 (MiSTer's DDRAM_*, on clk)
	input  logic        ddr_busy,
	output logic [7:0]  ddr_burstcnt,
	output logic [28:0] ddr_addr,
	input  logic [63:0] ddr_dout,
	input  logic        ddr_dout_ready,
	output logic        ddr_rd,
	output logic [63:0] ddr_din,
	output logic [7:0]  ddr_be,
	output logic        ddr_we,

	// video: the raster (rtl/m2_vtiming.sv), and the VDU's picture
	input  logic [9:0]  hpos,
	input  logic [8:0]  vpos,
	output logic [23:0] rgb,
	output logic        vdu_on,
	output logic [15:0] audio_l,
	output logic [15:0] audio_r,

	// the CD's audio: a raw image of the disc on the SD card
	input  logic        cd_mounted,
	output logic [31:0] sd_lba,
	output logic        sd_rd,
	input  logic        sd_ack,
	input  logic        sd_wr,
	input  logic [7:0]  sd_d,

	// the inputs, active low (rtl/m2_kio.sv)
	input  logic [7:0]  in_p1,
	input  logic [7:0]  in_dsw,
	input  logic [15:0] in_p4,
	input  logic [15:0] in_p6,
	input  logic [15:0] in_p5,          // Evil Night's gun switches and aim (rtl/m2_guns.sv)
	input  logic [9:0]  gun_x [0:2],
	input  logic [7:0]  gun_y [0:2],

	// what each CPU is doing: the last instruction retired, how many, the last exception taken (and how many);
	// the last register stub access
	output logic [31:0] st_pc [0:1],
	output logic [31:0] st_count [0:1],
	output logic [4:0]  st_exc [0:1],
	output logic [15:0] st_nexc [0:1],
	output logic [31:0] st_dev_a,
	output logic [31:0] st_dev_d,
	output logic        st_dev_w,
	output logic [31:0] st_ndev,

	// bench: the retires (ppc_pipe's), each CPU's
	output logic        retire,
	output logic        retire2,
	output logic [31:0] ipc0_o,
	output logic [31:0] ipc_o,
	output logic        p2_retire,
	output logic        p2_retire2,
	output logic [31:0] p2_ipc0_o,
	output logic [31:0] p2_ipc_o
);
	localparam int N = 2;

	// ---- the map ------------------------------------------------------------------------------------------------------
	// a ROM or RAM address's DDR3 byte address (from 0x30000000), or none (a register stub)
	typedef struct packed { logic mem; logic rom; logic [27:0] a; } map_t;
	function automatic map_t map(input logic [31:0] a);
		map_t m;
		m.mem = 1'b1; m.rom = 1'b1; m.a = {7'h0, a[20:0]};
		if (a[31:20] == 12'hfff) m.a = {8'h0, a[19:0]};
		else if (a[31:21] == 11'h100) ;                          // 0x20000000-0x201fffff
		else if (a[31:24] == 8'h40) begin m.rom = 1'b0; m.a = {4'h1, a[23:0]}; end
		else m.mem = 1'b0;
		return m;
	endfunction

	// ---- the CPUs and their caches -------------------------------------------------------------------------------------
	logic [N-1:0] rs;                   // each CPU's reset
	logic [N-1:0] c_rd, c_we, c_busy, c_ready;
	logic [31:3]  c_a [0:N-1];
	logic [7:0]   c_burst [0:N-1];
	logic [7:0]   c_be [0:N-1];
	logic [63:0]  c_wd [0:N-1];
	logic [N-1:0] c_u_req, c_u_we;
	logic [N-1:0] c_u_ack;
	logic [31:0]  c_u_pa [0:N-1];
	logic [3:0]   c_u_size [0:N-1];
	logic [63:0]  c_u_wd [0:N-1];
	logic [63:0]  u_rdata;
	logic [N-1:0] sn_v;                 // a write by another master: its line
	logic [31:5]  sn_a;
	logic         sn_t;
	logic [N-1:0] c_ret, c_ret2;
	logic [3:0]   c_pf [0:N-1], c_perf [0:N-1];
	logic         ppc1_int, ppc2_int;
	logic [31:0]  c_ipc [0:N-1];
	logic [31:0]  c_ipc0 [0:N-1];
	logic [4:0]   c_exc [0:N-1];
	ppc_fpu_pkg::fp_req_t fp_req [0:N-1];
	ppc_fpu_pkg::fp_res_t fp_res;

	// DEC and TB
	logic [2:0] tick_n;
	always_ff @(posedge clk) tick_n <= rst || tick_n == 3'(TICK - 1) ? 3'd0 : tick_n + 3'd1;
	wire dec_tick = tick_n == 3'(TICK - 1);

	ppc_fpx #(.TWO(1'b1)) fpx (.clk, .rst, .req0(fp_req[0]), .req1(fp_req[1]), .res(fp_res));

	genvar g;
	generate
	for (g = 0; g < N; g++)
	begin : g_cpu
		logic        if_req, if_rdy, if_kill, if_valid;
		logic [31:0] if_pa, if_data, if_va, d_va;
		logic        d_req, d_kill, d_we, d_rdy, d_valid;
		logic [31:0] d_pa;
		logic [3:0]  d_size;
		logic [63:0] d_wdata, d_rdata;
		// verilator lint_off UNUSEDSIGNAL
		map_t        m_if, m_d;
		// verilator lint_on UNUSEDSIGNAL
		assign m_if = map(if_pa);
		assign m_d = map(d_pa);
		// verilator lint_off PINCONNECTEMPTY
		// (no fast multiply: the device is too full for it)
		ppc_pipe #(.FWD(1'b0), .BENCH(1'b0), .FP_EXT(1'b1), .FP_ID(g != 0)) cpu (
			.clk, .rst(rs[g]),
			.if_req, .if_va, .if_rdy, .if_pa, .if_kill, .if_valid, .if_data,
			.d_req, .d_va, .d_kill, .d_we, .d_pa, .d_size, .d_wdata, .d_rdy, .d_valid, .d_rdata,
			.int_ext(g == 0 ? ppc1_int : ppc2_int), .dec_tick, .tb_tick(dec_tick),
			.retire(c_ret[g]), .retire2(c_ret2[g]), .ipc0_o(c_ipc0[g]), .iop0_o(), .ipc_o(c_ipc[g]), .iop_o(), .exc_o(c_exc[g]),
			.timer_read_o(), .pc_o(), .gpr_o(), .fpr_o(),
			.cr_o(), .lr_o(), .ctr_o(), .xer_o(), .msr_o(), .srr0_o(), .srr1_o(), .fpscr_o(), .gpr_pend_o(), .fpr_pend_o(),
			.perf_o(c_perf[g]), .perf_pc_o(),
			.dbg_hold(1'b0), .dbg_idle(), .dbg_we(1'b0), .dbg_idx(11'd0), .dbg_val(64'd0), .dbg_int(2'd0),
			.fp_req(fp_req[g]), .fp_res
		);
		// verilator lint_on PINCONNECTEMPTY
		ppc_cache #(.KB(`PPC_CACHE_KB)) cache
		(
			.clk, .rst(rs[g]), .sn_v(sn_v[g]), .sn_a,
			.if_req, .if_va, .if_rdy, .if_pa, .if_kill, .if_valid, .if_data, .i_mem(m_if.mem),
			.d_req, .d_va, .d_kill, .d_we, .d_pa, .d_size, .d_wdata, .d_rdy, .d_valid, .d_rdata,
			.d_mem(m_d.mem), .d_cacheable(m_d.mem), .d_writable(!m_d.rom),
			.u_req(c_u_req[g]), .u_pa(c_u_pa[g]), .u_we(c_u_we[g]), .u_size(c_u_size[g]), .u_wdata(c_u_wd[g]), .u_ack(c_u_ack[g]), .u_rdata,
			.mem_rd(c_rd[g]), .mem_we(c_we[g]), .mem_a(c_a[g]), .mem_burst(c_burst[g]), .mem_wd(c_wd[g]), .mem_be(c_be[g]),
			.mem_busy(c_busy[g]), .mem_ready(c_ready[g]), .mem_dout(ddr_dout), .pf(c_pf[g])
		);

		// status
		always_ff @(posedge clk)
			if (rst)
			begin
				st_pc[g] <= 32'h0; st_count[g] <= 32'h0; st_exc[g] <= 5'd0; st_nexc[g] <= 16'h0;
			end
			else if (c_ret[g])
			begin
				st_pc[g] <= c_ipc[g];
				st_count[g] <= st_count[g] + (c_ret2[g] ? 32'd2 : 32'd1);
				if (c_exc[g] != 5'd0) begin st_exc[g] <= c_exc[g]; st_nexc[g] <= st_nexc[g] + 16'd1; end
			end
	end
	endgenerate

	assign retire = c_ret[0];
	assign retire2 = c_ret2[0];
	assign ipc0_o = c_ipc0[0];
	assign ipc_o = c_ipc[0];
	assign p2_retire = c_ret[1];
	assign p2_retire2 = c_ret2[1];
	assign p2_ipc0_o = c_ipc0[1];
	assign p2_ipc_o = c_ipc[1];

	// ---- DDR3 ----------------------------------------------------------------------------------------------------------
	logic        ld_pend;
	logic [25:0] ld_a;
	logic        ld_ymz;
	logic        ld_cd;
	logic [7:0]  ld_d;
	logic        dma_rd, dma_we;
	logic [31:3] dma_a;
	logic [63:0] dma_wd;
	logic [7:0]  dma_be;

	logic [2:0]  q_own [0:11];
	logic [3:0]  q_n;
	logic        vdu_m_rd, vdu_m_four, vdu_m_busy, vdu_m_ready;
	logic [31:3] vdu_m_a;
	logic        ata_m_rd, ata_m_busy, ata_m_ready;
	logic [31:3] ata_m_a;
	logic        dsp_m_rd, dsp_m_busy, dsp_m_ready;
	logic [31:3] dsp_m_a;
	logic        te_m_rd, te_m_we, te_m_busy, te_m_ready, te_busy;
	logic [23:0] v_rgb;
	logic [31:3] te_m_a;
	logic [63:0] te_m_wd;
	logic [7:0]  te_m_be;
	logic [4:0]  te_int;
	logic [31:3] g_a;
	logic        g_rd, g_we;
	logic [7:0]  g_burst, g_be;
	logic [63:0] g_wd;
	logic        ymz_m_rd, ymz_m_busy, ymz_m_ready;
	logic [21:3] ymz_rom_a;
	wire  [31:3] ymz_m_a = {6'h15, 4'd0, ymz_rom_a};
	logic        dma_busy, dma_ready;
	m2_bus bus
	(
		.clk, .rst, .hold(ld_pend),
		.c_rd, .c_we, .c_a, .c_burst, .c_wd, .c_be, .c_busy, .c_ready,
		.dma_rd, .dma_we, .dma_a, .dma_wd, .dma_be, .dma_busy, .dma_ready,
		.ata_rd(ata_m_rd), .ata_a(ata_m_a), .ata_busy(ata_m_busy), .ata_ready(ata_m_ready),
		.dsp_rd(dsp_m_rd), .dsp_a(dsp_m_a), .dsp_busy(dsp_m_busy), .dsp_ready(dsp_m_ready),
		.ymz_rd(ymz_m_rd), .ymz_a(ymz_m_a), .ymz_busy(ymz_m_busy), .ymz_ready(ymz_m_ready),
		.vdu_rd(vdu_m_rd), .vdu_four(vdu_m_four), .vdu_a(vdu_m_a), .vdu_busy(vdu_m_busy), .vdu_ready(vdu_m_ready),
		.te_rd(te_m_rd), .te_we(te_m_we), .te_a(te_m_a), .te_wd(te_m_wd), .te_be(te_m_be), .te_busy(te_m_busy), .te_ready(te_m_ready),
		.ddr_busy, .ddr_dout_ready,
		.g_rd, .g_we, .g_a, .g_burst, .g_wd, .g_be,
		.sn_v, .sn_t, .sn_a, .q_own, .q_n
	);
	// verilator lint_off UNUSEDSIGNAL
	map_t        m_g;
	// verilator lint_on UNUSEDSIGNAL
	// (the CD image's address is the drive's own: no CPU sees it)
	assign m_g = g_a[31:27] == 5'b01010 ? map_t'({1'b1, 1'b1, g_a[26] ? 3'b011 : g_a[25] ? 3'b010 : 3'b001, g_a[24:3], 3'b000}) : map({g_a, 3'b000});
	assign ddr_burstcnt = ld_pend ? 8'd1 : g_burst;
	wire [27:3] ld_ddr = ld_ymz ? {6'b011000, ld_a[21:3]} : ld_cd ? {ld_a[25] ? 3'b010 : 3'b001, ld_a[24:3]} : {7'h0, ld_a[20:3]};
	assign ddr_addr = {4'b0011, ld_pend ? ld_ddr : m_g.a[27:3]};
	assign ddr_rd = g_rd;
	assign ddr_we = ld_pend || g_we;
	assign ddr_din = ld_pend ? {8{ld_d}} : g_wd;
	assign ddr_be = ld_pend ? 8'h01 << ld_a[2:0] : g_be;

	// ---- the CPUs' resets (rst, or the CDE's: the CPU that asks): held until DDR3 has answered all its caches asked (so nothing
	// it answers reaches a request made after) -----------------------------------------------------------------------------
	logic        soft_rst, u_last;
	logic [1:0]  rs_n [0:N-1];          // (the CPU needs more than a clock of it)
	generate
	for (g = 0; g < N; g++)
	begin : g_rs
		wire sft = soft_rst && u_last == (g != 0);
		logic out;
		always_comb
		begin
			out = 1'b0;
			for (int j = 0; j < 12; j++) if (q_n > 4'(j) && q_own[j] == 3'(g)) out = 1'b1;
		end
		always_ff @(posedge clk)
		begin
			rs_n[g] <= sft ? 2'd3 : rs_n[g] != 2'd0 ? rs_n[g] - 2'd1 : 2'd0;
			rs[g] <= rst || sft || rs_n[g] != 2'd0 || (rs[g] && out);
		end
	end
	endgenerate

	// ---- the download -------------------------------------------------------------------------------------------------
	assign ld_wait = ld_pend;
	always_ff @(posedge clk)
		if (ld_wr && !ld_sel[1]) begin ld_pend <= 1'b1; ld_a <= ld_addr; ld_d <= ld_data; ld_cd <= ld_sel[0]; ld_ymz <= ld_sel[2]; end
		else if (!ddr_busy) ld_pend <= 1'b0;

	// ---- the registers: one CPU's access at a time: the choice, the access, the answer, a clock each ----------------------
	logic [N-1:0] u_pend;
	wire         n_req = u_pend != 2'b00;
	wire         n_s = !u_pend[0];
	logic        u_req, u_s, a_req, a_s, a_we;
	logic [31:0] u_pa;
	logic        u_we;
	logic [3:0]  u_size, a_size;
	logic [63:0] u_wdata;
	logic [31:0] a_w;
	logic [1:0]  a_off;
	always_ff @(posedge clk)
		if (rst) begin u_pend <= 2'b00; u_last <= 1'b0; c_u_ack <= 2'b00; u_req <= 1'b0; a_req <= 1'b0; end
		else
		begin
			u_pend <= (u_pend & ~(n_req ? (2'b01 << n_s) : 2'b00)) | c_u_req;
			u_req <= n_req; u_s <= n_s;
			u_pa <= c_u_pa[n_s]; u_we <= c_u_we[n_s]; u_size <= c_u_size[n_s]; u_wdata <= c_u_wd[n_s];
			a_req <= u_req; a_s <= u_s;
			c_u_ack <= a_req ? (2'b01 << a_s) : 2'b00;
			if (u_req) u_last <= u_s;
		end

	// ---- the register stubs -------------------------------------------------------------------------------------------
	localparam int NS = 16;
	logic [31:0] sa [0:NS-1];
	logic [31:0] sv [0:NS-1];
	logic [NS-1:0] s_used;
	logic [3:0]  s_next;

	// bytes [off, off + n) of a word, big-endian, right-aligned
	function automatic logic [63:0] rd_bytes(input logic [63:0] w, input logic [2:0] off, input logic [3:0] n);
		logic [63:0] v;
		v = 64'h0;
		for (int j = 0; j < 8; j++)
			if (4'(j) < n && 32'(off) + j < 8) v = {v[55:0], w[8 * (32'(off) + j) +: 8]};
		return v;
	endfunction

	// the registers whose reads MAME 0.289 makes constants (3dom2.cpp): CPUID (which CPU, with the DSW's video resolution bit set)
	function automatic logic fixed_rd(input logic [31:2] a, input logic s, output logic [31:0] v);
		v = {s, 31'h40000000};
		return {a, 2'b00} == 32'h10000000;
	endfunction

	// ---- the BDA's registers, and the CDE ---------------------------------------------------------------------------------
	wire         u_cde = u_pa[31:16] == 16'h0400;
	wire         u_bda = u_pa[31:20] == 12'h000;
	wire         u_kio = u_pa[31:24] == 8'h37;
	wire         u_ata = u_pa[31:24] == 8'h3f;
	wire         u_te = u_pa[31:16] == 16'h0004;
	wire         u_dsp = u_pa[31:16] == 16'h0006;
	wire         u_tk = u_pa[31:14] == 18'h0db00;       // 0x36c00000-0x36c03fff
	wire         u_ymz = u_pa[31:4] == 28'h3e80000;     // 0x3e800000-0x3e80000f: the YMZ280B, on Evil Night's sub board
	logic [31:0] cde_rd, bda_rd, te_rd, dsp_rd;
	logic        dsp_int;
	logic [15:0] kio_rd, atapi_rd;
	logic        cde_int;
	logic        cd_rd, cd_valid, cd_int;
	logic [15:0] cd_d;
	// verilator lint_off PINCONNECTEMPTY
	// the board, from the download (kept through a reset)
	logic        ram8 = 1'b0;
	always_ff @(posedge clk) if (ld_wr && ld_sel == 3'd3 && ld_addr == 26'h2000) ram8 <= ld_data[0];
	m2_bda bda
	(
		.clk, .rst, .vpos,
		.mcfg0(ram8 ? 32'h0000b400 : 32'h00004800),     // (5: 8 MB, 2: 4 MB, as MAME's ramsize_to_mcfg_field)
		.a(u_pa[19:2]), .we(u_req && u_we && u_bda), .wd(u_wdata[31:0]), .rd(bda_rd),
		.lines({te_int, 1'b0, dsp_int, 21'h0, cde_int, 3'b000}),
		.ppc1_int, .ppc2_int, .line()
	);
	// verilator lint_on PINCONNECTEMPTY
	// verilator lint_off PINCONNECTEMPTY
	m2_cde cde
	(
		.clk, .rst,
		.a(u_pa[15:2]), .we(u_req && u_we && u_cde), .wd(u_wdata[31:0]), .rd(cde_rd),
		.soft_rst, .intr(cde_int),
		.dma_rd, .dma_we, .dma_a, .dma_wd, .dma_be, .dma_busy, .dma_ready, .dma_dout(ddr_dout),
		.ata_rd(cd_rd), .ata_valid(cd_valid), .ata_d(cd_d)
	);
	// verilator lint_on PINCONNECTEMPTY
	m2_vdu vdu
	(
		.clk, .rst,
		.a(u_pa[5:2]), .we(u_req && u_we && u_pa[31:8] == 24'h000300), .wd(u_wdata[31:0]),
		.hpos, .vpos, .rgb(v_rgb), .on(vdu_on),
		.m_rd(vdu_m_rd), .m_four(vdu_m_four), .m_a(vdu_m_a), .m_busy(vdu_m_busy), .m_ready(vdu_m_ready), .m_dout(ddr_dout)
	);
	// verilator lint_off PINCONNECTEMPTY
	m2_te te
	(
		.clk, .rst,
		.a(u_pa[15:2]), .we(u_req && u_we && u_te), .wd(u_wdata[31:0]), .rd(te_rd),
		.intr(te_int),
		.m_rd(te_m_rd), .m_we(te_m_we), .m_a(te_m_a), .m_wd(te_m_wd), .m_be(te_m_be), .m_busy(te_m_busy), .m_ready(te_m_ready), .m_dout(ddr_dout),
		.busy(te_busy)
	);
	// verilator lint_on PINCONNECTEMPTY
`ifdef M2_HWPROF
	// a debug build's profile over the picture (rtl/m2_prof.sv)
	m2_prof prof
	(
		.clk, .rst,
		.ev({c_perf[0] == 4'd8, c_perf[0] == 4'd7, c_perf[0] == 4'd6, c_perf[0] == 4'd5, c_perf[0] == 4'd4, c_perf[0] == 4'd3, c_perf[0] == 4'd2, c_perf[0] == 4'd1,
		      c_pf[0], c_ret[0], te_busy}),
		.hpos, .vpos, .rgb_in(v_rgb), .rgb
	);
`else
	assign rgb = v_rgb;
`endif
	// 44.1 kHz, from 66.67 MHz
	logic [10:0] dac_n;
	logic [15:0] dac_l, dac_r;
	wire         dac_tick = dac_n == 11'd1511;
	always_ff @(posedge clk) dac_n <= rst || dac_tick ? 11'd0 : dac_n + 11'd1;
	m2_dspp dsp
	(
		.clk, .rst,
		.pre_a(c_u_pa[n_s][11:2]), .a(u_pa[15:2]), .we(u_req && u_we && u_dsp), .wd(u_wdata[31:0]), .rd(dsp_rd), .intr(dsp_int),
		.m_rd(dsp_m_rd), .m_a(dsp_m_a), .m_busy(dsp_m_busy), .m_ready(dsp_m_ready), .m_dout(ddr_dout),
		.dac_tick, .dac_l, .dac_r
	);
	logic        cd_play, cd_stop, cd_playing, cd_finished, cd_paused;
	logic [7:0]  cd_vol_l, cd_vol_r;
	logic [23:0] cd_lba, cd_len, cd_pos;
	// verilator lint_off UNUSEDSIGNAL
	logic [15:0] cda_l, cda_r;
	// verilator lint_on UNUSEDSIGNAL
	// (the image hasn't the 2 s between the data track and the first of the audio; the data track's own sectors are never played)
	m2_cdda #(.LBA0(24'd150)) cdda
	(
		.clk, .rst, .tick(dac_tick),
		.play(cd_play), .lba(cd_lba), .len(cd_len), .stop(cd_stop), .paused(cd_paused), .pos(cd_pos), .playing(cd_playing), .finished(cd_finished),
		.mounted(cd_mounted), .sd_lba, .sd_rd, .sd_ack, .sd_wr, .sd_d,
		.l(cda_l), .r(cda_r)
	);
	// the mix, as MAME's: the DSP at full, the CD at half and at the game's volume
	function automatic logic [15:0] mix(input logic [15:0] d, input logic [14:0] c);
		logic signed [16:0] s;
		s = 17'($signed(d)) + 17'($signed(c));
		return s[16] == s[15] ? s[15:0] : s[16] ? 16'h8000 : 16'h7fff;
	endfunction
	// verilator lint_off UNUSEDSIGNAL
	logic signed [24:0] cdv_l, cdv_r;
	// verilator lint_on UNUSEDSIGNAL
	logic [15:0] mix0_l, mix0_r;
	function automatic logic [15:0] mix_ymz(input logic [15:0] a, input logic signed [15:0] b);
		logic signed [16:0] s;
		s = 17'($signed(a)) + 17'(b);
		return s[16] == s[15] ? s[15:0] : s[16] ? 16'h8000 : 16'h7fff;
	endfunction
	// the YMZ280B (Evil Night's sub board): its samples are in DDR3, its registers at 0x3e800000, the select at +0 and the data at +2, a byte in bits 15:8 of a 16-bit access,
	// as the game makes them (MAME's unit mask allows the byte lanes of any size)
	logic [7:0]  ymz_ext, ymz_st;
	logic signed [15:0] ymz_l, ymz_r;
	wire         ymz_wr = u_req && u_we && u_ymz;
	wire         ymz_rd = u_req && !u_we && u_ymz;
	m2_ymz280b ymz
	(
		.clk, .rst, .tick(dac_n == 11'd755 || dac_tick),
		.sel_we(ymz_wr && (u_size == 4'd4 || !u_pa[1])), .sel_d(u_size == 4'd4 ? u_wdata[31:24] : u_size == 4'd2 ? u_wdata[15:8] : u_wdata[7:0]),
		.dat_we(ymz_wr && (u_size == 4'd4 || u_pa[1])), .dat_d(u_size == 4'd1 ? u_wdata[7:0] : u_wdata[15:8]),
		.ext_rd(ymz_rd && !u_pa[1]), .st_rd(ymz_rd && (u_pa[1] || u_size == 4'd4)), .ext_q(ymz_ext), .st_q(ymz_st),
		.m_rd(ymz_m_rd), .m_a(ymz_rom_a), .m_busy(ymz_m_busy), .m_ready(ymz_m_ready), .m_dout(ddr_dout),
		.out_l(ymz_l), .out_r(ymz_r), .rnd_done(), .rnd_l(), .rnd_r()
	);
	always_ff @(posedge clk)
	begin
		cdv_l <= $signed(cda_l) * $signed({1'b0, cd_vol_l});
		cdv_r <= $signed(cda_r) * $signed({1'b0, cd_vol_r});
		mix0_l <= mix(dac_l, cdv_l[23:9]);
		mix0_r <= mix(dac_r, cdv_r[23:9]);
		// on the 44.1 kHz tick only: the YMZ280B's value changes when its round ends, which is later or sooner as DDR3 answers, and
		// MiSTer's audio filter, running far faster than 44.1 kHz, hears that wander as static under every sound
		if (dac_tick)
		begin
			audio_l <= mix_ymz(mix0_l, ymz_l);
			audio_r <= mix_ymz(mix0_r, ymz_r);
		end
	end
	m2_atapi cd
	(
		.clk, .rst,
		.a(u_pa[4:1]), .re(u_req && !u_we && u_ata), .we(u_req && u_we && u_ata), .wd(u_wdata[15:0]), .rd(atapi_rd), .intrq(cd_int),
		.ata_rd(cd_rd), .ata_valid(cd_valid), .ata_d(cd_d),
		.m_rd(ata_m_rd), .m_a(ata_m_a), .m_busy(ata_m_busy), .m_ready(ata_m_ready), .m_dout(ddr_dout),
		.play(cd_play), .play_stop(cd_stop), .play_lba(cd_lba), .play_len(cd_len), .pos(cd_pos), .playing(cd_playing), .finished(cd_finished),
		.paused(cd_paused), .vol_l(cd_vol_l), .vol_r(cd_vol_r)
	);
	// the M48T58: 8 KB, a byte in bits 15:8 of each 16-bit address. Read from the address coming up, as the DSP's are. Its clock doesn't run: its
	// registers read as the memory they're in
	logic [7:0]  tk_q;
	wire         tk_ld = ld_wr && ld_sel == 3'd3 && !ld_addr[13];
	wire         tk_we = u_req && u_we && u_tk;
	ppc_ram #(.W(8), .AW(13)) tk
	(
		.clk, .we(tk_ld || tk_we), .wa(tk_ld ? ld_addr[12:0] : u_pa[13:1]), .wd(tk_ld ? ld_data : u_wdata[15:8]),
		.ra(c_u_pa[n_s][13:1]), .rd(tk_q)
	);
	m2_kio kio
	(
		.clk, .rst,
		.a(u_pa[23:1]), .we(u_req && u_we && u_kio), .wd(u_wdata[15:0]), .rd(kio_rd),
		.ata_int(cd_int), .in_p1, .in_dsw, .in_p4, .in_p6, .in_p5, .gun_x, .gun_y,
		.ee_wr(ld_wr && ld_sel == 3'd2), .ee_a(ld_addr[6:0]), .ee_d(ld_data), .ee_ua, .ee_ud, .ee_chg
	);

	// the stubs' compares a clock early, on the address the choice takes (s_hit: the entry with u_pa's word), with the write
	// of the clock in them (the stubs' words are written by u_req's access, to entry s_k): from u_pa through the compares to
	// the words was a long path. An address is in one entry at most
	logic [NS-1:0] s_hit;
	logic [3:0]  s_k;
	wire         s_wr = u_req && u_we && !(u_cde || u_bda || u_kio || u_ata || u_dsp || u_ymz);
	wire  [31:2] s_na = c_u_pa[n_s][31:2];
	always_comb
	begin
		s_k = s_next;
		for (int i = NS - 1; i >= 0; i--) if (s_hit[i]) s_k = 4'(i);
	end
	always_ff @(posedge clk)
		for (int i = 0; i < NS; i++)
			s_hit[i] <= !rst && (s_wr && s_k == 4'(i) ? u_pa[31:2] == s_na : s_used[i] && sa[i][31:2] == s_na);
	// a write's word, the entry's with the access's bytes in it, apart from the read's (whose choice of the devices' words
	// was in the write's path; no read of a device's address takes an entry's word, so what one holds for TE is unseen)
	logic [31:0] s_w;
	always_comb
	begin
		s_w = 32'h0;
		for (int i = 0; i < NS; i++) s_w = s_w | (s_hit[i] ? sv[i] : 32'h0);
		for (int j = 0; j < 4; j++)
			if (4'(j) < u_size && 32'(u_pa[1:0]) + j < 4)
				s_w[8 * (3 - (32'(u_pa[1:0]) + j)) +: 8] = u_wdata[8 * (32'(u_size) - 1 - j) +: 8];
	end
`ifdef VERILATOR
	// (the compares as they were, on u_pa)
	always_ff @(posedge clk)
		if (!rst && u_req)
		begin
			logic oh;
			logic [3:0] ok;
			oh = 1'b0; ok = s_next;
			for (int i = 0; i < NS; i++)
				if (s_used[i] && sa[i] == {u_pa[31:2], 2'b00} && !oh) begin oh = 1'b1; ok = 4'(i); end
			if (oh != (s_hit != '0) || ok != s_k) $display("STUB hit wrong %08x", u_pa);
		end
`endif

	always_ff @(posedge clk)
		if (a_req) u_rdata <= a_we ? 64'h0 : rd_bytes({a_w[7:0], a_w[15:8], a_w[23:16], a_w[31:24], 32'h0} >> 32, {1'b0, a_off}, a_size);

	always_ff @(posedge clk)
	begin
		if (rst)
		begin
			s_used <= 16'h0000; s_next <= 4'd0;
			st_ndev <= 32'h0; st_dev_a <= 32'h0; st_dev_d <= 32'h0; st_dev_w <= 1'b0;
		end
		else if (u_req)
		begin
			// the 32-bit word at the address (an access inside it, in its bytes)
			logic hit;
			logic [3:0] k;
			logic [31:0] w, fv;
			hit = s_hit != '0; k = s_k; w = 32'h0;
			for (int i = 0; i < NS; i++) w = w | (s_hit[i] ? sv[i] : 32'h0);
			if (u_cde) w = cde_rd;
			if (u_te) w = te_rd;
			else if (u_dsp) w = dsp_rd;
			else if (u_bda) w = bda_rd;
			if (u_kio) w = {2{kio_rd}};
			if (u_ata) w = {2{atapi_rd}};
			if (u_tk) w = {2{tk_q, 8'h00}};
			if (u_ymz) w = {ymz_ext, 8'h00, ymz_st, 8'h00};
			if (!u_we && fixed_rd(u_pa[31:2], u_s, fv)) w = fv;
			if (u_we && (u_cde || u_bda || u_kio || u_ata || u_dsp || u_tk || u_ymz)) a_w <= 32'h0;
			else if (u_we)
			begin
				sa[k] <= {u_pa[31:2], 2'b00};
				sv[k] <= s_w;
				s_used[k] <= 1'b1;
				if (!hit) s_next <= s_next + 4'd1;
				a_w <= 32'h0;
			end
			else a_w <= w;
			a_we <= u_we; a_off <= u_pa[1:0]; a_size <= u_size;
			st_ndev <= st_ndev + 32'd1;
			st_dev_a <= u_pa;
			st_dev_w <= u_we;
			st_dev_d <= u_we ? u_wdata[31:0] : w;
		end
	end
`ifdef M2_PROF
	// a frame's worth of clocks at a time: the Triangle Engine, each CPU, the bus
	longint p_n, p_te, p_tewait, p_lists, p_go[0:7], p_ddrb;
	longint p_ret[0:1], p_il[0:1], p_dl[0:1], p_wf[0:1], p_dr[0:1], p_wn[0:1];
	logic   p_te1;
	always_ff @(posedge clk)
	begin
		p_te1 <= te.busy;
		p_n <= p_n + 1;
		p_te <= p_te + longint'(te.busy);
		p_tewait <= p_tewait + longint'((te_m_rd || te_m_we) && te_m_busy);
		p_lists <= p_lists + longint'(te.busy && !p_te1);
		p_ddrb <= p_ddrb + longint'(ddr_busy);
		if (bus.took) p_go[bus.who] <= p_go[bus.who] + 1;
		for (int j = 0; j < 2; j++)
		begin
			p_ret[j] <= p_ret[j] + longint'(c_ret[j]) + longint'(c_ret[j] && c_ret2[j]);
		end
		p_il[0] <= p_il[0] + longint'(g_cpu[0].cache.i_st != 0);
		p_il[1] <= p_il[1] + longint'(g_cpu[1].cache.i_st != 0);
		p_dl[0] <= p_dl[0] + longint'(g_cpu[0].cache.d_st == 3);
		p_dl[1] <= p_dl[1] + longint'(g_cpu[1].cache.d_st == 3);
		p_wf[0] <= p_wf[0] + longint'(g_cpu[0].cache.d_st == 2);
		p_wf[1] <= p_wf[1] + longint'(g_cpu[1].cache.d_st == 2);
		p_dr[0] <= p_dr[0] + longint'(g_cpu[0].cache.d_st == 5 || g_cpu[0].cache.d_st == 6);
		p_dr[1] <= p_dr[1] + longint'(g_cpu[1].cache.d_st == 5 || g_cpu[1].cache.d_st == 6);
		p_wn[0] <= p_wn[0] + longint'(g_cpu[0].cache.w_push);
		p_wn[1] <= p_wn[1] + longint'(g_cpu[1].cache.w_push);
		if (rst || p_n == 1122000)
		begin
			if (!rst) $display("PROF te %0d wait %0d lists %0d | go c0 %0d c1 %0d dma %0d ata %0d vdu %0d te %0d dsp %0d | ddrb %0d | p1 ret %0d il %0d dl %0d wf %0d dr %0d wn %0d | p2 ret %0d il %0d dl %0d wf %0d dr %0d wn %0d",
				p_te, p_tewait, p_lists, p_go[0], p_go[1], p_go[2], p_go[3], p_go[4], p_go[5], p_go[6], p_ddrb,
				p_ret[0], p_il[0], p_dl[0], p_wf[0], p_dr[0], p_wn[0], p_ret[1], p_il[1], p_dl[1], p_wf[1], p_dr[1], p_wn[1]);
			p_n <= 0; p_te <= 0; p_tewait <= 0; p_lists <= 0; p_ddrb <= 0;
			for (int j = 0; j < 8; j++) p_go[j] <= 0;
			for (int j = 0; j < 2; j++) begin p_ret[j] <= 0; p_il[j] <= 0; p_dl[j] <= 0; p_wf[j] <= 0; p_dr[j] <= 0; p_wn[j] <= 0; end
		end
	end
`endif
endmodule
