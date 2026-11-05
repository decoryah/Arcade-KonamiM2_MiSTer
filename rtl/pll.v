// PLL: 50 MHz reference in, 66.67 MHz for the CPUs and the BDA, 133.33 MHz for memory and the same shifted for an SDRAM
// chip's clock pin (pll_0002.v).
`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk   66.67 MHz, the CPUs and the BDA
		output wire  outclk_1, // outclk1.clk   133.33 MHz, memory
		output wire  outclk_2, // outclk2.clk   133.33 MHz, shifted: SDRAM_CLK
		output wire  locked    //  locked.export
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.locked   (locked)
	);

endmodule
