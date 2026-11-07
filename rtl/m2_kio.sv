// m2_kio: Konami's I/O on the BioBus, what MAME 0.289 makes of it (konamim2.cpp): the inputs (0x37e00000, IO1), the 003461's serial
// data register (0x37c0001e), the gun ports (0x37a00020, nothing there) and the 93C46 EEPROM (0x37400000). All 16-bit accesses.
//
// The EEPROM's contents come with the download (ee_*), the first address's two bytes first, the first of them bits 15:8; Main reads them back
// the same way (ee_u*) to save them.
`default_nettype none
module m2_kio (
	input  logic        clk,
	input  logic        rst,

	input  logic [23:1] a,              // of 0x37xxxxxx
	input  logic        we,
	input  logic [15:0] wd,
	output logic [15:0] rd,

	input  logic        ata_int,
	input  logic [7:0]  in_p1,          // IO1 3 (bits 7:0): coins, service, active low
	input  logic [7:0]  in_dsw,         // IO1 2: the DIP switches
	input  logic [15:0] in_p4,          // IO1 4: players, active low
	input  logic [15:0] in_p6,          // IO1 6: the service switch, active low

	input  logic        ee_wr,
	input  logic [6:0]  ee_a,
	input  logic [7:0]  ee_d,
	input  logic [6:0]  ee_ua,          // the upload, Main saving it: a byte, in the download's order, the clock after its address
	output logic [7:0]  ee_ud,
	output logic        ee_chg          // a clock: the game wrote it, so Main saves it when the OSD next opens
);
	// ---- the EEPROM ------------------------------------------------------------------------------------------------------
	typedef enum logic [2:0] { E_IDLE, E_CMD, E_READ, E_WRITE, E_END } est_t;
	est_t        e_st;
	logic        cs, sk, di, ee_do, sk_q, ewen;
	logic [3:0]  e_n;
	logic [6:0]  e_cmd;
	logic [15:0] e_sr;
	logic [15:0] e_q, e_wd;
	logic [5:0]  e_ra;
	logic        e_we;
	logic [5:0]  e_wa;
	logic [7:0]  e_hi;

	ppc_ram_s #(.W(16), .AW(6)) mem (.clk, .we(e_we || (ee_wr && ee_a[0])), .wa(e_we ? e_wa : ee_a[6:1]), .wd(e_we ? e_wd : {e_hi, ee_d}), .ra(e_ra), .rd(e_q));
	// a copy for the upload, so it never gets in the way of the game's reads
	logic [15:0] u_q;
	logic        u_lo;
	ppc_ram_s #(.W(16), .AW(6)) umem (.clk, .we(e_we || (ee_wr && ee_a[0])), .wa(e_we ? e_wa : ee_a[6:1]), .wd(e_we ? e_wd : {e_hi, ee_d}), .ra(ee_ua[6:1]), .rd(u_q));
	always_ff @(posedge clk) u_lo <= ee_ua[0];
	assign ee_ud = u_lo ? u_q[7:0] : u_q[15:8];
	assign ee_chg = e_we;

	wire sk_up = sk && !sk_q;
	logic [1:0] e_load;                 // (the memory's answer is two clocks from the address)
	always_ff @(posedge clk)
	begin
		sk_q <= sk;
		e_we <= 1'b0;
		e_load <= {e_load[0], 1'b0};
		if (ee_wr && !ee_a[0]) e_hi <= ee_d;
		if (rst)
		begin
			e_st <= E_IDLE; ee_do <= 1'b1; ewen <= 1'b0; cs <= 1'b0; sk <= 1'b0; di <= 1'b0;
		end
		else
		begin
			if (e_load[1]) e_sr <= e_q;
			if (!cs) begin e_st <= E_IDLE; ee_do <= 1'b1; end
			else if (sk_up)
				case (e_st)
					E_IDLE:
						if (di) begin e_st <= E_CMD; e_n <= 4'd0; end
					E_CMD:
					begin
						logic [7:0] c;
						c = {e_cmd[6:0], di};
						e_cmd <= c[6:0];
						e_n <= e_n + 4'd1;
						if (e_n == 4'd7)
						begin
							e_n <= 4'd0;
							e_ra <= c[5:0];
							e_wa <= c[5:0];
							case (c[7:6])
								2'b10: begin e_st <= E_READ; ee_do <= 1'b0; e_load[0] <= 1'b1; end
								2'b01: e_st <= E_WRITE;
								2'b11:
								begin
									if (ewen) begin e_we <= 1'b1; e_wd <= 16'hffff; end
									e_st <= E_END;
								end
								default:
								begin
									if (c[5:4] == 2'b11) ewen <= 1'b1;
									if (c[5:4] == 2'b00) ewen <= 1'b0;
									e_st <= E_END;
								end
							endcase
						end
					end
					E_READ:
					begin
						ee_do <= e_sr[15];
						e_sr <= {e_sr[14:0], 1'b0};
					end
					E_WRITE:
					begin
						e_wd <= {e_wd[14:0], di};
						e_n <= e_n + 4'd1;
						if (e_n == 4'd15)
						begin
							if (ewen) e_we <= 1'b1;
							e_st <= E_END;
						end
					end
					default: ;
				endcase

			if (we && a[23:16] == 8'h40 && a[3:1] == 3'd0) begin cs <= wd[7]; sk <= wd[6]; di <= wd[5]; end
		end
	end

	// ---- the rest -------------------------------------------------------------------------------------------------------
	logic [15:0] sio;
	always_ff @(posedge clk)
		if (rst) sio <= 16'h0;
		else if (we && a[23:16] == 8'hc0 && a[15:4] == 12'h001 && a[3:1] == 3'd7) sio <= wd;

	always_comb
	begin
		rd = 16'h0;
		if (a[23:16] == 8'he0 && a[15:4] == 12'h000)
			case (a[3:1])
				3'd2: rd = {8'h0, in_dsw};
				3'd3: rd = {2'b00, ata_int, 2'b11, 1'b1, 1'b0, ee_do, in_p1};
				3'd4: rd = in_p4;
				3'd6: rd = in_p6;
				default: rd = 16'hffff;
			endcase
		else if (a[23:16] == 8'hc0 && a[15:4] == 12'h001 && a[3:1] == 3'd7) rd = sio;
		else if (a[23:16] == 8'ha0 && a[15:4] == 12'h002)
			rd = a[3:1] == 3'd3 ? 16'hffff : 16'h0;
		else if (a[23:16] == 8'ha0 && a[15:4] == 12'h003 && a[3:1] == 3'd0) rd = 16'hffff;
	end
endmodule
