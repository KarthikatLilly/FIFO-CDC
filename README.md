# Async FIFO-Based CDC Bridge with Backpressure — Build Specification

**Purpose of this document:** This README is a complete, self-contained specification meant to be handed to a code-generation agent (or a human Verilog/SystemVerilog engineer) with no other context. Every module's name, parameters, ports, and internal behavior are pinned down exactly so that independently generated files will wire together with zero integration errors. The author will take the generated code, run it in Vivado (XSIM for simulation, then Synthesis/Implementation for timing), and report back results after 1–2 days. Because turnaround is slow, correctness on the first pass matters more than speed — follow this spec literally rather than improvising alternate architectures, port names, or flag equations.

The project follows the well-established Cummings dual-clock FIFO architecture (the canonical reference used across the industry for this exact problem), extended with a reset synchronizer and a configurable hysteresis-based backpressure controller.

---

## 0. Instructions to the Code-Generation Agent

- Generate every file listed in Section 3, using the exact module name, parameter names, and port names/widths/directions given in Section 5. Do not rename, reorder, or "improve" the interface — other modules are written against these exact names.
- Follow the Coding Rules in Section 7 strictly. These exist to guarantee zero-latch, zero-lint-warning, Vivado-clean code on the first synthesis attempt.
- Follow the flag equations given verbatim (full/empty/gray-binary conversion). These are well-known correct formulas — do not derive alternative logic even if it looks equivalent.
- Implement the testbench's `METRIC:` print statements exactly as specified in Section 6 — these lines are what get grepped out of the Vivado simulation log to populate the metrics table and, eventually, resume bullets.
- Before finalizing, run through the Self-Check Checklist in Section 9 and confirm every item.
- Output all files using the exact filenames in the tree in Section 3 (module name == file name).

---

## 1. Project Summary

A parameterizable asynchronous FIFO that safely transfers data from a fast write-clock domain (simulating a sensor/ADC) to a slow read-clock domain (simulating a processor/memory-controller bus), using Gray-coded pointers and double-flop synchronizers to avoid metastability, plus a hysteresis-based backpressure controller that stalls the producer before the FIFO actually overflows. A deliberately broken single-flop crossing (`naive_cdc_bridge.v`) is included purely as a side-by-side comparison to demonstrate — via Vivado's static timing analysis — why the synchronizer chain is necessary.

---

## 2. Resume Metrics Contract

This project is structured so that every resume bullet is backed by a number that comes directly out of a Vivado log, timing report, or Python-generated plot — not an estimate. The table below is the contract: each metric has a defined source and will be filled in `docs/metrics.md` after the first Vivado run.

| # | Metric | Source | Feeds resume bullet about |
|---|--------|--------|---------------------------|
| 1 | Random transactions run, 0 mismatches | `tb_async_fifo.sv` METRIC prints | Verification rigor |
| 2 | Functional coverage % | SV covergroup in testbench | Verification completeness |
| 3 | Max occupancy reached / DEPTH | METRIC print + Python cross-check | Design correctness |
| 4 | Backpressure watermark accuracy (assert/deassert exactly at configured occupancy) | METRIC print | Backpressure design quality |
| 5 | WNS (Worst Negative Slack) — naive single-flop crossing | Vivado Timing Summary, `naive_cdc_bridge.v` run | CDC risk demonstration |
| 6 | WNS — synchronized design | Vivado Timing Summary, `async_fifo_top.v` run | CDC risk elimination |
| 7 | Fmax achieved post-implementation | Vivado Timing Summary | Design performance |
| 8 | Synchronizer MTBF (years) | Hand calculation using Section 8.5 formula + Vivado/device τ, T0 | Metastability rigor |
| 9 | LUT / FF / BRAM utilization % | Vivado Utilization Report | Efficiency |
| 10 | Number of directed + randomized test scenarios | Testbench structure | Verification breadth |

> Do not fabricate any of these — leave a metric blank in `docs/metrics.md` if a Vivado run hasn't produced it yet.

---

## 3. Repository / File Structure

