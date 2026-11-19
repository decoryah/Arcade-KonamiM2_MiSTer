// tb_crt: rtl/m2_crt.sv (CRT Adjust) on the M2's raster (rtl/m2_vtiming.sv), both of them (+arc for Hell Night's).
// The source picture's pixel says where it came from ({1, vpos, hpos}); a model of the display takes the output at each pixel
// enable, as arcade_video does, and records per line where the picture starts and ends (clocks after the hsync's rise), how many
// pixels it has and whether they are the source's in order, and per frame on which line (hsync rises after the vsync's) each
// source line is.
//   +arc         Hell Night's raster
//   +sweep       every H-Size at H-Position 0 and at the menu's ends: where the picture lands
//   +limits      (with -DNOCLAMP: run.sh limits) every H-Size: the H-Positions at which the picture is whole and in the line
// Without +sweep: the checks (Off as before; On at 0/0/0 in the same place; the picture whole and inside the line for every
// H-Size at every H-Position; V-Shift moves it by whole lines; the last line kept).
`timescale 1ns/1ps
module tb;
	reg clk = 1'b0;
	always #7.5 clk = ~clk;

	reg arc = 1'b0;
	reg rst = 1'b1;   // (the raster's counters start from its reset)
	initial #200 rst = 1'b0;
	wire ce_pix, hblank, vblank, hsync, vsync;
	wire [9:0] hpos;
	wire [8:0] vpos;
	m2_vtiming vt (.clk(clk), .rst(rst), .arc(arc), .ce_pix(ce_pix), .hpos(hpos), .vpos(vpos), .hblank(hblank), .vblank(vblank),
	               .hsync(hsync), .vsync(vsync));
	wire [23:0] rgb = (hblank | vblank) ? 24'h0 : {1'b1, 4'b0, vpos, hpos};

	reg       on = 1'b0;
	reg [4:0] osz = 5'd0;
	reg [6:0] opos = 7'd0;
	reg [4:0] ovs = 5'd0;
	wire        ce_o, hs_o, vs_o, hb_o, vb_o;
	wire [23:0] rgb_o;
`ifdef NOCLAMP
	m2_crt #(.VTOTAL(416), .CLAMP(1'b0)) dut
