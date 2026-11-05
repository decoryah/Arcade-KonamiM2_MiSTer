// PowerPC 602 as MAME 0.289 runs it (cpu/powerpc/ppcdrc.cpp; the reference is tools/ref/ppc602, checked against MAME's
// traces by sim/ppcreplay). Bit-exact with MAME's instruction semantics, not cycle-exact: one instruction at a time, in
// the states
//   TOP (interrupts) -> FETCH -> EXEC (everything but memory and the float unit) -> [MEM: the accesses, one at a time,
//   in MAME's order] -> [FPU] -> TOP, or EXC (an exception's SRR0 / SRR1 / MSR / vector) on a fault.
// MAME's quirks kept (see ppc602.h): single-precision arithmetic in double steps then a round to single (the float unit);
// tlbld / tlbli do nothing, so with relocation on, an address no BAT maps is a TLB miss unless HID0[0x80] (protection-
// only) maps it to itself; divw / divwu by zero give 0; lmw skips rA; no FP-unavailable exception; MSR[POW] doesn't stop.
// SPRs MAME keeps but the 602 doesn't have read 0 here (only the ones listed in spr_idx exist).
`default_nettype none
module ppc_core (
	input  logic        clk,
	input  logic        rst,            // held while 1; on release, the 602's reset (PC 0xfff00100, MSR[IP])

	// one access at a time: bus_req held with the address (and data) until bus_ack; read data comes with bus_ack.
	// Physical addresses; size 1, 2, 4 or 8 bytes, any alignment; data right-aligned, big-endian.
	output logic        bus_req,
	output logic        bus_we,
	output logic        bus_fetch,      // an instruction fetch
	output logic [31:0] bus_addr,
	output logic [3:0]  bus_size,
	output logic [63:0] bus_wdata,
	input  logic        bus_ack,
	input  logic [63:0] bus_rdata,

	input  logic        int_ext,        // external interrupt (level; taken when MSR[EE])
	input  logic        dec_tick,       // decrement DEC (the bus clock / 4 on the board)
	input  logic        tb_tick,        // advance TB

	// bench: an instruction finished, its address and word, the state after it
	output logic        retire,
	output logic [31:0] ipc_o,
	output logic [31:0] iop_o,
	output logic [4:0]  exc_o,          // the exception it took (0: none)
	output logic        timer_read_o,   // it read TB or DEC
	output logic [31:0] pc_o,
	output logic [32*32-1:0] gpr_o,
	output logic [64*32-1:0] fpr_o,
	output logic [31:0] cr_o, lr_o, ctr_o, xer_o, msr_o, srr0_o, srr1_o, fpscr_o,
	// bench: while rst, or between instructions (dbg_hold), load a register: 0-31 GPRs, 32-63 FPRs (dbg_val64), 64 PC,
	// 65 CR, 66 XER, 67 MSR, 68 FPSCR, 69 DEC, 70 TBL, 71 TBU, 72-75 TGPRs, 80-95 SRs, 1024+n SPR n
	input  logic        dbg_hold,       // stop at the next instruction boundary (TOP)
	output logic        dbg_idle,       // stopped there
	input  logic        dbg_we,
	input  logic [10:0] dbg_idx,
	input  logic [63:0] dbg_val,
	// bench: take an interrupt now (where MAME took it): 1 external, 2 decrementer
	input  logic [1:0]  dbg_int
);
	// ---- architectural state ------------------------------------------------------------------------------------------
	logic [31:0] gpr [0:31];
	logic [63:0] fpr [0:31];
	logic [31:0] tgpr [0:3];
	logic [3:0]  crf [0:7];
	logic [30:0] xer;                   // OV, CA, byte count (SO, bit 31, is xerso)
	logic        xerso;
	logic [31:0] msr, pc, fpscr;
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
	localparam logic [4:0] EX_DSI = 3, EX_ISI = 4, EX_EI = 5, EX_PROGRAM = 7, EX_DECREMENT = 9, EX_SYSCALL = 12,
		EX_ITLBMISS = 16, EX_DTLBMISSL = 17, EX_DTLBMISSS = 18;

	function automatic logic [31:0] get_cr();
		logic [31:0] v;
		for (int i = 0; i < 8; i++) v[31 - 4 * i -: 4] = crf[i];
		return v;
	endfunction

	always_comb
	begin
		for (int i = 0; i < 32; i++) begin gpr_o[32 * i +: 32] = gpr[i]; fpr_o[64 * i +: 64] = fpr[i]; end
		pc_o = pc;
		cr_o = get_cr();
		lr_o = sprv[X_LR];
		ctr_o = sprv[X_CTR];
		xer_o = {xerso, xer};
		msr_o = msr;
		srr0_o = sprv[X_SRR0];
		srr1_o = sprv[X_SRR1];
		fpscr_o = fpscr;
	end

	// ---- helpers ------------------------------------------------------------------------------------------------------
	function automatic logic [31:0] rol32(input logic [31:0] v, input logic [4:0] s);
		return (v << s) | (v >> (6'd32 - {1'b0, s}));
	endfunction
	function automatic logic [31:0] rlw_mask(input logic [4:0] mb, input logic [4:0] me);
		logic [31:0] m;
		m = (32'hffffffff >> mb) ^ (me == 5'd31 ? 32'h0 : 32'hffffffff >> (me + 5'd1));
		return mb > me ? ~m : m;
	endfunction
	function automatic logic [3:0] cmp4(input logic lt, input logic gt, input logic so);
		return {lt, gt, !lt && !gt, so};
	endfunction
	function automatic logic [31:0] crmask(input logic [2:0] n);
		return 32'hf0000000 >> {n, 2'b00};
	endfunction

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

	// ---- the float unit -------------------------------------------------------------------------------------------------
	logic        fpu_start, fpu_done;
	logic [4:0]  fpu_op;
	logic [63:0] fpu_a, fpu_b, fpu_c, fpu_res;
	logic [3:0]  fpu_crf;
	ppc_fpu fpu (
		.clk, .rst, .start(fpu_start), .op(fpu_op), .rn(fmode), .a(fpu_a), .b(fpu_b), .c(fpu_c),
		.done(fpu_done), .res(fpu_res), .crf(fpu_crf)
	);
	import ppc_fpu_pkg::*;

	// ---- control ------------------------------------------------------------------------------------------------------
	typedef enum logic [3:0] { S_RESET, S_TOP, S_FETCH, S_EXEC, S_MEM, S_DIV, S_FPU, S_FPUST, S_EXC, S_DONE } state_t;
	// (Verilator takes the tasks' writes for another process)
	// verilator lint_off MULTIDRIVEN
	state_t state;
	// verilator lint_on MULTIDRIVEN

	logic [31:0] ipc, op, npc;
	logic [4:0]  exc;                   // pending exception for S_EXC
	logic [31:0] exc_srr0, exc_param;
	logic        timer_read;
	logic        rst_q, dec_irq;

	// memory sequencing
	typedef enum logic [3:0] { M_LOAD, M_STORE, M_LMW, M_STMW, M_LSW, M_STSW, M_DCBZ, M_LFS, M_STFS, M_STWCX } mkind_t;
	mkind_t      mkind;
	logic [31:0] m_ea;                  // effective address of the current access
	logic [3:0]  m_size;
	logic [63:0] m_wdata;
	logic        m_sext;                // lha
	logic        m_bswap;               // lhbrx / lwbrx / sthbrx / stwbrx
	logic [4:0]  m_rd;                  // destination (or source) register
	logic        m_upd;                 // write rA = EA after
	logic [4:0]  m_ra;
	logic [31:0] m_upd_ea;
	logic [6:0]  m_count;               // remaining items (lmw / stmw registers, string bytes, dcbz beats)
	logic [4:0]  m_reg;                 // lmw / lsw current register
	logic [1:0]  m_byte;                // string op byte within a register
	logic        m_fpd;                 // lfd / stfd (64-bit FPR), else integer
	logic        m_active;              // a bus access is out
	logic        m_resv;                // lwarx: reserve when the load is done

	// divider
	logic [31:0] dv_q, dv_r, dv_d;
	logic [5:0]  dv_n;
	logic        dv_neg_q, dv_oe, dv_rc;

	// FP
	logic [4:0]  f_rd;
	logic        f_rc;
	logic        f_cmp;
	logic [2:0]  f_crfd;

	wire [5:0]  opc = op[31:26];
	wire [4:0]  rD = op[25:21], rA = op[20:16], rB = op[15:11], frC = op[10:6];
	wire [31:0] simm = {{16{op[15]}}, op[15:0]};
	wire [31:0] uimm = {16'h0, op[15:0]};
	wire [9:0]  xo = op[10:1];
	wire        rc = op[0];
	wire        oe = op[10];
	wire [31:0] ra_v = gpr[rA], rb_v = gpr[rB], rs_v = gpr[rD];
	wire [31:0] raz = rA == 0 ? 32'h0 : gpr[rA];
	wire [9:0]  sprn = {op[15:11], op[20:16]};

	assign retire = state == S_DONE;
	assign ipc_o = ipc;
	assign iop_o = op;
	assign timer_read_o = timer_read;
	assign dbg_idle = state == S_TOP && dbg_hold;

	// the access the core is making
	tr_t fetch_tr, data_tr;
	assign fetch_tr = translate(pc, 2'd2);
	wire m_wr = mkind == M_STORE || mkind == M_STMW || mkind == M_STSW || mkind == M_DCBZ || mkind == M_STWCX;
	assign data_tr = translate(m_ea, m_wr ? 2'd1 : 2'd0);

	logic [4:0] exc_q;
	assign exc_o = exc_q;

	// results of EXEC computed combinationally
	logic [63:0] mulw;
	assign mulw = $signed({{32{ra_v[31]}}, ra_v}) * $signed({{32{(opc == 6'h07) ? simm[31] : rb_v[31]}}, (opc == 6'h07) ? simm : rb_v});
	wire [31:0] mulhwu = 32'(({32'h0, ra_v} * {32'h0, rb_v}) >> 32);

	task automatic set_cr0(input logic [31:0] v);
		crf[0] <= {v[31], !v[31] && v != 0, v == 0, xerso};
	endtask

	task automatic raise(input logic [4:0] e, input logic [31:0] param);
		exc <= e;
		exc_param <= param;
		exc_srr0 <= e == EX_SYSCALL ? ipc + 32'd4 : ipc;
		state <= S_EXC;
	endtask

	// start a data access sequence
	task automatic mem_start(input mkind_t k, input logic [31:0] ea, input logic [3:0] size, input logic [4:0] rd,
		input logic upd, input logic sext, input logic bswap, input logic fpd);
		mkind <= k;
		m_ea <= ea;
		m_size <= size;
		m_rd <= rd;
		m_upd <= upd;
		m_ra <= rA;
		m_upd_ea <= ea;
		m_sext <= sext;
		m_bswap <= bswap;
		m_fpd <= fpd;
		m_active <= 1'b0;
		m_resv <= 1'b0;
		state <= S_MEM;
	endtask

	function automatic logic [63:0] bswapn(input logic [31:0] v, input logic [3:0] size);
		if (size == 4'd2) return {48'h0, v[7:0], v[15:8]};
		return {32'h0, v[7:0], v[15:8], v[23:16], v[31:24]};
	endfunction


	always_ff @(posedge clk)
	begin
		rst_q <= rst;
		if (rst)
		begin
			state <= S_RESET;
			bus_req <= 1'b0;
			bus_we <= 1'b0;
			bus_fetch <= 1'b0;
			fpu_start <= 1'b0;
			dec_irq <= 1'b0;
			if (!rst_q)
			begin
				// the 602's reset, on the first clock of rst
				pc <= 32'hfff00100;
				msr <= MSR_IP;
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
			fpu_start <= 1'b0;
			if (dec_tick)
			begin
				// the decrementer exception when DEC goes negative
				dec <= dec - 32'd1;
				if (dec == 32'h0) dec_irq <= 1'b1;
			end
			if (tb_tick) tb <= tb + 64'd1;
			case (state)
				S_RESET:
				begin
					exc_q <= 5'd0;
					state <= S_TOP;
				end

				S_TOP:
				begin
					exc_q <= 5'd0;
					timer_read <= 1'b0;
					if (dbg_hold)
					begin
						if (dbg_we) dbg_write();
						if (dbg_int != 2'd0)
						begin
							ipc <= pc;
							exc <= dbg_int == 2'd1 ? EX_EI : EX_DECREMENT;
							exc_param <= 32'h0;
							exc_srr0 <= pc;
							state <= S_EXC;
						end
					end
					else if (int_ext && msr[15])
					begin
						ipc <= pc;
						exc <= EX_EI;
						exc_param <= 32'h0;
						exc_srr0 <= pc;
						state <= S_EXC;
					end
					else if (dec_irq && msr[15])
					begin
						ipc <= pc;
						exc <= EX_DECREMENT;
						exc_param <= 32'h0;
						exc_srr0 <= pc;
						dec_irq <= 1'b0;
						state <= S_EXC;
					end
					else
					begin
						ipc <= pc;
						state <= S_FETCH;
					end
				end

				S_FETCH:
				begin
					if (!fetch_tr.ok)
					begin
						exc <= fetch_tr.prot ? EX_ISI : EX_ITLBMISS;
						exc_param <= fetch_tr.prot ? 32'h08000000 : 32'h0;
						exc_srr0 <= ipc;
						state <= S_EXC;
					end
					else if (!bus_req)
					begin
						bus_req <= 1'b1;
						bus_we <= 1'b0;
						bus_fetch <= 1'b1;
						bus_addr <= fetch_tr.pa;
						bus_size <= 4'd4;
					end
					else if (bus_ack)
					begin
						bus_req <= 1'b0;
						bus_fetch <= 1'b0;
						op <= bus_rdata[31:0];
						npc <= pc + 32'd4;
						state <= S_EXEC;
					end
				end

				S_EXEC: exec();

				S_MEM: mem_step();

				S_DIV:
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
						gpr[rD] <= q;
						if (dv_oe) xer[30] <= 1'b0;
						if (dv_rc) set_cr0(q);
						pc <= npc;
						state <= S_DONE;
					end
				end

				S_FPU:
				begin
					if (fpu_done)
					begin
						if (f_cmp)
						begin
							crf[f_crfd] <= fpu_crf;
							fpscr[15:12] <= fpu_crf;
						end
						else
							fpr[f_rd] <= fpu_res;
						if (f_rc) crf[1] <= fpscr[31:28];
						pc <= npc;
						state <= S_DONE;
					end
				end

				S_FPUST:
				begin
					// stfs: the FPR rounded to single, then the store
					if (fpu_done)
					begin
						m_wdata <= {32'h0, fpu_res[31:0]};
						state <= S_MEM;
					end
				end

				S_EXC:
				begin
					logic [31:0] srr1, m, andmask, ormask, base;
					logic tlb;
					tlb = exc == EX_ITLBMISS || exc == EX_DTLBMISSL || exc == EX_DTLBMISSS;
					if (exc == EX_DSI) sprv[X_DAR] <= exc_param;
					sprv[X_SRR0] <= exc_srr0;
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
					if (msr[17] != m[17]) swap_tgpr();
					base = m[6] ? 32'hfff00000 : sprv[X_IBR];
					pc <= base | {19'h0, exc, 8'h0};
					exc_q <= exc;
					state <= S_DONE;
				end

				S_DONE: state <= S_TOP;

				default: state <= S_TOP;
			endcase
		end
	end

	task automatic swap_tgpr();
		for (int i = 0; i < 4; i++)
		begin
			gpr[i] <= tgpr[i];
			tgpr[i] <= gpr[i];
		end
	endtask

	task automatic dbg_write();
		if (dbg_idx < 32) gpr[dbg_idx[4:0]] <= dbg_val[31:0];
		else if (dbg_idx < 64) fpr[dbg_idx[4:0]] <= dbg_val;
		else if (dbg_idx == 64) pc <= dbg_val[31:0];
		else if (dbg_idx == 65) for (int i = 0; i < 8; i++) crf[i] <= dbg_val[31 - 4 * i -: 4];
		else if (dbg_idx == 66) begin xer <= dbg_val[30:0]; xerso <= dbg_val[31]; end
		else if (dbg_idx == 67) msr <= dbg_val[31:0];
		else if (dbg_idx == 68) begin fpscr <= dbg_val[31:0]; fmode <= dbg_val[1:0]; end
		else if (dbg_idx == 69) dec <= dbg_val[31:0];
		else if (dbg_idx == 70) tb[31:0] <= dbg_val[31:0];
		else if (dbg_idx == 71) tb[63:32] <= dbg_val[31:0];
		else if (dbg_idx >= 72 && dbg_idx < 76) tgpr[dbg_idx[1:0]] <= dbg_val[31:0];
		else if (dbg_idx >= 80 && dbg_idx < 96) sr[dbg_idx[3:0]] <= dbg_val[31:0];
		else if (dbg_idx >= 1024)
		begin
			int k;
			k = spr_idx(dbg_idx[9:0]);
			if (k >= 0) sprv[k] <= dbg_val[31:0];
		end
	endtask

	// ---- MFSPR / MTSPR (MAME's ppccom_execute_mfspr / mtspr for a 602) ------------------------------------------------
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

	// ---- EXEC ---------------------------------------------------------------------------------------------------------
	task automatic exec();
		logic [31:0] res, t;
		logic [32:0] s33;
		state <= S_DONE;
		pc <= npc;
		case (opc)
			6'h03: // TWI
			begin
				if ((rD[4] && $signed(ra_v) < $signed(simm)) || (rD[3] && $signed(ra_v) > $signed(simm)) ||
					(rD[2] && ra_v == simm) || (rD[1] && ra_v < simm) || (rD[0] && ra_v > simm))
					raise(EX_PROGRAM, 32'h20000);
			end
			6'h07: gpr[rD] <= mulw[31:0];                                                          // MULLI
			6'h08: begin gpr[rD] <= simm - ra_v; xer[29] <= ra_v <= simm; end                      // SUBFIC
			6'h0a: crf[op[25:23]] <= cmp4(ra_v < uimm, ra_v > uimm, xerso);                        // CMPLI
			6'h0b: crf[op[25:23]] <= cmp4($signed(ra_v) < $signed(simm), $signed(ra_v) > $signed(simm), xerso); // CMPI
			6'h0c, 6'h0d:                                                                          // ADDIC, ADDIC.
			begin
				s33 = {1'b0, ra_v} + {1'b0, simm};
				gpr[rD] <= s33[31:0];
				xer[29] <= s33[32];
				if (opc == 6'h0d) set_cr0(s33[31:0]);
			end
			6'h0e: gpr[rD] <= raz + simm;                                                          // ADDI
			6'h0f: gpr[rD] <= raz + {op[15:0], 16'h0};                                             // ADDIS
			6'h10: bc(op[1] ? simm & ~32'd3 : ipc + (simm & ~32'd3));                              // BCx
			6'h11: raise(EX_SYSCALL, 32'h0);                                                       // SC
			6'h12:                                                                                 // Bx
			begin
				t = {{6{op[25]}}, op[25:2], 2'b00};
				if (op[0]) sprv[X_LR] <= ipc + 32'd4;
				pc <= op[1] ? t : ipc + t;
			end
			6'h13: op13();
			6'h14: begin res = (ra_v & ~rlw_mask(op[10:6], op[5:1])) | (rol32(rs_v, op[15:11]) & rlw_mask(op[10:6], op[5:1])); gpr[rA] <= res; if (rc) set_cr0(res); end
			6'h15: begin res = rol32(rs_v, op[15:11]) & rlw_mask(op[10:6], op[5:1]); gpr[rA] <= res; if (rc) set_cr0(res); end
			6'h17: begin res = rol32(rs_v, rb_v[4:0]) & rlw_mask(op[10:6], op[5:1]); gpr[rA] <= res; if (rc) set_cr0(res); end
			6'h18: gpr[rA] <= rs_v | uimm;
			6'h19: gpr[rA] <= rs_v | {op[15:0], 16'h0};
			6'h1a: gpr[rA] <= rs_v ^ uimm;
			6'h1b: gpr[rA] <= rs_v ^ {op[15:0], 16'h0};
			6'h1c: begin res = rs_v & uimm; gpr[rA] <= res; set_cr0(res); end
			6'h1d: begin res = rs_v & {op[15:0], 16'h0}; gpr[rA] <= res; set_cr0(res); end
			6'h1f: op1f();
			// loads and stores, D-form
			6'h20: mem_start(M_LOAD, raz + simm, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0);
			6'h21: mem_start(M_LOAD, ra_v + simm, 4'd4, rD, 1'b1, 1'b0, 1'b0, 1'b0);
			6'h22: mem_start(M_LOAD, raz + simm, 4'd1, rD, 1'b0, 1'b0, 1'b0, 1'b0);
			6'h23: mem_start(M_LOAD, ra_v + simm, 4'd1, rD, 1'b1, 1'b0, 1'b0, 1'b0);
			6'h24: begin m_wdata <= {32'h0, rs_v}; mem_start(M_STORE, raz + simm, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0); end
			6'h25: begin m_wdata <= {32'h0, rs_v}; mem_start(M_STORE, ra_v + simm, 4'd4, rD, 1'b1, 1'b0, 1'b0, 1'b0); end
			6'h26: begin m_wdata <= {56'h0, rs_v[7:0]}; mem_start(M_STORE, raz + simm, 4'd1, rD, 1'b0, 1'b0, 1'b0, 1'b0); end
			6'h27: begin m_wdata <= {56'h0, rs_v[7:0]}; mem_start(M_STORE, ra_v + simm, 4'd1, rD, 1'b1, 1'b0, 1'b0, 1'b0); end
			6'h28: mem_start(M_LOAD, raz + simm, 4'd2, rD, 1'b0, 1'b0, 1'b0, 1'b0);
			6'h29: mem_start(M_LOAD, ra_v + simm, 4'd2, rD, 1'b1, 1'b0, 1'b0, 1'b0);
			6'h2a: mem_start(M_LOAD, raz + simm, 4'd2, rD, 1'b0, 1'b1, 1'b0, 1'b0);
			6'h2b: mem_start(M_LOAD, ra_v + simm, 4'd2, rD, 1'b1, 1'b1, 1'b0, 1'b0);
			6'h2c: begin m_wdata <= {48'h0, rs_v[15:0]}; mem_start(M_STORE, raz + simm, 4'd2, rD, 1'b0, 1'b0, 1'b0, 1'b0); end
			6'h2d: begin m_wdata <= {48'h0, rs_v[15:0]}; mem_start(M_STORE, ra_v + simm, 4'd2, rD, 1'b1, 1'b0, 1'b0, 1'b0); end
			6'h2e: begin m_count <= 7'd32 - {2'b0, rD}; m_reg <= rD; mem_start(M_LMW, raz + simm, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0); end
			6'h2f: begin m_count <= 7'd32 - {2'b0, rD}; m_reg <= rD; m_wdata <= {32'h0, rs_v}; mem_start(M_STMW, raz + simm, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0); end
			6'h30: mem_start(M_LFS, raz + simm, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0);
			6'h31: mem_start(M_LFS, ra_v + simm, 4'd4, rD, 1'b1, 1'b0, 1'b0, 1'b0);
			6'h32: mem_start(M_LOAD, raz + simm, 4'd8, rD, 1'b0, 1'b0, 1'b0, 1'b1);
			6'h33: mem_start(M_LOAD, ra_v + simm, 4'd8, rD, 1'b1, 1'b0, 1'b0, 1'b1);
			6'h34: stfs_start(raz + simm, 1'b0);
			6'h35: stfs_start(ra_v + simm, 1'b1);
			6'h36: begin m_wdata <= fpr[rD]; mem_start(M_STORE, raz + simm, 4'd8, rD, 1'b0, 1'b0, 1'b0, 1'b1); end
			6'h37: begin m_wdata <= fpr[rD]; mem_start(M_STORE, ra_v + simm, 4'd8, rD, 1'b1, 1'b0, 1'b0, 1'b1); end
			6'h3b: op3b();
			6'h3f: op3f();
			default: raise(EX_PROGRAM, 32'h80000);
		endcase
	endtask

	task automatic stfs_start(input logic [31:0] ea, input logic upd);
		mem_start(M_STORE, ea, 4'd4, rD, upd, 1'b0, 1'b0, 1'b0);
		fpu_op <= F_D2S;
		fpu_a <= fpr[rD];
		fpu_start <= 1'b1;
		state <= S_FPUST;
	endtask

	// branch conditional to target t (BO in rD, BI in rA); LR = ipc + 4 if LK, taken or not
	task automatic bc(input logic [31:0] t);
		logic [31:0] ctr;
		logic go;
		ctr = sprv[X_CTR];
		go = 1'b1;
		if (!rD[2])
		begin
			ctr = ctr - 32'd1;
			sprv[X_CTR] <= ctr;
			if ((ctr != 0) == rD[1]) go = 1'b0;
		end
		if (!rD[4] && crf[rA[4:2]][3 - rA[1:0]] != rD[3]) go = 1'b0;
		if (op[0]) sprv[X_LR] <= ipc + 32'd4;
		if (go) pc <= t;
	endtask

	task automatic op13();
		logic a, b, v;
		a = crf[op[20:18]][3 - op[17:16]];
		b = crf[op[15:13]][3 - op[12:11]];
		case (xo)
			10'h010: bc(sprv[X_LR] & ~32'd3);                                                      // BCLR
			10'h210: bc(sprv[X_CTR] & ~32'd3);                                                     // BCCTR
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
				if (msr[17]) swap_tgpr();
				pc <= sprv[X_SRR0];
			end
			10'h096: ;                                                                             // ISYNC
			default: raise(EX_PROGRAM, 32'h80000);
		endcase
	endtask

	task automatic op1f();
		logic [31:0] res, a, b, s;
		logic [32:0] s33;
		logic [5:0] n;
		a = ra_v;
		b = rb_v;
		s = rs_v;
		case (xo)
			10'h004: // TW
				if ((rD[4] && $signed(a) < $signed(b)) || (rD[3] && $signed(a) > $signed(b)) || (rD[2] && a == b) ||
					(rD[1] && a < b) || (rD[0] && a > b))
					raise(EX_PROGRAM, 32'h20000);
			10'h10a, 10'h30a, 10'h00a, 10'h20a, 10'h08a, 10'h28a, 10'h0ca, 10'h2ca, 10'h0ea, 10'h2ea:
			begin
				// ADD, ADDC, ADDE, ADDZE, ADDME
				logic [31:0] bb;
				logic cin, wca;
				bb = xo[7:0] == 8'h0a || xo[7:0] == 8'h8a ? b : xo[7:0] == 8'hca ? 32'h0 : 32'hffffffff;
				cin = xo[7:0] == 8'h0a ? 1'b0 : xo[7:0] == 8'h8a || xo[7:0] == 8'hca || xo[7:0] == 8'hea ? xer[29] : 1'b0;
				if (xo[8:0] == 9'h10a) cin = 1'b0;
				s33 = {1'b0, a} + {1'b0, bb} + {32'h0, cin};
				res = s33[31:0];
				wca = xo[8:0] != 9'h10a;
				if (wca) xer[29] <= s33[32];
				if (oe) begin xer[30] <= (~(a[31] ^ bb[31])) & (a[31] ^ res[31]); if ((~(a[31] ^ bb[31])) & (a[31] ^ res[31])) xerso <= 1'b1; end
				gpr[rD] <= res;
				if (rc) crf[0] <= {res[31], !res[31] && res != 0, res == 0, xerso | (oe & (~(a[31] ^ bb[31])) & (a[31] ^ res[31]))};
			end
			10'h028, 10'h228, 10'h008, 10'h208, 10'h088, 10'h288, 10'h0c8, 10'h2c8, 10'h0e8, 10'h2e8:
			begin
				// SUBF, SUBFC, SUBFE, SUBFZE, SUBFME: ~a + b + cin
				logic [31:0] bb;
				logic cin, ov;
				bb = xo[7:0] == 8'h28 || xo[7:0] == 8'h08 || xo[7:0] == 8'h88 ? b : xo[7:0] == 8'hc8 ? 32'h0 : 32'hffffffff;
				cin = xo[7:0] == 8'h28 || xo[7:0] == 8'h08 ? 1'b1 : xer[29];
				s33 = {1'b0, ~a} + {1'b0, bb} + {32'h0, cin};
				res = s33[31:0];
				ov = (~(~a[31] ^ bb[31])) & (~a[31] ^ res[31]);
				if (xo[7:0] != 8'h28) xer[29] <= s33[32];
				if (oe) begin xer[30] <= ov; if (ov) xerso <= 1'b1; end
				gpr[rD] <= res;
				if (rc) crf[0] <= {res[31], !res[31] && res != 0, res == 0, xerso | (oe & ov)};
			end
			10'h068, 10'h268:                                                                      // NEG
			begin
				res = -a;
				if (oe) begin xer[30] <= a == 32'h80000000; if (a == 32'h80000000) xerso <= 1'b1; end
				gpr[rD] <= res;
				if (rc) crf[0] <= {res[31], !res[31] && res != 0, res == 0, xerso | (oe & (a == 32'h80000000))};
			end
			10'h000: crf[op[25:23]] <= cmp4($signed(a) < $signed(b), $signed(a) > $signed(b), xerso);  // CMP
			10'h020: crf[op[25:23]] <= cmp4(a < b, a > b, xerso);                                  // CMPL
			10'h00b: begin res = mulhwu; gpr[rD] <= res; if (rc) set_cr0(res); end           // MULHWU
			10'h04b: begin res = mulw[63:32]; gpr[rD] <= res; if (rc) set_cr0(res); end            // MULHW
			10'h0eb, 10'h2eb:                                                                      // MULLW
			begin
				logic ov;
				res = mulw[31:0];
				ov = mulw[63:32] != {32{mulw[31]}};
				if (oe) begin xer[30] <= ov; if (ov) xerso <= 1'b1; end
				gpr[rD] <= res;
				if (rc) crf[0] <= {res[31], !res[31] && res != 0, res == 0, xerso | (oe & ov)};
			end
			10'h1cb, 10'h3cb, 10'h1eb, 10'h3eb:                                                    // DIVWU, DIVW
			begin
				logic sgn;
				sgn = xo[5];
				if (b == 0 || (sgn && b == 32'hffffffff && a == 32'h80000000))
				begin
					gpr[rD] <= 32'h0;
					if (oe) begin xerso <= 1'b1; xer[30] <= 1'b1; end
					if (rc) crf[0] <= {3'b001, xerso | oe};
				end
				else
				begin
					dv_neg_q <= sgn && (a[31] ^ b[31]);
					dv_q <= sgn && a[31] ? -a : a;
					dv_d <= sgn && b[31] ? -b : b;
					dv_r <= 32'h0;
					dv_n <= 6'd32;
					dv_oe <= oe;
					dv_rc <= rc;
					state <= S_DIV;
					pc <= pc;
				end
			end
			10'h01c: begin res = s & b; gpr[rA] <= res; if (rc) set_cr0(res); end                  // AND
			10'h03c: begin res = s & ~b; gpr[rA] <= res; if (rc) set_cr0(res); end                 // ANDC
			10'h1dc: begin res = ~(s & b); gpr[rA] <= res; if (rc) set_cr0(res); end               // NAND
			10'h1bc: begin res = s | b; gpr[rA] <= res; if (rc) set_cr0(res); end                  // OR
			10'h19c: begin res = s | ~b; gpr[rA] <= res; if (rc) set_cr0(res); end                 // ORC
			10'h07c: begin res = ~(s | b); gpr[rA] <= res; if (rc) set_cr0(res); end               // NOR
			10'h13c: begin res = s ^ b; gpr[rA] <= res; if (rc) set_cr0(res); end                  // XOR
			10'h11c: begin res = ~(s ^ b); gpr[rA] <= res; if (rc) set_cr0(res); end               // EQV
			10'h018: begin n = b[5:0]; res = n > 31 ? 32'h0 : s << n[4:0]; gpr[rA] <= res; if (rc) set_cr0(res); end // SLW
			10'h218: begin n = b[5:0]; res = n > 31 ? 32'h0 : s >> n[4:0]; gpr[rA] <= res; if (rc) set_cr0(res); end // SRW
			10'h318:                                                                               // SRAW
			begin
				n = b[5:0];
				if (n >= 32)
				begin
					res = {32{s[31]}};
					xer[29] <= s[31];
				end
				else
				begin
					res = $signed(s) >>> n[4:0];
					xer[29] <= s[31] && (s & ~(32'hffffffff << n[4:0])) != 0;
				end
				gpr[rA] <= res;
				if (rc) set_cr0(res);
			end
			10'h338:                                                                               // SRAWI
			begin
				res = $signed(s) >>> op[15:11];
				xer[29] <= s[31] && (s & ~(32'hffffffff << op[15:11])) != 0;
				gpr[rA] <= res;
				if (rc) set_cr0(res);
			end
			10'h01a: begin res = clz32(s); gpr[rA] <= res; if (rc) set_cr0(res); end               // CNTLZW
			10'h3ba: begin res = {{24{s[7]}}, s[7:0]}; gpr[rA] <= res; if (rc) set_cr0(res); end   // EXTSB
			10'h39a: begin res = {{16{s[15]}}, s[15:0]}; gpr[rA] <= res; if (rc) set_cr0(res); end // EXTSH

			// indexed loads and stores
			10'h057: mem_start(M_LOAD, raz + b, 4'd1, rD, 1'b0, 1'b0, 1'b0, 1'b0);                // LBZX
			10'h117: mem_start(M_LOAD, raz + b, 4'd2, rD, 1'b0, 1'b0, 1'b0, 1'b0);                // LHZX
			10'h157: mem_start(M_LOAD, raz + b, 4'd2, rD, 1'b0, 1'b1, 1'b0, 1'b0);                // LHAX
			10'h017: mem_start(M_LOAD, raz + b, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0);                // LWZX
			10'h217: mem_start(M_LFS, raz + b, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0);                 // LFSX
			10'h257: mem_start(M_LOAD, raz + b, 4'd8, rD, 1'b0, 1'b0, 1'b0, 1'b1);                // LFDX
			10'h316: mem_start(M_LOAD, raz + b, 4'd2, rD, 1'b0, 1'b0, 1'b1, 1'b0);                // LHBRX
			10'h216: mem_start(M_LOAD, raz + b, 4'd4, rD, 1'b0, 1'b0, 1'b1, 1'b0);                // LWBRX
			10'h077: mem_start(M_LOAD, a + b, 4'd1, rD, 1'b1, 1'b0, 1'b0, 1'b0);                  // LBZUX
			10'h137: mem_start(M_LOAD, a + b, 4'd2, rD, 1'b1, 1'b0, 1'b0, 1'b0);                  // LHZUX
			10'h177: mem_start(M_LOAD, a + b, 4'd2, rD, 1'b1, 1'b1, 1'b0, 1'b0);                  // LHAUX
			10'h037: mem_start(M_LOAD, a + b, 4'd4, rD, 1'b1, 1'b0, 1'b0, 1'b0);                  // LWZUX
			10'h237: mem_start(M_LFS, a + b, 4'd4, rD, 1'b1, 1'b0, 1'b0, 1'b0);                   // LFSUX
			10'h277: mem_start(M_LOAD, a + b, 4'd8, rD, 1'b1, 1'b0, 1'b0, 1'b1);                  // LFDUX
			10'h014: begin mem_start(M_LOAD, raz + b, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0); m_resv <= 1'b1; end   // LWARX
			10'h255, 10'h215:                                                                      // LSWI, LSWX
			begin
				logic [6:0] cnt;
				cnt = xo == 10'h255 ? {2'b0, rB == 0 ? 5'd0 : rB} : xer[6:0];
				if (xo == 10'h255 && rB == 0) cnt = 7'd32;
				m_count <= cnt;
				m_reg <= rD;
				m_byte <= 2'd0;
				mem_start(M_LSW, xo == 10'h255 ? raz : raz + b, 4'd1, rD, 1'b0, 1'b0, 1'b0, 1'b0);
				if (cnt == 0) state <= S_DONE;
			end
			10'h0d7: begin m_wdata <= {56'h0, s[7:0]}; mem_start(M_STORE, raz + b, 4'd1, rD, 1'b0, 1'b0, 1'b0, 1'b0); end   // STBX
			10'h197: begin m_wdata <= {48'h0, s[15:0]}; mem_start(M_STORE, raz + b, 4'd2, rD, 1'b0, 1'b0, 1'b0, 1'b0); end  // STHX
			10'h097: begin m_wdata <= {32'h0, s}; mem_start(M_STORE, raz + b, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0); end        // STWX
			10'h297: stfs_start(raz + b, 1'b0);                                                    // STFSX
			10'h3d7: begin m_wdata <= {32'h0, fpr[rD][31:0]}; mem_start(M_STORE, raz + b, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0); end // STFIWX
			10'h2d7: begin m_wdata <= fpr[rD]; mem_start(M_STORE, raz + b, 4'd8, rD, 1'b0, 1'b0, 1'b0, 1'b1); end          // STFDX
			10'h396: begin m_wdata <= {48'h0, s[7:0], s[15:8]}; mem_start(M_STORE, raz + b, 4'd2, rD, 1'b0, 1'b0, 1'b0, 1'b0); end // STHBRX
			10'h296: begin m_wdata <= {32'h0, s[7:0], s[15:8], s[23:16], s[31:24]}; mem_start(M_STORE, raz + b, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0); end // STWBRX
			10'h0f7: begin m_wdata <= {56'h0, s[7:0]}; mem_start(M_STORE, a + b, 4'd1, rD, 1'b1, 1'b0, 1'b0, 1'b0); end     // STBUX
			10'h1b7: begin m_wdata <= {48'h0, s[15:0]}; mem_start(M_STORE, a + b, 4'd2, rD, 1'b1, 1'b0, 1'b0, 1'b0); end    // STHUX
			10'h0b7: begin m_wdata <= {32'h0, s}; mem_start(M_STORE, a + b, 4'd4, rD, 1'b1, 1'b0, 1'b0, 1'b0); end          // STWUX
			10'h2b7: stfs_start(a + b, 1'b1);                                                      // STFSUX
			10'h2f7: begin m_wdata <= fpr[rD]; mem_start(M_STORE, a + b, 4'd8, rD, 1'b1, 1'b0, 1'b0, 1'b1); end             // STFDUX
			10'h096:                                                                               // STWCX.
			begin
				m_wdata <= {32'h0, s};
				// the reservation goes when the store is made (a fault keeps it)
				if (reserved) mem_start(M_STWCX, raz + b, 4'd4, rD, 1'b0, 1'b0, 1'b0, 1'b0);
				else crf[0] <= {3'b000, xerso};
			end
			10'h2d5, 10'h295:                                                                      // STSWI, STSWX
			begin
				logic [6:0] cnt;
				cnt = xo == 10'h2d5 ? {2'b0, rB} : xer[6:0];
				if (xo == 10'h2d5 && rB == 0) cnt = 7'd32;
				m_count <= cnt;
				m_reg <= rD;
				m_byte <= 2'd0;
				m_wdata <= {56'h0, gpr[rD][31:24]};
				mem_start(M_STSW, xo == 10'h2d5 ? raz : raz + b, 4'd1, rD, 1'b0, 1'b0, 1'b0, 1'b0);
				if (cnt == 0) state <= S_DONE;
			end
			// cache, TLB, sync: nothing in MAME
			10'h036, 10'h056, 10'h0f6, 10'h116, 10'h256, 10'h356, 10'h1d6, 10'h236, 10'h3d6, 10'h132, 10'h172,
			10'h3d2, 10'h3f2: ;
			10'h3f6:                                                                               // DCBZ
			begin
				m_count <= 7'd4;
				m_wdata <= 64'h0;
				mem_start(M_DCBZ, (raz + b) & ~32'd31, 4'd8, rD, 1'b0, 1'b0, 1'b0, 1'b0);
			end
			// moves
			10'h013: gpr[rD] <= get_cr();                                                          // MFCR
			10'h053: gpr[rD] <= msr;                                                               // MFMSR
			10'h153:                                                                               // MFSPR
			begin
				gpr[rD] <= mfspr_v(sprn);
				timer_read <= sprn == 10'd22 || sprn == 10'd268 || sprn == 10'd269;
			end
			10'h253: gpr[rD] <= sr[op[19:16]];                                                     // MFSR
			10'h293: gpr[rD] <= sr[b[31:28]];                                                      // MFSRIN
			10'h173:                                                                               // MFTB
				if (sprn == 10'd268 || sprn == 10'd269) begin gpr[rD] <= mfspr_v(sprn); timer_read <= 1'b1; end
				else raise(EX_PROGRAM, 32'h80000);
			10'h090:                                                                               // MTCRF
				for (int i = 0; i < 8; i++)
					if (op[19 - i]) crf[i] <= s[31 - 4 * i -: 4];
			10'h092:                                                                               // MTMSR
			begin
				msr <= s;
				if (msr[17] != s[17]) swap_tgpr();
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

	function automatic logic [31:0] clz32(input logic [31:0] x);
		for (int i = 31; i >= 0; i--)
			if (x[i]) return 32'(31 - i);
		return 32'd32;
	endfunction

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

	// ---- floating point -----------------------------------------------------------------------------------------------
	task automatic fpu_go(input logic [4:0] fop);
		fpu_op <= fop;
		fpu_a <= fpr[rA];
		fpu_b <= fpr[rB];
		fpu_c <= fpr[frC];
		fpu_start <= 1'b1;
		f_rd <= rD;
		f_rc <= rc;
		f_cmp <= 1'b0;
		state <= S_FPU;
		pc <= pc;
	endtask

	task automatic op3b();
		case (op[5:1])
			5'h15: fpu_go(F_ADDS);
			5'h14: fpu_go(F_SUBS);
			5'h19: fpu_go(F_MULS);
			5'h12: fpu_go(F_DIVS);
			5'h16: fpu_go(F_SQRTS);
			5'h18: fpu_go(F_RES);
			5'h1d: fpu_go(F_MADDS);
			5'h1c: fpu_go(F_MSUBS);
			5'h1f: fpu_go(F_NMADDS);
			5'h1e: fpu_go(F_NMSUBS);
			default: raise(EX_PROGRAM, 32'h80000);
		endcase
	endtask

	task automatic op3f();
		logic [63:0] fb;
		fb = fpr[rB];
		if (xo[4])
			case (op[5:1])
				5'h15: fpu_go(F_ADD);
				5'h14: fpu_go(F_SUB);
				5'h19: fpu_go(F_MUL);
				5'h12: fpu_go(F_DIV);
				5'h16: fpu_go(F_SQRT);
				5'h1a: fpu_go(F_RSQRTE);
				// FSEL: c if a >= 0.0 (not NaN, and positive or a zero), else b; no CR1 even with Rc (MAME)
				5'h17: fpr[rD] <= !(fpr[rA][62:52] == 11'h7ff && fpr[rA][51:0] != 0) && (!fpr[rA][63] || fpr[rA][62:0] == 0)
					? fpr[frC] : fb;
				5'h1d: fpu_go(F_MADD);
				5'h1c: fpu_go(F_MSUB);
				5'h1f: fpu_go(F_NMADD);
				5'h1e: fpu_go(F_NMSUB);
				default: raise(EX_PROGRAM, 32'h80000);
			endcase
		else
			case (xo)
				10'h000, 10'h020:                                                                  // FCMPU, FCMPO
				begin
					fpu_go(F_CMP);
					f_cmp <= 1'b1;
					f_crfd <= op[25:23];
					f_rc <= 1'b0;
				end
				10'h00c: fpu_go(F_RSP);
				// these leave CR1 alone even with Rc (MAME)
				10'h00e: begin fpu_go(F_CTIW); f_rc <= 1'b0; end
				10'h00f: begin fpu_go(F_CTIWZ); f_rc <= 1'b0; end
				10'h028: fpr[rD] <= fb ^ 64'h8000000000000000;                                     // FNEG
				10'h048: fpr[rD] <= fb;                                                            // FMR
				10'h088: fpr[rD] <= fb | 64'h8000000000000000;                                     // FNABS
				10'h108: fpr[rD] <= fb & ~64'h8000000000000000;                                    // FABS
				// the rounding mode the float unit uses (fmode) follows FPSCR[RN] only through these, as MAME's host mode
				// does (mcrfs clearing RN leaves it)
				10'h046: begin fpscr[31 - rD] <= 1'b0; if (rD == 5'd30) fmode <= {1'b0, fpscr[0]}; if (rD == 5'd31) fmode <= {fpscr[1], 1'b0}; end // MTFSB0
				10'h026: begin fpscr[31 - rD] <= 1'b1; if (rD == 5'd30) fmode <= {1'b1, fpscr[0]}; if (rD == 5'd31) fmode <= {fpscr[1], 1'b1}; end // MTFSB1
				10'h040:                                                                           // MCRFS
				begin
					crf[op[25:23]] <= fpscr[31 - 4 * op[20:18] -: 4];
					fpscr <= fpscr & ~crmask(op[20:18]);
				end
				10'h247: fpr[rD][31:0] <= fpscr;                                                   // MFFS (MAME: the low word)
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

	// ---- memory -------------------------------------------------------------------------------------------------------
	// One access at a time: translate (fault -> exception, nothing changed), then the bus; then the next item or done.
	task automatic mem_step();
		logic wr;
		wr = m_wr;
		if (!m_active)
		begin
			// lsw clears each register before its first byte is read (MAME), even when the read faults
			if (mkind == M_LSW && m_byte == 2'd0) gpr[m_reg] <= 32'h0;
			if (!data_tr.ok)
			begin
				logic [23:0] seg;
				logic [31:0] hashbase, hashmask, hash;
				if (data_tr.prot)
				begin
					sprv[X_DSISR] <= 32'h08000000 | (wr ? 32'h02000000 : 32'h0);
					raise(EX_DSI, m_ea);
				end
				else
				begin
					seg = sr[m_ea[31:28]][23:0];
					hashbase = sprv[X_SDR1] & 32'hffff0000;
					hashmask = {7'h0, sprv[X_SDR1][8:0], 16'hffff};
					hash = {13'h0, seg[18:0]} ^ {16'h0, m_ea[27:12]};
					sprv[X_DMISS] <= m_ea;
					sprv[X_DCMP] <= 32'h80000000 | {1'b0, seg[23:0], 7'h0} | {26'h0, m_ea[27:22]};
					sprv[X_HASH1] <= hashbase | ((hash << 6) & hashmask);
					sprv[X_HASH2] <= hashbase | ((~hash << 6) & hashmask);
					raise(wr ? EX_DTLBMISSS : EX_DTLBMISSL, m_ea);
				end
			end
			else
			begin
				bus_req <= 1'b1;
				bus_we <= wr;
				bus_addr <= data_tr.pa;
				bus_size <= m_size;
				bus_wdata <= m_bswap ? bswapn(m_wdata[31:0], m_size) : m_wdata;
				m_active <= 1'b1;
			end
		end
		else if (bus_ack)
		begin
			logic [63:0] d;
			bus_req <= 1'b0;
			bus_we <= 1'b0;
			m_active <= 1'b0;
			d = m_bswap ? bswapn(bus_rdata[31:0], m_size) : bus_rdata;
			case (mkind)
				M_LOAD:
				begin
					if (m_fpd) fpr[m_rd] <= d;
					else if (m_sext) gpr[m_rd] <= {{16{d[15]}}, d[15:0]};
					else gpr[m_rd] <= d[31:0];
					if (m_resv) reserved <= 1'b1;
					mem_finish();
				end
				M_LFS:
				begin
					// single to double in the float unit
					fpu_op <= F_S2D;
					fpu_a <= {32'h0, d[31:0]};
					fpu_start <= 1'b1;
					f_rd <= m_rd;
					f_rc <= 1'b0;
					f_cmp <= 1'b0;
					if (m_upd) gpr[m_ra] <= m_upd_ea;
					state <= S_FPU;
				end
				M_STORE: mem_finish();
				M_STWCX: begin crf[0] <= {3'b001, xerso}; reserved <= 1'b0; mem_finish(); end
				M_LMW:
				begin
					if (m_reg != m_ra) gpr[m_reg] <= d[31:0];
					next_item(m_reg == 5'd31, 32'd4);
					m_reg <= m_reg + 5'd1;
				end
				M_STMW:
				begin
					m_wdata <= {32'h0, gpr[m_reg + 5'd1]};
					next_item(m_reg == 5'd31, 32'd4);
					m_reg <= m_reg + 5'd1;
				end
				M_LSW:
				begin
					logic [31:0] v;
					v = m_byte == 0 ? 32'h0 : gpr[m_reg];
					v[31 - 8 * m_byte -: 8] = d[7:0];
					gpr[m_reg] <= v;
					m_byte <= m_byte + 2'd1;
					if (m_byte == 2'd3) m_reg <= m_reg + 5'd1;
					next_item(m_count == 7'd1, 32'd1);
					m_count <= m_count - 7'd1;
				end
				M_STSW:
				begin
					logic [4:0] reg_n;
					logic [1:0] byte_n;
					byte_n = m_byte + 2'd1;
					reg_n = m_byte == 2'd3 ? m_reg + 5'd1 : m_reg;
					m_wdata <= {56'h0, gpr[reg_n][31 - 8 * byte_n -: 8]};
					m_byte <= byte_n;
					m_reg <= reg_n;
					next_item(m_count == 7'd1, 32'd1);
					m_count <= m_count - 7'd1;
				end
				M_DCBZ:
				begin
					next_item(m_count == 7'd1, 32'd8);
					m_count <= m_count - 7'd1;
				end
				default: mem_finish();
			endcase
		end
	endtask

	task automatic next_item(input logic last, input logic [31:0] step);
		if (last) mem_finish();
		else m_ea <= m_ea + step;
	endtask

	task automatic mem_finish();
		if (m_upd) gpr[m_ra] <= m_upd_ea;
		pc <= npc;
		state <= S_DONE;
	endtask
endmodule
