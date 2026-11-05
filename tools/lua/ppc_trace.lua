-- ppc_trace.lua: MAME traces of Konami M2's two PPC602s for the reference model's replay bench (sim/ppcreplay).
--
-- From power-on (PPCT_AT=0) or from the end of frame PPCT_AT, for PPCT_FRAMES frames, each CPU gets a debugger trace
-- (PPCT_OUT/<cpu>.tr) with an "R" line of registers before every instruction (r0-r31, CR, LR, CTR, XER, MSR, SRR0, SRR1,
-- FPSCR) and an "MR/MW address bits data" line for every data access (debugger watchpoints over the whole space).
-- Started mid-run it first writes PPCT_OUT/ram.bin (0x40000000-0x40ffffff as the CPUs read it, big-endian) and
-- PPCT_OUT/<cpu>.state (every register MAME's state interface has).
--
-- Run (the debugger is needed; ui.ini's skip_warnings 1 gets past the warning screen), once per CPU:
--   PPCT_CPU=:ppc2 PPCT_BP=spr_writes.txt PPCT_OUT=cap/t900 PPCT_AT=900 PPCT_FRAMES=1 \
--     mame polystar -debug -debugger none -autoboot_script ppc_trace.lua
-- Each traced instruction costs about 250 bytes.

local OUT    = os.getenv("PPCT_OUT") or "ppctrace"
local AT     = tonumber(os.getenv("PPCT_AT") or "0") or 0
local FRAMES = tonumber(os.getenv("PPCT_FRAMES") or "1") or 1
-- one CPU a run (PPCT_CPU, default :ppc1), with the debugger's focus on it: a trace action's tracelog goes to the
-- visible CPU's file with the visible CPU's registers, so two CPUs traced at once mix their lines
local CPUS   = { os.getenv("PPCT_CPU") or ":ppc1" }

local SEP = package.config:sub(1, 1)
if SEP == "\\" then
	os.execute('if not exist "' .. OUT:gsub("/", "\\") .. '" mkdir "' .. OUT:gsub("/", "\\") .. '"')
else
	os.execute('mkdir -p "' .. OUT .. '"')
end

local machine = manager.machine
local dbg = machine.debugger

local function action()
	local fmt, args = "R", ""
	for i = 0, 31 do
		fmt = fmt .. " %X"
		args = args .. ",r" .. i
	end
	for _, n in ipairs({ "cr", "lr", "ctr", "xer", "msr", "srr0", "srr1", "fpscr" }) do
		fmt = fmt .. " %X"
		args = args .. "," .. n
	end
	return '{tracelog "' .. fmt .. '\\n"' .. args .. "}"
end

-- PPCT_BP (from tools/ppc_spr_scan.py): breakpoints on every instruction that writes a register MAME's state interface
-- doesn't show, from power-on; their values go into the .state files as "SPR<n> value" (and ESASRR from esa's MSR)
local BP = os.getenv("PPCT_BP")

local function set_breakpoints()
	if not BP then return end
	local n = 0
	for line in io.lines(BP) do
		local pc, kind, spr, reg = line:match("^(%x+) (%a+) (%d+) (%d+)$")
		if pc then
			for i, tag in ipairs(CPUS) do
				local act
				if kind == "mtspr" then
					act = string.format('printf "SPRW %d %X %%X",r%s; g', i, tonumber(spr), reg)
				elseif kind == "esa" then
					act = string.format('printf "ESA %d %%X",msr; g', i)
				else
					act = string.format('printf "DSA %d",msr; g', i)
				end
				machine.devices[tag].debug:bpset(tonumber(pc, 16), "1", act)
			end
			n = n + 1
		end
	end
	print(string.format("PPCT %d breakpoints", n))
end

-- the last value each CPU wrote to each register, from the breakpoints' log; read every frame (the debugger console
-- keeps only its latest lines), up to the marker the previous frame left
local last_spr = { {} }
local mark = 0

