// PowerPC 602 as MAME 0.289 runs it, pipelined: the same instruction semantics as rtl/ppc_core.sv (checked against the
// reference model, tools/ref/ppc602, by sim/ppccore and sim/ppcreplay), an instruction a clock when nothing stalls.
//
//   fetch:  a request a clock to the instruction side (virtually indexed: the address goes out unregistered, the physical
//           address follows the next clock, from the translation of the registered one). The response goes to X, or to
//           the skid register when X is stalled; the next fetch goes out only when the skid will be free. A b, or a bc
//           statically predicted taken, sends the next fetch to its target (with the response).
//   X:      decode, execute and write back (GPRs, CR, XER, the SPRs, MSR), branches (one predicted the wrong way, a
//           bclr / bcctr taken, or a redirect costs one clock) and the data request (its virtual address). Its GPRs are
//           read the clock before, for the instruction it will hold.
//           Exceptions and interrupts are taken here: X goes to EXC for one clock (SRR0 / SRR1 / MSR), then the vector.
//   M:      the clock after the request, its translation: the physical address out, or a fault, taken precisely (the
//           instruction X holds then isn't taken, an update form's rA is put back); a store that may cover an instruction
//           already fetched (by its offset in the page) refetches after it. An access retires here (with X's next instruction, perhaps: retire2).
//           Then the response to a load (the GPR or FPR written the clock it comes); a store's acknowledge. Two accesses
//           out (M, and the one behind it, N): the next may go in one's address clock, and they're answered in order.
//   FP:     rtl/ppc_fpp.sv beside X, the float pipeline (an op a clock, its FPR written at its end), and rtl/ppc_fpu.sv
//           for divide and square root (with the pipeline empty, and stopping it); with MSR[FP] clear an FP op takes the
//           FP-unavailable exception (the kernel's lazy switch of the FPRs between tasks), otherwise no FP op faults. fcmpu /
//           fcmpo and the moves are X's (the moves written through M). The FPRs are singles, as the 602's (rtl/ppc_fps.sv): lfd
//           takes the nearest single, stfd waits a clock for its double.
// The GPRs and FPRs are in RAM (rtl/ppc_regs.sv), read the clock before X (for the instruction it will hold, or SEQ's
// next register): X takes what was written since from the writes it keeps (a clock back; two for X's own, which go to
// the RAM a clock late). With FWD, a register written in a clock (M's load or move, a float unit's result) is forwarded
// to X in that clock too; without it (the default: the forward is 3 ns of the worst path) an instruction using it waits a
// clock. With FPF (the default), an op to the float pipeline takes the pipeline's results itself as they leave it, from
// its last stage or its result register, so it doesn't wait for them either way; and the float pipeline's result
// register (wv) is forwarded to X's own float instructions (compares, moves, stores) as with FWD.
// Hazards stall X: a source or destination that a load in M or a float unit hasn't written yet; a third access while
// two are out; the float units not free for the op. Multi-access instructions (lmw, stmw, lsw, stsw, dcbz, stwcx.)
// run in X one access at a time with M empty (SEQ); divw in DIV. The instructions that change fetch translation
// (mtmsr, mtsr, IBATs, HID0, esa / dsa, rfi, isync) and a store to an instruction already fetched refetch after them.
// TGPR: r0-r3 are physical 32-35 while MSR[TGPR] (tsel), so taking a TLB-miss exception moves nothing.
//
// Bench: retire is a clock when an instruction (or exception) is done, in order (retire2: two, an access then the
// instruction after it); the registers out are the
// architectural state then, but for the GPRs / FPRs in gpr_pend_o / fpr_pend_o (older loads and float ops not yet
// written). dbg_hold stops X before its next instruction (dbg_idle once M and the float unit are empty, the fetches
// flushed); dropping it for one clock runs one instruction.
`default_nettype none
module ppc_pipe #(
	parameter bit FWD = 1'b0,           // forward the registers written in a clock to X then
	parameter bit FPF = 1'b1,           // the float pipeline takes its own results as they leave it (FWD or not)
	parameter bit BENCH = 1'b1,         // the bench's outputs of the registers (gpr_o, fpr_o; else 0)
	parameter bit FP_EXT = 1'b0,        // the float units are outside, shared (rtl/ppc_fpx.sv) ...
	parameter bit FP_ID = 1'b0,         // ... and this CPU is this one of the two
	parameter bit FP_EXC = 1'b1         // the FP-unavailable exception (0: none, as MAME has it, for sim/ppcreplay's replay of its traces)
) (
	input  logic        clk,
	input  logic        rst,            // held while 1; on release, the 602's reset (PC 0xfff00100, MSR[IP])

	// instruction side: a request is taken at the clock edge when if_req && if_rdy; its response (if_valid, if_data) comes
	// on a later clock, while the core drives if_pa (its physical address). if_kill drops the request that's out (its
	// response, if this clock, is ignored); a new request may go out with it. One request out at a time.
	output logic        if_req,
	output logic [31:0] if_va,
	input  logic        if_rdy,
	output logic [31:0] if_pa,
	output logic        if_kill,
	input  logic        if_valid,
	input  logic [31:0] if_data,

	// data side: a request is taken at the edge when d_req && d_rdy, with d_va (its virtual address); the next clock
	// (its address clock) the core drives it: d_pa (physical), d_we, d_size (1, 2, 4 or 8, any alignment), d_wdata
	// (right-aligned, big-endian), or d_kill to drop it; and goes on driving them (but d_kill) until the next is taken.
	// d_valid answers it, in that clock or later (never one killed), with d_rdata for a read. Two out at most: the next
	// may be taken in one's address clock or later, and they're answered in order.
	output logic        d_req,
	output logic [31:0] d_va,
	output logic        d_kill,
	output logic        d_we,
	output logic [31:0] d_pa,
	output logic [3:0]  d_size,
	output logic [63:0] d_wdata,
	input  logic        d_rdy,
	input  logic        d_valid,
	input  logic [63:0] d_rdata,

	input  logic        int_ext,        // external interrupt (level; taken when MSR[EE])
	input  logic        dec_tick,       // decrement DEC (the bus clock / 4 on the board)
	input  logic        tb_tick,        // advance TB

	// bench: an instruction finished, its address and word, the state after it; retire2: two (ipc0_o / iop0_o the first)
	output logic        retire,
	output logic        retire2,
	output logic [31:0] ipc0_o,
	output logic [31:0] iop0_o,
	output logic [31:0] ipc_o,
	output logic [31:0] iop_o,
	output logic [4:0]  exc_o,          // the exception it took (0: none)
	output logic        timer_read_o,   // it read TB or DEC
	output logic [31:0] pc_o,
	output logic [32*32-1:0] gpr_o,
	output logic [64*32-1:0] fpr_o,
	output logic [31:0] cr_o, lr_o, ctr_o, xer_o, msr_o, srr0_o, srr1_o, fpscr_o,
	output logic [31:0] gpr_pend_o,     // GPRs an older load hasn't written yet, or an access not yet retired has
	output logic [31:0] fpr_pend_o,     // FPRs an older load or float op hasn't written yet
	// bench: what X did this clock (0 took an instruction, 1 empty, 2 a GPR from a load, 3 an FPR from a load or move,
	// 4 an FPR from the float unit, 5 the float unit busy, 6 an access out, 7 a multi-clock state, 8 held), at perf_pc_o
	output logic [3:0]  perf_o,
	output logic [31:0] perf_pc_o,
	// bench: while rst, or held (dbg_idle), load a register: 0-31 GPRs, 32-63 FPRs, 64 PC, 65 CR, 66 XER, 67 MSR,
	// 68 FPSCR, 69 DEC, 70 TBL, 71 TBU, 72-75 TGPRs, 80-95 SRs, 1024+n SPR n
	input  logic        dbg_hold,
	output logic        dbg_idle,
	input  logic        dbg_we,
	input  logic [10:0] dbg_idx,
	input  logic [63:0] dbg_val,
	// bench: while held, take an interrupt now (where MAME took it): 1 external, 2 decrementer
	input  logic [1:0]  dbg_int,

	// the float units, with FP_EXT
	output ppc_fpu_pkg::fp_req_t fp_req,
	// verilator lint_off UNUSEDSIGNAL
	input  ppc_fpu_pkg::fp_res_t fp_res
	// verilator lint_on UNUSEDSIGNAL
);
	import ppc_fpu_pkg::*;

	// ---- architectural state ------------------------------------------------------------------------------------------
	// (the GPRs and FPRs: ppc_regs below; these copies are the bench's)
	logic [31:0] gpr [0:35];            // r0-r31, then the TGPRs' other bank (32-35)
	logic        tsel;                  // r0-r3 are 32-35 (MSR[TGPR] as the core has followed it)
	logic [32:0] fpr [0:31];            // (the bench's copies; bit 32: the value's an integer, see rtl/ppc_fps.sv)
	logic [3:0]  crf [0:7];
	logic [30:0] xer;                   // OV, CA, byte count (SO, bit 31, is xerso)
	logic        xerso;
	logic [31:0] msr, fpscr;
	logic [31:0] pc;                    // the next instruction in program order (after what X has taken)
	logic [1:0]  fmode;                 // the float unit's rounding mode (see MTFSB0)
	logic [31:0] sr [0:15];
	logic [31:0] dec;
	logic [63:0] tb;
	logic        reserved;

	// the SPRs this core keeps, by MAME's number
	localparam int NSPR = 48;
	logic [31:0] sprv [0:NSPR-1];
	function automatic int spr_idx(input logic [9:0] n);
		case (n)
			10'd8: return 0;    10'd9: return 1;    10'd18: return 2;   10'd19: return 3;   10'd25: return 4;
			10'd26: return 5;   10'd27: return 6;   10'd272: return 7;  10'd273: return 8;  10'd274: return 9;
			10'd275: return 10; 10'd282: return 11; 10'd528: return 12; 10'd529: return 13; 10'd530: return 14;
			10'd531: return 15; 10'd532: return 16; 10'd533: return 17; 10'd534: return 18; 10'd535: return 19;
			10'd536: return 20; 10'd537: return 21; 10'd538: return 22; 10'd539: return 23; 10'd540: return 24;
			10'd541: return 25; 10'd542: return 26; 10'd543: return 27; 10'd976: return 28; 10'd977: return 29;
			10'd978: return 30; 10'd979: return 31; 10'd980: return 32; 10'd981: return 33; 10'd982: return 34;
			10'd984: return 35; 10'd986: return 36; 10'd987: return 37; 10'd990: return 38; 10'd991: return 39;
			10'd1008: return 40; 10'd1009: return 41; 10'd1010: return 42; 10'd1013: return 43; 10'd1021: return 44;
			10'd1022: return 45; 10'd346: return 46; 10'd1011: return 47;
			default: return -1;
		endcase
	endfunction
	localparam int X_LR = 0, X_CTR = 1, X_DSISR = 2, X_DAR = 3, X_SDR1 = 4, X_SRR0 = 5, X_SRR1 = 6, X_IBAT = 12,
		X_DBAT = 20, X_DMISS = 28, X_DCMP = 29, X_HASH1 = 30, X_HASH2 = 31, X_IBR = 36, X_ESASRR = 37, X_HID0 = 40;

	localparam logic [31:0] MSR_AP = 32'h00800000, MSR_SA = 32'h00400000,
		MSR_TGPR = 32'h00020000, MSR_EE = 32'h00008000, MSR_PR = 32'h00004000, MSR_IP = 32'h00000040,
		MSR_IR = 32'h00000020, MSR_DR = 32'h00000010, MSR_LE = 32'h00000001;
	localparam logic [4:0] EX_DSI = 3, EX_ISI = 4, EX_EI = 5, EX_PROGRAM = 7, EX_FPU = 8, EX_DECREMENT = 9, EX_SYSCALL = 12,
		EX_ITLBMISS = 16, EX_DTLBMISSL = 17, EX_DTLBMISSS = 18;

	// a GPR's physical register
	function automatic logic [5:0] pg(input logic [4:0] r);
		return r < 5'd4 && tsel ? {4'b1000, r[1:0]} : {1'b0, r};
	endfunction

	function automatic logic [31:0] get_cr();
		logic [31:0] v;
		for (int i = 0; i < 8; i++) v[31 - 4 * i -: 4] = crf[i];
		return v;
	endfunction

	// ---- helpers ------------------------------------------------------------------------------------------------------
	// (no adder on s: the word twice, shifted)
	// verilator lint_off UNUSEDSIGNAL
	function automatic logic [31:0] rol32(input logic [31:0] v, input logic [4:0] s);
		logic [63:0] w;
		w = {v, v} << s;
		return w[63:32];
	endfunction
	// verilator lint_on UNUSEDSIGNAL
	// bits mb to me (bit 0 the top), wrapping round if mb > me (wrap, which the caller knows early)
	// verilator lint_off UNUSEDSIGNAL
	function automatic logic [31:0] ror32(input logic [31:0] v, input logic [4:0] s);
		logic [63:0] w;
		w = {v, v} >> s;
		return w[31:0];
	endfunction
	// verilator lint_on UNUSEDSIGNAL
	function automatic logic [31:0] rlw_mask(input logic [4:0] mb, input logic [4:0] me, input logic wrap);
		logic [31:0] m;
		m = (32'hffffffff >> mb) ^ (32'h7fffffff >> me);
		return wrap ? ~m : m;
	endfunction
	function automatic logic [3:0] cmp4(input logic lt, input logic gt, input logic so);
		return {lt, gt, !lt && !gt, so};
	endfunction
	function automatic logic [31:0] crmask(input logic [2:0] n);
		return 32'hf0000000 >> {n, 2'b00};
	endfunction
	function automatic logic [31:0] clz32(input logic [31:0] x);
		for (int i = 31; i >= 0; i--)
			if (x[i]) return 32'(31 - i);
		return 32'd32;
	endfunction
	function automatic logic [63:0] bswapn(input logic [31:0] v, input logic [3:0] size);
		if (size == 4'd2) return {48'h0, v[7:0], v[15:8]};
		return {32'h0, v[7:0], v[15:8], v[23:16], v[31:24]};
	endfunction
	// (not all of these arguments' bits are used)
	// verilator lint_off UNUSEDSIGNAL
	// a store [a, a + n) may cover the instruction word at ia: their offsets in the page, which translation doesn't change,
	// so this needs no translation (a match in another page only costs a refetch). w: the words after a's that it reaches,
	// (a[1:0] + n - 1) / 4 (cov_w, with the address)
	function automatic logic covers(input logic [11:0] a, input logic [2:0] w, input logic [11:0] ia);
		logic [9:0] d;
		d = ia[11:2] - a[11:2];
		return d <= {7'd0, w};
	endfunction
	function automatic logic [2:0] cov_w(input logic [1:0] a, input logic [3:0] n);
		logic [4:0] l;
		l = {3'b000, a} + {1'b0, n} - 5'd1;
		return l[4:2];
	endfunction
	// verilator lint_on UNUSEDSIGNAL

	// BAT / protection-only translation (MAME's ppccom_translate_address_internal for a 602); type 0 read, 1 write, 2 fetch
	typedef struct packed { logic ok; logic prot; logic [31:0] pa; } tr_t;
	logic [15:0] sr_n;                  // the SRs' N bits (Quartus 17 crashes reading sr[] in translate)
	always_comb for (int i = 0; i < 16; i++) sr_n[i] = sr[i][28];
	function automatic tr_t translate(input logic [31:0] a, input logic [1:0] typ);
		tr_t t;
		logic transpriv, hit;
		int base;
		t.ok = 1'b1; t.prot = 1'b0; t.pa = a;
		if ((typ == 2 && !msr[5]) || (typ != 2 && !msr[4])) return t;
		transpriv = !msr[14];
		base = typ == 2 ? X_IBAT : X_DBAT;
		hit = 1'b0;
		// the lowest-numbered match wins
		for (int n = 0; n < 4; n++)
		begin
			logic [31:0] upper, lower, mask;
			upper = sprv[base + 2 * n];
			lower = sprv[base + 2 * n + 1];
			mask = (~upper << 15) & 32'hfffe0000;
			if (!hit && upper[{4'd0, transpriv}] && (a & mask) == (upper & mask))
			begin
				hit = 1'b1;
				t.ok = typ == 1 ? lower[1:0] == 2'd2 : lower[1:0] != 2'd0;
				t.prot = !t.ok;
				t.pa = (lower & mask) | (a & ~mask);
			end
		end
		if (!hit && !sprv[X_HID0][7])
		begin
			// no BAT and not protection-only mode (which maps it to itself): a miss, or for a fetch a no-execute segment
			t.ok = 1'b0;
			t.prot = typ == 2 && sr_n[a[31:28]];
		end
		return t;
	endfunction

	// MFSPR (MAME's ppccom_execute_mfspr for a 602)
	function automatic logic [31:0] mfspr_v(input logic [9:0] n);
		int k;
		case (n)
			10'd1:   return {xerso, xer};
			10'd287: return 32'h00050200;
			10'd22:  return dec;
			10'd268: return tb[31:0];
			10'd269: return {8'h0, tb[55:32]};
			default:
			begin
				k = spr_idx(n);
				return k >= 0 ? sprv[k] : 32'h0;
			end
		endcase
	endfunction

	// verilator lint_off UNUSEDSIGNAL
	// the float op an instruction sends to the float unit
	typedef struct packed { logic go; logic [4:0] op; } fdec_t;
	function automatic fdec_t fpu_dec(input logic [31:0] o);
		fdec_t d;
		d.go = 1'b1;
		d.op = F_ADD;
		if (o[31:26] == 6'h3b)
			case (o[5:1])
				5'h15: d.op = F_ADDS; 5'h14: d.op = F_SUBS; 5'h19: d.op = F_MULS; 5'h12: d.op = F_DIVS;
				5'h18: d.op = F_RES; 5'h1d: d.op = F_MADDS; 5'h1c: d.op = F_MSUBS;   // (no fsqrts: illegal on the 602, user's manual 4.5.7.2)
				5'h1f: d.op = F_NMADDS; 5'h1e: d.op = F_NMSUBS;
				default: d.go = 1'b0;
			endcase
		else if (o[31:26] == 6'h3f && o[5])
			case (o[5:1])
				5'h15: d.op = F_ADD; 5'h14: d.op = F_SUB; 5'h19: d.op = F_MUL; 5'h12: d.op = F_DIV;
				5'h1a: d.op = F_RSQRTE; 5'h1d: d.op = F_MADD; 5'h1c: d.op = F_MSUB;    // (no fsqrt: illegal)
				5'h1f: d.op = F_NMADD; 5'h1e: d.op = F_NMSUB;
				default: d.go = 1'b0;
			endcase
		else if (o[31:26] == 6'h3f)
			case (o[10:1])
				10'h00c: d.op = F_RSP;
				10'h00e: d.op = F_CTIW;
				10'h00f: d.op = F_CTIWZ;
				default: d.go = 1'b0;
			endcase
		else d.go = 1'b0;
		return d;
	endfunction
	// verilator lint_on UNUSEDSIGNAL

	// ---- control state ------------------------------------------------------------------------------------------------
	typedef enum logic [2:0] { XS_RUN, XS_CHK, XS_DIV, XS_SEQ, XS_EXC } xstate_t;
	// (Verilator takes the tasks' writes for another process)
	// verilator lint_off MULTIDRIVEN
	xstate_t     xstate;
	// verilator lint_on MULTIDRIVEN
	logic        rst_q, hold_q, credit, dec_irq;
	// int_ext a clock later: from the controllers' registers (a long way off) through X to everything after it was a long
	// path; the level a clock late changes nothing a program can see
	logic        int_q;
	always_ff @(posedge clk) int_q <= int_ext;

	// fetch and the instruction in X
	logic        fo, fstop;             // a fetch is out (at fo_va); no more fetches (after a fetch fault) until a redirect
	logic [31:0] fo_va, fpc;            // fpc: the next address to fetch
	logic        xv, sv;                // X and the skid hold an instruction
	logic [31:0] ipc, op, spc, sins;
	logic [1:0]  xflt, sflt;            // the fetch faulted: 1 TLB miss, 2 ISI
	logic        xpred, spred;          // fetched on as a taken branch (to its target)

	// exception entry (EXC)
	logic [4:0]  exc;
	logic [31:0] exc_param, exc_ipc;

	// retire: X's (and the multi-clock states', EXC's); M's
	logic        ret_x, ret_m;
	logic [31:0] ret_ipc, ret_op, retm_ipc, retm_op;
	logic [4:0]  exc_q;
	logic        timer_q;
	logic [31:0] mc_ipc, mc_op;         // the instruction a multi-clock state finishes

	// M's address clock: the access taken last clock (X's, or SEQ's: a_seq), translated as it was taken (nothing that
	// changes the translation runs in a clock X or SEQ takes an access), so its address clock starts from registers
	logic        a_v, a_seq, a_we, a_upd;
	logic [31:0] a_va, a_ipc, a_op, a_rav;  // a_rav: an update form's rA before
	logic [31:0] a_pa;                  // its translation (kept for after: the data side may do it later)
	logic        a_tok, a_tprot;
	logic [3:0]  a_size;
	logic [2:0]  a_cw;                  // (X's: the words after a_va's its store reaches, for a_cov)
	logic [63:0] a_wdata;
	logic [5:0]  a_ra;

	// M: the access out (the older, which d_valid answers)
	typedef enum logic [2:0] { MK_LOAD, MK_LFD, MK_LFS, MK_ST, MK_FMOV } mkind_t;
	logic        m_valid, m_wr_en, m_sext, m_bswap, m_resv;
	mkind_t      m_kind;
	logic [5:0]  m_rd;                  // the physical GPR, or the FPR
	logic [3:0]  m_size;
	logic [32:0] m_val;                 // MK_FMOV: the FPR's value
`ifdef VERILATOR
	logic [32:0] m_vchk;                // (what m_val and gw_v were set to, for the checks)
	logic [31:0] gw_vchk;
