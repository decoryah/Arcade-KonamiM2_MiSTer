// A register file in RAM for rtl/ppc_pipe.sv: two write ports, each with its own bank (a copy per read port), and a
// live value table (the bank that wrote an entry last; w1 wins when both write it in a clock). NR read ports,
// registered: the address the clock before. What an entry written in that clock reads is either value (no_rw_check):
// the core forwards those writes itself.
`default_nettype none
module ppc_regs #(
	parameter int W = 32,               // bits an entry
	parameter int AW = 6,               // address bits
	parameter int NR = 3                // read ports
) (
	input  logic                   clk,
	input  logic                   we0,
	input  logic [AW-1:0]          wa0,
	input  logic [W-1:0]           wd0,
	input  logic                   we1,
	input  logic [AW-1:0]          wa1,
	input  logic [W-1:0]           wd1,
	input  logic [NR-1:0][AW-1:0]  ra,
	output logic [NR-1:0][W-1:0]   rd
);
	logic [(1 << AW) - 1:0] lvt;
	always_ff @(posedge clk)
	begin
		if (we0) lvt[wa0] <= 1'b0;
		if (we1) lvt[wa1] <= 1'b1;
	end

	genvar i;
	generate
	for (i = 0; i < NR; i++)
	begin : g_rd
		logic [W-1:0] q0, q1;
		logic sel;
		ppc_ram #(.W(W), .AW(AW)) b0 (.clk, .we(we0), .wa(wa0), .wd(wd0), .ra(ra[i]), .rd(q0));
		ppc_ram #(.W(W), .AW(AW)) b1 (.clk, .we(we1), .wa(wa1), .wd(wd1), .ra(ra[i]), .rd(q1));
		always_ff @(posedge clk) sel <= lvt[ra[i]];
		assign rd[i] = sel ? q1 : q0;
	end
	endgenerate
endmodule

// one bank's copy: a simple dual-port RAM, the read registered
module ppc_ram #(
	parameter int W = 32,
	parameter int AW = 6
) (
	input  logic          clk,
	input  logic          we,
	input  logic [AW-1:0] wa,
	input  logic [W-1:0]  wd,
	input  logic [AW-1:0] ra,
	output logic [W-1:0]  rd
);
	(* ramstyle = "no_rw_check" *) logic [W-1:0] mem [0:(1 << AW) - 1];
	always_ff @(posedge clk)
	begin
		if (we) mem[wa] <= wd;
		rd <= mem[ra];
	end
endmodule
