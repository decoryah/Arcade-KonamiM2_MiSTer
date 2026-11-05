// ppc_cache: rtl/ppc_pipe.sv's caches and its way to memory. Lines of 32 bytes, direct-mapped, 8 KB each side, indexed by
// the virtual address's low bits (BATs map 128 KB or more; pages aren't mapped), tagged by the physical.
//
// sn_v: another bus master has written memory, in line sn_a (the clock after DDR3 took it): that line goes, both sides, if it's
// here, and a read of it under way is kept from being valid (it may have read older than the write). So memory is coherent, as
// in MAME, and dcbi and the like can stay what they are there, no-ops. A clash at the tags (the rare chance of two writes
// to them in a clock that can't wait) sends all lines (inv_all). A line read that isn't kept leaves its index invalid, as its
// words have replaced what was there.
//
//   instruction side: a fetch hit answers in its address clock, so a fetch a clock. A miss reads the line and asks again
//                     (i_mem low: the line reads as zeros).
//                     It watches the stores (a second copy of the tags), so code written is never stale.
//   data side:        a load hit answers the clock after its address clock; a miss reads the line. Write-through, no write
//                     allocate: a store goes to the store buffer, and into the line on a hit (the clock after, with d_rdy low).
//   not cached:       (d_cacheable low, or across 8 bytes) one or two words, after the store buffer has drained; a store
//                     across 8 bytes invalidates its lines in both caches. Not memory (d_mem low): the u_ port, one access.
//
// The memory port takes one job at a time, the store buffer first: words (burst 1), lines (burst 4), with mem_a the
// physical address of the first word. A line read waits for the store buffer, and a store to a line being read
// keeps that line from being valid, so nothing reads older than a store done.
//
`default_nettype none
module ppc_cache (
	input  logic        clk,
	input  logic        rst,
	input  logic        sn_v,
	input  logic [31:5] sn_a,

	// the core's sides (rtl/ppc_pipe.sv's contract)
	input  logic        if_req,
	input  logic [31:0] if_va,
	output logic        if_rdy,
	input  logic [31:0] if_pa,
	input  logic        if_kill,
	output logic        if_valid,
	output logic [31:0] if_data,
	input  logic        i_mem,          // if_pa's: memory

	input  logic        d_req,
	// verilator lint_off UNUSEDSIGNAL
	input  logic [31:0] d_va,
	// verilator lint_on UNUSEDSIGNAL
	input  logic        d_kill,
	input  logic        d_we,
	input  logic [31:0] d_pa,
	input  logic [3:0]  d_size,
	input  logic [63:0] d_wdata,
	output logic        d_rdy,
	output logic        d_valid,
	output logic [63:0] d_rdata,
	input  logic        d_mem,          // d_pa's: memory, not the u_ port
	input  logic        d_cacheable,
	input  logic        d_writable,     // (a store to memory that isn't, the ROM, is dropped)

	// an access that isn't memory: u_req one clock, u_ack answers on a later one
	output logic        u_req,
	output logic [31:0] u_pa,
	output logic        u_we,
	output logic [3:0]  u_size,
	output logic [63:0] u_wdata,
	input  logic        u_ack,
	input  logic [63:0] u_rdata,

	// memory: 8-byte words, the lowest address in bits 7:0
	output logic        mem_rd,
	output logic        mem_we,
	output logic [31:3] mem_a,
	output logic [7:0]  mem_burst,
	output logic [63:0] mem_wd,
	output logic [7:0]  mem_be,
	input  logic        mem_busy,
	input  logic        mem_ready,
	input  logic [63:0] mem_dout
);
	localparam int FIFO = 4;

	function automatic logic [31:0] word_be(input logic [63:0] w, input logic hi);
		logic [31:0] v;
		v = hi ? w[63:32] : w[31:0];
		return {v[7:0], v[15:8], v[23:16], v[31:24]};
	endfunction
	// bytes [off, off + n) of two words (the first the lower address), big-endian, right-aligned
	function automatic logic [63:0] rd_bytes(input logic [63:0] w0, input logic [63:0] w1, input logic [2:0] off,
		input logic [3:0] n);
		logic [127:0] win;
		logic [63:0] v;
		win = {w1, w0};
		v = 64'h0;
		for (int j = 0; j < 8; j++)
			if (4'(j) < n) v = {v[55:0], win[8 * (32'(off) + j) +: 8]};
		return v;
	endfunction

	// ---- the tags' sweep: all of them invalid after reset, or inv_all ------------------------------------------------------
	logic [8:0] sw_n;
	wire        sw = !sw_n[8];
	logic       inv_all;
	always_ff @(posedge clk)
		if (rst || inv_all) sw_n <= 9'd0;
		else if (sw) sw_n <= sw_n + 9'd1;

	// ---- what the others write: the tags read in sn_v's clock, compared the clock after, the line invalidated then -------------
	logic        sn1_v;
	logic [31:5] sn1_a;
	logic        sn_i, sn_d;            // it's here
	always_ff @(posedge clk)
	begin
		sn1_v <= !rst && sn_v;
		sn1_a <= sn_a;
	end

	// ---- the memory engine ----------------------------------------------------------------------------------------------
	typedef enum logic [1:0] { J_WORD, J_U, J_DLINE, J_ILINE } jown_t;
	typedef enum logic [1:0] { E_IDLE, E_REQ, E_WAIT } est_t;
	est_t        e_st;
	jown_t       e_own;
	logic [1:0]  e_n;                   // beats still to come of a line; the words of a J_U
	logic        e_two, e_second, e_we;
	logic [31:3] e_a;
	logic [63:0] e_wd0, e_wd1, e_rd0;
	logic [7:0]  e_be0, e_be1;

	// the store buffer
	logic [31:3] w_a [0:FIFO-1];
	logic [63:0] w_d [0:FIFO-1];
	logic [7:0]  w_be [0:FIFO-1];
	logic [$clog2(FIFO)-1:0] w_rp, w_wp;
	logic [$clog2(FIFO):0]   w_cnt;
	wire         w_empty = w_cnt == 0;
	wire         w_full = w_cnt == ($clog2(FIFO)+1)'(FIFO);
	logic        w_push;
	logic [31:3] w_pa;
	logic [63:0] w_pd;
	logic [7:0]  w_pbe;

	// the jobs waiting
	logic        d_line_pend, i_line_pend, u_pend;
	logic [31:5] d_line_a, i_line_a;
	logic [31:3] u_ja;
	logic        u_jwe, u_jtwo;
	logic [63:0] u_jwd0, u_jwd1;
	logic [7:0]  u_jbe0, u_jbe1;

	wire e_pick_w = e_st == E_IDLE && !w_empty;
	wire e_pick_u = e_st == E_IDLE && w_empty && u_pend;
	wire e_pick_d = e_st == E_IDLE && w_empty && !u_pend && d_line_pend;
	// (not before a store across 8 bytes, whose lines have gone already)
	logic x_store;
	wire e_pick_i = e_st == E_IDLE && w_empty && !u_pend && !d_line_pend && i_line_pend && !x_store;

	assign mem_rd = e_st == E_REQ && !e_we;
	assign mem_we = e_st == E_REQ && e_we;
	assign mem_a = e_second ? e_a + 29'd1 : e_a;
	assign mem_burst = e_own == J_DLINE || e_own == J_ILINE ? 8'd4 : 8'd1;
	assign mem_wd = e_second ? e_wd1 : e_wd0;
	assign mem_be = e_second ? e_be1 : e_be0;

	wire line_beat = e_st == E_WAIT && mem_ready && (e_own == J_DLINE || e_own == J_ILINE);
	wire line_last = line_beat && e_n == 2'd0;
	wire u_done = e_own == J_U && ((e_st == E_REQ && e_we && !mem_busy && (e_second || !e_two)) ||
		(e_st == E_WAIT && mem_ready && (e_second || !e_two)));
	wire w_taken = e_pick_w;

	always_ff @(posedge clk)
		if (rst)
		begin
			e_st <= E_IDLE;
			e_second <= 1'b0;
		end
		else
			case (e_st)
				E_IDLE:
				begin
					e_second <= 1'b0;
					if (e_pick_w)
					begin
						e_own <= J_WORD; e_we <= 1'b1; e_two <= 1'b0; e_a <= w_a[w_rp];
						e_wd0 <= w_d[w_rp]; e_be0 <= w_be[w_rp];
						e_st <= E_REQ;
					end
					else if (e_pick_u)
					begin
						e_own <= J_U; e_we <= u_jwe; e_two <= u_jtwo; e_a <= u_ja;
						e_wd0 <= u_jwd0; e_wd1 <= u_jwd1; e_be0 <= u_jbe0; e_be1 <= u_jbe1;
						e_st <= E_REQ;
					end
					else if (e_pick_d)
					begin
						e_own <= J_DLINE; e_we <= 1'b0; e_two <= 1'b0; e_a <= {d_line_a, 2'b00}; e_n <= 2'd3;
						e_st <= E_REQ;
					end
					else if (e_pick_i)
					begin
						e_own <= J_ILINE; e_we <= 1'b0; e_two <= 1'b0; e_a <= {i_line_a, 2'b00}; e_n <= 2'd3;
						e_st <= E_REQ;
					end
				end
				E_REQ:
					if (!mem_busy)
					begin
						if (!e_we) e_st <= E_WAIT;
						else if (e_two && !e_second) e_second <= 1'b1;
						else e_st <= E_IDLE;
					end
				E_WAIT:
					if (mem_ready)
					begin
						if (e_own == J_U)
						begin
							if (e_two && !e_second)
							begin
								e_rd0 <= mem_dout;
								e_second <= 1'b1;
								e_st <= E_REQ;
							end
							else e_st <= E_IDLE;
						end
						else if (e_n == 2'd0) e_st <= E_IDLE;
						else e_n <= e_n - 2'd1;
					end
				default: e_st <= E_IDLE;
			endcase

	always_ff @(posedge clk)
		if (rst)
		begin
			w_rp <= '0; w_wp <= '0; w_cnt <= '0;
		end
		else
		begin
			if (w_push)
			begin
				w_a[w_wp] <= w_pa; w_d[w_wp] <= w_pd; w_be[w_wp] <= w_pbe;
				w_wp <= w_wp + 1'b1;
			end
			if (w_taken) w_rp <= w_rp + 1'b1;
			w_cnt <= w_cnt + ($clog2(FIFO)+1)'(w_push) - ($clog2(FIFO)+1)'(w_taken);
		end

	// ---- the instruction side ---------------------------------------------------------------------------------------------
	typedef enum logic [2:0] { I_RUN, I_LINE, I_TAG, I_REPLAY } ist_t;
	ist_t        i_st;
	logic        i_out;                 // a fetch's address clock
	logic [31:0] i_lva;                 // the fetch missed
	logic [31:13] i_lpa;
	logic [1:0]  i_wn;                  // the line's next beat
	logic        i_zero;                // the line isn't memory
	logic        i_killed, i_cancel;    // the fetch dropped; a store to the line
	logic [1:0]  i_recent;              // its tag was written these clocks ago (a store that read the tag before it)

	logic [19:0] it_q, it2_q;
	logic [63:0] id_q;
	logic [7:0]  it_ra, it_wa;
	logic [19:0] it_wd;
	logic        it_we;
	logic        s_inv, s_inv_q;        // a store's line goes: its tag written this clock; the clock after
	logic [7:0]  s_idx, s_idx_q, i_idx;

	// verilator lint_off UNUSEDSIGNAL
	wire [31:0]  i_rva = i_st == I_REPLAY ? i_lva : if_va;
	// verilator lint_on UNUSEDSIGNAL
	logic        x_inv;                 // a store across 8 bytes: a line of it goes, x_idx's
	logic [7:0]  x_idx;
	wire         i_scan = sw || x_inv || (s_inv && s_idx == i_idx) || (s_inv_q && s_idx_q == i_idx);
	wire         i_hit = it_q[19] && it_q[18:0] == if_pa[31:13] && !i_scan;
	wire         i_miss = i_out && !i_hit;
	assign if_valid = i_out && i_hit;
	assign if_data = word_be(id_q, if_pa[2]);
	assign if_rdy = i_st == I_RUN && !sw && (!i_out || if_valid || if_kill);

	ppc_ram #(.W(64), .AW(10)) i_data
	(
		.clk,
		.we(line_beat && e_own == J_ILINE), .wa({i_lva[12:5], i_wn}), .wd(i_zero ? 64'h0 : mem_dout),
		.ra(i_rva[12:3]), .rd(id_q)
	);
	assign it_ra = i_rva[12:5];
	ppc_ram #(.W(20), .AW(8)) i_tag (.clk, .we(it_we), .wa(it_wa), .wd(it_wd), .ra(it_ra), .rd(it_q));
	ppc_ram #(.W(20), .AW(8)) i_tag2 (.clk, .we(it_we), .wa(it_wa), .wd(it_wd), .ra(d_va[12:5]), .rd(it2_q));
	logic [19:0] it3_q;
	ppc_ram #(.W(20), .AW(8)) i_tag3 (.clk, .we(it_we), .wa(it_wa), .wd(it_wd), .ra(sn_a[12:5]), .rd(it3_q));
	assign sn_i = sn1_v && ((it3_q[19] && it3_q[18:0] == sn1_a[31:13]) || (i_recent[0] && sn1_a == {i_lpa, i_lva[12:5]}));

	always_comb
	begin
		it_we = 1'b0; it_wa = 8'h0; it_wd = 20'h0;
		if (sw) begin it_we = 1'b1; it_wa = sw_n[7:0]; end
		else if (s_inv) begin it_we = 1'b1; it_wa = s_idx; end
		else if (sn_i) begin it_we = 1'b1; it_wa = sn1_a[12:5]; end
		else if (i_st == I_TAG)
		begin
			it_we = 1'b1; it_wa = i_lva[12:5]; it_wd = {!i_cancel, i_lpa};
		end
	end

	logic        store_a;               // a store to memory in its address clock
	always_ff @(posedge clk)
		if (rst)
		begin
			i_st <= I_RUN; i_out <= 1'b0; i_line_pend <= 1'b0; i_killed <= 1'b0; i_cancel <= 1'b0; i_recent <= 2'd0;
		end
		else
		begin
			i_recent <= {i_recent[0], i_st == I_TAG && !sw && !s_inv && !sn_i};
			if (if_req && if_rdy) i_idx <= if_va[12:5];
			else if (i_st == I_REPLAY) i_idx <= i_lva[12:5];
			if (if_kill) i_killed <= i_st != I_RUN;
			if (store_a && d_pa[31:5] == {i_lpa, i_lva[12:5]}) i_cancel <= 1'b1;
			if (sn_v && sn_a == {i_lpa, i_lva[12:5]}) i_cancel <= 1'b1;
			if (inv_all || (x_inv && x_idx == i_lva[12:5])) i_cancel <= 1'b1;
			case (i_st)
				I_RUN:
				begin
					i_out <= if_req && if_rdy;
					if (i_miss && !if_kill)
					begin
						i_lva <= if_pa;
						i_lpa <= if_pa[31:13];
						i_line_pend <= 1'b1;
						i_line_a <= if_pa[31:5];
						i_wn <= 2'd0;
						i_zero <= !i_mem;
						i_killed <= 1'b0;
						i_cancel <= 1'b0;
						i_out <= 1'b0;
						i_st <= I_LINE;
					end
				end
				I_LINE:
				begin
					if (e_pick_i) i_line_pend <= 1'b0;
					if (line_beat && e_own == J_ILINE)
					begin
						i_wn <= i_wn + 2'd1;
						if (line_last) i_st <= I_TAG;
					end
				end
				I_TAG:
					// (the sweep or a store's invalidate first)
					if (!sw && !s_inv && !sn_i)
						i_st <= I_REPLAY;
				I_REPLAY:
				begin
					i_st <= I_RUN;
					i_out <= !i_killed && !if_kill;
				end
				default: i_st <= I_RUN;
			endcase
		end
	wire i_snoop = store_a && ((it2_q[19] && it2_q[18:0] == d_pa[31:13]) ||
		((i_st == I_TAG || i_recent != 2'd0) && d_pa[31:5] == {i_lpa, i_lva[12:5]}));
	always_ff @(posedge clk)
	begin
		s_inv <= !rst && (i_snoop || x_inv);
		s_idx <= x_inv ? x_idx : d_pa[12:5];
		s_inv_q <= !rst && s_inv;
		s_idx_q <= s_idx;
	end

	// ---- the data side ------------------------------------------------------------------------------------------------
	typedef enum logic [3:0] { D_IDLE, D_APH, D_WFULL, D_LINE, D_XINV, D_DRAIN, D_U, D_STUB, D_RESP } dst_t;
	dst_t        d_st;
	logic [31:0] p_pa;
	logic [3:0]  p_size;
	logic [63:0] p_wdata;
	logic [63:0] d_val;
	logic        p_we, p_cross, d_wr;   // d_wr: a store hit's write to the line, with RESP
	logic [63:0] d_wd;
	logic [7:0]  d_be;
	logic [12:3] d_wa;
	logic [1:0]  d_wn;
	logic        p_mem, p_hit, x_n;
	logic        d_cancel;              // the line read isn't to be kept: a write to it, or inv_all
	logic        d_recent;              // its tag was written last clock
	logic [127:0] p_win;
	logic [15:0]  p_be;

	logic [19:0] dt_q;
	logic [63:0] dd_q;
	wire         d_hit = dt_q[19] && dt_q[18:0] == d_pa[31:13];
	wire         d_cross = {1'b0, d_pa[2:0]} + d_size > 4'd8;
	assign store_a = d_st == D_APH && !d_kill && d_we && d_mem && d_writable;
	assign x_inv = d_st == D_XINV;
	assign x_idx = x_n ? p_pa[12:5] + 8'(p_pa[4:3] == 2'd3) : p_pa[12:5];
	assign x_store = x_inv || (d_st == D_DRAIN && p_we && p_mem);

	// the store's bytes in the (16-byte) window
	logic [127:0] s_win;
	logic [15:0]  s_be;
	always_comb
	begin
		s_win = 128'h0; s_be = 16'h0;
		for (int j = 0; j < 8; j++)
			if (4'(j) < d_size)
			begin
				s_win[8 * (32'(d_pa[2:0]) + j) +: 8] = d_wdata[8 * (32'(d_size) - 1 - j) +: 8];
				s_be[32'(d_pa[2:0]) + j] = 1'b1;
			end
	end
	wire d_push_ok = store_a && !d_cross && !w_full;
	assign w_push = d_push_ok || (d_st == D_WFULL && !w_full);
	assign w_pa = d_st == D_WFULL ? p_pa[31:3] : d_pa[31:3];
	assign w_pd = d_st == D_WFULL ? p_win[63:0] : s_win[63:0];
	assign w_pbe = d_st == D_WFULL ? p_be[7:0] : s_be[7:0];

	assign d_valid = d_st == D_RESP;
	assign d_rdy = !sw && !d_wr && (d_st == D_IDLE || d_st == D_RESP);
	assign d_rdata = d_val;
	assign u_pa = p_pa; assign u_we = p_we; assign u_size = p_size; assign u_wdata = p_wdata;
	assign u_req = d_st == D_DRAIN && w_empty && !p_mem;

	wire line_d = line_beat && e_own == J_DLINE;
	ppc_ram_be i_ddata
	(
		.clk,
		.we(d_wr || line_d), .be(line_d ? 8'hff : d_be), .wa(line_d ? {p_pa[12:5], d_wn} : d_wa), .wd(line_d ? mem_dout : d_wd),
		.ra(d_va[12:3]), .rd(dd_q)
	);
	wire         d_fill = line_last && e_own == J_DLINE;
	wire         dt_we = sw || x_inv || sn_d || d_fill;
	wire [7:0]   dt_wa = sw ? sw_n[7:0] : x_inv ? x_idx : sn_d ? sn1_a[12:5] : p_pa[12:5];
	wire [19:0]  dt_wd = sw || x_inv || sn_d ? 20'h0 : {!d_cancel && !inv_all, p_pa[31:13]};
	ppc_ram #(.W(20), .AW(8)) i_dtag (.clk, .we(dt_we), .wa(dt_wa), .wd(dt_wd), .ra(d_va[12:5]), .rd(dt_q));
	logic [19:0] dt2_q;
	ppc_ram #(.W(20), .AW(8)) i_dtag2 (.clk, .we(dt_we), .wa(dt_wa), .wd(dt_wd), .ra(sn_a[12:5]), .rd(dt2_q));
	assign sn_d = sn1_v && ((dt2_q[19] && dt2_q[18:0] == sn1_a[31:13]) || (d_recent && sn1_a == p_pa[31:5]));
	always_ff @(posedge clk)
	begin
		inv_all <= !rst && !sw && ((sn_d && (x_inv || d_fill)) || (sn_i && s_inv));
		d_recent <= d_fill && !sw && !x_inv && !sn_d;
	end

	always_ff @(posedge clk)
	begin
		d_wr <= 1'b0;
		if (inv_all || (sn_v && sn_a == p_pa[31:5])) d_cancel <= 1'b1;
		if (rst)
		begin
			d_st <= D_IDLE; d_line_pend <= 1'b0; u_pend <= 1'b0;
		end
		else
		begin
			if (e_pick_u) u_pend <= 1'b0;
			if (e_pick_d) d_line_pend <= 1'b0;
			case (d_st)
				D_IDLE, D_RESP: if (d_req && d_rdy) d_st <= D_APH; else d_st <= D_IDLE;
				D_APH:
					if (d_kill) d_st <= D_IDLE;
					else
					begin
						p_pa <= d_pa; p_we <= d_we; p_size <= d_size; p_wdata <= d_wdata; p_cross <= d_cross;
						p_win <= s_win; p_be <= s_be;
						p_mem <= d_mem; p_hit <= d_cacheable && d_hit;
						if (!d_mem) d_st <= D_DRAIN;
						else if (d_we)
						begin
							if (!d_writable) begin d_val <= 64'h0; d_st <= D_RESP; end
							else if (d_cross) begin x_n <= 1'b0; d_st <= D_XINV; end
							else if (w_full) d_st <= D_WFULL;
							else
							begin
								d_wr <= d_cacheable && d_hit;
								d_wa <= d_pa[12:3]; d_wd <= s_win[63:0]; d_be <= s_be[7:0];
								d_val <= 64'h0;
								d_st <= D_RESP;
							end
						end
						else if (d_cacheable && !d_cross)
						begin
							if (d_hit) begin d_val <= rd_bytes(dd_q, 64'h0, d_pa[2:0], d_size); d_st <= D_RESP; end
							else begin d_line_pend <= 1'b1; d_line_a <= d_pa[31:5]; d_wn <= 2'd0; d_cancel <= inv_all; d_st <= D_LINE; end
						end
						else d_st <= D_DRAIN;
					end
				D_WFULL:
					if (!w_full)
					begin
						d_wr <= p_hit;
						d_wa <= p_pa[12:3]; d_wd <= p_win[63:0]; d_be <= p_be[7:0];
						d_val <= 64'h0;
						d_st <= D_RESP;
					end
				D_LINE:
					if (line_d)
					begin
						d_wn <= d_wn + 2'd1;
						if (d_wn == p_pa[4:3]) d_val <= rd_bytes(mem_dout, 64'h0, p_pa[2:0], p_size);
						if (line_last) d_st <= D_RESP;
					end
				D_XINV:
				begin
					x_n <= 1'b1;
					if (x_n) d_st <= D_DRAIN;
				end
				D_DRAIN:
					if (w_empty)
					begin
						if (p_mem)
						begin
							u_ja <= p_pa[31:3]; u_jwe <= p_we; u_jtwo <= p_cross;
							u_jwd0 <= p_win[63:0]; u_jwd1 <= p_win[127:64]; u_jbe0 <= p_be[7:0]; u_jbe1 <= p_be[15:8];
							u_pend <= 1'b1;
							d_st <= D_U;
						end
						else d_st <= D_STUB;
					end
				D_U:
					if (u_done)
					begin
						d_val <= p_we ? 64'h0 : p_cross ? rd_bytes(e_rd0, mem_dout, p_pa[2:0], p_size) : rd_bytes(mem_dout, 64'h0, p_pa[2:0], p_size);
						d_st <= D_RESP;
					end
				D_STUB:
					if (u_ack) begin d_val <= u_rdata; d_st <= D_RESP; end
				default: d_st <= D_IDLE;
			endcase
		end
	end
endmodule

// a simple dual-port RAM of 1024 x 64 with byte enables, the read registered; what an entry written in that clock reads
// is either value (the data side never reads it then)
module ppc_ram_be (
	input  logic        clk,
	input  logic        we,
	input  logic [7:0]  be,
	input  logic [9:0]  wa,
	input  logic [63:0] wd,
	input  logic [9:0]  ra,
	output logic [63:0] rd
);
	genvar i;
	generate
	for (i = 0; i < 8; i++)
	begin : g_b
		ppc_ram #(.W(8), .AW(10)) b (.clk, .we(we && be[i]), .wa, .wd(wd[8 * i +: 8]), .ra, .rd(rd[8 * i +: 8]));
	end
	endgenerate
endmodule