```
async-fifo-cdc/
├── rtl/
│   ├── rst_sync.v
│   ├── gray_counter.v
│   ├── gray2bin.v
│   ├── sync_r2w.v
│   ├── sync_w2r.v
│   ├── wptr_full.v
│   ├── rptr_empty.v
│   ├── fifomem.v
│   ├── backpressure_ctrl.v
│   ├── async_fifo_top.v
│   └── naive_cdc_bridge.v        (standalone, NOT part of async_fifo_top — demo only)
├── tb/
│   └── tb_async_fifo.sv
├── constraints/
│   ├── async_fifo_top.xdc
│   └── naive_cdc_bridge.xdc
├── scripts/
│   └── vcd_parser.py
└── docs/
    ├── design_doc.md             (template, filled in after Vivado run)
    └── metrics.md                (template, filled in after Vivado run)
```

Total: 11 RTL/TB files + 2 XDC files + 1 Python script + 2 doc templates.

---

## 4. Global Conventions (apply to every file)

| Item | Convention |
|------|------------|
| Default `DATA_WIDTH` | 8 |
| Default `ADDR_WIDTH` | 4 → `DEPTH = 2**ADDR_WIDTH = 16` |
| Pointer width | `ADDR_WIDTH + 1` bits everywhere (extra MSB is the classic Cummings wrap-detection bit — required for full/empty disambiguation) |
| Write clock | `wclk`, nominal 100 MHz → 10 ns period |
| Read clock | `rclk`, nominal 37 MHz → 27 ns period (intentionally non-integer ratio to stress the synchronizer) |
| Reset | Single top-level async, active-low `rst_n`. Internally synchronized per-domain via `rst_sync.v` into `wrst_n_sync` and `rrst_n_sync`. No module except `rst_sync.v` may use the raw, unsynchronized `rst_n` directly in a sequential always block. |
| Synchronizer depth | Parameter `SYNC_STAGES`, default 2 |
| Reset style inside domains | Asynchronous assert, synchronous de-assert, using the domain's synchronized reset signal |
| Signal naming | `_bin` = binary pointer, `_gray` = Gray-coded pointer, `_sync` = has crossed a synchronizer, `_n` suffix = active-low |
| Numeric literals | Always sized (e.g. `4'd0`, not `0`) |
| Blocking vs non-blocking | `<=` only inside `always @(posedge clk ...)`; `=` only inside `always @*` combinational blocks. Never mixed in the same block. |

---

## 5. Module-by-Module Specification

### 5.1 `rst_sync.v` — Reset Synchronizer

Converts one async active-low reset into a per-domain reset that asserts asynchronously (immediately) but de-asserts synchronously (avoiding reset-removal timing violations) — a real interview talking point in its own right.

**Parameters:** `SYNC_STAGES` (default 2)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | input | 1 | domain clock |
| `async_rst_n` | input | 1 | raw async active-low reset |
| `sync_rst_n` | output | 1 | domain-synchronized active-low reset |

**Behavior:**

```verilog
reg [SYNC_STAGES-1:0] sync_chain;
always @(posedge clk or negedge async_rst_n)
  if (!async_rst_n) sync_chain <= {SYNC_STAGES{1'b0}};
  else               sync_chain <= {sync_chain[SYNC_STAGES-2:0], 1'b1};
assign sync_rst_n = sync_chain[SYNC_STAGES-1];
```

---

### 5.2 `gray_counter.v` — Binary + Gray Pointer Counter

Single source of truth for a domain's pointer — binary form (for memory addressing and occupancy math) and Gray form (for safe crossing) must be registered from the same next-state value in the same cycle. Do not compute `gray_out` combinationally from an already-registered `bin_out` in a separate always block — that introduces a one-cycle mismatch bug.

