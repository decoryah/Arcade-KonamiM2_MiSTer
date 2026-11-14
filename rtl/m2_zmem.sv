// m2_zmem: the Triangle Engine's Z buffer in the board's SDRAM (Z_SDRAM), a 32-byte line at a time (te_zc, the colour cache's lines for Z).
//
//   on clk (66.67 MHz)       a queue of 16 lines to write, and a line to read, which goes first unless the queue has its line. One at a
//                            time to the SDRAM: the line's address and the queue's head held for it until it's done
//   on clk_mem (133.33 MHz)  the SDRAM: the pin-level ways of the Gaelco 3D core's sdram_ctrl (single-word commands, the pins' registers in the
//                            I/O cells, the chip clocked by the PLL's shifted output, the read data taken a fixed number of clocks after its
//                            READ), at CL3. A line is 16 READs or WRITEs a clock apart (byte masks on DQM) in its row, which stays open for
//                            the next (a 1 KB row holds 32 lines, and the pixels go along them): 18 to 24 clocks, 6 more for another row
//                            of the bank. Refresh every 7.5 us, the banks closed for it.
//
// clk_mem is twice clk and in phase with it (one PLL), so what crosses is timed as it is: a toggle each way, and what goes with it held.
// Address: the byte address's 24:12 the row, 11:10 the bank, 9:1 the column (32 MB; a 64 or 128 MB module's first 32 MB).
`default_nettype none

module m2_zmem #(
	parameter int POWERUP = 33400       // clk_mem clocks the chip's given at power-up before its first command: 250 us
) (
	input  logic         clk,
	input  logic         rst,
	input  logic         clk_mem,
	input  logic         rd_late,        // the read data a clock later (CL3 + 2 clocks after the READ, not + 1)
	output logic         ready,          // (clk_mem) the chip's set up

	input  logic         l_rd,           // a line read: one at a time, taken when l_rbusy is low; l_ready (a clock) with its data
	input  logic [24:5]  l_ra,
	output logic         l_rbusy,
	output logic         l_ready,
	output logic [255:0] l_rdata,
	input  logic         l_we,           // a line written, taken unless the queue's full
	input  logic [24:5]  l_wa,
	input  logic [255:0] l_wdata,
	input  logic [31:0]  l_wbe,
	output logic         l_wfull,
	output logic         idle,           // nothing queued or under way

	output logic [12:0]  sd_a,
	output logic [1:0]   sd_ba,
	output logic [1:0]   sd_dqm,         // {DQMH, DQML}
	output logic         sd_nras,
	output logic         sd_ncas,
	output logic         sd_nwe,
	output logic [15:0]  sd_dq_o,
	output logic         sd_dq_oe,
	input  logic [15:0]  sd_dq_i
);
	// ---- clk: the queue ------------------------------------------------------------------------------------------------
	logic [3:0]   q_wp, q_rp;
	logic [4:0]   q_n;
	logic         q_old;                // the head's been in the RAM a clock: its read's good
	logic [15:0]  q_v;
	logic [24:5]  q_a [0:15];
	logic [287:0] q_m;
	assign l_wfull = q_n[4];
	wire          push = l_we && !l_wfull;
	te_ram #(.W(288), .AW(4)) q_ram (.clk, .we(push), .wa(q_wp), .wd({l_wbe, l_wdata}), .re(1'b1), .ra(q_rp), .rd(q_m));
	// a read waits for any of its line's writes still queued (one under way is done first)
	logic         r_pend, r_on;
	logic [24:5]  r_a;
	logic [15:0]  r_m;
	wire  [24:5]  r_ax = r_pend ? r_a : l_ra;   // (a read goes in the clock it's asked for, if it can)
	always_comb for (int i = 0; i < 16; i++) r_m[i] = q_v[i] && q_a[i] == r_ax;
	assign l_rbusy = r_pend;

	// what's under way: o_t toggled for each, a write's line taken out of the queue (o_d); z_d (clk_mem) toggled back when it's done, a write's
	// once clk_mem's side has taken its line. The next goes in the clock that's seen
	logic         o_t, o_wr, o_on;
	logic [24:5]  o_a;
	logic [287:0] o_d;
	logic         z_d;
	logic [255:0] z_rdata;
	wire          o_done = o_on && z_d == o_t;
	wire          o_free = !o_on || o_done;
	wire          o_rd = o_free && (r_pend ? !r_on : l_rd) && r_m == 16'h0;
	wire          o_wq = o_free && !o_rd && q_old;
	assign l_rdata = z_rdata;

	always_ff @(posedge clk)
	begin
		l_ready <= 1'b0;
		if (rst)
		begin
			q_wp <= 4'd0; q_rp <= 4'd0; q_n <= 5'd0; q_v <= 16'h0; q_old <= 1'b0;
			r_pend <= 1'b0; r_on <= 1'b0; o_on <= 1'b0; o_t <= z_d;
		end
		else
		begin
			if (push) begin q_a[q_wp] <= l_wa; q_v[q_wp] <= 1'b1; q_wp <= q_wp + 4'd1; end
			if (l_rd && !r_pend) begin r_pend <= 1'b1; r_a <= l_ra; end
			q_old <= q_n != 5'd0 && !o_wq;
			q_n <= q_n + 5'(push) - 5'(o_wq);
			if (o_done)
			begin
				o_on <= 1'b0;
				if (!o_wr) begin r_pend <= 1'b0; r_on <= 1'b0; l_ready <= 1'b1; end
			end
			if (o_rd) begin o_on <= 1'b1; o_t <= !o_t; o_wr <= 1'b0; o_a <= r_ax; r_on <= 1'b1; end
			if (o_wq)
			begin
				o_on <= 1'b1; o_t <= !o_t; o_wr <= 1'b1; o_a <= q_a[q_rp]; o_d <= q_m;
				q_v[q_rp] <= 1'b0; q_rp <= q_rp + 4'd1;
			end
		end
	end

	// ---- clk_mem: the SDRAM --------------------------------------------------------------------------------------------
	localparam logic [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100, C_PRE = 3'b010, C_REF = 3'b001, C_MODE = 3'b000;
	localparam logic [12:0] MODE = 13'b000_0_00_011_0_000;  // burst 1, sequential, CL3, burst writes as programmed
	localparam int REFRESH = 1000;                          // clocks between refreshes: 7.5 us (8192 rows in 64 ms is 7.8 us)
	typedef enum logic [2:0] { S_INIT, S_IDLE, S_PRE, S_ACT, S_RCD, S_CMD, S_TAIL, S_REF } sst_t;
	sst_t         s_st;
	logic [2:0]   cmd = C_NOP;          // (NOP from power-up)
	assign {sd_nras, sd_ncas, sd_nwe} = cmd;
	// what goes to the pins the next clock: the pins' registers (in the I/O cells) have nothing but these before them
	logic [2:0]   n_cmd = C_NOP;
	logic [12:0]  n_a;
	logic [1:0]   n_ba, n_dqm;
	logic [15:0]  n_dq;
	logic         n_oe;
	always_ff @(posedge clk_mem) begin cmd <= n_cmd; sd_a <= n_a; sd_ba <= n_ba; sd_dqm <= n_dqm; sd_dq_o <= n_dq; sd_dq_oe <= n_oe; end
	logic [15:0]  s_n;                  // a wait
	logic [10:0]  s_ref;
	logic [3:0]   op_v;                 // the banks' open rows
	logic [12:0]  op_row [0:3];
	logic         s_rf;                 // the precharge's for a refresh
	logic         s_due;
	logic [3:0]   s_w;                  // the word
	logic         s_t, s_wr;            // the last o_t taken
	logic [24:5]  s_a;
	logic [287:0] s_d;                  // the line written
	// (the next in the row just opened, after a write: straight on)
	wire          s_next = !s_due && o_t != s_t && op_v[o_a[11:10]] && op_row[o_a[11:10]] == o_a[24:12];
	// (for the bench: clk_mem's side's state read on clk)
	assign idle = !o_on && !r_pend && q_n == 5'd0 && s_st == S_IDLE && s_t == o_t;
	logic [15:0]  dq_in;
	logic [6:0]   cap_v;
	logic [3:0]   cap_w [0:6];
	logic         rst_m, rst_m1;        // the reset, for clk_mem
	always_ff @(posedge clk_mem) begin rst_m1 <= rst; rst_m <= rst_m1; end
	always_ff @(posedge clk_mem)
	begin
		n_cmd <= C_NOP;
		n_oe <= 1'b0;
		n_dqm <= 2'b00;
		s_ref <= s_ref + 11'd1;
		s_due <= s_ref >= 11'(REFRESH);
		// the read data: the pins' register every clock; a READ's word index behind it, by the pins' clock and CAP
		dq_in <= sd_dq_i;
		cap_v <= {1'b0, cap_v[6:1]};
		for (int i = 0; i < 6; i++) cap_w[i] <= cap_w[i + 1];
		if (cap_v[0]) z_rdata[16 * cap_w[0] +: 16] <= dq_in;
		case (s_st)
			S_INIT:
			begin
				// the power-up wait, then: precharge all, eight refreshes 10 clocks apart, the mode
				ready <= 1'b0;
				s_n <= s_n + 16'd1;
				s_ref <= 11'd0;
				op_v <= 4'h0;
				if (s_n == 16'(POWERUP)) begin n_cmd <= C_PRE; n_a <= 13'h0400; end
				for (int k = 0; k < 8; k++) if (s_n == 16'(POWERUP + 4 + 10 * k)) n_cmd <= C_REF;
				if (s_n == 16'(POWERUP + 90)) begin n_cmd <= C_MODE; n_a <= MODE; n_ba <= 2'd0; end
				if (s_n == 16'(POWERUP + 94)) begin ready <= 1'b1; s_st <= S_IDLE; end
			end
			S_IDLE:
				if (s_due)
				begin
					if (op_v != 4'h0) begin n_cmd <= C_PRE; n_a <= 13'h0400; op_v <= 4'h0; s_rf <= 1'b1; s_n <= 16'd0; s_st <= S_PRE; end
					else begin n_cmd <= C_REF; s_ref <= 11'd0; s_due <= 1'b0; s_n <= 16'd0; s_st <= S_REF; end
				end
				else if (o_t != s_t)
				begin
					s_t <= o_t; s_wr <= o_wr; s_a <= o_a; s_w <= 4'd0; s_rf <= 1'b0;
					if (o_wr) begin s_d <= o_d; z_d <= o_t; end
					n_ba <= o_a[11:10];
					if (op_v[o_a[11:10]] && op_row[o_a[11:10]] == o_a[24:12]) s_st <= S_CMD;
					else if (op_v[o_a[11:10]]) begin n_cmd <= C_PRE; n_a <= 13'h0000; op_v[o_a[11:10]] <= 1'b0; s_n <= 16'd0; s_st <= S_PRE; end
					else begin n_cmd <= C_ACT; n_a <= o_a[24:12]; op_v[o_a[11:10]] <= 1'b1; op_row[o_a[11:10]] <= o_a[24:12]; s_n <= 16'd0; s_st <= S_RCD; end
				end
			// tRP: the ACTIVE or the REFRESH 3 clocks after the PRECHARGE
			S_PRE: begin s_n <= s_n + 16'd1; if (s_n == 16'd1) s_st <= s_rf ? S_IDLE : S_ACT; end
			S_ACT: begin n_cmd <= C_ACT; n_a <= s_a[24:12]; op_v[s_a[11:10]] <= 1'b1; op_row[s_a[11:10]] <= s_a[24:12]; s_n <= 16'd0; s_st <= S_RCD; end
			S_RCD: begin s_n <= s_n + 16'd1; if (s_n == 16'd1) s_st <= S_CMD; end   // (tRCD: the first READ or WRITE 3 clocks after the ACTIVE)
			S_CMD:
			begin
				n_a <= {4'b0000, s_a[9:5], s_w};
				n_ba <= s_a[11:10];
				if (s_wr)
				begin
					n_cmd <= C_WRITE;
					n_dq <= s_d[16 * s_w +: 16];
					n_oe <= 1'b1;
					n_dqm <= {~s_d[256 + 2 * s_w + 1], ~s_d[256 + 2 * s_w]};
				end
				else
				begin
					n_cmd <= C_READ;
					if (rd_late) begin cap_v[6] <= 1'b1; cap_w[6] <= s_w; end
					else begin cap_v[5] <= 1'b1; cap_w[5] <= s_w; end
				end
				s_w <= s_w + 4'd1;
				if (s_w == 4'd15)
				begin
					if (s_wr && s_next)
					begin
						s_t <= o_t; s_wr <= o_wr; s_a <= o_a;
						if (o_wr) begin s_d <= o_d; z_d <= o_t; end
					end
					else begin s_n <= 16'd0; s_st <= S_TAIL; end
				end
			end
			// after the last READ its data; after the last WRITE tWR, for a precharge that may come next
			S_TAIL: begin s_n <= s_n + 16'd1; if (s_n == (s_wr ? 16'd1 : 16'd6)) begin z_d <= s_t; s_st <= S_IDLE; end end   // (a write's z_d again)
			S_REF: begin s_n <= s_n + 16'd1; if (s_n == 16'd8) s_st <= S_IDLE; end    // (tRFC 66 ns)
			default: s_st <= S_IDLE;
		endcase
		// (what's under way when clk's side resets is dropped there, o_t made z_d: so here)
		if (rst_m) begin s_st <= S_INIT; s_n <= 16'd0; cap_v <= 7'd0; ready <= 1'b0; s_t <= z_d; op_v <= 4'h0; end
	end
endmodule
