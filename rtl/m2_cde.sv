// m2_cde: the CDE, what MAME 0.289 makes of it (3dom2.cpp): its registers (slot 4, 0x04000000; +0x400 clears the bits given,
// on the ones that have it), and its two DMA channels, from the BioBus to memory.
//
// A DMA moves bytes in address order, 8 bytes at most to a memory write. Its source is memory (the ROM), or the ATA data port at
// 0x3f000000 (16 bits a read, the first byte in bits 15:8), whichever slot the address says. The registers it was started with
// count down as it goes.
`default_nettype none
module m2_cde #(
	parameter int ID_READY = 16667      // clocks from UNIQ_ID_CMD to its interrupt (250 us)
) (
	input  logic        clk,
	input  logic        rst,

	// the registers: a read's value in the clock of its address, a write in that clock
	input  logic [15:2] a,
	input  logic        we,
	input  logic [31:0] wd,
	output logic [31:0] rd,
	output logic        soft_rst,       // RESET_CNTL bit 0: a pulse, the CPU's
	output logic        intr,

	// memory: as ppc_cache's port, one word a request; dma_a the address on the bus
	output logic        dma_rd,
	output logic        dma_we,
	output logic [31:3] dma_a,
	output logic [63:0] dma_wd,
	output logic [7:0]  dma_be,
	input  logic        dma_busy,
	input  logic        dma_ready,
	input  logic [63:0] dma_dout,

	// the ATA data port: ata_rd a clock, ata_valid with its value on a later one
	output logic        ata_rd,
	input  logic        ata_valid,
	input  logic [15:0] ata_d
);
	localparam logic [31:0] I_SDBG_WRT_DONE = 32'h10000000, I_ID_READY = 32'h00100000, I_DMA2_DONE = 32'h00000100,
		I_DMA1_DONE = 32'h00000080;
	localparam logic [31:0] C_RESET = 32'h200, C_CURR_VALID = 32'h80, C_DIRECTION = 32'h400;

	logic [31:0] sdbg_cntl, int_status, int_enable, visa_dis;
	logic        bblock_en;
	logic [15:11] dev_setup [0:7];      // (what a DMA needs of them)
	logic [31:0] dma_cntl [0:1];
	logic [31:0] dma_cbad [0:1];
	logic [31:0] dma_cpad [0:1];
	logic [31:0] dma_ccnt [0:1];
	logic [14:0] id_n;
	logic        id_run;

	assign intr = (int_status & int_enable) != 32'h0;

	wire  [15:0] ba = {a, 2'b00};
	wire         clr = ba[10];
	wire  [15:0] wa = {ba[15:11], 1'b0, ba[9:0]};
	wire         wch = ba[5];
	function automatic logic [31:0] cw(input logic [31:0] r, input logic [31:0] d, input logic c);
		return c ? r & ~d : d;
	endfunction
	function automatic logic [31:0] cs(input logic [31:0] r, input logic [31:0] d, input logic c);
		return c ? r & ~d : r | d;
	endfunction

	always_comb
		case (ba)
			16'h0000: rd = 32'h00010000;            // DEVICE_ID
			16'h000c: rd = sdbg_cntl;
			16'h0018: rd = int_status;
			16'h001c: rd = int_enable;
			16'h0204: rd = 32'h00000080;            // BBLOCK
			16'h0208: rd = {31'h0, bblock_en};
			16'h0224: rd = 32'hffffffff;            // UNIQ_ID_RD
			16'h0280: rd = 32'h63659000;            // SYSTEM_CONF: SYSCONFIG_ARCADE
			16'h0284: rd = visa_dis;
			16'h02a0: rd = 32'h00000020;            // MICRO_STATUS
			16'h1000: rd = dma_cntl[0];
			16'h1020: rd = dma_cntl[1];
			default:  rd = 32'h0;
		endcase

	// ---- a DMA ----------------------------------------------------------------------------------------------------------
	typedef enum logic [3:0] { X_IDLE, X_BYTE, X_RD, X_RDW, X_ATA, X_ATAW, X_WR, X_END } xst_t;
	xst_t        x_st;
	logic        x_ch;
	logic [31:0] x_src, x_dst;
	logic [31:0] x_cnt;
	logic        x_io, x_ata;
	logic [63:0] s_buf;
	logic [31:3] s_tag;
	logic        s_ok;
	logic [15:0] a_buf;
	logic        a_ok, a_lo;
	logic [63:0] d_buf;
	logic [7:0]  d_be;
	logic [31:3] d_tag;
	logic        x_last;                // the write is the last

	wire         x_start0 = dma_cntl[0][7];
	wire         x_start1 = dma_cntl[1][7];
	wire [7:0]   s_byte = s_buf[8 * x_src[2:0] +: 8];
	wire         d_have = d_be != 8'h0;

	assign dma_rd = x_st == X_RD;
	assign dma_we = x_st == X_WR;
	assign dma_a = x_st == X_WR ? d_tag : x_src[31:3];
	assign dma_wd = d_buf;
	assign dma_be = d_be;
	assign ata_rd = x_st == X_ATA;

	wire [7:0] x_byte = x_ata ? (a_lo ? a_buf[7:0] : a_buf[15:8]) : s_byte;

	always_ff @(posedge clk)
	begin
		soft_rst <= 1'b0;
		if (rst)
		begin
			sdbg_cntl <= 32'h0; int_status <= 32'h0; int_enable <= 32'h0; visa_dis <= 32'h0;
			bblock_en <= 1'b1;
			dma_cntl[0] <= 32'h0; dma_cntl[1] <= 32'h0;
			id_run <= 1'b0;
			x_st <= X_IDLE;
		end
		else
		begin
			// UNIQ_ID_CMD's wait
			if (id_run)
			begin
				if (id_n == 15'd0) begin id_run <= 1'b0; int_status <= int_status | I_ID_READY; end
				id_n <= id_n - 15'd1;
			end

			case (x_st)
				X_IDLE:
					if (x_start0 || x_start1)
					begin
						logic ch;
						ch = !x_start0;
						x_ch <= ch;
						x_src <= dma_cbad[ch]; x_dst <= dma_cpad[ch]; x_cnt <= dma_ccnt[ch];
						x_ata <= dma_cbad[ch][31:24] == 8'h3f;
						x_io <= dev_setup[dma_cbad[ch][28:26]][15:13] != 3'd0;
						s_ok <= 1'b0; a_ok <= 1'b0; a_lo <= 1'b0; d_be <= 8'h0;
						x_st <= (dma_ccnt[ch] == 32'h0 || (dma_cntl[ch] & C_DIRECTION) != 32'h0) ? X_END : X_BYTE;
					end
				X_BYTE:
					if (x_cnt == 32'h0)
					begin
						if (d_have) begin x_last <= 1'b1; x_st <= X_WR; end
						else x_st <= X_END;
					end
					else if (d_have && d_tag != x_dst[31:3]) begin x_last <= 1'b0; x_st <= X_WR; end
					else if (x_ata && !a_ok) x_st <= X_ATA;
					else if (!x_ata && !(s_ok && s_tag == x_src[31:3])) x_st <= X_RD;
					else
					begin
						d_buf[8 * x_dst[2:0] +: 8] <= x_byte;
						d_be[x_dst[2:0]] <= 1'b1;
						d_tag <= x_dst[31:3];
						x_dst <= x_dst + 32'd1;
						x_cnt <= x_cnt - 32'd1;
						if (x_ata)
						begin
							a_lo <= !a_lo;
							if (a_lo) a_ok <= 1'b0;
						end
						else x_src <= x_src + (x_io ? 32'd0 : 32'd1);
					end
				X_RD: if (!dma_busy) x_st <= X_RDW;
				X_RDW:
					if (dma_ready)
					begin
						s_buf <= dma_dout; s_tag <= x_src[31:3]; s_ok <= 1'b1;
						x_st <= X_BYTE;
					end
				X_ATA: x_st <= X_ATAW;
				X_ATAW:
					if (ata_valid)
					begin
						a_buf <= ata_d; a_ok <= 1'b1;
						x_st <= X_BYTE;
					end
				X_WR:
					if (!dma_busy)
					begin
						d_be <= 8'h0;
						x_st <= x_last ? X_END : X_BYTE;
					end
				X_END:
				begin
					dma_cntl[x_ch] <= dma_cntl[x_ch] & ~C_CURR_VALID;
					dma_ccnt[x_ch] <= 32'h0;
					int_status <= int_status | (x_ch ? I_DMA2_DONE : I_DMA1_DONE);
					x_st <= X_IDLE;
				end
				default: x_st <= X_IDLE;
			endcase

			if (we)
			begin
				case (wa)
					16'h000c: sdbg_cntl <= cw(sdbg_cntl, wd, clr);
					16'h0014: int_status <= int_status | I_SDBG_WRT_DONE;
					16'h0018: int_status <= cw(int_status, wd, clr);
					16'h001c: int_enable <= cs(int_enable, wd, clr);
					16'h0020:
						if (wd[0])
						begin
							soft_rst <= 1'b1;
							bblock_en <= 1'b0;
						end
					16'h0220: begin id_run <= 1'b1; id_n <= 15'(ID_READY - 1); end
					16'h0284: visa_dis <= cw(visa_dis, wd, clr);
					16'h1000, 16'h1020:
					begin
						logic [31:0] nc;
						nc = cw(dma_cntl[wch], wd, clr);
						if ((dma_cntl[wch] & C_RESET) == 32'h0 && (nc & C_RESET) != 32'h0) nc = 32'h0;
						dma_cntl[wch] <= nc;
					end
					16'h1004, 16'h1024: dma_cbad[wch] <= cw(dma_cbad[wch], wd, clr);
					16'h1008, 16'h1028: dma_cpad[wch] <= cw(dma_cpad[wch], wd, clr);
					16'h100c, 16'h102c: dma_ccnt[wch] <= cw(dma_ccnt[wch], wd, clr);
					default:
						if (wa[15:6] == 10'h009 && !wa[2]) // 0x240-0x27c: DEVn_SETUP
						begin
							// verilator lint_off UNUSEDSIGNAL
							logic [31:0] ns;
							// verilator lint_on UNUSEDSIGNAL
							ns = cw({16'h0, dev_setup[wa[5:3]], 11'h0}, wd, clr);
							dev_setup[wa[5:3]] <= ns[15:11];
						end
				endcase
			end
		end
	end
endmodule