`else
	m2_crt #(.VTOTAL(416)) dut
`endif (.clk(clk), .arc(arc), .on(on), .osd_size(osz), .osd_pos(opos), .osd_vshift(ovs),
	                            .ce_in(ce_pix), .rgb_in(rgb), .hs_in(hsync), .vs_in(vsync), .hb_in(hblank), .vb_in(vblank),
	                            .ce_out(ce_o), .rgb_out(rgb_o), .hs_out(hs_o), .vs_out(vs_o), .hb_out(hb_o), .vb_out(vb_o));

	// ---- the display
	integer t = 0;
	always @(posedge clk) t <= t + 1;
	reg     hs_d = 1'b0, vs_d = 1'b0;
	integer t_hs = 0, hs_w = 0, line = 0, frame = 0;
	integer npx = 0, f_t = 0, l_t = 0, f_sh = 0, l_sh = 0, sv = -1, bad = 0;
	// the line just ended
	integer r_line, r_len, r_npx, r_ft, r_lt, r_fsh, r_lsh, r_sv, r_bad, r_hsw, r_frame;
	event   line_done;
	// per frame: the line each source line was on
	integer sv_at [0:511];
	integer k;
	initial for (k = 0; k < 512; k = k + 1) sv_at[k] = -1;

	always @(posedge clk) if (ce_o)
	begin
		hs_d <= hs_o;
		vs_d <= vs_o;
		// the vsync first: with CRT Adjust on, it rises with the hsync (both at the read rate), and the line starts there, as on a
		// monitor; off, it rises two pixels before
		if (vs_o & ~vs_d)
		begin
			frame = frame + 1;
			line = 0;
		end
		if (hs_o & ~hs_d)
		begin
			r_line = line; r_len = t - t_hs; r_npx = npx; r_ft = f_t; r_lt = l_t; r_fsh = f_sh; r_lsh = l_sh; r_sv = sv;
			r_bad = bad; r_hsw = hs_w; r_frame = frame;
			if (npx > 0 && sv >= 0) sv_at[sv] = line;
			-> line_done;
			t_hs = t;
			line = line + 1;
			npx = 0; bad = 0; sv = -1;
		end
		if (~hs_o & hs_d) hs_w = t - t_hs;
		if (!(hb_o | vb_o))
		begin
			if (rgb_o[23] !== 1'b1) bad = bad + 1;   // black or unknown inside the picture
			else
			begin
				if (npx == 0) begin f_t = t - t_hs; f_sh = rgb_o[9:0]; sv = rgb_o[18:10]; end
				else
				begin
					if (rgb_o[9:0] != l_sh + 1) bad = bad + 1;
					if (rgb_o[18:10] != sv) bad = bad + 1;
				end
				l_sh = rgb_o[9:0];
				l_t = t - t_hs;
				npx = npx + 1;
			end
		end
	end

	// ---- control
	integer W, H, VT, LINE_CLK, errors = 0;

	task automatic set(input reg o, input integer sz, input integer pos, input integer vsh);
		on = o;
		osz = (sz >= 0) ? sz : sz + 22;
		opos = (pos >= 0) ? pos : pos + 65;
		ovs = vsh;
	endtask

	// the next whole picture line after the settings have settled
	task automatic picture_line;
		integer n;
		n = 0;
		while (n < 3 || r_npx == 0) begin @(line_done); n = n + 1; end
	endtask

	task automatic whole_frame;
		integer f0;
		@(line_done); f0 = r_frame;
		while (r_frame < f0 + 3) @(line_done);   // two whole frames at these settings
		for (k = 0; k < 512; k = k + 1) sv_at[k] = -1;
		f0 = r_frame;
		while (r_frame == f0) @(line_done);      // and a third, recorded
	endtask

	task automatic check(input string what, input integer cond);
		if (!cond) begin errors = errors + 1; $display("FAIL %s", what); end
	endtask

	integer sz, pos, line0_off, ft0, lt0, hsw, len, s, vi, lo, hi, gaps;
	// the line a source line should be on, V-Shift s from where it was off: past the frame's end, in the next frame
	function automatic integer at(input integer s, input integer k);
		at = line0_off + s + k;
		if (at >= VT) at = at - VT;
		if (at < 0) at = at + VT;
	endfunction
	integer vsh_tests [0:4];
	initial begin vsh_tests[0] = -16; vsh_tests[1] = -1; vsh_tests[2] = 0; vsh_tests[3] = 1; vsh_tests[4] = 15; end
	initial
	begin
		if ($test$plusargs("arc")) arc = 1'b1;
		W = arc ? 512 : 640;
		H = arc ? 384 : 240;
		VT = arc ? 416 : 262;
		LINE_CLK = arc ? 673 * 4 : 857 * 5;
		// Off: as before
		set(0, 0, 0, 0);
		whole_frame;
		line0_off = sv_at[0];
		picture_line;
		ft0 = r_ft; lt0 = r_lt; hsw = r_hsw; len = r_len;
		$display("%s off: line %0d clocks, hsync %0d, picture %0d..%0d (%0d px), source line 0 on line %0d, %0d on %0d",
		         arc ? "arc" : "ntsc", len, hsw, ft0, lt0, r_npx, line0_off, H - 1, sv_at[H - 1]);
		check("off: whole line", r_npx == W && r_fsh == 0 && r_lsh == W - 1 && r_bad == 0);
		check("off: the last line", sv_at[H - 1] == line0_off + H - 1);

		// (compiled with NOCLAMP: every H-Size, the H-Positions at which the picture is whole and inside the line)
		if ($test$plusargs("limits"))
		begin
			for (sz = -16; sz <= 5; sz = sz + 1)
			begin
				lo = 999; hi = -999; gaps = 0;
				for (pos = -48; pos <= 16; pos = pos + 1)
				begin
					set(1, sz, pos, 0);
					picture_line;
					if (r_npx == W && r_fsh == 0 && r_lsh == W - 1 && r_bad == 0 && r_ft >= r_hsw && r_lt < r_len && r_len == len)
					begin
						if (lo == 999) lo = pos;
						else if (pos != hi + 1) gaps = gaps + 1;
						hi = pos;
					end
				end
				$display("limits size %3d: %0d .. %0d%s", sz, lo, hi, gaps ? " (gaps)" : "");
			end
			$finish;
		end

		if ($test$plusargs("sweep"))
		begin
			for (sz = -16; sz <= 5; sz = sz + 1)
				for (pos = -48; pos <= 16; pos = pos + 64)
				begin
					set(1, sz, pos, 0);
					picture_line;
					$display("size %3d pos %3d: picture %5d..%5d (%0d px, source %0d..%0d, bad %0d), hsync %0d, line %0d", sz, pos,
					         r_ft, r_lt, r_npx, r_fsh, r_lsh, r_bad, r_hsw, r_len);
				end
			for (sz = -16; sz <= 5; sz = sz + 1)
			begin
				set(1, sz, 0, 0);
				picture_line;
				$display("size %3d pos   0: picture %5d..%5d (%0d px, source %0d..%0d, bad %0d)", sz, r_ft, r_lt, r_npx, r_fsh, r_lsh,
				         r_bad);
			end
			$finish;
		end

		// On at 0 / 0 / 0: the same place, every pixel, every line
		set(1, 0, 0, 0);
		whole_frame;
		picture_line;
		$display("on 0/0/0: picture %0d..%0d (%0d px), hsync %0d, line %0d, source line 0 on line %0d, %0d on %0d", r_ft, r_lt,
		         r_npx, r_hsw, r_len, sv_at[0], H - 1, sv_at[H - 1]);
		check("on: same start", r_ft == ft0);
		check("on: same end", r_lt == lt0);
		check("on: whole line", r_npx == W && r_fsh == 0 && r_lsh == W - 1 && r_bad == 0);
		check("on: hsync and line as before", r_hsw == hsw && r_len == len);
		check("on: first line in place", sv_at[0] == line0_off);
		for (k = 0; k < H; k = k + 1)
			if (sv_at[k] != line0_off + k) begin check($sformatf("on: source line %0d on line %0d", k, sv_at[k]), 0); k = H; end

		// every H-Size at every H-Position: the picture whole, after the hsync pulse and inside the line
		for (sz = -16; sz <= 5; sz = sz + 1)
			for (pos = -48; pos <= 16; pos = pos + 1)
			begin
				set(1, sz, pos, 0);
				picture_line;
				if (!(r_npx == W && r_fsh == 0 && r_lsh == W - 1 && r_bad == 0 && r_ft >= r_hsw && r_lt < r_len && r_len == len))
				begin
					check($sformatf("size %0d pos %0d: picture %0d..%0d (%0d px, %0d..%0d, bad %0d), hsync %0d, line %0d", sz, pos,
					                r_ft, r_lt, r_npx, r_fsh, r_lsh, r_bad, r_hsw, r_len), 0);
				end
			end
		$display("H-Size x H-Position: %0d x %0d settings done", 22, 65);

		// V-Shift: the picture down by that many lines (the vsync earlier)
		for (vi = 0; vi < 5; vi = vi + 1)
		begin
			s = vsh_tests[vi];
			set(1, 0, 0, s);
			whole_frame;
			$display("V-Shift %3d: source line 0 on line %0d, %0d on %0d", s, sv_at[0], H - 1, sv_at[H - 1]);
			for (k = 0; k < H; k = k + 1)
				if (sv_at[k] != at(s, k))
				begin
					check($sformatf("V-Shift %0d: source line %0d on line %0d, not %0d", s, k, sv_at[k], at(s, k)), 0);
					k = H;
				end
		end

		// Off again: back as before
		set(0, 0, 0, 0);
		whole_frame;
		picture_line;
		check("off again", r_ft == ft0 && r_lt == lt0 && r_npx == W && sv_at[0] == line0_off);
		if (errors) $display("%0d FAILED", errors);
		else        $display("PASS");
		$finish;
	end
endmodule