**Parameters:** `WIDTH` (default `ADDR_WIDTH+1 = 5`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | input | 1 | |
| `rst_n` | input | 1 | synchronized domain reset |
| `en` | input | 1 | increment enable (already gated by full/empty upstream) |
| `bin_out` | output reg | WIDTH | binary pointer |
| `gray_out` | output reg | WIDTH | Gray-coded pointer |

**Behavior:**

```verilog
wire [WIDTH-1:0] bin_next  = bin_out + (en ? 1'b1 : 1'b0);
wire [WIDTH-1:0] gray_next = (bin_next >> 1) ^ bin_next;
always @(posedge clk or negedge rst_n)
  if (!rst_n) begin bin_out <= 0; gray_out <= 0; end
  else        begin bin_out <= bin_next; gray_out <= gray_next; end
```

---

### 5.3 `gray2bin.v` — Gray-to-Binary Converter (combinational)

Needed to convert a synchronized Gray pointer back to binary so occupancy (fill level) can be computed for the backpressure controller.

**Parameters:** `WIDTH` (default 5)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `gray_in` | input | WIDTH | |
| `bin_out` | output | WIDTH | |

**Behavior:** MSB passes through unchanged; each lower bit is the XOR of the corresponding Gray bit with the already-computed next-higher binary bit (ripple XOR from MSB down to LSB). Implement with a `generate`/`for` loop — do not use a fixed-width literal chain, since `WIDTH` is parameterized.

---

### 5.4 `sync_r2w.v` — Read Pointer → Write Domain Synchronizer

Brings the read pointer (Gray-coded) into the write clock domain safely. This relies on the Gray code's one-bit-change-per-increment property — include a comment stating this assumption explicitly in the generated file, since it is the reason multi-bit synchronization is safe here at all.

**Parameters:** `ADDR_WIDTH` (default 4), `SYNC_STAGES` (default 2)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `wclk` | input | 1 | |
| `wrst_n_sync` | input | 1 | |
| `rptr_gray_in` | input | `ADDR_WIDTH+1` | from `rptr_empty.v` |
| `rptr_gray_sync_out` | output reg | `ADDR_WIDTH+1` | registered, in wclk domain |

**Behavior:** `SYNC_STAGES`-deep shift register capturing the entire Gray pointer bus together at each stage (all bits move as one vector per stage — never synchronize individual bits separately).

---

### 5.5 `sync_w2r.v` — Write Pointer → Read Domain Synchronizer

Exact mirror of 5.4: parameters `ADDR_WIDTH`, `SYNC_STAGES`; ports `rclk`, `rrst_n_sync`, `wptr_gray_in`, `wptr_gray_sync_out`.

---

### 5.6 `wptr_full.v` — Write Pointer Domain Logic

Owns the write-domain pointer counter, the full flag, and the occupancy count used by the backpressure controller.

**Parameters:** `ADDR_WIDTH` (default 4)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `wclk` | input | 1 | |
| `wrst_n_sync` | input | 1 | |
| `wr_en` | input | 1 | requested write enable (ungated) |
| `rptr_gray_sync` | input | `ADDR_WIDTH+1` | from `sync_r2w.v` |
| `wptr_bin` | output | `ADDR_WIDTH+1` | to `fifomem.v` (address = lower `ADDR_WIDTH` bits) and to occupancy math |
| `wptr_gray` | output | `ADDR_WIDTH+1` | to `sync_w2r.v` |
| `full` | output reg | 1 | registered full flag |
| `wr_occupancy` | output | `ADDR_WIDTH+1` | current fill level as seen from write domain |

**Internal instances:** one `gray_counter.v` (`WIDTH=ADDR_WIDTH+1`, `en = wr_en & ~full`), one `gray2bin.v` (converts `rptr_gray_sync` → `rptr_bin_sync`).

**Full flag equation** (canonical Cummings form — use exactly this, computed from the next Gray pointer value so full is correct one cycle before the counter itself updates):

```verilog
wire [ADDR_WIDTH:0] wgray_next = (wbin_next >> 1) ^ wbin_next;   // from the internal counter's next-state
wire is_full = (wgray_next == {~rptr_gray_sync[ADDR_WIDTH:ADDR_WIDTH-1],
                                 rptr_gray_sync[ADDR_WIDTH-2:0]});
always @(posedge wclk or negedge wrst_n_sync)
  if (!wrst_n_sync) full <= 1'b0;
  else              full <= is_full;
```

**Occupancy:** `wr_occupancy = wptr_bin - rptr_bin_sync;` (plain subtraction — valid because both are `ADDR_WIDTH+1`-bit extended pointers; modulo wraparound arithmetic makes this correct without extra logic, this is the standard trick, do not add manual wrap-correction).

---

### 5.7 `rptr_empty.v` — Read Pointer Domain Logic

**Parameters:** `ADDR_WIDTH` (default 4)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `rclk` | input | 1 | |
| `rrst_n_sync` | input | 1 | |
| `rd_en` | input | 1 | requested read enable (ungated) |
| `wptr_gray_sync` | input | `ADDR_WIDTH+1` | from `sync_w2r.v` |
| `rptr_bin` | output | `ADDR_WIDTH+1` | to `fifomem.v` (address) |
| `rptr_gray` | output | `ADDR_WIDTH+1` | to `sync_r2w.v` |
| `empty` | output reg | 1 | registered empty flag |

**Internal instance:** one `gray_counter.v` (`en = rd_en & ~empty`).

**Empty flag equation** (canonical form — exact Gray-code equality, no inversion, unlike full):

```verilog
wire [ADDR_WIDTH:0] rgray_next = (rbin_next >> 1) ^ rbin_next;
wire is_empty = (rgray_next == wptr_gray_sync);
always @(posedge rclk or negedge rrst_n_sync)
  if (!rrst_n_sync) empty <= 1'b1;
  else              empty <= is_empty;
```

---

### 5.8 `fifomem.v` — Dual-Port Memory

**Parameters:** `DATA_WIDTH` (default 8), `ADDR_WIDTH` (default 4)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `wclk` | input | 1 | |
| `wr_en_gated` | input | 1 | `wr_en & ~full`, computed at top level |
| `wr_addr` | input | `ADDR_WIDTH` | `wptr_bin[ADDR_WIDTH-1:0]` |
| `wr_data` | input | `DATA_WIDTH` | |
| `rclk` | input | 1 | |
| `rd_en_gated` | input | 1 | `rd_en & ~empty`, computed at top level |
| `rd_addr` | input | `ADDR_WIDTH` | `rptr_bin[ADDR_WIDTH-1:0]` |
| `rd_data` | output reg | `DATA_WIDTH` | registered, one cycle of latency after `rd_en_gated` |
| `rd_valid` | output reg | 1 | delayed-by-one-cycle copy of `rd_en_gated`, marks `rd_data` valid |

**Behavior** (synchronous read, BRAM-inferable — do not use combinational/asynchronous read):

```verilog
reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];
always @(posedge wclk) if (wr_en_gated) mem[wr_addr] <= wr_data;
always @(posedge rclk) begin
  if (rd_en_gated) rd_data <= mem[rd_addr];
  rd_valid <= rd_en_gated;
end
```

---

### 5.9 `backpressure_ctrl.v` — Hysteresis Backpressure Controller

Asserts `almost_full`/`stall` before the FIFO is truly full, using two watermarks (hysteresis) so the signal doesn't chatter right at the boundary — this is a real design consideration worth a resume line on its own.

**Parameters:** `ADDR_WIDTH` (default 4), `ALMOST_FULL_HI` (default 14), `ALMOST_FULL_LO` (default 10)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `wclk` | input | 1 | |
| `wrst_n_sync` | input | 1 | |
| `wr_occupancy` | input | `ADDR_WIDTH+1` | from `wptr_full.v` |
| `almost_full` | output reg | 1 | |
| `stall` | output | 1 | `= almost_full` (kept as a separate port for interface clarity/extensibility) |

**Behavior:**

```verilog
always @(posedge wclk or negedge wrst_n_sync)
  if (!wrst_n_sync) almost_full <= 1'b0;
  else if (!almost_full && wr_occupancy >= ALMOST_FULL_HI) almost_full <= 1'b1;
  else if (almost_full  && wr_occupancy <= ALMOST_FULL_LO) almost_full <= 1'b0;
assign stall = almost_full;
```

---

### 5.10 `async_fifo_top.v` — Top-Level Wrapper

**Parameters:** `DATA_WIDTH(8)`, `ADDR_WIDTH(4)`, `ALMOST_FULL_HI(14)`, `ALMOST_FULL_LO(10)`, `SYNC_STAGES(2)`

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `rst_n` | input | 1 | single async top-level reset |
| `wclk` | input | 1 | |
| `wr_en` | input | 1 | |
| `wr_data` | input | `DATA_WIDTH` | |
| `full` | output | 1 | |
| `almost_full` | output | 1 | |
| `stall` | output | 1 | |
| `wr_occupancy` | output | `ADDR_WIDTH+1` | debug/monitor, also used by Python waveform script |
| `rclk` | input | 1 | |
| `rd_en` | input | 1 | |
| `rd_data` | output | `DATA_WIDTH` | |
| `rd_valid` | output | 1 | |
| `empty` | output | 1 | |

Instantiates: two `rst_sync.v` (one per domain), `wptr_full.v`, `rptr_empty.v`, `sync_r2w.v`, `sync_w2r.v`, `fifomem.v`, `backpressure_ctrl.v`. Gating logic (`wr_en & ~full`, `rd_en & ~empty`) is computed here at the top level and fed into `fifomem.v`.

---

### 5.11 `naive_cdc_bridge.v` — Intentionally Broken Reference (demo only, standalone)

**NOT** part of the FIFO datapath. Exists solely so Vivado's static timing analysis (and `report_cdc`) can be run on it to produce a "before" timing-violation number to contrast against the real design's "after" number.

**Parameters:** `DATA_WIDTH` (default 8)

| Port | Dir | Width |
|------|-----|-------|
| `wclk` | input | 1 |
| `wr_data` | input | `DATA_WIDTH` |
| `rclk` | input | 1 |
| `rd_data_bad` | output reg | `DATA_WIDTH` |

**Behavior:** a single register in the write domain, sampled directly by a single flop in the read domain — no Gray coding, no multi-stage synchronizer:

```verilog
reg [DATA_WIDTH-1:0] data_reg;
always @(posedge wclk) data_reg <= wr_data;
always @(posedge rclk) rd_data_bad <= data_reg;
```

---

## 6. Testbench Specification — `tb_async_fifo.sv`

**Clocks:** `wclk` period = 10 ns (100 MHz). `rclk` period = 27 ns (≈37.04 MHz, intentionally non-integer ratio to stress the synchronizer's timing relationship).

**Reset:** hold `rst_n = 0` for 100 ns, then release.

**Test 1 — Burst Overflow:** drive `wr_en = 1` continuously with an incrementing data pattern until `full` asserts; continue issuing writes for several more cycles while `full` is asserted and confirm none of them are written (no corruption, no silent overwrite); then drain completely via `rd_en = 1` and confirm occupancy returns to 0 and every accepted write is read back in order via the scoreboard described below.

**Test 2 — Backpressure / Slow Drain:** burst-fill to just below `ALMOST_FULL_HI`, then issue reads only intermittently (e.g., one read every few `rclk` cycles) while writes continue; confirm `almost_full`/`stall` assert at exactly `ALMOST_FULL_HI` occupancy and de-assert at exactly `ALMOST_FULL_LO` — log the exact occupancy value at each transition for the metrics table.

**Test 3 — Randomized Dual-Clock Stress:** run `NUM_RANDOM_TRANSACTIONS` (parameter, default 10000) cycles of randomized activity: each `wclk` cycle, assert `wr_en` with configurable probability (default 70%) and random data; each `rclk` cycle, assert `rd_en` with configurable probability (default 50%). Maintain a SystemVerilog queue as a golden reference: push the data value on every accepted write (`wr_en & ~full`), pop-and-compare on every valid read (`rd_valid == 1`). Any mismatch is a hard testbench failure.

**Scoreboard:** implement as a `bit [DATA_WIDTH-1:0]` SV queue, `push_back` on accepted write, `pop_front` and compare on valid read, increment a `mismatch_count` on any inequality.

**Functional coverage** (covergroup, sampled every `wclk`): bins for `full` asserted, `empty` asserted, `almost_full` asserted, occupancy in each quartile of `[0, DEPTH]`, a pointer wraparound event (address transitions from `DEPTH-1` to 0), and a same-cycle write+read-accepted event. Target: report the achieved coverage percentage at the end of the run.

**End-of-simulation report** — print these exact lines (fixed `METRIC:` prefix so they can be grepped straight out of the Vivado simulation log):

```
METRIC: TOTAL_WRITES_ACCEPTED = %0d
METRIC: TOTAL_READS_VALID = %0d
METRIC: SCOREBOARD_MISMATCHES = %0d
METRIC: MAX_OCCUPANCY = %0d
METRIC: FULL_ASSERT_COUNT = %0d
METRIC: ALMOST_FULL_ASSERT_COUNT = %0d
METRIC: EMPTY_ASSERT_COUNT = %0d
METRIC: COVERAGE_PCT = %0.2f
```

**Waveform dump:**

```verilog
initial begin
  $dumpfile("async_fifo_waveform.vcd");
  $dumpvars(0, tb_async_fifo);
end
```

---

## 7. Coding Rules (to guarantee a clean first Vivado pass)

1. **No inferred latches:** every combinational (`always @*`) block must assign every output on every branch; include `default:` in every `case`.
2. `<=` only inside `always @(posedge clk ...)` blocks; `=` only inside `always @*` blocks. Never mix within one block.
3. One `always` block per logically distinct signal group; no signal driven from more than one `always` block.
4. All parameters declared with `parameter`, overridden only via `#(.PARAM(value))` instantiation — never `defparam`.
5. Every sequential block resets using the synchronized domain reset, never the raw top-level `rst_n`, except inside `rst_sync.v` itself.
6. No combinational loops.
7. All bus widths sized explicitly and matched exactly to the port tables above — no implicit truncation.
8. Use Verilog-2001-compatible syntax for all `rtl/` files (ANSI-style port lists are fine); SystemVerilog constructs (queues, covergroups) are fine in `tb_async_fifo.sv` only, since XSIM supports SV testbenches.
9. Module name must equal file name exactly (e.g. `gray_counter.v` contains `module gray_counter`).

---

## 8. Vivado Workflow (for the human, after code generation)

1. Create a new RTL project targeting any Artix-7/Zynq part (e.g. `xc7a35tcpg236-1` for a Basys3).
2. Add all `rtl/*.v` files as design sources; add `tb/tb_async_fifo.sv` as a simulation-only source.
3. Set `tb_async_fifo` as the simulation top and `async_fifo_top` as the synthesis top.
4. Run Behavioral Simulation; let it run to completion; check the Tcl console/log for the `METRIC:` lines and confirm `SCOREBOARD_MISMATCHES = 0`.
5. Locate the auto-generated `async_fifo_waveform.vcd` under the simulation run directory (typically `<project>.sim/sim_1/behav/xsim/`) and copy it out for the Python step.
6. Open the waveform viewer, add `wptr_gray`, `rptr_gray`, `full`, `empty`, `almost_full`, `wr_occupancy`; screenshot for the design doc.
7. Add `constraints/async_fifo_top.xdc`:
   ```tcl
   create_clock -name wclk -period 10.000 [get_ports wclk]
   create_clock -name rclk -period 27.000 [get_ports rclk]
   set_clock_groups -asynchronous -group [get_clocks wclk] -group [get_clocks rclk]
   ```
8. Run Synthesis then Implementation; open the Timing Summary report; record WNS/WHS (should be clean/positive since the two clocks are properly declared asynchronous).
9. For the "before" comparison: create a second synthesis run using only `naive_cdc_bridge.v` with `constraints/naive_cdc_bridge.xdc` containing the same two `create_clock` lines but deliberately omitting `set_clock_groups -asynchronous`. Vivado will then analyze the crossing as if synchronous and report a large negative WNS — screenshot this number as the "before" metric.
10. Run Reports → Report CDC on both versions for an additional structural CDC violation report — a strong second screenshot for the design doc.
11. Record the post-implementation Utilization report (LUTs, FFs, BRAM %) for the efficiency metric.

### 8.5 MTBF Calculation (for the design doc, done by hand after step 8)

```
MTBF = e^(t_r / τ) / (T0 × f_clk × f_data)
```

where `t_r` = resolution time available (approximately one receiving-clock period minus setup time, obtainable from the Timing Summary), and `τ`, `T0` are flip-flop-specific metastability parameters. Xilinx does not always publish these directly for a given part/speed grade — pull them from the device's characterization data if available, or use a clearly-cited conservative published academic value, and state this assumption explicitly in the design doc rather than presenting it as a device-verified number.

---

## 9. Self-Check Checklist (agent completes before returning code)

- [ ] Every module's port list matches this README exactly (name, width, direction)
- [ ] Every parameter name and default matches this README exactly
- [ ] No combinational `always` block lacks a `default`/`else` covering all paths
- [ ] `<=` only in clocked blocks, `=` only in combinational blocks, never mixed
- [ ] Gray↔binary conversions implemented exactly as the formulas in 5.2/5.3
- [ ] `full`/`empty` equations match Section 5.6/5.7 verbatim — no ad-hoc equality logic
- [ ] No module outside `rst_sync.v` uses the raw, unsynchronized `rst_n`
- [ ] Testbench prints all eight `METRIC:` lines in the exact format given
- [ ] VCD dump filename and dumped scope match Section 6
- [ ] All 11 RTL/TB files present, filenames matching Section 3 exactly

---

## 10. Python Post-Processing — `scripts/vcd_parser.py`

- **Input:** path to `async_fifo_waveform.vcd` (default `../async_fifo_waveform.vcd`).
- Parse using the `vcdvcd` package (`pip install vcdvcd`).
- **Extract:** `wclk`, `rclk`, `wr_en`, `rd_en`, `full`, `empty`, `almost_full`, `wr_occupancy`, `wptr_bin`, `rptr_bin` (note: XSIM prefixes signal names with the instance hierarchy — inspect the VCD header to confirm exact hierarchical paths before hardcoding them).
- **Outputs three plots:**
  - `occupancy_vs_time.png` — step plot with horizontal reference lines at `ALMOST_FULL_LO`, `ALMOST_FULL_HI`, `DEPTH`
  - `pointer_trajectory.png` — `wptr_bin` and `rptr_bin` overlaid, showing the sawtooth wraparound pattern
  - `flag_timeline.png` — logic-analyzer-style timeline of `full`/`empty`/`almost_full`
- Also computes and prints: % of simulated time `full`/`empty`/`almost_full` were asserted, max occupancy reached, and count of full assertion events — cross-checked against the testbench's own `METRIC:` values as an independent consistency check.

---

## 11. Deliverables Checklist

- [ ] `rtl/rst_sync.v`
- [ ] `rtl/gray_counter.v`
- [ ] `rtl/gray2bin.v`
- [ ] `rtl/sync_r2w.v`
- [ ] `rtl/sync_w2r.v`
- [ ] `rtl/wptr_full.v`
- [ ] `rtl/rptr_empty.v`
- [ ] `rtl/fifomem.v`
- [ ] `rtl/backpressure_ctrl.v`
- [ ] `rtl/async_fifo_top.v`
- [ ] `rtl/naive_cdc_bridge.v`
- [ ] `tb/tb_async_fifo.sv`
- [ ] `constraints/async_fifo_top.xdc`
- [ ] `constraints/naive_cdc_bridge.xdc`
- [ ] `scripts/vcd_parser.py`
- [ ] `docs/design_doc.md` (template — architecture, MTBF calc, parameter justification, screenshots)
- [ ] `docs/metrics.md` (template — the Section 2 table, filled in after Vivado run)

---

## 12. Resume Bullet Templates (fill brackets from `docs/metrics.md`)

- Designed and verified a parameterizable asynchronous FIFO (Verilog, Vivado/XSIM) for clock-domain-crossing bridging using Gray-code pointer synchronization; verified zero data corruption across [N] randomized transactions at a 100 MHz/37 MHz non-integer clock ratio with [X]% functional coverage.
- Built a hysteresis-based backpressure controller triggering at a configurable [HI]/[DEPTH] occupancy watermark, preventing 100% of overflow events across [K] burst-write test iterations.
- Demonstrated CDC synchronization necessity via Vivado static timing analysis: a naive single-flop crossing showed [Y] ns of setup violation, eliminated entirely ([Z] ns positive slack) after inserting a 2-stage Gray-code synchronizer chain.
- Computed synchronizer MTBF of [M] years using the standard dual-flop metastability model, confirming negligible failure probability over target device lifetime.
- Implemented the design on [target part], consuming only [L]% LUTs and [F] flip-flops for a depth-16, 8-bit-wide FIFO.
