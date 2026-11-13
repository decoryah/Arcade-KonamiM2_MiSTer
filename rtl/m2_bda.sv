// m2_bda: the BDA's registers that aren't a unit of their own yet, what MAME 0.289 makes of them (3dom2.cpp): the PowerBus
// controller and its interrupts (0x00010000), the memory controller (0x00020000), and the VDU's line and line interrupts
// (0x00030000). ppc1 takes the PowerBus interrupt; ppc2's comes from the memory controller's GPIO 3 (inverted), which is how ppc1
// starts it (konamim2.cpp).
//
// The line: the raster's, 262 a frame, MAME's VLOC ((line + 20) % 260) + 1; with arc (the arcade monitor's raster, 416 a frame,
// rtl/m2_vtiming.sv) ((line + 26) % 410) + 1, MAME's m_vstart and m_vtotal from set_arcres()'s visible area. +0x400 clears the
// bits given, on the VDU's and the PowerBus's registers that have it.
`default_nettype none
module m2_bda (
	input  logic        clk,
	input  logic        rst,
	input  logic        arc,            // the arcade monitor's raster, not the TV's
	input  logic [31:0] mcfg0,          // the memory controller's reset: the sizes of the RAM's two banks

	// the registers: a read's value in the clock of its address, a write in that clock
	input  logic [19:2] a,              // of 0x000xxxxx
	input  logic        we,
	input  logic [31:0] wd,
	output logic [31:0] rd,

	input  logic [8:0]  vpos,           // the raster's line, from 0 where it starts being shown (20)
	input  logic [31:0] lines,          // interrupt lines from elsewhere (level): the CDE's on EXTD4 (bit 3), and so on

	output logic        ppc1_int,
	output logic        ppc2_int,

	output logic [8:0]  line            // the video line, 0-261 (0-415 with arc)
);
	localparam int L_VINT1 = 23, L_VINT0 = 24;

	wire [19:0] ba = {a, 2'b00};
	wire        clr = ba[10];
	wire [19:0] wa = {ba[19:11], 1'b0, ba[9:0]};

	logic [31:0] pb_en, pb_st, mcfg, mref, vint;

	// ---- the line ------------------------------------------------------------------------------------------------------
	logic [8:0]  ln;
	wire [8:0]   vstart = arc ? 9'd26 : 9'd20;
	wire [8:0]   vtotal = arc ? 9'd410 : 9'd260;
	wire [8:0]   ln_nx = vpos + vstart;
	wire         ln_end = ln_nx != ln;
	function automatic logic [10:0] vl(input logic [8:0] l);
		logic [9:0] x;
		x = 10'(l) + 10'(vstart);
		x = x >= 10'(vtotal) ? x - 10'(vtotal) : x;
		return {1'b0, x} + 11'd1;
	endfunction
	always_ff @(posedge clk)
		ln <= ln_nx;
	assign line = ln;

	// (the last lines are the first ones over again to VLOC, and no interrupt: MAME's timers are for a line under 260, or 410)
	wire ln_ok = ln_end && ln_nx < vtotal;
	wire vhit0 = ln_ok && vl(ln_nx) == vint[30:20] && vint[30:20] != 11'd0;
	wire vhit1 = ln_ok && vl(ln_nx) == vint[14:4] && vint[14:4] != 11'd0;

	always_comb
	begin
		rd = 32'h0;
		case (ba)
			20'h10040: rd = pb_en;
			20'h10050: rd = pb_st | lines | (vint[31] ? 32'h1 << L_VINT0 : 32'h0) | (vint[15] ? 32'h1 << L_VINT1 : 32'h0);
			20'h20000: rd = mcfg;
			20'h20004: rd = mref;
			20'h30000: rd = {18'h0, vl(ln), 3'b000};
			20'h30004: rd = vint;
			default: ;
		endcase
	end

	assign ppc1_int = ((pb_st | lines | (vint[31] ? 32'h1 << L_VINT0 : 32'h0) | (vint[15] ? 32'h1 << L_VINT1 : 32'h0)) & pb_en) != 32'h0;

	always_ff @(posedge clk)
		if (rst)
		begin
			pb_en <= 32'h0; pb_st <= 32'h0;
			mcfg <= mcfg0; mref <= 32'h0;
			vint <= 32'h0;
			ppc2_int <= 1'b0;
		end
		else
		begin
			if (vhit0) vint[31] <= 1'b1;
			if (vhit1) vint[15] <= 1'b1;
			if (we)
				case (wa)
					20'h10040: pb_en <= clr ? pb_en & ~wd : pb_en | wd;
					20'h10060:
						if (clr) pb_st <= pb_st & ~wd;
						else if (wd == 32'h1) pb_st <= pb_st | wd;
					20'h20000: mcfg <= wd;
					20'h20004:
					begin
						mref <= wd;
						if (wd[23:22] != 2'b00) ppc2_int <= !wd[21];
					end
					20'h30004:
					begin
						vint <= clr ? vint & ~wd : wd;
						if (vhit0 && !(clr && wd[31])) vint[31] <= 1'b1;
						if (vhit1 && !(clr && wd[15])) vint[15] <= 1'b1;
					end
					default: ;
				endcase
		end
endmodule
