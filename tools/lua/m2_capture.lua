-- m2_capture.lua: Konami M2 (konamim2.cpp) feature and trace capture for MAME
--
-- Watches both PPC602s' accesses to the BDA through debugger watchpoints, keeps a copy of the triangle engine's
-- registers, and walks every TE command list the way m2_te_device::execute() does (at the end of the frame its start was
-- written in: see "CPU-side watchpoints" below). Writes, under M2CAP_OUT:
--
--   frames.csv     a line a frame: lists, triangles, estimated pixels, texture loads, BDA traffic by unit
--   features.txt   every TE render state seen, with its triangle and pixel counts; registers and values written
--   events.log     list starts and ends (frame, scanline, CPU, addresses), texture loads, VDU writes, oddities
--   te_lists.bin   with M2CAP_DUMP=1: each list's words as fetched, for the TE testbench
--   texloads.bin   with M2CAP_DUMP=1: each texture load's registers and source bytes
--   trace/         with M2CAP_TRACE: a debugger trace of each CPU for each frame
--
-- Settings (environment variables):
--   M2CAP_OUT        output directory (default m2cap; must not contain spaces)
--   M2CAP_FRAMES     exit after this many frames (default 0: run until MAME is closed)
--   M2CAP_DUMP       1: write te_lists.bin and texloads.bin (default 0)
--   M2CAP_SNAP       save a snapshot every N frames (default 0: never)
--   M2CAP_TRACE      frames at which to start a CPU trace, e.g. "600,1800,3600"
--   M2CAP_TRACE_LEN  frames each trace runs for (default 2; about 45 MB a CPU a frame)
--
-- Run (the debugger is needed: -debug -debugger none; ui.ini's skip_warnings 1 gets past the warning screen):
--   mame polystar -window -nothrottle -debug -debugger none -autoboot_script tools/lua/m2_capture.lua
--
-- Written against MAME 0.289's konamim2.cpp, 3dom2.cpp and 3dom2_te.cpp.

local OUT       = os.getenv("M2CAP_OUT") or "m2cap"
local MAXF      = tonumber(os.getenv("M2CAP_FRAMES") or "0") or 0
local DUMP      = (os.getenv("M2CAP_DUMP") or "0") == "1"
local SNAP      = tonumber(os.getenv("M2CAP_SNAP") or "0") or 0
local TRACE_AT  = os.getenv("M2CAP_TRACE") or ""
local TRACE_LEN = tonumber(os.getenv("M2CAP_TRACE_LEN") or "2") or 2

local SEP = package.config:sub(1, 1)

local function mkdir(path)
	if SEP == "\\" then
		os.execute('if not exist "' .. path .. '" mkdir "' .. path:gsub("/", "\\") .. '"')
	else
		os.execute('mkdir -p "' .. path .. '"')
	end
end

---------------------------------------------------------------------------------------------------------------------
-- BDA map (3dom2.h): device bases as the CPUs see them
---------------------------------------------------------------------------------------------------------------------

local BDA_UNITS = {
	{ name = "powerbus", base = 0x00010000, size = 0x10000 },
	{ name = "memctl",   base = 0x00020000, size = 0x10000 },
	{ name = "vdu",      base = 0x00030000, size = 0x10000 },
	{ name = "te",       base = 0x00040000, size = 0x10000 },
	{ name = "dsp",      base = 0x00060000, size = 0x10000 },
	{ name = "ctrlport", base = 0x00070000, size = 0x10000 },
	{ name = "mpeg",     base = 0x00080000, size = 0x10000 },
	{ name = "tram",     base = 0x000c0000, size = 0x04000 },
	{ name = "cde",      base = 0x04000000, size = 0x1000000 },
	{ name = "cpuid",    base = 0x10000000, size = 0x10000 },
	{ name = "ata",      base = 0x3f000000, size = 0x1000000 },
}

local RAM_BASE = 0x40000000
local RAM_END  = 0x40ffffff      -- 16 MB window; Polystars has 2 x 4 MB

---------------------------------------------------------------------------------------------------------------------
-- TE register names (3dom2_te.h structs; unit 3 registers start at 0x400 / 4, below that is PIP RAM)
---------------------------------------------------------------------------------------------------------------------

local TE_NAMES = {
	[0] = { "TEMasterMode", "Reserved", "TEICntlData", "TEICntl", "TEDCntlData", "TEDCntl", "IWP", "IRP", "IntEn",
	        "IntStat", "VertexCtrl" },
	[2] = { "ESCntl", "ESCapAddr", "ESCapData" },
	[3] = { "TexCntl", "TexLdCntl", "TexAddrCntl", "TexPIPCntl", "TexTabCntl", "TexLODBase0", "TexLODBase1",
	        "TexLODBase2", "TexLODBase3", "TexLdSrcBase", "TexByteCnt", "UVMax", "UVMask", "TexSrcType01",
	        "TexSrcType23", "TexExpType", "TexSrcConst0", "TexSrcConst1", "TexSrcConst2", "TexSrcConst3", "TexSrcExp" },
	[4] = { "Snoop", "SuperGenCtrl", "UserGenCtrl", "DiscardCtrl", "Status", "IntCtrl", "FBClip", "XWinClip",
	        "YWinClip", "DstCtrl", "DstBaseAddr", "DstXStride", "SrcCtrl", "SrcBaseAddr", "SrcXStride", "SrcOffset",
	        "ZCtrl", "ZBaseAddr", "ZOffset", "ZClip", "SSBDSBCtrl", "ConstIn", "TxtMultCntl", "TxtCoefConst0",
	        "TxtCoefConst1", "SrcMultCntl", "SrcCoefConst0", "SrcCoefConst1", "ALUCtrl", "SrcAlphaCtrl",
	        "DstAlphaCtrl", "DstAlphaConst", "DitherMatA", "DitherMatB" },
}

local function te_reg_name(unit, reg)
	if unit == 1 then
		return string.format("SE:%02x", reg)
	elseif unit == 3 then
		if reg < 0x100 then
			return "PIPRAM"
		end
		local n = TE_NAMES[3][reg - 0x100 + 1]
		return "TM:" .. (n or string.format("%03x", reg))
	end
	local t = TE_NAMES[unit]
	local n = t and t[reg + 1]
	return ({ [0] = "GC:", [2] = "ES:", [4] = "DB:" })[unit] .. (n or string.format("%03x", reg))
end

-- The render state a triangle is drawn with: the registers whose values define which TE features it uses
local STATE_REGS = {
	{ 0, 0x000, "TEMasterMode" },
	{ 3, 0x100, "TexCntl" },       { 3, 0x102, "TexAddrCntl" }, { 3, 0x103, "TexPIPCntl" },
	{ 3, 0x104, "TexTabCntl" },    { 3, 0x10f, "TexExpType" },
	{ 4, 0x001, "SuperGenCtrl" },  { 4, 0x002, "UserGenCtrl" }, { 4, 0x003, "DiscardCtrl" },
	{ 4, 0x009, "DstCtrl" },       { 4, 0x00c, "SrcCtrl" },     { 4, 0x010, "ZCtrl" },
	{ 4, 0x014, "SSBDSBCtrl" },    { 4, 0x016, "TxtMultCntl" }, { 4, 0x019, "SrcMultCntl" },
	{ 4, 0x01c, "ALUCtrl" },       { 4, 0x01d, "SrcAlphaCtrl" },{ 4, 0x01e, "DstAlphaCtrl" },
}

---------------------------------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------------------------------

local te = { [0] = {}, [1] = {}, [2] = {}, [3] = {}, [4] = {} }
local te_run = "stopped"           -- stopped, paused, running
local te_depth = 0

local frame = 0
local fs = {}                       -- this frame's counters
local states = {}                   -- render state key -> { tris, pixels, verts, frames }
local regvals = {}                  -- "name" -> { [value] = count }
local oddities = {}
local vtx = { {}, {}, {} }          -- the setup engine's three vertex slots (x, y)
local vcnt, tsort = 0, "OMN"

local f_frames, f_events, f_lists, f_tex
local space1, space2, screen

local cpu_tags = {}
local trace_starts = {}
local trace_active = false
local trace_end = 0

local function reset_frame_stats()
	fs = { lists = 0, list_words = 0, vtx = 0, tris = 0, pixels = 0.0, texloads = 0, texload_bytes = 0, te_w = 0, vdu_w = 0, cnt = {},
	       listend = 0, unit = {} }
end

local function ev(fmt, ...)
	if f_events then
		f_events:write(string.format("%6d ", frame), string.format(fmt, ...), "\n")
	end
end

local function odd(what)
	if not oddities[what] then
		ev("ODD %s (first seen)", what)
	end
	oddities[what] = (oddities[what] or 0) + 1
end

local function note_value(name, v)
	local t = regvals[name]
	if not t then
		t = {}
		regvals[name] = t
	end
	t[v] = (t[v] or 0) + 1
end

local function te_get(unit, reg)
	return te[unit][reg] or 0
end

local function te_wr(unit, reg, v, mode)
	if mode == 0 then
		te[unit][reg] = v
	elseif mode == 2 then
		te[unit][reg] = te_get(unit, reg) | v
	elseif mode == 3 then
		te[unit][reg] = te_get(unit, reg) & ~v & 0xffffffff
	end
end

local function f32(bits)
	return string.unpack(">f", string.pack(">I4", bits))
end

local function scanline()
	return screen and screen:vpos() or -1
end

---------------------------------------------------------------------------------------------------------------------
-- The setup engine's vertex slots, as add_vertex() replaces them: what the counted triangle covers
---------------------------------------------------------------------------------------------------------------------

local FAN = { OMN = { 2, "ONM" }, MNO = { 1, "NMO" }, ONM = { 3, "OMN" }, NOM = { 3, "MON" }, MON = { 1, "NOM" },
              NMO = { 2, "MNO" } }
local STRIP = { OMN = { 1, "NOM" }, MNO = { 3, "OMN" }, ONM = { 1, "NMO" }, NOM = { 2, "MNO" }, MON = { 2, "ONM" },
                NMO = { 3, "MON" } }

local function state_key()
	local parts = {}
	for i, r in ipairs(STATE_REGS) do
		parts[i] = string.format("%08x", te_get(r[1], r[2]))
	end
	return table.concat(parts, " ")
end

local function add_vertex(x, y, flags, key)
	if flags & 0x00080000 ~= 0 then
		vcnt, tsort = 0, "OMN"
	end
	if vcnt < 3 then
		vcnt = vcnt + 1
		vtx[vcnt] = { x, y }
		if vcnt < 3 then
			return
		end
		tsort = "OMN"
	else
		local t = (flags & 0x00100000 ~= 0) and FAN[tsort] or STRIP[tsort]
		vtx[t[1]] = { x, y }
		tsort = t[2]
	end
	local a = vtx[1]
	local b = vtx[2]
	local c = vtx[3]
	local area = math.abs((b[1] - a[1]) * (c[2] - a[2]) - (c[1] - a[1]) * (b[2] - a[2])) * 0.5
	if area ~= area or area > 1.0e7 then         -- NaN or off-screen garbage
		odd("triangle with bad coordinates")
		area = 0
	end
	fs.tris = fs.tris + 1
	fs.pixels = fs.pixels + area
	local s = states[key]
	s.tris = s.tris + 1
	s.pixels = s.pixels + area
	if s.last_frame ~= frame then
		s.frames = s.frames + 1
		s.last_frame = frame
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Triangle engine: m2_te_device::write(), teicntl_w(), tedcntl_w(), execute()
---------------------------------------------------------------------------------------------------------------------

local te_write, execute

local function load_texture(space)
	local cntl = te_get(3, 0x101)
	local src = te_get(3, 0x109)
	local cnt = te_get(3, 0x10a)
	local dst = te_get(3, 0x105)
	local mode = (cntl >> 8) & 3
	local comp = (cntl & 0x400) ~= 0
	fs.texloads = fs.texloads + 1
	note_value("TexLoad mode", mode)
	note_value("TexLoad compressed", comp and 1 or 0)
	note_value("TexLoad TexExpType", te_get(3, 0x10f))
	note_value("TexLoad TexSrcType01", te_get(3, 0x10d))
	note_value("TexLoad TexSrcType23", te_get(3, 0x10e))
	ev("TEXLOAD mode=%d comp=%d src=%08x dst=%08x cnt=%08x exptype=%08x", mode, comp and 1 or 0, src, dst, cnt,
		te_get(3, 0x10f))
	-- The byte count is texels when compressed and rows / textures in the other modes: dump a bounded window
	local nbytes = math.min(cnt, 0x10000)
	if comp then
		nbytes = math.min(cnt * 4 + 16, 0x10000)
	end
	fs.texload_bytes = fs.texload_bytes + nbytes
	if DUMP and f_tex then
		local regs = {}
		for r = 0x100, 0x114 do
			regs[#regs + 1] = string.pack(">I4", te_get(3, r))
		end
		f_tex:write(string.pack(">I4I4I4", 0x544c4430, frame, nbytes), table.concat(regs))
		local bytes = {}
		for i = 0, nbytes - 1 do
			local a = src + i
			bytes[#bytes + 1] = string.char((a >= RAM_BASE and a <= RAM_END) and space:read_u8(a) or 0)
		end
		f_tex:write(table.concat(bytes))
	end
end

local function teicntl_w(data, mode, ctx)
	local newreg = 0
	if mode == 0 or mode == 2 then
		newreg = data
	end
	te_wr(0, 0, data, mode)                  -- as MAME: TEICntl also writes the master mode
	if newreg & 0x20 ~= 0 then
		te[0][7] = te_get(0, 2)
		execute(ctx, "STRT")
	elseif newreg & 0x10 ~= 0 then
		execute(ctx, "RSTRT")
	end
end

local function tedcntl_w(data, mode, ctx)
	te_wr(0, 5, data, mode)
	local v = te_get(0, 5)
	if v & 0x20 ~= 0 then
		note_value("TEDCntl SYNC", 1)
	elseif v & 0x10 ~= 0 then
		te_run = "paused"
		note_value("TEDCntl PSE", 1)
	elseif v & 0x08 ~= 0 then
		note_value("TEDCntl INT", 1)
	elseif v & 0x04 ~= 0 then
		te[0][7] = (te_get(0, 7) + te_get(0, 4)) & 0xffffffff
		note_value("TEDCntl JR", 1)
	elseif v & 0x02 ~= 0 then
		te[0][7] = te_get(0, 4)
		note_value("TEDCntl JA", 1)
	elseif v & 0x01 ~= 0 then
		load_texture(ctx.space)
	end
end

te_write = function(woff, data, ctx, from_list)
	local unit = (woff >> 11) & 7
	local reg = woff & 0x1ff
	local mode = (woff >> 9) & 3
	local name = te_reg_name(unit, reg)
	-- (PIP RAM, setup and edge-walker registers: their values are data, so only their writes are counted)
	local plain = unit == 1 or unit == 2 or (unit == 3 and reg < 0x100)
	note_value((from_list and "list " or "cpu  ") .. name, plain and 0 or data)
	if mode == 1 then
		odd("TE write with the invalid write mode")
		return
	end
	if unit == 0 and reg == 0 then
		te_wr(0, 0, data, mode)
		if te_get(0, 0) & 1 ~= 0 then
			te_run = "stopped"
		end
	elseif unit == 0 and reg == 3 then
		teicntl_w(data, mode, ctx)
	elseif unit == 0 and reg == 5 then
		tedcntl_w(data, mode, ctx)
	elseif unit > 4 then
		odd(string.format("TE write to unit %d", unit))
	else
		te_wr(unit, reg, data, mode)
	end
end

local function fetch(ctx, words)
	local a = te_get(0, 7)
	if a < RAM_BASE or a > RAM_END then
		odd(string.format("TE fetch outside RAM (%08x)", a))
		te_run = "stopped"
		return 0
	end
	local v = ctx.space:read_u32(a)
	te[0][7] = (a + 4) & 0xffffffff
	ctx.fetched = (ctx.fetched or 0) + 1
	if words then
		words[#words + 1] = string.pack(">I4I4", a, v)
	end
	return v
end

execute = function(ctx, how)
	te_depth = te_depth + 1
	if te_depth > 4 then
		odd("TE list started from inside a list, nested past 4")
		te_depth = te_depth - 1
		return
	end
	te_run = "running"
	local start = te_get(0, 7)
	local words = DUMP and {} or nil
	local nvtx, ninst = 0, 0
	local fetched0 = ctx.fetched or 0
	local tris0, pix0 = fs.tris, fs.pixels
	ev("LIST %s cpu=%s line=%d irp=%08x iwp=%08x master=%08x inten=%08x", how, ctx.cpu, ctx.line or scanline(), start,
		te_get(0, 6), te_get(0, 0), te_get(0, 8))
	while te_run == "running" do
		ninst = ninst + 1
		if ninst > 4000000 then
			odd("TE list over 4M instructions: stopped walking")
			break
		end
		local inst = fetch(ctx, words)
		local kind = inst & 0xf0000000
		if kind == 0x10000000 then
			local offs = inst & 0xffff
			local cnt = (inst >> 16) & 0xff
			for _ = 0, cnt do
				te_write(offs >> 2, fetch(ctx, words), ctx, true)
				offs = offs + 4
				if te_run ~= "running" then
					break
				end
			end
		elseif kind == 0x20000000 then
			local cnt = inst & 0xffff
			local flags = inst & 0x001f0000
			if (inst >> 24) & 0xf ~= 0 then
				odd("TE short vertex with version != 0")
				te_run = "stopped"
			else
				local shad = flags & 0x00010000 ~= 0
				local text = flags & 0x00020000 ~= 0
				local prsp = flags & 0x00040000 ~= 0
				local key = state_key() .. string.format(" vf=%02x", (flags >> 16) & 0x07)
				if not states[key] then
					states[key] = { tris = 0, pixels = 0.0, verts = 0, frames = 0, last_frame = -1 }
				end
				states[key].verts = states[key].verts + cnt + 1
				note_value("vertex flags (SHAD 1, TEXT 2, PRSP 4, NEW 8, RM 10)", (flags >> 16) & 0x1f)
				for _ = 0, cnt do
					local x = f32(fetch(ctx, words))
					local y = f32(fetch(ctx, words))
					if shad then
						for _ = 1, 4 do fetch(ctx, words) end
					end
					if prsp then
						fetch(ctx, words)
					end
					if text then
						fetch(ctx, words)
						fetch(ctx, words)
					end
					nvtx = nvtx + 1
					add_vertex(x, y, flags, key)
					flags = flags & ~0x00080000
				end
			end
		elseif kind == 0x30000000 then
			odd("TE long vertex format (MAME: unimplemented)")
			te_run = "stopped"
		elseif kind == 0x40000000 then
			odd("TE point format (MAME: unimplemented)")
			te_run = "stopped"
		else
			odd(string.format("TE illegal instruction %08x", inst))
			te_run = "stopped"
		end
		if te_get(0, 7) == te_get(0, 6) then
			te_run = (te_get(0, 0) & 0x04 ~= 0) and "stopped" or "paused"
			fs.listend = fs.listend + 1
		elseif te_get(0, 0) & (0x08 | 0x02) ~= 0 then
			te_run = "stopped"
		end
	end
	local nwords = (ctx.fetched or 0) - fetched0     -- (words fetched: jumps make the address span meaningless)
	fs.lists = fs.lists + 1
	fs.list_words = fs.list_words + nwords
	fs.vtx = fs.vtx + nvtx
	ev("LISTEND %s words=%d inst=%d vtx=%d tris=%d pix=%.0f end=%08x", te_run, nwords, ninst, nvtx,
		fs.tris - tris0, fs.pixels - pix0, te_get(0, 7))
	if DUMP and f_lists and words then
		f_lists:write(string.pack(">I4I4I4I4", 0x54454c30, frame, start, #words), table.concat(words))
	end
	te_depth = te_depth - 1
end


---------------------------------------------------------------------------------------------------------------------
-- CPU-side watchpoints
--
-- MAME's Lua memory taps cannot be used here: on the PPC's 64-bit bus a 32-bit access's mask (and often its data) has bit
-- 63 set, and handing that to Lua throws ("integer value will be misrepresented in lua"). Debugger watchpoints are used
-- instead: the TE's and the VDU's register writes are printed to the debugger console, which is read back at the end of
-- each frame, and the other units' accesses are counted in the debugger's temp0-temp9.
--
-- So a TE command list is walked at the end of the frame its start was written in, not inside that write: a list the game
-- rewrites within the same frame would be read as rewritten (it shows as an illegal instruction or a fetch outside RAM
-- in the oddities). MAME's debugger expressions take numbers in hex.
---------------------------------------------------------------------------------------------------------------------

local COUNTED = {   -- temp number, unit, access
	{ 0, "powerbus", "rw" }, { 1, "memctl", "rw" }, { 2, "dsp", "w" }, { 3, "dsp", "r" }, { 4, "ctrlport", "rw" },
	{ 5, "mpeg", "rw" }, { 6, "tram", "w" }, { 7, "cde", "rw" }, { 8, "ata", "rw" }, { 9, "cpuid", "rw" },
}
local COUNT_COLS = { "powerbus_rw", "memctl_rw", "dsp_w", "dsp_r", "ctrlport_rw", "mpeg_rw", "tram_w", "cde_rw", "ata_rw",
                     "cpuid_rw" }

local dbg
local log_seen_mark = nil       -- the marker line that ended the last frame's share of the console log

local function unit_by_name(name)
	for _, u in ipairs(BDA_UNITS) do
		if u.name == name then
			return u
		end
	end
end

local function set_watchpoints(cpu, n)
	local space = cpu.spaces["program"]
	local te_u = unit_by_name("te")
	local vdu_u = unit_by_name("vdu")
	cpu.debug:wpset(space, "w", te_u.base, te_u.size, "1",
		string.format('printf "M2TE %d %%X %%X %%X %%d",wpaddr,wpdata,wpsize,beamy; g', n))
	cpu.debug:wpset(space, "w", vdu_u.base, vdu_u.size, "1",
		string.format('printf "M2VDU %d %%X %%X",wpaddr,wpdata; g', n))
	for _, c in ipairs(COUNTED) do
		local u = unit_by_name(c[2])
		cpu.debug:wpset(space, c[3], u.base, u.size, "1", string.format("temp%d=temp%d+1; g", c[1], c[1]))
	end
end

-- A 32-bit register write as the debugger reports it: the byte address and the value (a 64-bit store: two registers)
local function te_line(cpu, addr, data, size, line)
	local base = unit_by_name("te").base
	local ctx = { space = space1, cpu = "ppc" .. cpu, line = line }
	fs.te_w = fs.te_w + 1
	if size == 0x40 or size == 8 then
		te_write((addr - base) >> 2, (data >> 32) & 0xffffffff, ctx, false)
		te_write((addr + 4 - base) >> 2, data & 0xffffffff, ctx, false)
	else
		te_write((addr - base) >> 2, data & 0xffffffff, ctx, false)
	end
end

local function vdu_line(cpu, addr, data)
	local r = (addr - unit_by_name("vdu").base) & 0x7ff
	fs.vdu_w = fs.vdu_w + 1
	note_value(string.format("VDU %03x", r & 0x3ff), data & 0xffffffff)
	ev("VDU cpu=ppc%d %03x%s=%08x", cpu, r & 0x3ff, (r & 0x400 ~= 0) and " clear" or "", data & 0xffffffff)
end

-- The console lines since the last frame's marker, then a new marker and the counters
local function read_console()
	dbg:command(string.format('printf "M2CNT %%d %%d %%d %%d %%d %%d %%d %%d %%d %%d",' ..
		'temp0,temp1,temp2,temp3,temp4,temp5,temp6,temp7,temp8,temp9'))
	for i = 0, 9 do
		dbg:command(string.format("temp%d=0", i))
	end
	local mark = string.format("M2MARK %x", frame)
	dbg:command(string.format('printf "%s"', mark))
	local log = dbg.consolelog
	local n = #log
	-- back to the last frame's marker (the console log is a ring: count back, not from a saved index)
	local first = 1
	if log_seen_mark then
		for i = n, 1, -1 do
			if log[i] == log_seen_mark then
				first = i + 1
				break
			end
			if i == 1 then
				odd("debugger console log wrapped within a frame: register writes lost")
			end
		end
	end
	for i = first, n do
		local line = log[i]
		local c, a, d, s, y = line:match("^M2TE (%d) (%x+) (%x+) (%x+) (%-?%d+)$")
		if c then
			te_line(tonumber(c), tonumber(a, 16), tonumber(d, 16), tonumber(s, 16), tonumber(y))
		else
			c, a, d = line:match("^M2VDU (%d) (%x+) (%x+)$")
			if c then
				vdu_line(tonumber(c), tonumber(a, 16), tonumber(d, 16))
			elseif line:match("^M2CNT") then
				local k = 0
				for v in line:sub(6):gmatch("%d+") do
					k = k + 1
					fs.cnt[k] = tonumber(v)
				end
			elseif line ~= mark and not line:match("^M2MARK") and line ~= "" then
				odd("debugger: " .. line:sub(1, 80))
			end
		end
	end
	log_seen_mark = mark
	if (fs.cnt[6] or 0) > 0 then
		odd("MPEG unit accessed")
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------------------------------------------------

local function frames_header()
	local h = { "frame", "lists", "list_words", "vertices", "triangles", "pixels_est", "listends", "texloads",
	            "texload_bytes", "te_w", "vdu_w" }
	for _, c in ipairs(COUNT_COLS) do
		h[#h + 1] = c
	end
	f_frames:write(table.concat(h, ","), "\n")
end

local function frames_line()
	local l = { frame, fs.lists, fs.list_words, fs.vtx, fs.tris, string.format("%.0f", fs.pixels), fs.listend,
	            fs.texloads, fs.texload_bytes, fs.te_w, fs.vdu_w }
	for i = 1, #COUNT_COLS do
		l[#l + 1] = fs.cnt[i] or 0
	end
	f_frames:write(table.concat(l, ","), "\n")
end

local function write_features()
	local f = io.open(OUT .. "/features.txt", "w")
	if not f then
		return
	end
	f:write(string.format("Konami M2 capture: %d frames\n\n", frame))
	f:write("== Render states (one line each; registers in this order) ==\n")
	local names = {}
	for _, r in ipairs(STATE_REGS) do
		names[#names + 1] = r[3]
	end
	f:write("# ", table.concat(names, " "), " vf(SHAD1|TEXT2|PRSP4)\n")
	f:write("# tris pixels_est verts frames : state\n")
	local keys = {}
	for k in pairs(states) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b) return states[a].pixels > states[b].pixels end)
	for _, k in ipairs(keys) do
		local s = states[k]
		f:write(string.format("%9d %12.0f %9d %6d : %s\n", s.tris, s.pixels, s.verts, s.frames, k))
	end
	f:write("\n== Register values written (name: value x count) ==\n")
	local rn = {}
	for k in pairs(regvals) do
		rn[#rn + 1] = k
	end
	table.sort(rn)
	for _, k in ipairs(rn) do
		local vals = {}
		local n = 0
		for v, c in pairs(regvals[k]) do
			vals[#vals + 1] = { v, c }
			n = n + 1
		end
		table.sort(vals, function(a, b) return a[2] > b[2] end)
		local shown = {}
		for i = 1, math.min(#vals, 24) do
			shown[#shown + 1] = string.format("%08x x%d", vals[i][1], vals[i][2])
		end
		f:write(string.format("%s: %s%s\n", k, table.concat(shown, ", "), n > 24 and string.format(" (+%d more)", n - 24) or ""))
	end
	f:write("\n== Oddities ==\n")
	for k, v in pairs(oddities) do
		f:write(string.format("%s: %d\n", k, v))
	end
	f:close()
end

---------------------------------------------------------------------------------------------------------------------
-- CPU traces (debugger)
---------------------------------------------------------------------------------------------------------------------

-- One file per CPU per frame, so the file name is the frame boundary
local function trace_files()
	mkdir(OUT .. "/trace")
	for _, t in ipairs(cpu_tags) do
		dbg:command(string.format("trace %s/trace/%s_f%06d.tr,%s", OUT, t:gsub(":", ""), frame, t))
	end
	trace_active = true
end

local function trace_frame()
	if trace_active then
		for _, t in ipairs(cpu_tags) do
			dbg:command("trace off," .. t)
		end
		trace_active = false
		if frame < trace_end then
			trace_files()
		else
			ev("TRACE off")
		end
	elseif trace_starts[frame] then
		trace_end = frame + TRACE_LEN
		ev("TRACE on for %d frames", TRACE_LEN)
		trace_files()
	end
end

---------------------------------------------------------------------------------------------------------------------
-- Start-up and frame hooks
---------------------------------------------------------------------------------------------------------------------

local started = false

local function start()
	if started then
		return
	end
	local m = manager.machine
	dbg = m.debugger
	if not dbg then
		print("m2_capture: needs the debugger: run MAME with -debug -debugger none")
		m:exit()
		return
	end
	started = true
	if m.system.name ~= "polystar" and m.system.parent ~= "polystar" then
		print("m2_capture: written for polystar; running on " .. m.system.name .. " anyway")
	end
	mkdir(OUT)
	f_frames = assert(io.open(OUT .. "/frames.csv", "w"))
	f_events = assert(io.open(OUT .. "/events.log", "w"))
	if DUMP then
		f_lists = assert(io.open(OUT .. "/te_lists.bin", "wb"))
		f_tex = assert(io.open(OUT .. "/texloads.bin", "wb"))
	end
	frames_header()
	reset_frame_stats()

	screen = m.screens[":screen"]
	local ppc1 = m.devices[":ppc1"]
	local ppc2 = m.devices[":ppc2"]
	space1 = ppc1.spaces["program"]
	cpu_tags = { ":ppc1" }
	set_watchpoints(ppc1, 1)
	if ppc2 then
		cpu_tags[2] = ":ppc2"
		set_watchpoints(ppc2, 2)
	end
	for i = 0, 9 do
		dbg:command(string.format("temp%d=0", i))
	end
	for n in TRACE_AT:gmatch("%d+") do
		trace_starts[tonumber(n)] = true
	end
	dbg.execution_state = "run"
	ev("START %s, watchpoints on %d CPUs, screen %dx%d", m.system.name, #cpu_tags, screen and screen.width or 0,
		screen and screen.height or 0)
end

local function on_frame()
	if not started then
		return
	end
	read_console()
	frames_line()
	if frame % 60 == 0 then
		f_frames:flush()
		f_events:flush()
	end
	if SNAP > 0 and frame % SNAP == 0 and screen then
		screen:snapshot()
	end
	frame = frame + 1
	reset_frame_stats()
	trace_frame()
	if frame % 600 == 0 then
		write_features()
	end
	if MAXF > 0 and frame >= MAXF then
		manager.machine:exit()
	end
end

local function stop()
	if not started then
		return
	end
	if trace_active then
		for _, t in ipairs(cpu_tags) do
			dbg:command("trace off," .. t)
		end
	end
	write_features()
	for _, f in ipairs({ f_frames, f_events, f_lists, f_tex }) do
		if f then
			f:close()
		end
	end
	f_frames, f_events, f_lists, f_tex = nil, nil, nil, nil
	started = false
end

-- Keep the notifier subscriptions alive for the whole run. As an -autoboot_script this runs after the machine's first reset,
-- so start now; the reset notifier only covers a later reset with the script loaded some other way.
_G.m2cap_subs = {
	emu.add_machine_reset_notifier(start),
	emu.add_machine_frame_notifier(on_frame),
	emu.add_machine_stop_notifier(stop),
}
if manager.machine then
	start()
end