local function read_log()
	local log = dbg.consolelog
	local lines = {}
	local want = string.format("PPCTMARK %d", mark)
	for k = #log, 1, -1 do
		if mark > 0 and log[k] == want then break end
		lines[#lines + 1] = log[k]
	end
	for k = #lines, 1, -1 do
		local line = lines[k]
		local c, spr, v = line:match("^SPRW (%d) (%x+) (%x+)$")
		if c then
			last_spr[tonumber(c)][tonumber(spr, 16)] = tonumber(v, 16)
		end
		local ec, msr = line:match("^ESA (%d) (%x+)$")
		if ec then
			msr = tonumber(msr, 16)
			-- esa: ESASRR = EE, SA, AP, PR of the MSR before it
			last_spr[tonumber(ec)][987] = ((msr >> 15) & 1) | (((msr >> 22) & 1) << 1) | (((msr >> 23) & 1) << 2) |
				(((msr >> 14) & 1) << 3)
		end
	end
	mark = mark + 1
	-- debugger numbers are hex
	dbg:command(string.format('printf "PPCTMARK %%d",%X', mark))
end

local function spr_writes(i)
	return last_spr[i]
end

local function dump_state(tag)
	local dev = machine.devices[tag]
	local f = io.open(OUT .. "/" .. tag:gsub(":", "") .. ".state", "w")
	if BP then
		local w = spr_writes(1)
		local nums = {}
		for k, _ in pairs(w) do nums[#nums + 1] = k end
		table.sort(nums)
		for _, k in ipairs(nums) do f:write(string.format("SPR%d %X\n", k, w[k])) end
	end
	local names = {}
	for k, _ in pairs(dev.state) do names[#names + 1] = k end
	table.sort(names)
	for _, k in ipairs(names) do
		local e = dev.state[k]
		local ok, v = pcall(function() return e.value end)
		local s = "?"
		if ok and math.type(v) == "float" then
			-- the FPRs: the double's bits
			s = string.format("%016X", string.unpack("<I8", string.pack("<d", v)))
		elseif ok then
			s = string.format("%X", v)
		end
		f:write(string.format("%s %s\n", k, s))
	end
	f:close()
end

local function dump_ram()
	local sp = machine.devices[":ppc1"].spaces["program"]
	local f = io.open(OUT .. "/ram.bin", "wb")
	local chunk = {}
	for a = 0x40000000, 0x40fffffc, 4 do
		chunk[#chunk + 1] = string.pack(">I4", sp:read_u32(a))
		if #chunk == 4096 then
			f:write(table.concat(chunk))
			chunk = {}
		end
	end
	f:write(table.concat(chunk))
	f:close()
end

local function start()
	for _, tag in ipairs(CPUS) do
		local dev = machine.devices[tag]
		local file = OUT .. "/" .. tag:gsub(":", "") .. ".tr"
		dbg:command("trace " .. file .. "," .. tag .. ",noloop," .. action())
		local sp = dev.spaces["program"]
		dev.debug:wpset(sp, "r", 0, 0xffffffff, "1", 'tracelog "MR %X %X %X\\n",wpaddr,wpsize,wpdata; g')
		dev.debug:wpset(sp, "w", 0, 0xffffffff, "1", 'tracelog "MW %X %X %X\\n",wpaddr,wpsize,wpdata; g')
	end
	print(string.format("PPCT tracing from frame %d", AT))
end

local frame = 0
local tracing = false

dbg:command("focus " .. CPUS[1])
-- trace actions and breakpoint printfs evaluate against the visible CPU
local okv, errv = pcall(function() dbg.visible_cpu = machine.devices[CPUS[1]] end)
print("PPCT visible cpu: " .. (okv and tostring(dbg.visible_cpu and dbg.visible_cpu.tag) or ("not set: " .. tostring(errv))))
set_breakpoints()

if AT == 0 then
	start()
	tracing = true
end

emu.register_frame_done(function()
	frame = frame + 1
	if BP and not tracing then read_log() end
	if not tracing and frame == AT then
		for _, tag in ipairs(CPUS) do dump_state(tag) end
		dump_ram()
		start()
		tracing = true
	elseif tracing and frame >= AT + FRAMES then
		for _, tag in ipairs(CPUS) do dbg:command("trace off," .. tag) end
		print(string.format("PPCT done at frame %d", frame))
		machine:exit()
	end
end)