`endif
	// N: the one behind it (never a move), to M when M's is answered
	logic        n_valid, n_wr_en, n_sext, n_bswap, n_resv;
	mkind_t      n_kind;
	logic [5:0]  n_rd;
	logic [3:0]  n_size;

	// SEQ: the multi-access instructions
	typedef enum logic [2:0] { Q_LMW, Q_STMW, Q_LSW, Q_STSW, Q_DCBZ, Q_STWCX } qkind_t;
	qkind_t      sq_kind;
	logic [31:0] sq_ea;
	logic [3:0]  sq_size;
	logic [6:0]  sq_count;
	logic [4:0]  sq_reg, sq_ra;
	logic [1:0]  sq_byte;
	logic [63:0] sq_wdata;
	logic        sq_out;
	wire         sq_wr = sq_kind == Q_STMW || sq_kind == Q_STSW || sq_kind == Q_DCBZ || sq_kind == Q_STWCX;

	// DIV
	logic [31:0] dv_q, dv_r, dv_d;
	logic [5:0]  dv_n, dv_rd;
	logic        dv_tw, dv_sgn;         // XS_CHK: a trap's comparison (of dv_q with dv_d, its TO in dv_rd), or a division's
	logic        dv_neg_q, dv_oe, dv_rc;

	// the float units: the pipeline, and beside it the iterative one for divide and square root (which goes only with
	// the pipeline empty, and stops it)
	fdec_t       xf;
	fpk_t        x_fk;                 // xf.op's, for the float control (pd.fk)
	logic        x_slow;                // xf.op is the iterative unit's
	logic        x_madd;                // ... a multiply-add (its addend may come late)
	logic        fpu_busy, fpu_start, fpu_done;
	logic [4:0]  fpu_rd;
	logic [32:0] fpu_res;
	logic        fpp_issue, fpp_ok, fpp_dok, fpp_busy, fpp_ev, fpp_wv;
	logic [4:0]  fpp_erd, fpp_wrd;
	logic [32:0] fpp_evl, fpp_wval;
	logic [31:0] fpp_pe, fpp_pw, fpp_pn, fpp_lb;   // FPRs it writes (ppc_fps_ctl's pe / pw / pn), a late addend's (lb)

	wire m_done = m_valid && (m_kind == MK_FMOV || d_valid);
	wire m_free = !m_valid || (m_done && !n_valid);    // M empty after this clock (for a move)
	wire n_free = !n_valid || m_done;                  // room for another access after this clock
	// the access in its address clock faults: it's N's if N has one (the younger), else M's
	wire n_flt = a_v && !a_seq && a_flt && n_valid;
	wire fpu_free = !fpu_busy || fpu_done;
	// a float op can go: to the pipeline (with the iterative unit free), or to the iterative unit (with both empty)
	ppc_fpu_pkg::fp_res_t fr;
	wire fp_free = x_slow ? fpu_free && !fpp_busy && fr.allow[FP_ID] && fr.ffree : fpp_ok && fpu_free;

	// what's written this clock: M's load (to a GPR or an FPR) or move, the float units' results
	// verilator lint_off UNUSEDSIGNAL
	logic [63:0] m_d;                 // (lfd takes d_rdata whole)
	// verilator lint_on UNUSEDSIGNAL
	logic [32:0] m_fv;
	logic [31:0] m_gv;
	logic        m_gw, m_fw;
	always_comb
	begin
		m_d = m_bswap ? bswapn(d_rdata[31:0], m_size) : d_rdata;
		m_gv = m_sext ? {{16{m_d[15]}}, m_d[15:0]} : m_d[31:0];
		m_fv = m_kind == MK_LFD ? d2f(d_rdata) : m_kind == MK_LFS ? {1'b0, d_rdata[31:0]} : m_val;   // (never byte reversed)
		m_gw = m_done && m_kind == MK_LOAD && m_wr_en;
		m_fw = m_done && (m_kind == MK_LFD || m_kind == MK_LFS || m_kind == MK_FMOV);
	end
	// X's GPRs, read the clock before (gr_a / gr_b / gr_s, for its rA / rB / rS) with what was written since: in that
	// clock (gw_*: X, DIV, SEQ; gm_*: M's load), the one before (gw2_*: X's, which reach the RAM a clock late), this one
	// (M's load, FWD)
	logic [31:0] gr_a, gr_b, gr_s, gw_v, gm_v, gw2_v;
	logic [5:0]  gw_r, gm_r, gw2_r;
	logic        gw_en, gm_en, gw2_en;
	// ... which of those X's rA / rB / rS is ({s, b, a} for gw_ / gm_ / gw2_), found the clock before (gnext), so the
	// compares aren't in front of X's adders and the BAT translation. gh_w is chosen from both ways (gh_wk: X kept its
	// instruction, gh_wn: it took the next) by op_keep's last clock (gh_kq): from X's hazards through op_keep to X's
	// writes' choices was a long path
	logic [2:0]  gh_wk, gh_wn, gh_m, gh_w2;
	logic        gh_kq;
	wire  [2:0]  gh_w = gh_kq ? gh_wk : gh_wn;
	function automatic logic [31:0] gx(input logic [5:0] p, input logic [1:0] k, input logic [31:0] q);
		if (FWD && m_gw && m_rd == p) return m_gv;
		if (gh_w[k]) return gw_v;
		if (gh_m[k]) return gm_v;
		if (gh_w2[k]) return gw2_v;
		return q;
	endfunction
	// (SEQ's, through the rS port, compares)
	function automatic logic [31:0] gxc(input logic [5:0] p, input logic [31:0] q);
		if (FWD && m_gw && m_rd == p) return m_gv;
		if (gw_en && gw_r == p) return gw_v;
		if (gm_en && gm_r == p) return gm_v;
		if (gw2_en && gw2_r == p) return gw2_v;
		return q;
	endfunction
	// the FPRs the same way (fr_a / fr_b / fr_c / fr_s for rA / rB / frC / rD), with the writes of the clock before (fu_*:
	// the float units', fm_*: M's) and this one (FWD; the float pipeline's, a register, with FPF too)
	logic [32:0] fr_a, fr_b, fr_c, fr_s, fu_v, fm_v;
	logic [4:0]  fu_r, fm_r;
	logic        fu_en, fm_en;
	logic        fu_we;                 // the units' write (or the bench's) this clock
	logic [4:0]  fu_wa;
	logic [32:0] fu_wd;
	// ... which of X's rA / rB / frC / rD ({s, c, b, a}: k 0 to 3) the float pipeline's write (fpp_wrd), the units' (fu_r)
	// and M's (fm_r) are, found the clock before both ways and chosen as gh_w is (the compares were in front of the
	// float units' operands)
	logic [3:0]  fh_pk, fh_pn, fh_uk, fh_un, fh_mk, fh_mn;
	wire  [3:0]  fh_p = gh_kq ? fh_pk : fh_pn, fh_u = gh_kq ? fh_uk : fh_un, fh_m = gh_kq ? fh_mk : fh_mn;
	function automatic logic [32:0] fx(input logic [4:0] f, input logic [1:0] k, input logic [32:0] q);
		if ((FWD || FPF) && fpp_wv && fh_p[k]) return fpp_wval;
		if (FWD && fpu_busy && fpu_done && fpu_rd == f) return fpu_res;
		if (FWD && m_fw && m_rd[4:0] == f) return m_fv;
		if (fu_en && fh_u[k]) return fu_v;
		if (fm_en && fh_m[k]) return fm_v;
		return q;
	endfunction

	function automatic logic gpend_n(input logic [5:0] p);
		return n_valid && n_kind == MK_LOAD && n_wr_en && n_rd == p;
	endfunction
	function automatic logic gpend(input logic [5:0] p);
		return (m_valid && m_kind == MK_LOAD && m_wr_en && m_rd == p) || gpend_n(p);
	endfunction
	function automatic logic fpend_n(input logic [4:0] f);
		return n_valid && (n_kind == MK_LFD || n_kind == MK_LFS) && n_rd[4:0] == f;
	endfunction
	function automatic logic fpend_m(input logic [4:0] f);
		return (m_valid && (m_kind == MK_LFD || m_kind == MK_LFS || m_kind == MK_FMOV) && m_rd[4:0] == f) || fpend_n(f);
	endfunction
	function automatic logic fpend_u(input logic [4:0] f);
		return fpp_pn[f] || (fpu_busy && fpu_rd == f);
	endfunction
	function automatic logic fpend(input logic [4:0] f);
		return fpend_m(f) || fpend_u(f);
	endfunction
	// the same for X's hazards: what's not written by the end of this clock (with FWD), or by its start
	function automatic logic gpend_x(input logic [5:0] p);
		return (gpend(p) && !(FWD && m_done)) || gpend_n(p);
	endfunction
	function automatic logic fpend_mx(input logic [4:0] f);
		return (fpend_m(f) && !(FWD && m_done)) || fpend_n(f);
	endfunction
	function automatic logic fpend_ux(input logic [4:0] f);
		return FWD || FPF ? fpp_pw[f] || (fpu_busy && !(FWD && fpu_done) && fpu_rd == f) : fpend_u(f);
	endfunction
	function automatic logic fpend_x(input logic [4:0] f);
		return fpend_mx(f) || fpend_ux(f);
	endfunction
	// for an op to the float pipeline, which takes its results as they leave its last stage (ev; FWD forwards them, with
	// FPF it takes them itself): a source not ready then; a multiply-add's addend not ready by the time the op reaches A0;
	// a destination written later by an op in flight. The float units' part (_u), then with M's
	function automatic logic fpend_fu(input logic [4:0] f);
		return fpu_busy && !(FWD && fpu_done) && fpu_rd == f;
	endfunction
	function automatic logic fpend_pu(input logic [4:0] f);
		return FWD || FPF ? fpp_pe[f] || fpend_fu(f) : fpend_u(f);
	endfunction
	function automatic logic fpend_pbu(input logic [4:0] f);
		return FWD || FPF ? (fpp_pe[f] && !fpp_lb[f]) || fpend_fu(f) : fpend_u(f);
	endfunction
	function automatic logic fpend_pdu(input logic [4:0] f);
		return FWD || FPF ? (fpp_pn[f] && !fpp_dok) || fpend_fu(f) : fpend_u(f);
	endfunction
	function automatic logic fpend_p(input logic [4:0] f);
		return fpend_mx(f) || fpend_pu(f);
	endfunction
	function automatic logic fpend_pb(input logic [4:0] f);
		return fpend_mx(f) || fpend_pbu(f);
	endfunction
	function automatic logic fpend_pd(input logic [4:0] f);
		return fpend_mx(f) || fpend_pdu(f);
	endfunction

	// the float units' operands, with the float pipeline's results as they leave it
	function automatic logic [32:0] fxe(input logic [4:0] f, input logic [1:0] k, input logic [32:0] q);
		return FWD && fpp_ev && fpp_erd == f ? fpp_evl : fx(f, k, q);
	endfunction
	// (an operand's bit 32, an integer's mark, isn't the units': they take its word as a single)
	// verilator lint_off UNUSEDSIGNAL
	wire [32:0] fa_u = fxe(op[20:16], 2'd0, fr_a), fb_u = fxe(op[15:11], 2'd1, fr_b), fc_u = fxe(op[10:6], 2'd2, fr_c);
	// verilator lint_on UNUSEDSIGNAL
	logic [2:0]  fpp_bw, fpp_fe, fpp_fw;
	ppc_fps_ctl fpctl (
		.clk, .rst, .allow(fr.allow[FP_ID]), .res_a(fr.res_a), .res_s(fr.res_s), .res_w(fr.res_w),
		.issue(fpp_issue), .pk(x_fk), .rd(op[25:21]), .ra(op[20:16]), .rb(op[15:11]), .rc(op[10:6]), .ok(fpp_ok),
		.dok(fpp_dok), .busy(fpp_busy), .bw(fpp_bw), .fe(fpp_fe), .fw(fpp_fw), .pe(fpp_pe), .pw(fpp_pw), .pn(fpp_pn), .lb(fpp_lb)
	);
	assign fp_req = '{fpp_issue, fpu_start, xf.op, fmode, fa_u[31:0], fb_u[31:0], fc_u[31:0], op[25:21], fpp_bw,
		FPF ? fpp_fe : 3'b0, FPF ? fpp_fw : 3'b0, xv && xf.go};
	assign fpp_ev = fr.ev && fr.ecpu == FP_ID;
	assign fpp_erd = fr.erd;
	assign fpp_evl = fr.evl;
	assign fpp_wv = fr.wv && fr.wcpu == FP_ID;
	assign fpp_wrd = fr.wrd;
	assign fpp_wval = fr.wval;
	assign fpu_done = fr.fdone && fr.fcpu == FP_ID;
	assign fpu_res = {1'b0, fr.fres};
	generate
	if (FP_EXT) begin : g_fpext assign fr = fp_res; end
	else begin : g_fpint ppc_fpx #(.TWO(1'b0)) fpx (.clk, .rst, .req0(fp_req), .req1('0), .res(fr)); end
	endgenerate

	// the fields an instruction reads or writes, for the hazards (a little more than it uses: the cost is a stall):
	// {g_a, g_b, g_d, f_a, f_b, f_c, f_d, x_fmov}
	// verilator lint_off UNUSEDSIGNAL
	function automatic logic [7:0] rw_dec(input logic [31:0] o);
		logic ga, gb, gd, fa, fb, fc, fd, fm, fpx;
		logic [9:0] x;
		x = o[10:1];
		fpx = o[31:26] == 6'h1f && (x == 10'h217 || x == 10'h237 || x == 10'h257 || x == 10'h277 || x == 10'h297 ||
			x == 10'h2b7 || x == 10'h2d7 || x == 10'h2f7 || x == 10'h3d7);   // an indexed float load / store
		{ga, gb, gd, fa, fb, fc, fd, fm} = '0;
		case (o[31:26])
			6'h10, 6'h11, 6'h12, 6'h13: ;
			6'h1f: begin ga = 1'b1; gb = 1'b1; gd = !fpx; fd = fpx; end
			6'h17: begin ga = 1'b1; gb = 1'b1; gd = 1'b1; end
			6'h30, 6'h31, 6'h32, 6'h33, 6'h34, 6'h35, 6'h36, 6'h37: begin ga = 1'b1; fd = 1'b1; end
			6'h3b:
				case (o[5:1])
					5'h12, 5'h14, 5'h15: {fa, fb, fd} = 3'b111;
					5'h18: {fb, fd} = 2'b11;          // (no fsqrts: illegal on the 602)
					5'h19: {fa, fc, fd} = 3'b111;
					5'h1c, 5'h1d, 5'h1e, 5'h1f: {fa, fb, fc, fd} = 4'b1111;
					default: ;
				endcase
			6'h3f:
				if (o[5])
					case (o[5:1])
						5'h12, 5'h14, 5'h15: {fa, fb, fd} = 3'b111;
						5'h1a: {fb, fd} = 2'b11;          // (no fsqrt: illegal on the 602)
						5'h19: {fa, fc, fd} = 3'b111;
						5'h17: begin {fa, fb, fc, fd} = 4'b1111; fm = 1'b1; end
						5'h1c, 5'h1d, 5'h1e, 5'h1f: {fa, fb, fc, fd} = 4'b1111;
						default: ;
					endcase
				else
					case (x)
						10'h000, 10'h020: {fa, fb} = 2'b11;
						10'h00c, 10'h00e, 10'h00f: {fb, fd} = 2'b11;
						10'h028, 10'h048, 10'h088, 10'h108: begin {fb, fd} = 2'b11; fm = 1'b1; end
						10'h247: begin fd = 1'b1; fm = 1'b1; end
						10'h2c7: fb = 1'b1;
						default: ;
					endcase
			default: begin ga = 1'b1; gd = 1'b1; end
		endcase
		return {ga, gb, gd, fa, fb, fc, fd, fm};
	endfunction
	// the access an instruction makes, from its word alone (xm_*'s decode, which has the rest): a single one (xm_mem), a
	// SEQ one (xm_seq), an stfd's conversion to a double (xm_cvt), a store (xm_we), an update form (xm_upd), an indexed one
	typedef struct packed { logic mem, seq, cvt, we, upd, idx; } mdec_t;
	function automatic mdec_t mem_dec(input logic [31:0] o);
		mdec_t d;
		d = '0;
		d.idx = o[31:26] == 6'h1f;
		if (o[31:26] == 6'h2e || o[31:26] == 6'h2f) d.seq = 1'b1;                                  // LMW, STMW
		else if (o[31:30] == 2'b10 || o[31:29] == 3'b110)                                           // 0x20 to 0x37
		begin
			d.mem = 1'b1;
			d.upd = o[26];
			d.we = o[31:28] == 4'b1001 || o[31:27] == 5'b10110 || o[31:28] == 4'b1101;          // 0x24-27, 0x2c-2d, 0x34-37
			d.cvt = o[31:27] == 5'b11011;                                                           // STFD, STFDU
		end
		else if (d.idx)
			case (o[10:1])
				10'h057, 10'h117, 10'h157, 10'h017, 10'h217, 10'h257, 10'h316, 10'h216, 10'h014: d.mem = 1'b1;
				10'h077, 10'h137, 10'h177, 10'h037, 10'h237, 10'h277: begin d.mem = 1'b1; d.upd = 1'b1; end
				10'h0d7, 10'h197, 10'h097, 10'h3d7, 10'h297, 10'h396, 10'h296: begin d.mem = 1'b1; d.we = 1'b1; end
				10'h2d7: begin d.mem = 1'b1; d.we = 1'b1; d.cvt = 1'b1; end                         // STFDX
				10'h0f7, 10'h1b7, 10'h0b7, 10'h2b7: begin d.mem = 1'b1; d.we = 1'b1; d.upd = 1'b1; end
				10'h2f7: begin d.mem = 1'b1; d.we = 1'b1; d.upd = 1'b1; d.cvt = 1'b1; end            // STFDUX
				10'h255, 10'h215, 10'h2d5, 10'h295, 10'h3f6, 10'h096: d.seq = 1'b1;
				default: ;
			endcase
		return d;
	endfunction
	// X's result for a GPR (x_res) and a float move's (m_val), chosen from the word alone: which (rs); the adder's operands
	// (ad_z rA's a zero, ad_n complemented; ad_b the other; ad_c the carry in); the logic ops' truth table on {rS, b} (lg_t)
	// and their b (lg_b); the moves' (ms, spr, MFSPR's the one spr_rv reads); the float move (fm)
	localparam logic [2:0] R_ADD = 3'd0, R_LOG = 3'd1, R_SH = 3'd2, R_MULL = 3'd3, R_MULH = 3'd4, R_MISC = 3'd5, R_EA = 3'd6;
	localparam logic [2:0] AB_SIMM = 3'd0, AB_SHI = 3'd1, AB_RB = 3'd2, AB_ZERO = 3'd3, AB_ONES = 3'd4;
	localparam logic [1:0] AC_0 = 2'd0, AC_1 = 2'd1, AC_CA = 2'd2;
	localparam logic [1:0] LB_RB = 2'd0, LB_UIMM = 2'd1, LB_UHI = 2'd2;
	localparam logic [2:0] MS_CLZ = 3'd0, MS_EXTSB = 3'd1, MS_EXTSH = 3'd2, MS_CR = 3'd3, MS_MSR = 3'd4, MS_SPR = 3'd5,
		MS_SR = 3'd6, MS_SRIN = 3'd7;
	localparam logic [2:0] FM_B = 3'd0, FM_SEL = 3'd1, FM_NEG = 3'd2, FM_NABS = 3'd3, FM_ABS = 3'd4, FM_FFS = 3'd5;
	typedef struct packed {
		logic [2:0] rs; logic ad_z, ad_n; logic [2:0] ad_b; logic [1:0] ad_c; logic [3:0] lg_t; logic [1:0] lg_b;
		logic [2:0] ms; logic [5:0] spr;
	} rdec_t;
	// an SPR's for spr_rv: sprv's index, or 48 XER, 49 PVR, 50 DEC, 51 TBL, 52 TBU, 63 none
	function automatic logic [5:0] spr_rd(input logic [9:0] n);
		int k;
		case (n)
			10'd1:   return 6'd48;
			10'd287: return 6'd49;
			10'd22:  return 6'd50;
			10'd268: return 6'd51;
			10'd269: return 6'd52;
			default:
			begin
				k = spr_idx(n);
				return k >= 0 ? 6'(k) : 6'd63;
			end
		endcase
	endfunction
	function automatic rdec_t res_dec(input logic [31:0] o);
		rdec_t d;
		// (field by field: Quartus takes a pattern's member names for the module's signals of the same names)
		d.rs = R_ADD; d.ad_z = 1'b0; d.ad_n = 1'b0; d.ad_b = AB_SIMM; d.ad_c = AC_0; d.lg_t = 4'h0; d.lg_b = LB_RB;
		d.ms = MS_CLZ; d.spr = spr_rd({o[15:11], o[20:16]});
		case (o[31:26])
			6'h07: d.rs = R_MULL;                                                                    // MULLI
			6'h08: begin d.ad_n = 1'b1; d.ad_c = AC_1; end                                            // SUBFIC
			6'h0e: d.ad_z = o[20:16] == 5'd0;                                                         // ADDI
			6'h0f: begin d.ad_z = o[20:16] == 5'd0; d.ad_b = AB_SHI; end                              // ADDIS
			6'h14, 6'h15, 6'h17: d.rs = R_SH;
			6'h18: begin d.rs = R_LOG; d.lg_t = 4'b1110; d.lg_b = LB_UIMM; end                        // ORI
			6'h19: begin d.rs = R_LOG; d.lg_t = 4'b1110; d.lg_b = LB_UHI; end                         // ORIS
			6'h1a: begin d.rs = R_LOG; d.lg_t = 4'b0110; d.lg_b = LB_UIMM; end                        // XORI
			6'h1b: begin d.rs = R_LOG; d.lg_t = 4'b0110; d.lg_b = LB_UHI; end                         // XORIS
			6'h1c: begin d.rs = R_LOG; d.lg_t = 4'b1000; d.lg_b = LB_UIMM; end                        // ANDI.
			6'h1d: begin d.rs = R_LOG; d.lg_t = 4'b1000; d.lg_b = LB_UHI; end                         // ANDIS.
			6'h1f:
				case (o[10:1])
					10'h10a, 10'h30a, 10'h00a, 10'h20a: d.ad_b = AB_RB;                               // ADD, ADDC
					10'h08a, 10'h28a: begin d.ad_b = AB_RB; d.ad_c = AC_CA; end                       // ADDE
					10'h0ca, 10'h2ca: begin d.ad_b = AB_ZERO; d.ad_c = AC_CA; end                     // ADDZE
					10'h0ea, 10'h2ea: begin d.ad_b = AB_ONES; d.ad_c = AC_CA; end                     // ADDME
					10'h028, 10'h228, 10'h008, 10'h208: begin d.ad_n = 1'b1; d.ad_b = AB_RB; d.ad_c = AC_1; end // SUBF, SUBFC
					10'h088, 10'h288: begin d.ad_n = 1'b1; d.ad_b = AB_RB; d.ad_c = AC_CA; end       // SUBFE
					10'h0c8, 10'h2c8: begin d.ad_n = 1'b1; d.ad_b = AB_ZERO; d.ad_c = AC_CA; end     // SUBFZE
					10'h0e8, 10'h2e8: begin d.ad_n = 1'b1; d.ad_b = AB_ONES; d.ad_c = AC_CA; end     // SUBFME
					10'h068, 10'h268: begin d.ad_n = 1'b1; d.ad_b = AB_ZERO; d.ad_c = AC_1; end      // NEG
					10'h00b, 10'h04b: d.rs = R_MULH;                                                  // MULHWU, MULHW
					10'h0eb, 10'h2eb: d.rs = R_MULL;                                                  // MULLW
					10'h01c: begin d.rs = R_LOG; d.lg_t = 4'b1000; end                                // AND
					10'h03c: begin d.rs = R_LOG; d.lg_t = 4'b0100; end                                // ANDC
					10'h1dc: begin d.rs = R_LOG; d.lg_t = 4'b0111; end                                // NAND
					10'h1bc: begin d.rs = R_LOG; d.lg_t = 4'b1110; end                                // OR
					10'h19c: begin d.rs = R_LOG; d.lg_t = 4'b1101; end                                // ORC
					10'h07c: begin d.rs = R_LOG; d.lg_t = 4'b0001; end                                // NOR
					10'h13c: begin d.rs = R_LOG; d.lg_t = 4'b0110; end                                // XOR
					10'h11c: begin d.rs = R_LOG; d.lg_t = 4'b1001; end                                // EQV
					10'h018, 10'h218, 10'h318, 10'h338: d.rs = R_SH;                                  // SLW, SRW, SRAW, SRAWI
					10'h01a: d.rs = R_MISC;                                                           // CNTLZW
					10'h3ba: begin d.rs = R_MISC; d.ms = MS_EXTSB; end
					10'h39a: begin d.rs = R_MISC; d.ms = MS_EXTSH; end
					10'h013: begin d.rs = R_MISC; d.ms = MS_CR; end                                   // MFCR
					10'h053: begin d.rs = R_MISC; d.ms = MS_MSR; end                                  // MFMSR
					10'h153, 10'h173: begin d.rs = R_MISC; d.ms = MS_SPR; end                         // MFSPR, MFTB
					10'h253: begin d.rs = R_MISC; d.ms = MS_SR; end                                   // MFSR
					10'h293: begin d.rs = R_MISC; d.ms = MS_SRIN; end                                 // MFSRIN
					default: ;
				endcase
			default: ;
		endcase
		return d;
	endfunction
	function automatic logic [2:0] fm_dec(input logic [31:0] o);
		if (o[31:26] != 6'h3f) return FM_B;
		if (o[5]) return FM_SEL;                                                                     // FSEL
		case (o[10:1])
			10'h028: return FM_NEG;
			10'h088: return FM_NABS;
			10'h108: return FM_ABS;
			10'h247: return FM_FFS;                                                                  // MFFS
			default: return FM_B;                                                                    // FMR
		endcase
	endfunction
	// verilator lint_on UNUSEDSIGNAL
	// X's decode, done as its instruction goes in (from op, it cost the hazards and all after them several levels):
	// rw_dec's, the float op, a multiply-add, the iterative unit's, a two-clock one (x_mul), the access, its address's rA|0
	// a zero
	typedef struct packed {
		logic [7:0] rw; fdec_t xf; fpk_t fk; logic madd, slow, mul; mdec_t m; logic ea_z;   // (fk: xf.op's, the float control's)
		logic fpi;                                               // a float instruction (x_fpoff)
		logic sh_r, sh_ar, sh_i, sh_x, sh_w, sh_wrap, sh_ins;   // the rotator's choices (sh_*)
		rdec_t r; logic [2:0] fm;                                // X's result's (x_res), a float move's (m_val)
		logic cr0w; logic [1:0] cr0o;                            // a record form's CR0 (cr0o: the overflow in its SO)
		logic cmpw, cmp_s, cmp_i;                                // a compare's (signed, with the immediate)
		logic fce;                                               // fcmpu / fcmpo (their operands may come as they leave the float pipeline)
	} pdec_t;
	function automatic pdec_t pdec(input logic [31:0] o);
		pdec_t d;
		d.rw = rw_dec(o);
		d.xf = fpu_dec(o);
		d.fk = fpk_s(d.xf.op);
		d.madd = d.xf.op == F_MADD || d.xf.op == F_MSUB || d.xf.op == F_NMADD || d.xf.op == F_NMSUB || d.xf.op == F_MADDS ||
			d.xf.op == F_MSUBS || d.xf.op == F_NMADDS || d.xf.op == F_NMSUBS;
		d.slow = d.xf.op == F_DIV || d.xf.op == F_DIVS || d.xf.op == F_RES;   // (frsqrte: the pipeline's, as the 602's)
		d.mul = o[31:26] == 6'h07 || (o[31:26] == 6'h1f && (o[10:1] == 10'h00b || o[10:1] == 10'h04b || o[10:1] == 10'h0eb ||
			o[10:1] == 10'h2eb)) || (o[31:26] == 6'h3f && !o[5] && (o[10:1] == 10'h000 || o[10:1] == 10'h020));
		d.fpi = o[31:26] == 6'h3b || o[31:26] == 6'h3f || o[31:29] == 3'b110 || (o[31:26] == 6'h1f && (o[10:1] == 10'h217 ||
			o[10:1] == 10'h237 || o[10:1] == 10'h257 || o[10:1] == 10'h277 || o[10:1] == 10'h297 || o[10:1] == 10'h2b7 ||
			o[10:1] == 10'h2d7 || o[10:1] == 10'h2f7 || o[10:1] == 10'h3d7));
		d.m = mem_dec(o);
		d.ea_z = o[20:16] == 5'd0 && !d.m.upd;
		d.sh_r = o[31:26] == 6'h1f && (o[10:1] == 10'h218 || o[10:1] == 10'h318 || o[10:1] == 10'h338);
		d.sh_ar = o[31:26] == 6'h1f && (o[10:1] == 10'h318 || o[10:1] == 10'h338);
		d.sh_i = o[31:26] == 6'h14 || o[31:26] == 6'h15 || (o[31:26] == 6'h1f && o[10:1] == 10'h338);
		d.sh_x = o[31:26] == 6'h1f && o[10:1] != 10'h338;
		d.sh_w = o[31:26] != 6'h1f;
		d.sh_wrap = o[31:26] != 6'h1f && o[10:6] > o[5:1];
		d.sh_ins = o[31:26] == 6'h14;
		d.r = res_dec(o);
		if (d.m.upd) d.r.rs = R_EA;
		d.fm = fm_dec(o);
		d.cr0w = 1'b0; d.cr0o = 2'd0;
		case (o[31:26])
			6'h0d, 6'h1c, 6'h1d: d.cr0w = 1'b1;                                                   // ADDIC., ANDI., ANDIS.
			6'h14, 6'h15, 6'h17: d.cr0w = o[0];                                                   // RLWIMI, RLWINM, RLWNM
			6'h1f:
				case (o[10:1])
					10'h10a, 10'h30a, 10'h00a, 10'h20a, 10'h08a, 10'h28a, 10'h0ca, 10'h2ca, 10'h0ea, 10'h2ea,
					10'h028, 10'h228, 10'h008, 10'h208, 10'h088, 10'h288, 10'h0c8, 10'h2c8, 10'h0e8, 10'h2e8,
					10'h068, 10'h268:
						begin d.cr0w = o[0]; d.cr0o = o[10] ? 2'd1 : 2'd0; end                     // the adds, the subtracts, NEG
					10'h0eb, 10'h2eb: begin d.cr0w = o[0]; d.cr0o = o[10] ? 2'd2 : 2'd0; end            // MULLW
					10'h00b, 10'h04b, 10'h01c, 10'h03c, 10'h1dc, 10'h1bc, 10'h19c, 10'h07c, 10'h13c, 10'h11c,
					10'h018, 10'h218, 10'h318, 10'h338, 10'h01a, 10'h3ba, 10'h39a: d.cr0w = o[0];       // MULHW(U), logic, shifts, CNTLZW, EXTS
					default: ;
				endcase
			default: ;
		endcase
		d.cmpw = o[31:26] == 6'h0a || o[31:26] == 6'h0b || (o[31:26] == 6'h1f && (o[10:1] == 10'h000 || o[10:1] == 10'h020));
		d.cmp_s = o[31:26] == 6'h0b || (o[31:26] == 6'h1f && o[10:1] == 10'h000);
		d.cmp_i = o[31:26] == 6'h0a || o[31:26] == 6'h0b;
		d.fce = o[31:26] == 6'h3f && (o[10:1] == 10'h000 || o[10:1] == 10'h020);
		return d;
	endfunction
	pdec_t pd, spd;                     // op's, sins'
	logic g_a, g_b, g_d, f_a, f_b, f_c, f_d, x_fmov;
	assign {g_a, g_b, g_d, f_a, f_b, f_c, f_d, x_fmov} = pd.rw;

	// ---- the instruction in X -----------------------------------------------------------------------------------------
	wire [5:0]  opc = op[31:26];
	wire [4:0]  rD = op[25:21], rA = op[20:16], rB = op[15:11], frC = op[10:6];
	wire [31:0] simm = {{16{op[15]}}, op[15:0]};
	wire [31:0] uimm = {16'h0, op[15:0]};
	wire [9:0]  xo = op[10:1];
	wire        rc = op[0];
	wire        oe = op[10];
	wire [31:0] ra_v = gx(pg(rA), 2'd0, gr_a), rb_v = gx(pg(rB), 2'd1, gr_b), rs_v = gx(pg(rD), 2'd2, gr_s);
	wire [32:0] fs_v = fx(rD, 2'd3, fr_s);    // rD's FPR (a store's source)
	wire [31:0] raz = rA == 0 ? 32'h0 : ra_v;
	wire [9:0]  sprn = {op[15:11], op[20:16]};
	wire [31:0] npc = ipc + 32'd4;

	// the multiplies and fcmpu / fcmpo take two clocks in X: the multiplies' results registered in the first, used in the
	// second (mul_rdy); the compares' operands registered in the first (a float pipeline's result as it leaves it, with FPF),
	// compared in the second. So does stfd, its FPR made a double (cvt_r).
	logic [63:0] mulw;                  // (one multiply for all of them: signed, but MULHWU's operands extended with zeros)
	logic        mul_rdy;
	logic [31:0] fcmp_a, fcmp_b;
	wire  [3:0]  fcmp_r = cmp_s(fcmp_a, fcmp_b);
	logic [63:0] cvt_r;
	// a float instruction with MSR[FP] clear: taken, it does nothing and comes back after the kernel's handler
	wire         x_fpoff = FP_EXC && !msr[13] && pd.fpi;
	wire         x_mul = pd.mul;
	wire         mul_u = opc == 6'h1f && xo == 10'h00b;
	wire  [31:0] mul_b = opc == 6'h07 ? simm : rb_v;
	// one rotator and one mask for the rotates and shifts: a right shift by n is a left rotate by 32 - n, that is by 1 then by ~n
	// (the choices from pd: sh_r SRW, SRAW, SRAWI; sh_ar SRAW, SRAWI; sh_i the amount in op; sh_x SLW, SRW, SRAW, which
	// shift by 32 or more; sh_w the rotates, whose mask is in op, sh_wrap if it wraps; sh_ins RLWIMI)
	wire  [4:0]  sh_n = pd.sh_i ? op[15:11] : rb_v[4:0];
	wire         sh_big = pd.sh_x && rb_v[5];
	wire  [31:0] sh_rot = rol32(pd.sh_r ? {rs_v[30:0], rs_v[31]} : rs_v, pd.sh_r ? ~sh_n : sh_n);
	wire  [31:0] sh_m = sh_big ? 32'h0 : rlw_mask(pd.sh_w ? op[10:6] : pd.sh_r ? sh_n : 5'd0,
		pd.sh_w ? op[5:1] : pd.sh_r ? 5'd31 : ~sh_n, pd.sh_wrap);
	wire  [31:0] sh_res = (sh_rot & sh_m) | ((pd.sh_ins ? ra_v : {32{pd.sh_ar && rs_v[31]}}) & ~sh_m);
	wire         sh_ca = rs_v[31] && (sh_rot & ~sh_m) != 32'h0;                                 // (SRAW, SRAWI: a one shifted out of a negative)
	// whether sh_res is 0 (CR0's), beside the rotator rather than after it: the rotated bits under the mask are rS's under the
	// mask rotated back (a rotate's mask from op; a left shift's the bits kept, rS's low 32 - n; a right shift's its high
	// 32 - n, an arithmetic shift's sign among them), and RLWIMI's rA outside the mask. A shift by 32 or more leaves the sign
	wire  [31:0] sh_wm = rlw_mask(op[10:6], op[5:1], pd.sh_wrap);
	wire  [31:0] sh_zm = pd.sh_w ? ror32(sh_wm, sh_n) : pd.sh_r ? 32'hffffffff << sh_n : 32'hffffffff >> sh_n;
	wire         sh_zero = sh_big ? !(pd.sh_ar && rs_v[31]) : (rs_v & sh_zm) == 32'h0 && !(pd.sh_ins && (ra_v & ~sh_wm) != 32'h0);
	always_ff @(posedge clk)
	begin
		mulw <= $signed({{32{!mul_u && ra_v[31]}}, ra_v}) * $signed({{32{!mul_u && mul_b[31]}}, mul_b});
		// verilator lint_off UNUSEDSIGNAL
		begin
			logic [32:0] fa, fb;
			fa = (FWD || FPF) && fpp_ev && fpp_erd == rA ? fpp_evl : fx(rA, 2'd0, fr_a);
			fb = (FWD || FPF) && fpp_ev && fpp_erd == rB ? fpp_evl : fx(rB, 2'd1, fr_b);
			fcmp_a <= fa[31:0];
			fcmp_b <= fb[31:0];
		end
		// verilator lint_on UNUSEDSIGNAL
		cvt_r <= f2d(fs_v);
	end

	// a single access (xm_mem; the rest of the decode is for it) or a SEQ one (xm_seq)
	logic        xm_mem, xm_seq, xm_we, xm_upd, xm_sext, xm_bswap, xm_resv, xm_cvt;
	mkind_t      xm_kind;
	logic [31:0] xm_ea;
	logic [3:0]  xm_size;
	logic [63:0] xm_wdata;
	always_comb
	begin
		logic [31:0] ix, iu;            // indexed: rA|0 + rB, and the update form's rA + rB
		ix = raz + rb_v;
		iu = ra_v + rb_v;
		xm_mem = 1'b1; xm_seq = 1'b0; xm_we = 1'b0; xm_upd = 1'b0; xm_sext = 1'b0; xm_bswap = 1'b0; xm_resv = 1'b0;
		xm_cvt = 1'b0;
		xm_kind = MK_LOAD; xm_ea = raz + simm; xm_size = 4'd4; xm_wdata = 64'h0;
		case (opc)
			6'h20: ;                                                                                    // LWZ
			6'h21: begin xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h22: xm_size = 4'd1;                                                                      // LBZ
			6'h23: begin xm_size = 4'd1; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h24: begin xm_kind = MK_ST; xm_wdata = {32'h0, rs_v}; end                                 // STW
			6'h25: begin xm_kind = MK_ST; xm_wdata = {32'h0, rs_v}; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h26: begin xm_kind = MK_ST; xm_size = 4'd1; xm_wdata = {56'h0, rs_v[7:0]}; end            // STB
			6'h27: begin xm_kind = MK_ST; xm_size = 4'd1; xm_wdata = {56'h0, rs_v[7:0]}; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h28: xm_size = 4'd2;                                                                      // LHZ
			6'h29: begin xm_size = 4'd2; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h2a: begin xm_size = 4'd2; xm_sext = 1'b1; end                                            // LHA
			6'h2b: begin xm_size = 4'd2; xm_sext = 1'b1; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h2c: begin xm_kind = MK_ST; xm_size = 4'd2; xm_wdata = {48'h0, rs_v[15:0]}; end           // STH
			6'h2d: begin xm_kind = MK_ST; xm_size = 4'd2; xm_wdata = {48'h0, rs_v[15:0]}; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h2e, 6'h2f: begin xm_mem = 1'b0; xm_seq = 1'b1; end                                       // LMW, STMW
			6'h30: xm_kind = MK_LFS;                                                                    // LFS
			6'h31: begin xm_kind = MK_LFS; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h32: begin xm_kind = MK_LFD; xm_size = 4'd8; end                                          // LFD
			6'h33: begin xm_kind = MK_LFD; xm_size = 4'd8; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h34: begin xm_kind = MK_ST; xm_wdata = {32'h0, fs_v[31:0]}; end                         // STFS
			6'h35: begin xm_kind = MK_ST; xm_wdata = {32'h0, fs_v[31:0]}; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h36: begin xm_kind = MK_ST; xm_size = 4'd8; xm_wdata = cvt_r; xm_cvt = 1'b1; end                       // STFD
			6'h37: begin xm_kind = MK_ST; xm_size = 4'd8; xm_wdata = cvt_r; xm_cvt = 1'b1; xm_ea = ra_v + simm; xm_upd = 1'b1; end
			6'h1f:
			begin
				xm_ea = ix;
				case (xo)
					10'h057: xm_size = 4'd1;                                                            // LBZX
					10'h117: xm_size = 4'd2;                                                            // LHZX
					10'h157: begin xm_size = 4'd2; xm_sext = 1'b1; end                                  // LHAX
					10'h017: ;                                                                          // LWZX
					10'h217: xm_kind = MK_LFS;                                                          // LFSX
					10'h257: begin xm_kind = MK_LFD; xm_size = 4'd8; end                                // LFDX
					10'h316: begin xm_size = 4'd2; xm_bswap = 1'b1; end                                 // LHBRX
					10'h216: xm_bswap = 1'b1;                                                           // LWBRX
					10'h077: begin xm_size = 4'd1; xm_ea = iu; xm_upd = 1'b1; end                       // LBZUX
					10'h137: begin xm_size = 4'd2; xm_ea = iu; xm_upd = 1'b1; end                       // LHZUX
					10'h177: begin xm_size = 4'd2; xm_sext = 1'b1; xm_ea = iu; xm_upd = 1'b1; end       // LHAUX
					10'h037: begin xm_ea = iu; xm_upd = 1'b1; end                                       // LWZUX
					10'h237: begin xm_kind = MK_LFS; xm_ea = iu; xm_upd = 1'b1; end                     // LFSUX
					10'h277: begin xm_kind = MK_LFD; xm_size = 4'd8; xm_ea = iu; xm_upd = 1'b1; end     // LFDUX
					10'h014: xm_resv = 1'b1;                                                            // LWARX
					10'h0d7: begin xm_kind = MK_ST; xm_size = 4'd1; xm_wdata = {56'h0, rs_v[7:0]}; end  // STBX
					10'h197: begin xm_kind = MK_ST; xm_size = 4'd2; xm_wdata = {48'h0, rs_v[15:0]}; end // STHX
					10'h097: begin xm_kind = MK_ST; xm_wdata = {32'h0, rs_v}; end                       // STWX
					10'h297: begin xm_kind = MK_ST; xm_wdata = {32'h0, fs_v[31:0]}; end               // STFSX
					10'h3d7: begin xm_kind = MK_ST; xm_wdata = {32'h0, fs_v[31:0]}; end              // STFIWX
					10'h2d7: begin xm_kind = MK_ST; xm_size = 4'd8; xm_wdata = cvt_r; xm_cvt = 1'b1; end             // STFDX
					10'h396: begin xm_kind = MK_ST; xm_size = 4'd2; xm_wdata = {48'h0, rs_v[7:0], rs_v[15:8]}; end // STHBRX
					10'h296: begin xm_kind = MK_ST; xm_wdata = {32'h0, rs_v[7:0], rs_v[15:8], rs_v[23:16], rs_v[31:24]}; end // STWBRX
					10'h0f7: begin xm_kind = MK_ST; xm_size = 4'd1; xm_wdata = {56'h0, rs_v[7:0]}; xm_ea = iu; xm_upd = 1'b1; end  // STBUX
					10'h1b7: begin xm_kind = MK_ST; xm_size = 4'd2; xm_wdata = {48'h0, rs_v[15:0]}; xm_ea = iu; xm_upd = 1'b1; end // STHUX
					10'h0b7: begin xm_kind = MK_ST; xm_wdata = {32'h0, rs_v}; xm_ea = iu; xm_upd = 1'b1; end                      // STWUX
					10'h2b7: begin xm_kind = MK_ST; xm_wdata = {32'h0, fs_v[31:0]}; xm_ea = iu; xm_upd = 1'b1; end           // STFSUX
					10'h2f7: begin xm_kind = MK_ST; xm_size = 4'd8; xm_wdata = cvt_r; xm_cvt = 1'b1; xm_ea = iu; xm_upd = 1'b1; end           // STFDUX
					10'h255, 10'h215, 10'h2d5, 10'h295, 10'h3f6, 10'h096: begin xm_mem = 1'b0; xm_seq = 1'b1; end // strings, DCBZ, STWCX.
					default: xm_mem = 1'b0;
				endcase
			end
			default: xm_mem = 1'b0;
		endcase
		xm_we = xm_kind == MK_ST;
	end

	// branches: taken (rfi and isync too), and where
	logic        br_taken;
	logic [31:0] br_target;
	always_comb
	begin
		logic [31:0] c, t;
		logic go;
		c = sprv[X_CTR] - 32'd1;
		go = 1'b1;
		if (!rD[2] && ((c != 0) == rD[1])) go = 1'b0;
		if (!rD[4] && crf[rA[4:2]][3 - rA[1:0]] != rD[3]) go = 1'b0;
		t = {{6{op[25]}}, op[25:2], 2'b00};
		br_taken = 1'b0;
		br_target = npc;
		case (opc)
			6'h10: begin br_taken = go; br_target = op[1] ? simm & ~32'd3 : ipc + (simm & ~32'd3); end
			6'h12: begin br_taken = 1'b1; br_target = op[1] ? t : ipc + t; end
			6'h13:
				case (xo)
					10'h010: begin br_taken = go; br_target = sprv[X_LR] & ~32'd3; end
					10'h210: begin br_taken = go; br_target = sprv[X_CTR] & ~32'd3; end
					10'h032: begin br_taken = 1'b1; br_target = sprv[X_SRR0]; end                     // RFI
					10'h096: br_taken = 1'b1;                                                        // ISYNC
					default: ;
				endcase
			default: ;
		endcase
	end
	// the instructions that change what the fetches already out were translated with
	wire x_ser = opc == 6'h1f && (xo == 10'h092 || xo == 10'h0d2 || xo == 10'h0f2 || xo == 10'h254 || xo == 10'h274 ||
		(xo == 10'h1d3 && ((sprn >= 10'd528 && sprn <= 10'd535) || sprn == 10'd1008)));

	// ---- X control ----------------------------------------------------------------------------------------------------
	tr_t ftr, dtr;
	// verilator lint_off UNUSEDSIGNAL
	tr_t dts;                           // (its pa)
	// verilator lint_on UNUSEDSIGNAL
	assign ftr = translate(fo_va, 2'd2);
	assign dtr = translate(d_va, (xstate == XS_SEQ ? sq_wr : pd.m.we) ? 2'd1 : 2'd0);     // (the check's)

	// the data side's translation, its parts apart (translate's, one after another, were a long path from the address
	// adder): whether it may (dck: {ok, prot}, the DBATs side by side); and where, with every valid DBAT mapping to itself
	// (dt_id, as the games set them) the address as it is, else a clock later for X (xt_va, the address held while X
	// waits a clock; SEQ's sq_ea is a register already)
	function automatic logic [1:0] dchk(input logic [31:0] a, input logic wr);
		logic [3:0] m, okn;
		logic ok;
		if (!msr[4]) return 2'b10;
		for (int n = 0; n < 4; n++)
		begin
			logic [31:0] upper, mask;
			logic [1:0]  pp;
			upper = sprv[X_DBAT + 2 * n];
			pp = sprv[X_DBAT + 2 * n + 1][1:0];
			mask = (~upper << 15) & 32'hfffe0000;
			m[n] = upper[{4'd0, !msr[14]}] && ((a ^ upper) & mask) == 32'h0;
			okn[n] = wr ? pp == 2'd2 : pp != 2'd0;
		end
		ok = m[0] ? okn[0] : m[1] ? okn[1] : m[2] ? okn[2] : m[3] ? okn[3] : sprv[X_HID0][7];
		return {ok, m != 4'h0 && !ok};
	endfunction
	function automatic logic dbat_ident();
		for (int n = 0; n < 4; n++)
		begin
			logic [31:0] upper, lower, mask;
			upper = sprv[X_DBAT + 2 * n];
			lower = sprv[X_DBAT + 2 * n + 1];
			mask = (~upper << 15) & 32'hfffe0000;
			if (upper[1:0] != 2'b00 && ((upper ^ lower) & mask) != 32'h0) return 1'b0;
		end
		return 1'b1;
	endfunction
	wire  [1:0]  dck = dchk(d_va, xstate == XS_SEQ ? sq_wr : pd.m.we);
	logic        dt_id, xt_rdy;
	logic [31:0] xt_va;
	assign dts = translate(xstate == XS_SEQ ? sq_ea : xt_va, 2'd0);

	// the fetch's translation, kept (ut_*) for the 128K block it was done for (a BAT's smallest, so all of it translates
	// alike): a fetch in another block, or the first after what may change it (msr's IR and PR, the IBATs, HID0, the SRs:
	// the reset, the bench's writes, an exception, rfi and the x_ser instructions as they go, but an mtmsr that leaves IR
	// and PR, as the idle loops' do), translates (ftr, into ut_*) and goes out again, a clock later
	logic        ut_v, ut_ok, ut_prot;
	logic [31:17] ut_blk, ut_pa;
	wire ut_hit  = ut_v && fo_va[31:17] == ut_blk;
	wire f_retry = fo && !ut_hit;
	wire ut_keep = opc == 6'h1f && xo == 10'h092 && rs_v[5] == msr[5] && rs_v[14] == msr[14];
	wire ut_clr  = dbg_we || xstate == XS_EXC || (x_exec && ((x_ser && !ut_keep) || (opc == 6'h13 && xo == 10'h032)));
	always_ff @(posedge clk)
		if (rst || ut_clr) ut_v <= 1'b0;
		else if (f_retry)
		begin
			ut_v <= 1'b1; ut_blk <= fo_va[31:17];
			ut_ok <= ftr.ok; ut_prot <= ftr.prot; ut_pa <= ftr.pa[31:17];
		end

	wire f_flt  = fo && ut_hit && !ut_ok;
	wire f_resp = fo && ut_hit && (!ut_ok || if_valid);
	wire [1:0] f_rflt = f_flt ? (ut_prot ? 2'd2 : 2'd1) : 2'd0;

	logic x_go, x_run, x_int, x_try, x_haz0, x_haz, x_ok, x_cons, x_exec, a_flt, a_cov, a_snoop, x_redir, x_take, hold_flush, sq_fin;
	logic [31:0] x_target, vec;
	always_comb
	begin
		x_go = !dbg_hold || credit;
		x_run = xstate == XS_RUN;
		x_int = (int_q || dec_irq) && msr[15];
		// M's address clock: X's access faults, or a store covers an instruction fetched after it (which X then doesn't
		// take)
		a_flt = a_v && !a_tok;
		a_cov = a_v && !a_seq && a_we && ((xv && covers(a_va[11:0], a_cw, ipc[11:0])) ||
			(sv && covers(a_va[11:0], a_cw, spc[11:0])) || (fo && covers(a_va[11:0], a_cw, fo_va[11:0])));
		a_snoop = a_cov && a_tok;
		x_try = x_run && xv && x_go && !(a_v && !a_seq && (a_flt || a_cov));
		xf = pd.xf;
		x_fk = pd.fk;
		x_madd = pd.madd;
		x_slow = pd.slow;
		x_haz0 = (g_a && gpend_x(pg(rA))) || (g_b && gpend_x(pg(rB))) || (g_d && gpend_x(pg(rD))) ||
			(xf.go && !x_slow ?
				(f_a && fpend_p(rA)) || (f_b && (x_madd ? fpend_pb(rB) : fpend_p(rB))) || (f_c && fpend_p(frC)) ||
				(f_d && fpend_pd(rD)) :
			 (FWD || FPF) && pd.fce ?
				(f_a && fpend_p(rA)) || (f_b && fpend_p(rB)) :
				(f_a && fpend_x(rA)) || (f_b && fpend_x(rB)) || (f_c && fpend_x(frC)) || (f_d && fpend_x(rD))) ||
			(pd.m.mem && !n_free) || (x_fmov && !m_free) || (pd.m.seq && m_valid) || (xf.go && !fp_free);
		x_haz = x_haz0 || ((x_mul || pd.m.cvt) && !mul_rdy) || (pd.m.mem && !dt_id && !xt_rdy);
		x_ok = x_try && !x_int && xflt == 2'd0 && !x_fpoff && !x_haz;
		x_exec = x_ok && (!pd.m.mem || d_rdy);
		x_cons = x_try && (x_int || xflt != 2'd0 || x_fpoff || x_exec);
		fpu_start = x_exec && xf.go && x_slow;
		fpp_issue = x_exec && xf.go && !x_slow;
		sq_fin = xstate == XS_SEQ && sq_out && d_valid && seq_last();
		vec = (msr[6] ? 32'hfff00000 : sprv[X_IBR]) | {19'h0, exc, 8'h0};
		x_redir = (x_exec && (br_taken != xpred || x_ser)) || a_snoop || xstate == XS_EXC || (sq_fin && sq_wr);
		x_target = xstate == XS_EXC ? vec : xstate == XS_SEQ || a_snoop ? pc : br_taken ? br_target : npc;
		x_take = !xv || x_cons;
		hold_flush = dbg_hold && !credit && x_run;

		// the data request: X's single access, or SEQ's; the access, in its address clock
		d_req = xstate == XS_SEQ ? !sq_out : x_ok && pd.m.mem;
		// one adder for X's address (rA|0 + d or rB; the update forms' rA + d or rB) and SEQ's, each operand chosen before it
		// (where the adder's own LUTs take the choice)
		d_va = (xstate == XS_SEQ ? sq_ea : pd.ea_z ? 32'h0 : ra_v) + (xstate == XS_SEQ ? 32'h0 : pd.m.idx ? rb_v : simm);
		d_kill = a_flt;
		d_pa = a_pa; d_we = a_we; d_size = a_size; d_wdata = a_wdata;
	end

	// X's GPR result, from units whose choices pd has (rdec_t): gw_v takes it with no decode in front, and CR0 its zero
	function automatic logic [31:0] spr_rv(input logic [5:0] k);
		case (k)
			6'd48: return {xerso, xer};
			6'd49: return 32'h00050200;
			6'd50: return dec;
			6'd51: return tb[31:0];
			6'd52: return {8'h0, tb[55:32]};
			default: return k < 6'(NSPR) ? sprv[k] : 32'h0;
		endcase
	endfunction
	logic [31:0] ad_b, lg_v, ms_v, x_res;
	logic        ad_c, x_neg, x_zero;
	wire  [31:0] ad_a = (pd.r.ad_z ? 32'h0 : ra_v) ^ {32{pd.r.ad_n}};
	wire  [32:0] ad_s = {1'b0, ad_a} + {1'b0, ad_b} + {32'h0, ad_c};
	wire         ad_ov = !(ad_a[31] ^ ad_b[31]) && (ad_a[31] ^ ad_s[31]);
	// the sum's zero test without the carries: a + b + c is zero when each bit's a ^ b is the carry a zero sum brings it,
	// c or the bit below's a | b
	wire         ad_zero = (ad_a ^ ad_b) == {ad_a[30:0] | ad_b[30:0], ad_c};
	wire  [31:0] lg_b = pd.r.lg_b == LB_RB ? rb_v : pd.r.lg_b == LB_UIMM ? uimm : {op[15:0], 16'h0};
	always_comb
	begin
		case (pd.r.ad_b)
			AB_SIMM: ad_b = simm;
			AB_SHI:  ad_b = {op[15:0], 16'h0};
			AB_RB:   ad_b = rb_v;
			AB_ZERO: ad_b = 32'h0;
			default: ad_b = 32'hffffffff;
		endcase
		ad_c = pd.r.ad_c == AC_1 || (pd.r.ad_c == AC_CA && xer[29]);
		for (int i = 0; i < 32; i++) lg_v[i] = pd.r.lg_t[{rs_v[i], lg_b[i]}];
		case (pd.r.ms)
			MS_CLZ:   ms_v = clz32(rs_v);
			MS_EXTSB: ms_v = {{24{rs_v[7]}}, rs_v[7:0]};
			MS_EXTSH: ms_v = {{16{rs_v[15]}}, rs_v[15:0]};
			MS_CR:    ms_v = get_cr();
			MS_MSR:   ms_v = msr;
			MS_SPR:   ms_v = spr_rv(pd.r.spr);
			MS_SR:    ms_v = sr[op[19:16]];
			default:  ms_v = sr[rb_v[31:28]];
		endcase
		case (pd.r.rs)
			R_ADD:   x_res = ad_s[31:0];
			R_LOG:   x_res = lg_v;
			R_SH:    x_res = sh_res;
			R_MULL:  x_res = mulw[31:0];
			R_MULH:  x_res = mulw[63:32];
			R_MISC:  x_res = ms_v;
			default: x_res = d_va;
		endcase
		// CR0's sign and zero, only from the units a record form takes its result from, each unit's own compare and the
		// choice after it (R_MISC's are CNTLZW's, a zero when rS's top bit is set, EXTSB's and EXTSH's)
		case (pd.r.rs)
			R_ADD:   begin x_neg = ad_s[31]; x_zero = ad_zero; end
			R_LOG:   begin x_neg = lg_v[31]; x_zero = lg_v == 32'h0; end
			R_SH:    begin x_neg = sh_res[31]; x_zero = sh_zero; end
			R_MULL:  begin x_neg = mulw[31]; x_zero = mulw[31:0] == 32'h0; end
			R_MULH:  begin x_neg = mulw[63]; x_zero = mulw[63:32] == 32'h0; end
			default:
			begin
				x_neg = pd.r.ms == MS_EXTSB ? rs_v[7] : pd.r.ms == MS_EXTSH && rs_v[15];
				x_zero = pd.r.ms == MS_CLZ ? rs_v[31] : pd.r.ms == MS_EXTSB ? rs_v[7:0] == 8'h0 : rs_v[15:0] == 16'h0;
			end
		endcase
	end
`ifdef VERILATOR
	always_ff @(posedge clk)
	begin
		if (xv && pd.r.rs == R_SH && sh_zero != (sh_res == 32'h0)) $display("PIPE sh_zero wrong: %08x %08x", op, rs_v);
		if (x_exec && pd.cr0w && (x_neg != x_res[31] || x_zero != (x_res == 32'h0))) $display("PIPE cr0 wrong: %08x %08x", op, x_res);
	end
`endif
	function automatic logic [3:0] cr0x(input logic so);
		return {x_neg, !x_neg && !x_zero, x_zero, so};
	endfunction
	// a record form's CR0 (its overflow in SO with OE: the adder's, NEG's among them, which is rA = 0x80000000's; MULLW's) and
	// a compare's field, which X writes with x_exec the only late choice (in the clock's block, after the states': from X's
	// hazards through exec's choices to CRF was a long path)
	wire         x_cr0ov = pd.cr0o == 2'd1 ? ad_ov : pd.cr0o == 2'd2 ? mulw[63:32] != {32{mulw[31]}} : 1'b0;
	wire  [31:0] cmp_b = !pd.cmp_i ? rb_v : pd.cmp_s ? simm : uimm;
	wire  [3:0]  cmp_d = pd.cmp_s ? cmp4($signed(ra_v) < $signed(cmp_b), $signed(ra_v) > $signed(cmp_b), xerso) :
		cmp4(ra_v < cmp_b, ra_v > cmp_b, xerso);

	// the float moves' value, from pd.fm (FSEL: c if a >= 0.0, not NaN and positive or a zero, else b; MFFS: an integer, as
	// the manual has it)
	logic [32:0] m_val_d;
	always_comb
	begin
		// verilator lint_off UNUSEDSIGNAL
		logic [32:0] fa, v;
		// verilator lint_on UNUSEDSIGNAL
		fa = fx(rA, 2'd0, fr_a);
		v = pd.fm == FM_FFS ? {1'b1, fpscr} :
			pd.fm == FM_SEL && !snan(fa[31:0]) && (!fa[31] || fa[30:0] == 31'h0) ? fx(frC, 2'd2, fr_c) : fx(rB, 2'd1, fr_b);
		case (pd.fm)
			FM_NEG:  v[31] = !v[31];
			FM_NABS: v[31] = 1'b1;
			FM_ABS:  v[31] = 1'b0;
			default: ;
		endcase
		m_val_d = v;
	end
	always_ff @(posedge clk)
		if (rst || x_exec || !(x_try && !x_int && xflt == 2'd0 && !x_fpoff && (x_mul || pd.m.cvt) && !x_haz0)) mul_rdy <= 1'b0;
		else mul_rdy <= 1'b1;
	// (dt_id cleared as a DBAT's written, by mtspr or the bench: the clock after uses the slow way, then dbat_ident's new
	// answer; with a DBAT not mapping to itself, X's access waits a clock, its address held for translate)
	always_ff @(posedge clk)
		dt_id <= !(rst || dbg_we || (x_exec && opc == 6'h1f && xo == 10'h1d3 && sprn >= 10'd536 && sprn <= 10'd543)) &&
			dbat_ident();
	always_ff @(posedge clk)
		if (rst || x_exec || !(x_try && !x_int && xflt == 2'd0 && pd.m.mem && !dt_id && !x_haz0)) xt_rdy <= 1'b0;
		else
		begin
			xt_rdy <= 1'b1;
			xt_va <= d_va;
		end
	function automatic logic seq_last();
		case (sq_kind)
			Q_LMW, Q_STMW: return sq_reg == 5'd31;
			Q_STWCX: return 1'b1;
			default: return sq_count == 7'd1;
		endcase
	endfunction

	// ---- fetch --------------------------------------------------------------------------------------------------------
	// a fetched branch predicted taken: b, and bc by its static prediction (backward, or forward with y set; branch
	// always); the fetches go on at its target, X redirecting only when it goes the other way
	logic f_pt;
	logic [31:0] f_ptgt, nfpc;
	always_comb
	begin
		logic [31:0] d;
		d = if_data[31:26] == 6'h12 ? {{6{if_data[25]}}, if_data[25:2], 2'b00} : {{16{if_data[15]}}, if_data[15:2], 2'b00};
		f_ptgt = if_data[1] ? d : fo_va + d;
		f_pt = f_resp && !f_flt && (if_data[31:26] == 6'h12 ||
			(if_data[31:26] == 6'h10 && ((if_data[25] && if_data[23]) || (if_data[15] ^ if_data[21]))));
		nfpc = f_pt ? f_ptgt : fpc;
	end

	logic skid_after, f_want;
	always_comb
	begin
		skid_after = sv ? !x_take : f_resp && !x_take;
		f_want = (!fo || f_resp) && !skid_after && !fstop && !f_flt;
		if_req = x_redir || (!hold_flush && (f_want || f_retry));
		if_va = x_redir ? x_target : f_retry ? fo_va : nfpc;
		if_kill = x_redir || hold_flush ? fo : f_flt || f_retry;
		if_pa = {ut_pa, fo_va[16:0]};
	end

	always_ff @(posedge clk)
	begin
		if (rst)
		begin
			fo <= 1'b0; fstop <= 1'b0; xv <= 1'b0; sv <= 1'b0;
			fpc <= pc;                  // (which the bench may load)
		end
		else if (x_redir)
		begin
			xv <= 1'b0; sv <= 1'b0; fstop <= 1'b0;
			fo <= if_rdy;
			fo_va <= x_target;
			fpc <= if_rdy ? x_target + 32'd4 : x_target;
		end
		else if (hold_flush)
		begin
			xv <= 1'b0; sv <= 1'b0; fo <= 1'b0; fstop <= 1'b0;
			fpc <= pc;
		end
		else
		begin
			if (x_take)
			begin
				if (sv)
				begin
					xv <= 1'b1; ipc <= spc; op <= sins; pd <= spd; xflt <= sflt; xpred <= spred;
					sv <= 1'b0;
				end
				else
				begin
					xv <= f_resp;
					ipc <= fo_va; op <= if_data; pd <= pdec(if_data); xflt <= f_rflt; xpred <= f_pt;
				end
			end
			else if (f_resp)
			begin
				sv <= 1'b1; spc <= fo_va; sins <= if_data; spd <= pdec(if_data); sflt <= f_rflt; spred <= f_pt;
			end
			if (f_flt) fstop <= 1'b1;
			if (f_want && if_rdy)
			begin
				fo <= 1'b1;
				fo_va <= nfpc;
				fpc <= nfpc + 32'd4;
			end
			else
			begin
				if (f_resp) fo <= 1'b0;
				fpc <= nfpc;
			end
			// (fo_va's again, out now, or later as fpc)
			if (f_retry)
			begin
				fo <= if_rdy;
				if (!if_rdy) fpc <= fo_va;
			end
		end
	end

	// X's GPRs for the next clock: its next instruction's (what the fetch block puts in op): op's again if op_keep, else
	// op_nx's (op_keep comes late, so the register files have both)
	wire        op_keep = x_redir || hold_flush || !x_take;
	// verilator lint_off UNUSEDSIGNAL
	wire [31:0] op_nx = sv ? sins : if_data;
	// verilator lint_on UNUSEDSIGNAL
	// which of X's rA / rB / rS ({s, b, a}) a GPR written now (p) is next clock (for gh_*)
	function automatic logic [2:0] gnext(input logic [5:0] p);
		return op_keep ? {p == pg(op[25:21]), p == pg(op[15:11]), p == pg(op[20:16])} :
			{p == pg(op_nx[25:21]), p == pg(op_nx[15:11]), p == pg(op_nx[20:16])};
	endfunction
	// ... and which of its rA / rB / frC / rD ({s, c, b, a}) an FPR r is: op's (fnk), op_nx's (fnn), X's now (fnow)
	function automatic logic [3:0] fnk(input logic [4:0] r);
		return {r == op[25:21], r == op[10:6], r == op[15:11], r == op[20:16]};
	endfunction
	function automatic logic [3:0] fnn(input logic [4:0] r);
		return {r == op_nx[25:21], r == op_nx[10:6], r == op_nx[15:11], r == op_nx[20:16]};
	endfunction
	// verilator lint_off UNUSEDSIGNAL
	function automatic logic [3:0] fnow(input logic [4:0] r);
		return {r == rD, r == frC, r == rB, r == rA};
	endfunction
	// verilator lint_on UNUSEDSIGNAL
	// (rS, through SEQ: the register it reads when its access is answered)
	logic [5:0] seq_rs;
	always_comb
		case (sq_kind)
			Q_STMW: seq_rs = pg(sq_reg + 5'd1);
			Q_STSW: seq_rs = pg(sq_byte == 2'd3 ? sq_reg + 5'd1 : sq_reg);
			default: seq_rs = pg(sq_reg);
		endcase
	wire seq_rd = xstate == XS_SEQ && !sq_fin;
	// the value gw_v takes every clock, what's written if anything is (wgp has the register, its enable): X's x_res; a
	// faulted update form's rA put back; the bench's; DIV's, SEQ's
	logic [31:0] gw_v_d;
	always_comb
	begin
		gw_v_d = x_res;
		if (a_flt) gw_v_d = a_rav;
		case (xstate)
			XS_RUN: if (hold_flush && dbg_we && (dbg_idx < 11'd32 || (dbg_idx >= 11'd72 && dbg_idx < 11'd76))) gw_v_d = dbg_val[31:0];
			XS_CHK: gw_v_d = 32'h0;
			XS_DIV: gw_v_d = dv_neg_q ? -dv_q : dv_q;
			XS_SEQ:
				if (!sq_out || sq_kind != Q_LSW) gw_v_d = sq_out ? d_rdata[31:0] : 32'h0;
				else
				begin
					gw_v_d = sq_byte == 0 ? 32'h0 : gxc(seq_rs, gr_s);
					gw_v_d[31 - 8 * sq_byte -: 8] = d_rdata[7:0];
				end
			default: ;
		endcase
		if (rst) gw_v_d = dbg_val[31:0];
	end
	ppc_regs #(.W(32), .AW(6), .NR(3)) gregs (
		.clk,
		.we0(gw_en), .wa0(gw_r), .wd0(gw_v),
		.we1(m_gw && !rst), .wa1(m_rd), .wd1(m_gv),
		.ra_k({seq_rd ? seq_rs : pg(op[25:21]), pg(op[15:11]), pg(op[20:16])}),
		.ra_n({seq_rd ? seq_rs : pg(op_nx[25:21]), pg(op_nx[15:11]), pg(op_nx[20:16])}), .keep(op_keep),
		.rd({gr_s, gr_b, gr_a})
	);
	// the FPRs: the float units' (and the bench's) writes win over M's (never the same one in a clock)
	always_comb
	begin
		fu_we = 1'b0; fu_wa = dbg_idx[4:0]; fu_wd = d2f(dbg_val);
		if (!rst && fpp_wv) begin fu_we = 1'b1; fu_wa = fpp_wrd; fu_wd = fpp_wval; end
		else if (!rst && fpu_busy && fpu_done) begin fu_we = 1'b1; fu_wa = fpu_rd; fu_wd = fpu_res; end
		else if (dbg_we && dbg_idx >= 32 && dbg_idx < 64 && (rst ? rst_q : x_run && !x_cons && hold_flush)) fu_we = 1'b1;
	end
	ppc_regs #(.W(33), .AW(5), .NR(4)) fregs (
		.clk,
		.we0(m_fw && !rst), .wa0(m_rd[4:0]), .wd0(m_fv),
		.we1(fu_we), .wa1(fu_wa), .wd1(fu_wd),
		.ra_k({op[25:21], op[10:6], op[15:11], op[20:16]}),
		.ra_n({op_nx[25:21], op_nx[10:6], op_nx[15:11], op_nx[20:16]}), .keep(op_keep),
		.rd({fr_s, fr_c, fr_b, fr_a})
	);
	always_ff @(posedge clk)
	begin
		gw2_en <= gw_en; gw2_r <= gw_r; gw2_v <= gw_v;
		gh_w2 <= gw_en ? gnext(gw_r) : 3'b0;
`ifdef VERILATOR
		if (xv && (gh_w != {gw_en && gw_r == pg(rD), gw_en && gw_r == pg(rB), gw_en && gw_r == pg(rA)} ||
			gh_m != {gm_en && gm_r == pg(rD), gm_en && gm_r == pg(rB), gm_en && gm_r == pg(rA)} ||
			gh_w2 != {gw2_en && gw2_r == pg(rD), gw2_en && gw2_r == pg(rB), gw2_en && gw2_r == pg(rA)}))
			$display("PIPE gh_* wrong at %08x", ipc);
		// (the decode done as the instruction went in: X's, and its access's against xm_*)
		if (xv && (pd != pdec(op) || pd.m.mem != xm_mem || pd.m.seq != xm_seq || pd.m.cvt != xm_cvt || pd.m.we != xm_we ||
			pd.m.upd != xm_upd || (xm_mem && xstate != XS_SEQ && d_va != xm_ea)))
			$display("PIPE pd wrong at %08x", ipc);
		// (X's result, and a float move's, against what the decode in exec has)
		if (gw_en && gw_v != gw_vchk) $display("PIPE gw_v wrong at %08x", ret_ipc);
		if (m_valid && m_kind == MK_FMOV && m_val != m_vchk) $display("PIPE m_val wrong at %08x", ret_ipc);
		// (the data side's translation, its parts apart, against translate's)
		if (d_req && d_rdy && ((dt_id ? d_va : dts.pa) != dtr.pa || dck != {dtr.ok, dtr.prot} || (!dt_id && !dbat_ident() && xstate != XS_SEQ && xt_va != d_va)))
			$display("PIPE dtr wrong at %08x", ipc);
`endif
		fu_en <= fu_we; fu_r <= fu_wa; fu_v <= fu_wd;
		fm_en <= m_fw && !rst; fm_r <= m_rd[4:0]; fm_v <= m_fv;
		fh_pk <= fnk(fpp_erd); fh_pn <= fnn(fpp_erd);
		fh_uk <= fnk(fu_wa); fh_un <= fnn(fu_wa);
		fh_mk <= fnk(m_rd[4:0]); fh_mn <= fnn(m_rd[4:0]);
`ifdef VERILATOR
		if (xv && ((fpp_wv && fh_p != fnow(fpp_wrd)) || (fu_en && fh_u != fnow(fu_r)) || (fm_en && fh_m != fnow(fm_r))))
			$display("PIPE fh_* wrong at %08x", ipc);
`endif
	end

	// ---- bench outputs ------------------------------------------------------------------------------------------------
	always_comb
	begin
		for (int i = 0; i < 32; i++)
		begin
			gpr_o[32 * i +: 32] = BENCH ? gpr[pg(5'(i))] : 32'h0;
			fpr_o[64 * i +: 64] = BENCH ? f2d(fpr[i]) : 64'h0;
			// (and the rA an update form not yet retired has written: the access in its address clock)
			gpr_pend_o[i] = gpend(pg(5'(i))) || (a_v && !a_seq && a_upd && a_ra == pg(5'(i)));
			fpr_pend_o[i] = fpend(5'(i));
		end
		// (an access retired by M alone: X may have taken the next instruction, not yet done)
		pc_o = ret_m && !ret_x ? retm_ipc + 32'd4 : pc;
		cr_o = get_cr();
		lr_o = sprv[X_LR];
		ctr_o = sprv[X_CTR];
		xer_o = {xerso, xer};
		msr_o = msr;
		srr0_o = sprv[X_SRR0];
		srr1_o = sprv[X_SRR1];
		fpscr_o = fpscr;
	end
	assign retire = ret_x || ret_m;
	assign retire2 = ret_x && ret_m;
	assign ipc0_o = retm_ipc;
	assign iop0_o = retm_op;
	assign ipc_o = ret_x ? ret_ipc : retm_ipc;
	assign iop_o = ret_x ? ret_op : retm_op;
	assign exc_o = ret_x ? exc_q : 5'd0;
	assign timer_read_o = ret_x && timer_q;
	assign dbg_idle = dbg_hold && !credit && x_run && !m_valid && !a_v && !fpu_busy && !fpp_busy;
	always_comb
	begin
		logic fm, ff;
		fm = (f_a && fpend_mx(rA)) || (f_b && fpend_mx(rB)) || (f_c && fpend_mx(frC)) || (f_d && fpend_mx(rD));
		ff = xf.go && !x_slow ?
			(f_a && fpend_pu(rA)) || (f_b && (x_madd ? fpend_pbu(rB) : fpend_pu(rB))) || (f_c && fpend_pu(frC)) ||
			(f_d && fpend_pdu(rD)) :
			(FWD || FPF) && pd.fce ? (f_a && fpend_pu(rA)) || (f_b && fpend_pu(rB)) :
			(f_a && fpend_ux(rA)) || (f_b && fpend_ux(rB)) || (f_c && fpend_ux(frC)) || (f_d && fpend_ux(rD));
		perf_pc_o = ipc;
		if (!x_run) perf_o = 4'd7;
		else if (!xv) perf_o = 4'd1;
		else if (!x_go) perf_o = 4'd8;
		else if (x_cons) perf_o = 4'd0;
		else if ((g_a && gpend_x(pg(rA))) || (g_b && gpend_x(pg(rB))) || (g_d && gpend_x(pg(rD)))) perf_o = 4'd2;
		else if (fm) perf_o = 4'd3;
		else if (ff) perf_o = 4'd4;
		else if (xf.go && !fp_free) perf_o = 4'd5;
		else perf_o = 4'd6;
	end

	// ---- X, M, the float unit's results -------------------------------------------------------------------------------
	task automatic set_cr0(input logic [31:0] v);
		crf[0] <= {v[31], !v[31] && v != 0, v == 0, xerso};
	endtask
	task automatic wg(input logic [4:0] r, input logic [31:0] v);
		wgp(pg(r), v);
	endtask
	// (gw_v has gw_v_d; v is the bench's, its copy, and the check's)
	task automatic wgp(input logic [5:0] p, input logic [31:0] v);
		gpr[p] <= v;
		gw_en <= 1'b1;
		gw_r <= p;
`ifdef VERILATOR
		gw_vchk <= v;
`endif
		gh_wk <= {p == pg(op[25:21]), p == pg(op[15:11]), p == pg(op[20:16])};
		gh_wn <= {p == pg(op_nx[25:21]), p == pg(op_nx[15:11]), p == pg(op_nx[20:16])};
	endtask

	task automatic raise(input logic [4:0] e, input logic [31:0] param);
		exc <= e;
		exc_param <= param;
		ret_x <= 1'b0;
		xstate <= XS_EXC;
	endtask

	// a data access that doesn't translate: DSI, or a data TLB miss (with DMISS, DCMP, HASH1 / HASH2 for the handler)
	task automatic dfault(input logic [31:0] ea, input logic wr, input logic prot);
		logic [23:0] seg;
		logic [31:0] hashbase, hashmask, hash;
		if (prot)
		begin
			sprv[X_DSISR] <= 32'h08000000 | (wr ? 32'h02000000 : 32'h0);
			raise(EX_DSI, ea);
		end
		else
		begin
			seg = sr[ea[31:28]][23:0];
			hashbase = sprv[X_SDR1] & 32'hffff0000;
			hashmask = {7'h0, sprv[X_SDR1][8:0], 16'hffff};
			hash = {13'h0, seg[18:0]} ^ {16'h0, ea[27:12]};
			sprv[X_DMISS] <= ea;
			sprv[X_DCMP] <= 32'h80000000 | {1'b0, seg[23:0], 7'h0} | {26'h0, ea[27:22]};
			sprv[X_HASH1] <= hashbase | ((hash << 6) & hashmask);
			sprv[X_HASH2] <= hashbase | ((~hash << 6) & hashmask);
			raise(wr ? EX_DTLBMISSS : EX_DTLBMISSL, ea);
		end
	endtask

	always_ff @(posedge clk)
	begin
		rst_q <= rst;
		hold_q <= dbg_hold;
		gw_v <= gw_v_d;
		m_val <= m_val_d;           // (a move's in M a clock, the one after it's here)
		ret_x <= 1'b0;
		ret_m <= 1'b0;
		a_v <= 1'b0;
		gw_en <= 1'b0;
		gh_wk <= 3'b0;
		gh_wn <= 3'b0;
		gh_kq <= op_keep;
		gm_en <= m_gw;
		gm_r <= m_rd;
		gm_v <= m_gv;
		gh_m <= m_gw ? gnext(m_rd) : 3'b0;
		if (rst)
		begin
			xstate <= XS_RUN;
			m_valid <= 1'b0;
			n_valid <= 1'b0;
			fpu_busy <= 1'b0;
			credit <= 1'b0;
			dec_irq <= 1'b0;
			sq_out <= 1'b0;
			a_v <= 1'b0;
			if (!rst_q)
			begin
				// the 602's reset, on the first clock of rst
				pc <= 32'hfff00100;
				msr <= MSR_IP;
				dec <= 32'hffffffff;            // (MAME's: its first time through zero is a whole count away)
				tsel <= 1'b0;
				sprv[X_IBR] <= 32'h0;
				sprv[X_ESASRR] <= 32'h0;
				sprv[X_HID0] <= 32'h1;
				fpscr <= 32'h0;
				fmode <= 2'd0;
				reserved <= 1'b0;
			end
			// then the bench may load state while rst is held
			else if (dbg_we) dbg_write();
		end
		else
		begin
			if (hold_q && !dbg_hold) credit <= 1'b1;
			if (dec_tick)
			begin
				// the decrementer exception when DEC goes negative
				dec <= dec - 32'd1;
				if (dec == 32'h0) dec_irq <= 1'b1;
			end
			if (tb_tick) tb <= tb + 64'd1;

			// the data request taken: its address clock next
			if (d_req && d_rdy)
			begin
				a_v <= 1'b1;
				a_seq <= xstate == XS_SEQ;
				a_va <= d_va;
				a_pa <= dt_id ? d_va : dts.pa; a_tok <= dck[1]; a_tprot <= dck[0];
				if (xstate == XS_SEQ)
				begin
					a_we <= sq_wr; a_size <= sq_size; a_wdata <= sq_wdata; a_upd <= 1'b0;
					a_ipc <= mc_ipc;
				end
				else
				begin
					a_we <= xm_we; a_size <= xm_size; a_wdata <= xm_wdata; a_upd <= xm_upd;
					a_cw <= cov_w(d_va[1:0], xm_size);
					a_ipc <= ipc; a_op <= op; a_ra <= pg(rA); a_rav <= ra_v;
				end
			end
			// M's address clock: a fault (X's access out of M or N, its update undone; SEQ's not out), or X's retires
			if (a_v)
			begin
				if (a_flt)
				begin
					dfault(a_va, a_we, a_tprot);
					if (a_seq) sq_out <= 1'b0;
					else
					begin
						if (n_valid) n_valid <= 1'b0;
						else m_valid <= 1'b0;
						if (a_upd) wgp(a_ra, a_rav);
					end
				end
				else if (!a_seq)
				begin
					ret_m <= 1'b1;
					retm_ipc <= a_ipc;
					retm_op <= a_op;
				end
			end

			// M: the access out is answered; N's to M
			if (m_done)
			begin
				if (m_gw) gpr[m_rd] <= m_gv;
				if (m_fw) fpr[m_rd[4:0]] <= m_fv;
				if (m_kind == MK_LOAD && m_resv) reserved <= 1'b1;
				if (n_valid && !n_flt)
				begin
					m_kind <= n_kind; m_rd <= n_rd; m_size <= n_size; m_sext <= n_sext; m_bswap <= n_bswap; m_resv <= n_resv;
					m_wr_en <= n_wr_en;
				end
				else m_valid <= 1'b0;
				n_valid <= 1'b0;
			end
			// the float units' results
			if (fpu_busy && fpu_done)
			begin
				fpu_busy <= 1'b0;
				fpr[fpu_rd] <= fpu_res;
			end
			if (fpp_wv)
			begin
				fpr[fpp_wrd] <= fpp_wval;
			end

			// what an exception raised this clock saves (a decision too late in the clock to choose it)
			if (xstate != XS_EXC) exc_ipc <= a_flt ? a_ipc : hold_flush ? pc : ipc;

			case (xstate)
				XS_RUN:
					if (x_cons)
					begin
						credit <= 1'b0;
						mc_ipc <= ipc;
						mc_op <= op;
						if (x_int)
						begin
							raise(int_q ? EX_EI : EX_DECREMENT, 32'h0);
							if (!int_q) dec_irq <= 1'b0;
						end
						else if (xflt != 2'd0) raise(xflt == 2'd2 ? EX_ISI : EX_ITLBMISS, xflt == 2'd2 ? 32'h08000000 : 32'h0);
						else if (x_fpoff) raise(EX_FPU, 32'h0);
						else exec();
					end
					else if (hold_flush)
					begin
						if (dbg_we) dbg_write();
						if (dbg_int != 2'd0) raise(dbg_int == 2'd1 ? EX_EI : EX_DECREMENT, 32'h0);
					end

				XS_CHK:
					// the comparisons of a trap and a division, a clock of their own: those of X's forwarded operands are too late
					if (dv_tw)
					begin
						if ((dv_rd[4] && $signed(dv_q) < $signed(dv_d)) || (dv_rd[3] && $signed(dv_q) > $signed(dv_d)) ||
							(dv_rd[2] && dv_q == dv_d) || (dv_rd[1] && dv_q < dv_d) || (dv_rd[0] && dv_q > dv_d))
						begin
							raise(EX_PROGRAM, 32'h20000);
							exc_ipc <= mc_ipc;
						end
						else ret_mc();
					end
					else if (dv_d == 0 || (dv_sgn && dv_d == 32'hffffffff && dv_q == 32'h80000000))
					begin
						wgp(dv_rd, 32'h0);
						if (dv_oe) begin xerso <= 1'b1; xer[30] <= 1'b1; end
						if (dv_rc) crf[0] <= {3'b001, xerso | dv_oe};
						ret_mc();
					end
					else
					begin
						dv_neg_q <= dv_sgn && (dv_q[31] ^ dv_d[31]);
						dv_q <= dv_sgn && dv_q[31] ? -dv_q : dv_q;
						dv_d <= dv_sgn && dv_d[31] ? -dv_d : dv_d;
						dv_r <= 32'h0;
						dv_n <= 6'd32;
						xstate <= XS_DIV;
					end

				XS_DIV:
				begin
					// restoring division, a bit a clock
					if (dv_n != 0)
					begin
						logic [32:0] rem;
						rem = {dv_r, dv_q[31]};
						if (rem >= {1'b0, dv_d})
						begin
							dv_r <= 32'(rem - {1'b0, dv_d});
							dv_q <= {dv_q[30:0], 1'b1};
						end
						else
						begin
							dv_r <= {dv_r[30:0], dv_q[31]};
							dv_q <= {dv_q[30:0], 1'b0};
						end
						dv_n <= dv_n - 6'd1;
					end
					else
					begin
						logic [31:0] q;
						q = dv_neg_q ? -dv_q : dv_q;
						wgp(dv_rd, q);
						if (dv_oe) xer[30] <= 1'b0;
						if (dv_rc) set_cr0(q);
						ret_mc();
					end
				end

				XS_SEQ: seq_step();

				XS_EXC:
				begin
					logic [31:0] srr1, m, andmask, ormask;
					logic tlb;
					tlb = exc == EX_ITLBMISS || exc == EX_DTLBMISSL || exc == EX_DTLBMISSS;
					if (exc == EX_DSI) sprv[X_DAR] <= exc_param;
					sprv[X_SRR0] <= exc == EX_SYSCALL ? exc_ipc + 32'd4 : exc_ipc;
					srr1 = msr & 32'h87c0ffff;
					if (exc == EX_ISI || exc == EX_PROGRAM) srr1 = srr1 | exc_param;
					if (exc == EX_ITLBMISS) srr1 = srr1 | 32'h00040000;
					else if (exc == EX_DTLBMISSL) srr1 = srr1 | 32'h00010000;
					if (tlb) srr1 = {crf[0], srr1[27:0]};
					sprv[X_SRR1] <= srr1;
					andmask = 32'h00040000 | 32'h00008000 | 32'h00004000 | 32'h00002000 | 32'h00000800 | 32'h00000400 |
						32'h00000200 | 32'h00000100 | MSR_IR | MSR_DR | 32'h00000002 | MSR_LE;
					ormask = 32'h0;
					if (tlb) ormask = MSR_TGPR; else andmask = andmask | MSR_TGPR;
					m = (msr & ~andmask) | ormask;
					m[0] = m[16];
					msr <= m;
					if (msr[17] != m[17]) tsel <= !tsel;
					pc <= vec;
					ret_x <= 1'b1;
					ret_ipc <= exc_ipc;
					ret_op <= mc_op;
					exc_q <= exc;
					timer_q <= 1'b0;
					xstate <= XS_RUN;
				end

				default: xstate <= XS_RUN;
			endcase
			// (CRF's other writes are the other states', the debug write's, or another opcode's)
			if (x_exec && pd.cr0w) crf[0] <= cr0x(xerso | x_cr0ov);
			if (x_exec && pd.cmpw) crf[op[25:23]] <= cmp_d;

			// the float units take X's op
			if (fpu_start)
			begin
				fpu_busy <= 1'b1;
				fpu_rd <= rD;
			end
		end
	end

	// a multi-clock instruction is done
	task automatic ret_mc();
		ret_x <= 1'b1;
		ret_ipc <= mc_ipc;
		ret_op <= mc_op;
		exc_q <= 5'd0;
		timer_q <= 1'b0;
		xstate <= XS_RUN;
	endtask

	task automatic dbg_write();
		if (dbg_idx < 32) wg(dbg_idx[4:0], dbg_val[31:0]);
		else if (dbg_idx < 64) fpr[dbg_idx[4:0]] <= d2f(dbg_val);
		else if (dbg_idx == 64) pc <= dbg_val[31:0];
		else if (dbg_idx == 65) for (int i = 0; i < 8; i++) crf[i] <= dbg_val[31 - 4 * i -: 4];
		else if (dbg_idx == 66) begin xer <= dbg_val[30:0]; xerso <= dbg_val[31]; end
		else if (dbg_idx == 67) msr <= dbg_val[31:0];
		else if (dbg_idx == 68) begin fpscr <= dbg_val[31:0]; fmode <= dbg_val[1:0]; end
		else if (dbg_idx == 69) dec <= dbg_val[31:0];
		else if (dbg_idx == 70) tb[31:0] <= dbg_val[31:0];
		else if (dbg_idx == 71) tb[63:32] <= dbg_val[31:0];
		else if (dbg_idx >= 72 && dbg_idx < 76) wgp(tsel ? {4'b0000, dbg_idx[1:0]} : {4'b1000, dbg_idx[1:0]}, dbg_val[31:0]);
		else if (dbg_idx >= 80 && dbg_idx < 96) sr[dbg_idx[3:0]] <= dbg_val[31:0];
		else if (dbg_idx >= 1024)
		begin
			int k;
			k = spr_idx(dbg_idx[9:0]);
			if (k >= 0) sprv[k] <= dbg_val[31:0];
		end
	endtask

	// ---- EXEC (X takes the instruction) -------------------------------------------------------------------------------
	task automatic exec();
		pc <= br_taken ? br_target : npc;
		ret_x <= 1'b1;
		ret_ipc <= ipc;
		ret_op <= op;
		exc_q <= 5'd0;
		timer_q <= 1'b0;
		if (pd.m.mem)
		begin
			ret_x <= 1'b0;
			mem_issue();
		end
		else
			case (opc)
				6'h03: // TWI
				begin
					dv_q <= ra_v;
					dv_d <= simm;
					dv_rd <= {1'b0, rD};
					dv_tw <= 1'b1;
					ret_x <= 1'b0;
					xstate <= XS_CHK;
				end
				6'h07: wg(rD, mulw[31:0]);                                                             // MULLI
				6'h08: begin wg(rD, simm - ra_v); xer[29] <= ad_s[32]; end                             // SUBFIC
				6'h0a, 6'h0b: ;                                                                        // CMPLI, CMPI (cmp_d)
				6'h0c, 6'h0d:                                                                          // ADDIC, ADDIC. (CR0: cr0w)
				begin
					wg(rD, ra_v + simm);
					xer[29] <= ad_s[32];
				end
				6'h0e: wg(rD, raz + simm);                                                             // ADDI
				6'h0f: wg(rD, raz + {op[15:0], 16'h0});                                                // ADDIS
				6'h10: bc();                                                                           // BCx
				6'h11: raise(EX_SYSCALL, 32'h0);                                                  // SC
				6'h12: if (op[0]) sprv[X_LR] <= npc;                                                   // Bx
				6'h13: op13();
				6'h14, 6'h15, 6'h17: wg(rA, sh_res);                                                   // RLWIMI, RLWINM, RLWNM
				6'h18: wg(rA, rs_v | uimm);
				6'h19: wg(rA, rs_v | {op[15:0], 16'h0});
				6'h1a: wg(rA, rs_v ^ uimm);
				6'h1b: wg(rA, rs_v ^ {op[15:0], 16'h0});
				6'h1c: wg(rA, rs_v & uimm);
				6'h1d: wg(rA, rs_v & {op[15:0], 16'h0});
				6'h1f: op1f();
				6'h2e: begin sq_count <= 7'd32 - {2'b0, rD}; sq_reg <= rD; seq_start(Q_LMW, raz + simm, 4'd4); end
				6'h2f: begin sq_count <= 7'd32 - {2'b0, rD}; sq_reg <= rD; sq_wdata <= {32'h0, rs_v}; seq_start(Q_STMW, raz + simm, 4'd4); end
				6'h3b, 6'h3f: opfp();
				default: raise(EX_PROGRAM, 32'h80000);
			endcase
	endtask

	// a single access: out to the data side (taken this clock) and into M, or N behind M's (which may yet fault it)
	task automatic mem_issue();
		logic [5:0] rd;
		logic       wr_en;
		rd = xm_kind == MK_LOAD ? pg(rD) : {1'b0, rD};
		// the update form's rA wins over rD (MAME writes it last)
		wr_en = !(xm_upd && xm_kind == MK_LOAD && rD == rA);
		if (m_valid && (!m_done || n_valid))
		begin
			n_valid <= 1'b1;
			n_kind <= xm_kind; n_rd <= rd; n_size <= xm_size; n_sext <= xm_sext; n_bswap <= xm_bswap; n_resv <= xm_resv;
			n_wr_en <= wr_en;
		end
		else
		begin
			m_valid <= 1'b1;
			m_kind <= xm_kind; m_rd <= rd; m_size <= xm_size; m_sext <= xm_sext; m_bswap <= xm_bswap; m_resv <= xm_resv;
			m_wr_en <= wr_en;
		end
		if (pd.m.upd) wg(rA, d_va);
	endtask

	task automatic seq_start(input qkind_t k, input logic [31:0] ea, input logic [3:0] size);
		sq_kind <= k;
		sq_ea <= ea;
		sq_size <= size;
		sq_ra <= rA;
		sq_byte <= 2'd0;
		sq_out <= 1'b0;
		ret_x <= 1'b0;
		xstate <= XS_SEQ;
	endtask

	// branch conditional: CTR and LR (the target is br_target)
	task automatic bc();
		if (!rD[2]) sprv[X_CTR] <= sprv[X_CTR] - 32'd1;
		if (op[0]) sprv[X_LR] <= npc;
	endtask

	task automatic op13();
		logic a, b, v;
		a = crf[op[20:18]][3 - op[17:16]];
		b = crf[op[15:13]][3 - op[12:11]];
		case (xo)
			10'h010, 10'h210: bc();                                                                // BCLR, BCCTR
			10'h000: crf[op[25:23]] <= crf[op[20:18]];                                             // MCRF
			10'h101, 10'h081, 10'h0e1, 10'h1c1, 10'h1a1, 10'h021, 10'h0c1, 10'h121:
			begin
				case (xo)
					10'h101: v = a & b;
					10'h081: v = a & !b;
					10'h0e1: v = !(a & b);
					10'h1c1: v = a | b;
					10'h1a1: v = a | !b;
					10'h021: v = !(a | b);
					10'h0c1: v = a ^ b;
					default: v = !(a ^ b);
				endcase
				crf[op[25:23]][3 - op[22:21]] <= v;
			end
			10'h032:                                                                               // RFI
			begin
				msr <= ((msr & ~32'h87c0ffff) | (sprv[X_SRR1] & 32'h87c0ffff)) & ~MSR_TGPR;
				if (msr[17]) tsel <= !tsel;
			end
			10'h096: ;                                                                             // ISYNC
			default: raise(EX_PROGRAM, 32'h80000);
		endcase
	endtask

	task automatic op1f();
		logic [31:0] res, a, b, s;
		a = ra_v;
		b = rb_v;
		s = rs_v;
		case (xo)
			10'h004: // TW
			begin
				dv_q <= a;
				dv_d <= b;
				dv_rd <= {1'b0, rD};
				dv_tw <= 1'b1;
				ret_x <= 1'b0;
				xstate <= XS_CHK;
			end
			10'h10a, 10'h30a, 10'h00a, 10'h20a, 10'h08a, 10'h28a, 10'h0ca, 10'h2ca, 10'h0ea, 10'h2ea:
			begin
				// ADD, ADDC, ADDE, ADDZE, ADDME
				logic [31:0] bb;
				logic cin, wca;
				bb = xo[7:0] == 8'h0a || xo[7:0] == 8'h8a ? b : xo[7:0] == 8'hca ? 32'h0 : 32'hffffffff;
				cin = xo[7:0] == 8'h0a ? 1'b0 : xo[7:0] == 8'h8a || xo[7:0] == 8'hca || xo[7:0] == 8'hea ? xer[29] : 1'b0;
				if (xo[8:0] == 9'h10a) cin = 1'b0;
				res = a + bb + 32'(cin);
				wca = xo[8:0] != 9'h10a;
				if (wca) xer[29] <= ad_s[32];
				if (oe) begin xer[30] <= ad_ov; if (ad_ov) xerso <= 1'b1; end
				wg(rD, res);
			end
			10'h028, 10'h228, 10'h008, 10'h208, 10'h088, 10'h288, 10'h0c8, 10'h2c8, 10'h0e8, 10'h2e8:
			begin
				// SUBF, SUBFC, SUBFE, SUBFZE, SUBFME: ~a + b + cin
				logic [31:0] bb;
				logic cin;
				bb = xo[7:0] == 8'h28 || xo[7:0] == 8'h08 || xo[7:0] == 8'h88 ? b : xo[7:0] == 8'hc8 ? 32'h0 : 32'hffffffff;
				cin = xo[7:0] == 8'h28 || xo[7:0] == 8'h08 ? 1'b1 : xer[29];
				res = ~a + bb + 32'(cin);
				if (xo[7:0] != 8'h28) xer[29] <= ad_s[32];
				if (oe) begin xer[30] <= ad_ov; if (ad_ov) xerso <= 1'b1; end
				wg(rD, res);
			end
			10'h068, 10'h268:                                                                      // NEG
			begin
				if (oe) begin xer[30] <= a == 32'h80000000; if (a == 32'h80000000) xerso <= 1'b1; end
				wg(rD, -a);
			end
			10'h000, 10'h020: ;                                                                    // CMP, CMPL (cmp_d)
			10'h00b: begin res = mulw[63:32]; wg(rD, res); end                                     // MULHWU
			10'h04b: begin res = mulw[63:32]; wg(rD, res); end                                     // MULHW
			10'h0eb, 10'h2eb:                                                                      // MULLW
			begin
				logic ov;
				res = mulw[31:0];
				ov = mulw[63:32] != {32{mulw[31]}};
				if (oe) begin xer[30] <= ov; if (ov) xerso <= 1'b1; end
				wg(rD, res);
			end
			10'h1cb, 10'h3cb, 10'h1eb, 10'h3eb:                                                    // DIVWU, DIVW
			begin
				dv_q <= a;
				dv_d <= b;
				dv_sgn <= xo[5];
				dv_tw <= 1'b0;
				dv_rd <= pg(rD);
				dv_oe <= oe;
				dv_rc <= rc;
				ret_x <= 1'b0;
				xstate <= XS_CHK;
			end
			10'h01c: begin res = s & b; wg(rA, res); end                                         // AND
			10'h03c: begin res = s & ~b; wg(rA, res); end                                        // ANDC
			10'h1dc: begin res = ~(s & b); wg(rA, res); end                                      // NAND
			10'h1bc: begin res = s | b; wg(rA, res); end                                         // OR
			10'h19c: begin res = s | ~b; wg(rA, res); end                                        // ORC
			10'h07c: begin res = ~(s | b); wg(rA, res); end                                      // NOR
			10'h13c: begin res = s ^ b; wg(rA, res); end                                         // XOR
			10'h11c: begin res = ~(s ^ b); wg(rA, res); end                                      // EQV
			10'h018, 10'h218: begin res = sh_res; wg(rA, res); end                               // SLW, SRW
			10'h318, 10'h338: begin res = sh_res; xer[29] <= sh_ca; wg(rA, res); end             // SRAW, SRAWI
			10'h01a: begin res = clz32(s); wg(rA, res); end                                      // CNTLZW
			10'h3ba: begin res = {{24{s[7]}}, s[7:0]}; wg(rA, res); end                          // EXTSB
			10'h39a: begin res = {{16{s[15]}}, s[15:0]}; wg(rA, res); end                        // EXTSH

			10'h255, 10'h215:                                                                      // LSWI, LSWX
			begin
				logic [6:0] cnt;
				cnt = xo == 10'h255 ? {2'b0, rB} : xer[6:0];
				if (xo == 10'h255 && rB == 0) cnt = 7'd32;
				sq_count <= cnt;
				sq_reg <= rD;
				if (cnt != 0) seq_start(Q_LSW, xo == 10'h255 ? raz : raz + b, 4'd1);
			end
			10'h096:                                                                               // STWCX.
			begin
				sq_wdata <= {32'h0, s};
				// the reservation goes when the store is made (a fault keeps it)
				if (reserved) seq_start(Q_STWCX, raz + b, 4'd4);
				else crf[0] <= {3'b000, xerso};
			end
			10'h2d5, 10'h295:                                                                      // STSWI, STSWX
			begin
				logic [6:0] cnt;
				cnt = xo == 10'h2d5 ? {2'b0, rB} : xer[6:0];
				if (xo == 10'h2d5 && rB == 0) cnt = 7'd32;
				sq_count <= cnt;
				sq_reg <= rD;
				sq_wdata <= {56'h0, rs_v[31:24]};
				if (cnt != 0) seq_start(Q_STSW, xo == 10'h2d5 ? raz : raz + b, 4'd1);
			end
			// cache, TLB, sync: nothing in MAME
			10'h036, 10'h056, 10'h0f6, 10'h116, 10'h256, 10'h356, 10'h1d6, 10'h236, 10'h3d6, 10'h132, 10'h172,
			10'h3d2, 10'h3f2: ;
			10'h3f6:                                                                               // DCBZ
			begin
				sq_count <= 7'd4;
				sq_wdata <= 64'h0;
				seq_start(Q_DCBZ, (raz + b) & ~32'd31, 4'd8);
			end
			// moves
			10'h013: wg(rD, get_cr());                                                             // MFCR
			10'h053: wg(rD, msr);                                                                  // MFMSR
			10'h153:                                                                               // MFSPR
			begin
				wg(rD, mfspr_v(sprn));
				timer_q <= sprn == 10'd22 || sprn == 10'd268 || sprn == 10'd269;
			end
			10'h253: wg(rD, sr[op[19:16]]);                                                        // MFSR
			10'h293: wg(rD, sr[b[31:28]]);                                                         // MFSRIN
			10'h173:                                                                               // MFTB
				if (sprn == 10'd268 || sprn == 10'd269) begin wg(rD, mfspr_v(sprn)); timer_q <= 1'b1; end
				else raise(EX_PROGRAM, 32'h80000);
			10'h090:                                                                               // MTCRF
				for (int i = 0; i < 8; i++)
					if (op[19 - i]) crf[i] <= s[31 - 4 * i -: 4];
			10'h092:                                                                               // MTMSR
			begin
				msr <= s;
				if (msr[17] != s[17]) tsel <= !tsel;
			end
			10'h1d3: mtspr(sprn, s);                                                               // MTSPR
			10'h0d2: sr[op[19:16]] <= s;                                                           // MTSR
			10'h0f2: sr[b[31:28]] <= s;                                                            // MTSRIN
			10'h200:                                                                               // MCRXR
			begin
				crf[op[25:23]] <= {xerso, xer[30:28]};
				xer[30:28] <= 3'h0;
				xerso <= 1'b0;
			end
			10'h254:                                                                               // ESA
			begin
				if (msr[22]) raise(EX_PROGRAM, 32'h20000);
				else
				begin
					sprv[X_ESASRR][3:0] <= {msr[14], msr[23], msr[22], msr[15]};
					msr <= (msr & ~(MSR_AP | MSR_EE | MSR_PR)) | MSR_SA;
				end
			end
			10'h274:                                                                               // DSA
			begin
				if (!msr[22]) raise(EX_PROGRAM, 32'h20000);
				else
				begin
					msr[15] <= sprv[X_ESASRR][0];
					msr[22] <= sprv[X_ESASRR][1];
					msr[23] <= sprv[X_ESASRR][2];
					msr[14] <= sprv[X_ESASRR][3];
				end
			end
			default: raise(EX_PROGRAM, 32'h80000);
		endcase
	endtask

	task automatic mtspr(input logic [9:0] n, input logic [31:0] v);
		int k;
		case (n)
			10'd1: begin xer <= v[30:0]; xerso <= v[31]; end
			10'd287: ;
			10'd22: dec <= v;
			// as MAME: (tb & ~0xffffffff00000000) | v and (tb & ~0x00000000ffffffff) | v << 32
			10'd284: tb <= {32'h0, tb[31:0] | v};
			10'd285: tb <= {tb[63:32] | v, 32'h0};
			10'd976, 10'd977, 10'd978, 10'd979, 10'd980, 10'd981: ;
			default:
			begin
				k = spr_idx(n);
				if (k >= 0) sprv[k] <= v;
			end
		endcase
	endtask

	// ---- floating point: to the float unit, or done here (the moves, through M) ---------------------------------------
	// (m_val has m_val_d; v is the check's)
	// verilator lint_off UNUSEDSIGNAL
	task automatic fmov(input logic [32:0] v);
	// verilator lint_on UNUSEDSIGNAL
		m_valid <= 1'b1;
		m_kind <= MK_FMOV;
		m_rd <= {1'b0, rD};
`ifdef VERILATOR
		m_vchk <= v;
`endif
	endtask

	task automatic opfp();
		// verilator lint_off UNUSEDSIGNAL
		logic [32:0] fa, fb;
		// verilator lint_on UNUSEDSIGNAL
		fa = fx(rA, 2'd0, fr_a);
		fb = fx(rB, 2'd1, fr_b);
		if (xf.go)
		begin
			// out to a float unit (fpp_issue, fpu_start); with Rc, but for fctiw[z], CR1 is FPSCR's top (MAME), which
			// they don't change
			if (rc && xf.op != F_CTIW && xf.op != F_CTIWZ) crf[1] <= fpscr[31:28];
		end
		else if (opc == 6'h3b) raise(EX_PROGRAM, 32'h80000);
		else if (xo[4])
			case (op[5:1])
				// FSEL: c if a >= 0.0 (not NaN, and positive or a zero), else b; no CR1 even with Rc (MAME)
				5'h17: fmov(!snan(fa[31:0]) && (!fa[31] || fa[30:0] == 31'h0) ? fx(frC, 2'd2, fr_c) : fb);
				default: raise(EX_PROGRAM, 32'h80000);
			endcase
		else
			case (xo)
				10'h000, 10'h020:                                                                  // FCMPU, FCMPO
				begin
					crf[op[25:23]] <= fcmp_r;
					fpscr[15:12] <= fcmp_r;
				end
				// these leave CR1 alone even with Rc (MAME)
				10'h028: fmov(fb ^ 33'h080000000);                                          // FNEG
				10'h048: fmov(fb);                                                                 // FMR
				10'h088: fmov(fb | 33'h080000000);                                          // FNABS
				10'h108: fmov(fb & ~33'h080000000);                                         // FABS
				// the rounding mode the float unit uses (fmode) follows FPSCR[RN] only through these, as MAME's host mode
				// does (mcrfs clearing RN leaves it)
				10'h046: begin fpscr[31 - rD] <= 1'b0; if (rD == 5'd30) fmode <= {1'b0, fpscr[0]}; if (rD == 5'd31) fmode <= {fpscr[1], 1'b0}; end // MTFSB0
				10'h026: begin fpscr[31 - rD] <= 1'b1; if (rD == 5'd30) fmode <= {1'b1, fpscr[0]}; if (rD == 5'd31) fmode <= {fpscr[1], 1'b1}; end // MTFSB1
				10'h040:                                                                           // MCRFS
				begin
					crf[op[25:23]] <= fpscr[31 - 4 * op[20:18] -: 4];
					fpscr <= fpscr & ~crmask(op[20:18]);
				end
				10'h247: fmov({1'b1, fpscr});                                                     // MFFS: an integer, as the manual has it
				10'h2c7:                                                                           // MTFSF
				begin
					logic [31:0] m, v;
					m = 32'h0;
					for (int i = 0; i < 8; i++) if (op[24 - i]) m = m | crmask(3'(i));
					v = (fpscr & ~m) | (fb[31:0] & m);
					fpscr <= v;
					fmode <= v[1:0];
				end
				10'h086:                                                                           // MTFSFI
				begin
					logic [31:0] v;
					v = (fpscr & ~crmask(op[25:23])) | (rol32({28'h0, op[15:12]}, 5'd28 - {op[25:23], 2'b00}) & crmask(op[25:23]));
					fpscr <= v;
					if (op[25:23] == 3'd7) fmode <= v[1:0];
				end
				default: raise(EX_PROGRAM, 32'h80000);
			endcase
	endtask

	// ---- SEQ: one access at a time, M empty: out, its address clock (a fault: the exception, nothing changed), the
	// answer ----------------------------------------------------------------------------------------------------------
	task automatic seq_step();
		if (!sq_out)
		begin
			// lsw clears each register before its first byte is read (MAME), even when the read faults
			if (sq_kind == Q_LSW && sq_byte == 2'd0) wg(sq_reg, 32'h0);
			if (d_rdy) sq_out <= 1'b1;
		end
		else if (d_valid)
		begin
			sq_out <= 1'b0;
			case (sq_kind)
				Q_STWCX: begin crf[0] <= {3'b001, xerso}; reserved <= 1'b0; end
				Q_LMW:
				begin
					if (sq_reg != sq_ra) wg(sq_reg, d_rdata[31:0]);
					sq_reg <= sq_reg + 5'd1;
				end
				Q_STMW:
				begin
					sq_wdata <= {32'h0, gxc(seq_rs, gr_s)};
					sq_reg <= sq_reg + 5'd1;
				end
				Q_LSW:
				begin
					logic [31:0] v;
					v = sq_byte == 0 ? 32'h0 : gxc(seq_rs, gr_s);
					v[31 - 8 * sq_byte -: 8] = d_rdata[7:0];
					wg(sq_reg, v);
					sq_byte <= sq_byte + 2'd1;
					if (sq_byte == 2'd3) sq_reg <= sq_reg + 5'd1;
				end
				Q_STSW:
				begin
					logic [4:0] reg_n;
					logic [1:0] byte_n;
					logic [31:0] v;
					byte_n = sq_byte + 2'd1;
					reg_n = sq_byte == 2'd3 ? sq_reg + 5'd1 : sq_reg;
					v = gxc(seq_rs, gr_s);
					sq_wdata <= {56'h0, v[31 - 8 * byte_n -: 8]};
					sq_byte <= byte_n;
					sq_reg <= reg_n;
				end
				default: ;
			endcase
			sq_count <= sq_count - 7'd1;
			sq_ea <= sq_ea + (sq_kind == Q_DCBZ ? 32'd8 : sq_kind == Q_LMW || sq_kind == Q_STMW ? 32'd4 : 32'd1);
			if (seq_last()) ret_mc();
		end
	endtask
endmodule
