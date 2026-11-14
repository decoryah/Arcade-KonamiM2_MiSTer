// m2_vdu: the VDU, what MAME 0.289 makes of it (3dom2.cpp, screen_update), a line at a time: it follows the display list (VDL) from
// FV0A, a block of lines at a time, each block a header (DMA control, the frame buffer's address, the next block), control words and
// lines of the buffer. Each line is read into a line buffer while the line before it is shown.
//
// Places are MAME's: a line's x from 0 at the start of a 768 pixel line, shown from 126; lines from 0, shown from 20, to 259.
// The VDU's other features (interpolation, dither, the second field) MAME doesn't draw, and nor does this.
`default_nettype none
module m2_vdu (
	input  logic        clk,
	input  logic        rst,

	// the registers: writes (reads are 0, as MAME's; VLOC and VINT are rtl/m2_bda.sv's)
	input  logic [5:2]  a,
	input  logic        we,
	input  logic [31:0] wd,

	// the raster (rtl/m2_vtiming.sv)
	input  logic [9:0]  hpos,           // from 0 where a line starts being shown: pixels shown from MAME's x 126
	input  logic [8:0]  vpos,           // from 0 where a frame starts being shown: MAME's line - 20
	output logic [23:0] rgb,
	output logic        on,             // something to show: the list's been set
	output logic        frame,          // a frame's list starts (a clock), and flip with it if what the last frame showed differs
	output logic        flip,           // from the one before (its blocks' buffer addresses: a game flips by changing its list in memory)

	// memory
	output logic        m_rd,
	output logic        m_four,         // 4 words, the address aligned; else one
	output logic [31:3] m_a,
	input  logic        m_busy,
	input  logic        m_ready,
	input  logic [63:0] m_dout
);
	localparam int VTOTAL = 260, V_SHOWN = 20;
	localparam logic [9:0] X_SHOWN = 10'd126;

	logic [31:0] fv0a;
	logic [1:0]  vrst;
	always_ff @(posedge clk)
		if (rst) begin fv0a <= 32'h0; vrst <= 2'b00; end
		else if (we)
			case (a)
				4'd4: fv0a <= wd;           // 0x10
				4'd13: vrst <= wd[1:0];     // 0x34
				default: ;
			endcase
	assign on = fv0a != 32'h0 && vrst == 2'b00;

	// ---- the line buffers: one shown, one being read ----------------------------------------------------------------------
	logic        bank;                  // being shown
	logic [8:0]  bwa;
	logic        bwe;
	logic [8:0]  bra;
	logic [63:0] bq;
	ppc_ram #(.W(64), .AW(10)) lbuf (.clk, .we(bwe), .wa({!bank, bwa}), .wd(m_dout), .ra({bank, bra}), .rd(bq));

	// ---- following the list ----------------------------------------------------------------------------------------------
	typedef enum logic [3:0] { S_WAIT, S_NEW, S_WORD, S_WORDW, S_CMD, S_LINE, S_FETCH, S_FETCHW, S_DONE } st_t;
	st_t         st;
	logic [8:0]  ln;                    // the line being got ready
	logic [8:0]  v;                     // the line the list has got to
	logic        go;                    // a line has started
	// verilator lint_off UNUSEDSIGNAL
	logic [31:0] addr, ctl, lower, next;
	// verilator lint_on UNUSEDSIGNAL
	logic [5:0]  nw;
	logic [1:0]  w_i;
	logic        in_hdr;
	logic [8:0]  b_left;                // lines left of the block
	logic        have;                  // in a block
	logic        live;                  // the list's been followed from the frame's start
	logic        rep;                   // the line again (VDOUBLE)
	logic [10:0] hs, hw;
	logic        hd, vd, fmt32;
	logic [31:0] w32;                   // a word of the list
	assign w32 = {m_dout[7:0], m_dout[15:8], m_dout[23:16], m_dout[31:24]};
	wire  [31:0] w32_hi = {m_dout[39:32], m_dout[47:40], m_dout[55:48], m_dout[63:56]};
	wire  [31:0] w = addr[2] ? w32_hi : w32;

	logic [31:0] f_a;                   // the fetch's next address
	logic [8:0]  f_n;                   // bursts left
	logic [1:0]  f_beat;
	logic [8:0]  f_w;

	// what the next line is
	logic        n_show;
	logic [4:0]  n_off;
	logic [10:0] n_hs, n_hw;
	logic        n_hd, n_fmt;
	// what this line is
	logic        c_show;
	logic [4:0]  c_off;
	logic [10:0] c_hs, c_hw;
	logic        c_hd, c_fmt;

	logic [31:0] sig, sig_last;         // the frame's shown buffers (its blocks' addresses, rotated in), and the last frame's

	logic [8:0]  vpos_q;
	wire         l_start = vpos != vpos_q;
	wire  [8:0]  shown = vpos + 9'(V_SHOWN);       // the line shown now, 0-261
	wire  [8:0]  shown_nx = shown == 9'd261 ? 9'd0 : shown + 9'd1;

	assign m_rd = st == S_WORD || st == S_FETCH;
	assign m_four = st == S_FETCH;
	assign m_a = st == S_FETCH ? f_a[31:3] : addr[31:3];
	assign bwe = st == S_FETCHW && m_ready;
	assign bwa = f_w;

	always_ff @(posedge clk)
	begin
		vpos_q <= vpos;
		frame <= 1'b0; flip <= 1'b0;
		if (rst)
		begin
			st <= S_WAIT; go <= 1'b0; bank <= 1'b0; c_show <= 1'b0; n_show <= 1'b0; have <= 1'b0; live <= 1'b0; v <= 9'd0;
			hs <= 11'd0; hw <= 11'd0; hd <= 1'b0; vd <= 1'b0; fmt32 <= 1'b0; rep <= 1'b0; ln <= 9'd0;
		end
		else
		begin
			if (l_start) go <= 1'b1;
			case (st)
				S_WAIT:
					if (go || l_start)
					begin
						go <= 1'b0;
						// the line got ready is now shown
						bank <= !bank;
						c_show <= n_show; c_off <= n_off; c_hs <= n_hs; c_hw <= n_hw; c_hd <= n_hd; c_fmt <= n_fmt;
						n_show <= 1'b0;
						ln <= shown_nx;
						st <= S_NEW;
					end
				S_NEW:
					if (ln == 9'd0)
					begin
						v <= 9'd0; addr <= fv0a; have <= 1'b0; rep <= 1'b0;
						live <= on;
						frame <= 1'b1; flip <= sig != sig_last; sig_last <= sig; sig <= 32'h0;
						if (on) begin w_i <= 2'd0; in_hdr <= 1'b1; st <= S_WORD; end
						else st <= S_WAIT;
					end
					else if (!on || !live || ln >= 9'(VTOTAL)) st <= S_WAIT;
					else if (have) st <= S_LINE;
					else begin addr <= next; w_i <= 2'd0; in_hdr <= 1'b1; st <= S_WORD; end
				S_WORD: if (!m_busy) st <= S_WORDW;
				S_WORDW:
					if (m_ready)
					begin
						addr <= addr + 32'd4;
						if (in_hdr)
						begin
							case (w_i)
								2'd0: ctl <= w;
								2'd1: begin lower <= w; if (ctl[21]) sig <= {sig[26:0], sig[31:27]} ^ w; end
								2'd2: ;
								default: next <= w;
							endcase
							w_i <= w_i + 2'd1;
							if (w_i == 2'd3)
							begin
								// (words count the header)
								in_hdr <= 1'b0;
								nw <= ctl[14:9] - 6'd4;
								st <= ctl[14:9] > 6'd4 ? S_WORD : S_CMD;
							end
							else st <= S_WORD;
						end
						else
						begin
							case (w[31:29])
								3'b101:
								begin
									if (w[17]) hs <= w[28:18];
									if (w[5]) hw <= w[16:6];
									if (w[2]) hd <= w[4];
									if (w[1]) vd <= w[3];
								end
								3'b110:
									if (w[12]) fmt32 <= w[23];
								default: ;
							endcase
							nw <= nw - 6'd1;
							st <= nw > 6'd1 ? S_WORD : S_CMD;
						end
					end
				S_CMD:
				begin
					// a block's lines: 0 for the rest
					have <= 1'b1;
					b_left <= ctl[8:0] != 9'd0 ? ctl[8:0] : 9'(VTOTAL) - v;
					rep <= 1'b0;
					st <= S_LINE;
				end
				S_LINE:
				begin
					n_hs <= hs; n_hw <= hw; n_hd <= hd; n_fmt <= fmt32;
					if (ln < 9'(V_SHOWN) || !ctl[21])
					begin
						// nothing to read
						st <= S_DONE;
					end
					else
					begin
						n_show <= 1'b1;
						n_off <= lower[4:0];
						f_a <= {lower[31:5], 5'd0};
						f_w <= 9'd0;
						f_beat <= 2'd0;
						// (bytes + 31 to the next 32; a line buffer's 512 words at most)
						begin
							logic [13:0] bytes;
							bytes = fmt32 ? {1'b0, hw, 2'b00} : {2'b00, hw, 1'b0};
							bytes = bytes + {9'd0, lower[4:0]} + 14'd31;
							f_n <= bytes[13:5] > 9'd128 ? 9'd128 : bytes[13:5];
							st <= bytes[13:5] == 9'd0 ? S_DONE : S_FETCH;
						end
					end
				end
				S_FETCH: if (!m_busy) st <= S_FETCHW;
				S_FETCHW:
					if (m_ready)
					begin
						f_w <= f_w + 9'd1;
						f_beat <= f_beat + 2'd1;
						if (f_beat == 2'd3)
						begin
							f_a <= f_a + 32'd32;
							f_n <= f_n - 9'd1;
							// (if the line's started, what's been read must do)
							st <= f_n > 9'd1 && !go && !l_start ? S_FETCH : S_DONE;
						end
					end
				S_DONE:
				begin
					// on through the list
					if (!ctl[21] || !vd || rep)
					begin
						rep <= 1'b0;
						if (ctl[21]) lower <= lower + 32'({ctl[31:24], 5'd0});
						b_left <= b_left - 9'd1;
						if (b_left <= 9'd1) have <= 1'b0;
					end
					else rep <= 1'b1;
					v <= v + 9'd1;
					st <= S_WAIT;
				end
				default: st <= S_WAIT;
			endcase
		end
	end

	// ---- the pixels ------------------------------------------------------------------------------------------------------
	wire [10:0]  x = 11'(hpos) + 11'(X_SHOWN);
	wire [10:0]  i0 = x - c_hs;
	wire [10:0]  i = c_hd ? {1'b0, i0[10:1]} : i0;
	wire         in_px = c_show && x >= c_hs && i < c_hw;
	// verilator lint_off UNUSEDSIGNAL
	wire [12:0]  b = (c_fmt ? {i, 2'b00} : {1'b0, i, 1'b0}) + 13'(c_off);
	assign bra = {b[11:3]};
	logic        p_in;
	logic [2:0]  p_b;
	// verilator lint_on UNUSEDSIGNAL
	logic        p_fmt;
	wire [31:0]  q32 = p_b[2] ? {bq[39:32], bq[47:40], bq[55:48], bq[63:56]} : {bq[7:0], bq[15:8], bq[23:16], bq[31:24]};
	// verilator lint_off UNUSEDSIGNAL
	wire [15:0]  q16 = p_b[1] ? q32[15:0] : q32[31:16];
	// verilator lint_on UNUSEDSIGNAL
	always_ff @(posedge clk)
	begin
		p_in <= in_px; p_b <= b[2:0]; p_fmt <= c_fmt;
		rgb <= !p_in ? 24'h0
			: p_fmt ? q32[23:0]
			: {q16[14:10], q16[14:12], q16[9:5], q16[9:7], q16[4:0], q16[4:2]};
	end
endmodule
