// ppc_cache: rtl/ppc_pipe.sv's caches and its way to memory. Lines of 32 bytes, KB each side, the instructions direct-mapped,
// the data two ways of KB / 2 with LRU (32: in stage 1 a quarter of 8 KB direct-mapped's instruction misses, half its data
// misses, on MAME traces), indexed by the virtual
// address's low bits (BATs map 128 KB or more; pages aren't mapped), tagged by the physical.
//
// sn_v: another bus master has written memory, in line sn_a (the clock after DDR3 took it): that line goes, both sides, if it's
// here, and a read of it under way is kept from being valid (it may have read older than the write). So memory is coherent, as
// in MAME, and dcbi and the like can stay what they are there, no-ops. A clash at the tags (the rare chance of two writes
// to them in a clock that can't wait) sends all lines (inv_all). A line read that isn't kept leaves its index invalid, as its
// words have replaced what was there.
//
//   instruction side: a fetch hit answers in its address clock, so a fetch a clock. A miss reads the line and asks again
//                     (i_mem low: the line reads as zeros).
//                     It watches the stores (a second copy of the tags), so code written is never stale; a fetch at the
//                     index of a store waiting at the data side (h_v) misses till that store's done.
//   data side:        a load hit answers the clock after its address clock; a miss reads the line. Write-through, no write
//                     allocate: a store goes to the store buffer, and into the line on a hit (the clock after). An access a
//                     clock: the next request is taken in an access's address clock. If that access then has more to do (a
//                     miss, a full store buffer, not cached), the one taken waits (h_v): the core still drives its address
//                     clock's signals, and it's read again (D_HRD) and done after. A hit reads the words of the stores whose
//                     write to the line came in or after its read's clock (the store before it, one at a time).
//   not cached:       (d_cacheable low, or across 8 bytes) one or two words, after the store buffer has drained; a store
//                     across 8 bytes invalidates its lines in both caches. Not memory (d_mem low): the u_ port, one access.
//
// The memory port takes one job at a time, the store buffer first: words (burst 1), lines (burst 4), with mem_a the
// physical address of the first word. A line read waits for the store buffer, and a store to a line being read
// keeps that line from being valid, so nothing reads older than a store done.
//
`default_nettype none
module ppc_cache #(parameter int KB = 32) (
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
	input  logic [63:0] mem_dout,

	// for rtl/m2_prof.sv, from bit 0: an instruction line coming in, a data line coming in, the write FIFO full, an uncached access or a drain
	output logic [3:0]  pf
);
	localparam int FIFO = 4;
	localparam int IB = $clog2(KB) + 9;       // the index's top address bit (12 at 8 KB)
	localparam int LW = IB - 4;               // a line's index
	localparam int TW = 32 - IB;              // a tag: valid, then the physical address above the index
	localparam int DB = IB - 1;               // the data side's: two ways of KB / 2
	localparam int DL = DB - 4;
	localparam int DT = 32 - DB;

	function automatic logic [31:0] word_be(input logic [63:0] w, input logic hi);
		logic [31:0] v;
		v = hi ? w[63:32] : w[31:0];
		return {v[7:0], v[15:8], v[23:16], v[31:24]};
	endfunction
	// bytes [off, off + n) of two words (the first the lower address), big-endian, right-aligned: the answer's byte i (its
	// last first) the window's off + n - 1 - i, each its own choice (not a chain of shifts, which made the loads' answer
	// in the address clock a long path)
	function automatic logic [63:0] rd_bytes(input logic [63:0] w0, input logic [63:0] w1, input logic [2:0] off,
		input logic [3:0] n);
		logic [127:0] win;
		logic [63:0] v;
		logic [3:0] k;
		win = {w1, w0};
		v = 64'h0;
		for (int i = 0; i < 8; i++)
		begin
			k = {1'b0, off} + n - 4'd1 - 4'(i);
			if (4'(i) < n) v[8 * i +: 8] = win[8 * k +: 8];
		end
		return v;
	endfunction

	// ---- the tags' sweep: all of them invalid after reset, or inv_all ------------------------------------------------------
	logic [LW:0] sw_n;
	wire        sw = !sw_n[LW];
	logic       inv_all;
	always_ff @(posedge clk)
		if (rst || inv_all) sw_n <= '0;
		else if (sw) sw_n <= sw_n + (LW+1)'(1);

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
	logic [31:IB+1] i_lpa;
	logic [1:0]  i_wn;                  // the line's next beat
	logic        i_zero;                // the line isn't memory
	logic        i_killed, i_cancel;    // the fetch dropped; a store to the line
	logic [1:0]  i_recent;              // its tag was written these clocks ago (a store that read the tag before it)

	logic [TW-1:0] it_q, it2_q;
	logic [63:0] id_q;
	logic [LW-1:0] it_ra, it_wa;
	logic [TW-1:0] it_wd;
	logic        it_we;
	logic        s_inv, s_inv_q;        // a store's line goes: its tag written this clock; the clock after
	logic [LW-1:0] s_idx, s_idx_q, i_idx;
	logic        h_st;                  // a store waits at the data side (till its address clock again), at index h_idx
	logic [LW-1:0] h_idx, h_idx2;       // ... and h_idx2 (the next, if it runs into the next line)

	// verilator lint_off UNUSEDSIGNAL
	wire [31:0]  i_rva = i_st == I_REPLAY ? i_lva : if_va;
	// verilator lint_on UNUSEDSIGNAL
	logic        x_inv;                 // a store across 8 bytes: a line of it goes, x_idx's
	logic [LW-1:0] x_idx;
	wire         i_scan = sw || x_inv || (s_inv && s_idx == i_idx) || (s_inv_q && s_idx_q == i_idx) ||
		(h_st && (h_idx == i_idx || h_idx2 == i_idx));
	wire         i_hit = it_q[TW-1] && it_q[TW-2:0] == if_pa[31:IB+1] && !i_scan;
	wire         i_miss = i_out && !i_hit;
	assign if_valid = i_out && i_hit;
	assign if_data = word_be(id_q, if_pa[2]);
	assign if_rdy = i_st == I_RUN && !sw && (!i_out || if_valid || if_kill);

	ppc_ram #(.W(64), .AW(IB-2)) i_data
	(
		.clk,
		.we(line_beat && e_own == J_ILINE), .wa({i_lva[IB:5], i_wn}), .wd(i_zero ? 64'h0 : mem_dout),
		.ra(i_rva[IB:3]), .rd(id_q)
	);
	assign it_ra = i_rva[IB:5];
	ppc_ram #(.W(TW), .AW(LW)) i_tag (.clk, .we(it_we), .wa(it_wa), .wd(it_wd), .ra(it_ra), .rd(it_q));
	logic [IB:3] d_rva;                 // the data side's read address (in D_HRD the held access's, which is d_pa)
	ppc_ram #(.W(TW), .AW(LW)) i_tag2 (.clk, .we(it_we), .wa(it_wa), .wd(it_wd), .ra(d_rva[IB:5]), .rd(it2_q));
	logic [TW-1:0] it3_q;
	ppc_ram #(.W(TW), .AW(LW)) i_tag3 (.clk, .we(it_we), .wa(it_wa), .wd(it_wd), .ra(sn_a[IB:5]), .rd(it3_q));
	assign sn_i = sn1_v && ((it3_q[TW-1] && it3_q[TW-2:0] == sn1_a[31:IB+1]) || (i_recent[0] && sn1_a == {i_lpa, i_lva[IB:5]}));

	always_comb
	begin
		it_we = 1'b0; it_wa = '0; it_wd = '0;
		if (sw) begin it_we = 1'b1; it_wa = sw_n[LW-1:0]; end
		else if (s_inv) begin it_we = 1'b1; it_wa = s_idx; end
		else if (sn_i) begin it_we = 1'b1; it_wa = sn1_a[IB:5]; end
		else if (i_st == I_TAG)
		begin
			it_we = 1'b1; it_wa = i_lva[IB:5]; it_wd = {!i_cancel, i_lpa};
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
			if (if_req && if_rdy) i_idx <= if_va[IB:5];
			else if (i_st == I_REPLAY) i_idx <= i_lva[IB:5];
			if (if_kill) i_killed <= i_st != I_RUN;
			if (store_a && d_pa[31:5] == {i_lpa, i_lva[IB:5]}) i_cancel <= 1'b1;
			if (sn_v && sn_a == {i_lpa, i_lva[IB:5]}) i_cancel <= 1'b1;
			if (inv_all || (x_inv && x_idx == i_lva[IB:5])) i_cancel <= 1'b1;
			case (i_st)
				I_RUN:
				begin
					i_out <= if_req && if_rdy;
					if (i_miss && !if_kill)
					begin
						i_lva <= if_pa;
						i_lpa <= if_pa[31:IB+1];
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
	wire i_snoop = store_a && ((it2_q[TW-1] && it2_q[TW-2:0] == d_pa[31:IB+1]) ||
		((i_st == I_TAG || i_recent != 2'd0) && d_pa[31:5] == {i_lpa, i_lva[IB:5]}));
	always_ff @(posedge clk)
	begin
		s_inv <= !rst && (i_snoop || x_inv);
		s_idx <= x_inv ? x_idx : d_pa[IB:5];
		s_inv_q <= !rst && s_inv;
		s_idx_q <= s_idx;
	end

	// ---- the data side ------------------------------------------------------------------------------------------------
	// D_APH: an access's address clock (the core's, or the held one's again); D_HRD: the held one's read
	typedef enum logic [3:0] { D_IDLE, D_APH, D_WFULL, D_LINE, D_XINV, D_DRAIN, D_U, D_STUB, D_HRD } dst_t;
	// (Verilator takes the tasks' writes for another process)
	// verilator lint_off MULTIDRIVEN
	dst_t        d_st;
	logic        d_resp;                // the answer, this clock (d_val)
	// verilator lint_on MULTIDRIVEN
	logic        h_v, h_aph;            // an access taken waits; its address clock is this clock (it may be killed)
	logic [31:0] p_pa;
	logic [3:0]  p_size;
	logic [63:0] p_wdata;
	logic [63:0] d_val;
	logic        p_we, p_cross, d_wr;   // d_wr: a store hit's write to the line, the clock after it's done
	logic [63:0] d_wd;
	logic [7:0]  d_be;
	logic [DB:3] d_wa;
	logic        dw1_v, dw1_way;        // d_wr's of the clock before (what a read then may not have seen)
	logic [DB:3] dw1_wa;
	logic [63:0] dw1_wd;
	logic [7:0]  dw1_be;
	logic [1:0]  d_wn;
	logic        p_mem, p_hit, x_n;
	logic        d_cancel;              // the line read isn't to be kept: a write to it, or inv_all
	logic        d_recent;              // its tag was written last clock
	logic [127:0] p_win;
	logic [15:0]  p_be;

	logic [DT-1:0] dt_q [2];
	logic [63:0] dd_q [2];
	logic        lru_q;                 // d_va's index: the way to replace
	logic        p_way;                 // the way hit, or the way the line read goes to
	wire  [1:0]  d_hw;
	assign d_hw[0] = dt_q[0][DT-1] && dt_q[0][DT-2:0] == d_pa[31:DB+1];
	assign d_hw[1] = dt_q[1][DT-1] && dt_q[1][DT-2:0] == d_pa[31:DB+1];
	wire         d_hit = |d_hw;
	// each way's word, with the store writes its read came before: the one in its read's clock (dw1), the one now (d_wr)
	logic [63:0] dd_m [2];
	always_comb
		for (int w = 0; w < 2; w++)
		begin
			dd_m[w] = dd_q[w];
			for (int b = 0; b < 8; b++)
			begin
				if (dw1_v && dw1_way == 1'(w) && dw1_wa == d_pa[DB:3] && dw1_be[b]) dd_m[w][8 * b +: 8] = dw1_wd[8 * b +: 8];
				if (d_wr && p_way == 1'(w) && d_wa == d_pa[DB:3] && d_be[b]) dd_m[w][8 * b +: 8] = d_wd[8 * b +: 8];
			end
		end
	wire [63:0]  dd_hq = d_hw[1] ? dd_m[1] : dd_m[0];
	wire         d_cross = {1'b0, d_pa[2:0]} + d_size > 4'd8;
	// one byte-picker for every load's answer: a hit's way (in the address clock), a line's beat, an uncached word or two
	wire         rb_aph = d_st == D_APH;
	wire [63:0]  rb_w0 = rb_aph ? dd_hq : d_st == D_U && p_cross ? e_rd0 : mem_dout;
	wire [63:0]  rb_w1 = !rb_aph && p_cross ? mem_dout : 64'h0;
	wire [63:0]  rb = rd_bytes(rb_w0, rb_w1, rb_aph ? d_pa[2:0] : p_pa[2:0], rb_aph ? d_size : p_size);
	assign store_a = d_st == D_APH && !d_kill && d_we && d_mem && d_writable;
	assign x_inv = d_st == D_XINV;
	assign x_idx = x_n ? p_pa[IB:5] + LW'(p_pa[4:3] == 2'd3) : p_pa[IB:5];
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

	assign pf = {d_st == D_DRAIN || d_st == D_U, d_st == D_WFULL, d_st == D_LINE, i_st != I_RUN};
	assign d_valid = d_resp;
	// (not as the sweep starts either: a line read in whose tag a snoop's write displaced still has the old one, inv_all)
	assign d_rdy = !sw && !inv_all && (d_st == D_IDLE || d_st == D_APH);
	assign d_rdata = d_val;
	assign d_rva = d_st == D_HRD ? d_pa[IB:3] : d_va[IB:3];
	wire d_take = d_req && d_rdy;
	assign u_pa = p_pa; assign u_we = p_we; assign u_size = p_size; assign u_wdata = p_wdata;
	assign u_req = d_st == D_DRAIN && w_empty && !p_mem;

	wire line_d = line_beat && e_own == J_DLINE;
	wire         d_fill = line_last && e_own == J_DLINE;
	// each way: its data, its tags (and the snoop's copy); the sweep and a store across 8 bytes clear both
	logic [1:0]  sn_dw;
	assign sn_d = |sn_dw;
	genvar w;
	generate
	for (w = 0; w < 2; w++)
	begin : g_dw
		wire          mine = p_way == 1'(w);
		ppc_ram_be #(.AW(DB-2)) i_ddata
		(
			.clk,
			.we((d_wr || line_d) && mine), .be(line_d ? 8'hff : d_be), .wa(line_d ? {p_pa[DB:5], d_wn} : d_wa),
			.wd(line_d ? mem_dout : d_wd), .ra(d_rva[DB:3]), .rd(dd_q[w])
		);
		wire          dt_we = sw || x_inv || sn_dw[w] || (d_fill && mine);
		wire [DL-1:0] dt_wa = sw ? sw_n[DL-1:0] : x_inv ? x_idx[DL-1:0] : sn_dw[w] ? sn1_a[DB:5] : p_pa[DB:5];
		wire [DT-1:0] dt_wd = sw || x_inv || sn_dw[w] ? '0 : {!d_cancel && !inv_all, p_pa[31:DB+1]};
		ppc_ram #(.W(DT), .AW(DL)) i_dtag (.clk, .we(dt_we), .wa(dt_wa), .wd(dt_wd), .ra(d_rva[DB:5]), .rd(dt_q[w]));
		logic [DT-1:0] dt2_q;
		ppc_ram #(.W(DT), .AW(DL)) i_dtag2 (.clk, .we(dt_we), .wa(dt_wa), .wd(dt_wd), .ra(sn_a[DB:5]), .rd(dt2_q));
		assign sn_dw[w] = sn1_v && ((dt2_q[DT-1] && dt2_q[DT-2:0] == sn1_a[31:DB+1]) || (d_recent && mine && sn1_a == p_pa[31:5]));
	end
	endgenerate
	// the least recent way: the other one, after a hit or a line read in
	wire          lru_we = (d_st == D_APH && !d_kill && d_mem && d_cacheable && d_hit) || d_fill;
	wire [DL-1:0] lru_wa = d_fill ? p_pa[DB:5] : d_pa[DB:5];
	wire          lru_wd = d_fill ? !p_way : !d_hw[1];
	ppc_ram #(.W(1), .AW(DL)) i_lru (.clk, .we(lru_we), .wa(lru_wa), .wd(lru_wd), .ra(d_rva[DB:5]), .rd(lru_q));
	always_ff @(posedge clk)
	begin
		inv_all <= !rst && !sw && ((sn_d && (x_inv || d_fill)) || (sn_i && s_inv));
		d_recent <= d_fill && !sw && !x_inv && !sn_d;
	end

	// the access in its address clock answers next clock, and the one taken now (if any) has its address clock then
	task automatic d_done();
		d_resp <= 1'b1;
		d_st <= d_take ? D_APH : D_IDLE;
	endtask
	// ... or it has more to do, and the one taken now waits
	task automatic d_busy(input dst_t s);
		d_st <= s;
		if (d_take) begin h_v <= 1'b1; h_aph <= 1'b1; end
	endtask
	// ... which is done: it answers next clock, the one waiting (not killed in its address clock) is read again
	task automatic d_finish();
		d_resp <= 1'b1;
		d_st <= h_v && !(h_aph && d_kill) ? D_HRD : D_IDLE;
	endtask
	always_ff @(posedge clk)
	begin
		d_wr <= 1'b0;
		d_resp <= 1'b0;
		h_aph <= 1'b0;
		dw1_v <= d_wr; dw1_way <= p_way; dw1_wa <= d_wa; dw1_wd <= d_wd; dw1_be <= d_be;
		if (h_aph && d_kill) h_v <= 1'b0;
		if (h_aph && !d_kill && d_we)
		begin
			h_st <= 1'b1; h_idx <= d_pa[IB:5]; h_idx2 <= d_pa[IB:5] + LW'(d_cross && d_pa[4:3] == 2'd3);
		end
		else if (d_st == D_APH) h_st <= 1'b0;
		if (inv_all || (sn_v && sn_a == p_pa[31:5])) d_cancel <= 1'b1;
		if (rst)
		begin
			d_st <= D_IDLE; d_line_pend <= 1'b0; u_pend <= 1'b0; h_v <= 1'b0; h_st <= 1'b0;
		end
		else
		begin
			if (e_pick_u) u_pend <= 1'b0;
			if (e_pick_d) d_line_pend <= 1'b0;
			case (d_st)
				D_IDLE: d_st <= d_take ? D_APH : D_IDLE;
				D_HRD: if (!sw && !inv_all) begin h_v <= 1'b0; d_st <= D_APH; end
				D_APH:
					if (d_kill) d_st <= d_take ? D_APH : D_IDLE;
					else
					begin
						p_pa <= d_pa; p_we <= d_we; p_size <= d_size; p_wdata <= d_wdata; p_cross <= d_cross;
						p_win <= s_win; p_be <= s_be;
						p_mem <= d_mem; p_hit <= d_cacheable && d_hit; p_way <= d_hit ? d_hw[1] : lru_q;
						if (!d_mem) d_busy(D_DRAIN);
						else if (d_we)
						begin
							if (!d_writable) begin d_val <= 64'h0; d_done(); end
							else if (d_cross) begin x_n <= 1'b0; d_busy(D_XINV); end
							else if (w_full) d_busy(D_WFULL);
							else
							begin
								d_wr <= d_cacheable && d_hit;
								d_wa <= d_pa[DB:3]; d_wd <= s_win[63:0]; d_be <= s_be[7:0];
								d_val <= 64'h0;
								d_done();
							end
						end
						else if (d_cacheable && !d_cross)
						begin
							if (d_hit) begin d_val <= rb; d_done(); end
							else begin d_line_pend <= 1'b1; d_line_a <= d_pa[31:5]; d_wn <= 2'd0; d_cancel <= inv_all; d_busy(D_LINE); end
						end
						else d_busy(D_DRAIN);
					end
				D_WFULL:
					if (!w_full)
					begin
						d_wr <= p_hit;
						d_wa <= p_pa[DB:3]; d_wd <= p_win[63:0]; d_be <= p_be[7:0];
						d_val <= 64'h0;
						d_finish();
					end
				D_LINE:
					if (line_d)
					begin
						d_wn <= d_wn + 2'd1;
						if (d_wn == p_pa[4:3]) d_val <= rb;
						if (line_last) d_finish();
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
						d_val <= p_we ? 64'h0 : rb;
						d_finish();
					end
				D_STUB:
					if (u_ack) begin d_val <= u_rdata; d_finish(); end
				default: d_st <= D_IDLE;
			endcase
		end
	end
endmodule

// a simple dual-port RAM of 2^AW x 64 with byte enables, the read registered; what an entry written in that clock reads
// is either value (the data side puts the written bytes in after: dw1)
module ppc_ram_be #(parameter int AW = 10) (
	input  logic        clk,
	input  logic        we,
	input  logic [7:0]  be,
	input  logic [AW-1:0] wa,
	input  logic [63:0] wd,
	input  logic [AW-1:0] ra,
	output logic [63:0] rd
);
	genvar i;
	generate
	for (i = 0; i < 8; i++)
	begin : g_b
		ppc_ram #(.W(8), .AW(AW)) b (.clk, .we(we && be[i]), .wa, .wd(wd[8 * i +: 8]), .ra, .rd(rd[8 * i +: 8]));
	end
	endgenerate
endmodule
