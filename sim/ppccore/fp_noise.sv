// The other CPU, as far as the shared float units (rtl/ppc_fpx.sv) go: random ops at random times, its results for nobody. The
// bench's CPU has to give the model's answers through it all.
`default_nettype none
module fp_noise (
	input  logic clk,
	input  logic rst,
	input  ppc_fpu_pkg::fp_res_t res,
	output ppc_fpu_pkg::fp_req_t req
);
	import ppc_fpu_pkg::*;

	logic [63:0] x = 64'h9e3779b97f4a7c15;
	always_ff @(posedge clk) x <= {x[62:0], x[63] ^ x[62] ^ x[60] ^ x[59]};

	// a burst of ops, then a while without
	logic [4:0] op;
	always_comb
		case (x[11:8])
			4'd0: op = F_ADD;
			4'd1: op = F_SUBS;
			4'd2: op = F_MUL;
			4'd3: op = F_MULS;
			4'd4: op = F_MADDS;
			4'd5: op = F_NMSUBS;
			4'd6: op = F_NMADD;
			4'd7: op = F_RSP;
			4'd8: op = F_CTIWZ;
			4'd9: op = F_MADD;
			4'd10: op = F_ADDS;
			4'd11: op = F_DIVS;
			4'd12: op = F_RSQRTE;
			default: op = F_MADDS;
		endcase
	wire slow = op == F_DIVS || op == F_RSQRTE;

	logic ok, go, f_mine;
	logic [2:0] bw, fe, fw;
	// verilator lint_off PINCONNECTEMPTY
	ppc_fps_ctl ctl (
		.clk, .rst, .allow(res.allow[1]), .res_a(res.res_a), .res_s(res.res_s), .res_w(res.res_w),
		.issue(go && !slow), .pk(fpk_s(op)), .rd(x[16:12]), .ra(x[56:52]), .rb(x[21:17]), .rc(x[61:57]), .ok, .dok(), .busy(), .bw, .fe, .fw, .pe(), .pw(), .pn(),
		.lb()
	);
	// verilator lint_on PINCONNECTEMPTY
	wire busy_burst = x[40:38] != 3'd0;
	assign go = !rst && busy_burst && x[4] && (slow ? res.allow[1] && res.ffree && x[7:5] == 3'd0 && !f_mine : ok);
	always_ff @(posedge clk)
		if (rst) f_mine <= 1'b0;
		else if (go && slow) f_mine <= 1'b1;
		else if (res.fdone && res.fcpu) f_mine <= 1'b0;

	// (operands from a table of a few, to go through the units' cases)
	logic [31:0] va, vb;
	always_comb
	begin
		case (x[23:22])
			2'd0: va = 32'h3fc00000;
			2'd1: va = x[55:24];
			2'd2: va = 32'h00000001;
			default: va = {x[19:0], x[63:52]};
		endcase
		case (x[25:24])
			2'd0: vb = 32'hc0000000;
			2'd1: vb = {x[15:0], x[63:48]};
			2'd2: vb = 32'h7fc00000;
			default: vb = {x[3:0], x[63:36]};
		endcase
	end
	assign req = '{go && !slow, go && slow, op, x[27:26], va, vb, {va[15:0], vb[31:16]}, x[16:12], bw, fe, fw,
		!rst && busy_burst && x[4]};
endmodule
