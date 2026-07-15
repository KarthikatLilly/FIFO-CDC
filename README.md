# Async FIFO-Based CDC Bridge with Backpressure

## Where the Project Stands

You have a complete, spec-faithful async FIFO clock-domain-crossing bridge: a depth-16, 8-bit dual-clock FIFO that moves data from a 100 MHz write domain to a ~37 MHz read domain using Gray-coded pointers and double-flop synchronizers, plus a reset synchronizer per domain and a hysteresis backpressure controller. Alongside it sits an intentionally broken single-flop crossing that exists only to produce a "bad" timing number for contrast.

In the sandbox the RTL compiled clean (zero warnings) and the testbench ran to completion: **0 scoreboard mismatches**, 1931 writes accepted equalling 1931 reads back in order, max occupancy hitting 16, and the backpressure watermark asserting at exactly 14 and deasserting at exactly 10. The Python parser also ran against the generated VCD and its independent counts matched the testbench.

What's not done is anything that only Vivado can produce: WNS, Fmax, MTBF, and utilization — those are the blank rows in `docs/metrics.md`, and filling them is the point of the Vivado run.

---

## How the Design (Verilog) and Verification (SystemVerilog) Are Split

The split is by role, and it maps cleanly onto the folders.

The eleven files in `files/` are all plain Verilog-2001 and are the only things that ever get synthesized into logic. Ten of them wire together under `async_fifo_top.v` — that's the actual FPGA design. The eleventh, `naive_cdc_bridge.v`, is also synthesizable RTL but is deliberately not instantiated anywhere in the top; it's a standalone module you synthesize on its own in a separate run purely to measure the "before" timing violation.

The one file in `files/`, `tb_async_fifo.sv`, is SystemVerilog and is simulation-only — it never gets synthesized. It uses constructs that have no hardware meaning (a queue as the golden scoreboard, a covergroup for functional coverage, `$urandom` for the randomized stress test, `$dumpvars` for the waveform). Those are exactly the things a synthesizer would reject, which is why they live in the testbench and why the file carries the `.sv` extension while the design carries `.v`. In Vivado terms this becomes two different roles: the RTL files are design sources, the testbench is a simulation-only source.

Mental model:

- `.v` files = the chip
- `.sv` file = the test harness that pokes the chip in simulation
- `naive_cdc_bridge.v` = a side experiment for the timing story

---

## Where the SystemVerilog and Python Run

The SystemVerilog testbench runs inside Vivado, in its built-in simulator XSIM, when you launch Behavioral Simulation. You never run it standalone — Vivado elaborates `tb_async_fifo` (the sim top) together with the DUT and executes it. The `METRIC:` lines print into Vivado's Tcl console / simulation log, and the `$dumpfile` call writes `async_fifo_waveform.vcd` into the simulation run directory.

The Python script runs outside Vivado, on your own machine, after the simulation has produced that VCD. It isn't part of the FPGA toolchain at all — it just reads the waveform file and draws plots. You install its two dependencies (`pip install vcdvcd matplotlib`), then point it at the VCD that Vivado dropped in the sim folder. It's an independent cross-check: its numbers should agree with the testbench's `METRIC:` numbers.

---

## Full Vivado RTL Flow from Scratch

Here is the end-to-end sequence, assuming a fresh install and nothing set up yet.

### 1. Prerequisites

Install Vivado (the free WebPACK/Standard edition covers Artix-7). Have the `async-fifo-cdc/` folder on disk. Nothing else is needed to start.

### 2. Create the Project

Launch Vivado → **Create Project** → next through to **RTL Project**, and leave "Do not specify sources at this time" unchecked so you can add them now. For the part, pick any Artix-7/Zynq device; the README suggests `xc7a35tcpg236-1` (the Basys3 part). The specific part only matters later for utilization percentages and device-specific timing.

### 3. Add Design Sources

**Add Sources → Add or create design sources** → add all eleven `files/*.v` files. Vivado will parse them and build the hierarchy; `async_fifo_top` should appear as the natural top of the ten-module tree, with `naive_cdc_bridge` sitting separately as an unreferenced module (that's expected — leave it).

### 4. Add the Simulation Source

**Add Sources → Add or create simulation sources** → add `files/tb_async_fifo.sv` only. This keeps it out of synthesis. Vivado auto-detects `.sv` as SystemVerilog.

### 5. Set the Tops

In the Sources panel, set `async_fifo_top` as the synthesis/implementation top (right-click → **Set as Top**). Under the Simulation Sources set, set `tb_async_fifo` as the simulation top. These are two independent "top" settings and both must be right.

### 6. Run Behavioral Simulation

**Flow Navigator → Run Simulation → Run Behavioral Simulation**. Let it run to completion (the testbench calls `$finish` on its own after the random test drains — roughly 100+ µs of sim time). In the Tcl console / simulation log, confirm you see the eight `METRIC:` lines and that `SCOREBOARD_MISMATCHES = 0`. Also note `COVERAGE_PCT` here — this is where the real coverage number appears, since XSIM models covergroups.

### 7. Capture the Waveform

In the waveform viewer, add the signals (`wptr_gray`, `rptr_gray`, `full`, `empty`, `almost_full`, `wr_occupancy`) and screenshot for the design doc. Then find the auto-generated `async_fifo_waveform.vcd` — it lands under `<project>.sim/sim_1/behav/xsim/`. Copy it somewhere convenient.

### 8. Run the Python Post-Processing

```bash
pip install vcdvcd matplotlib
python scripts/vcd_parser.py <path-to>/async_fifo_waveform.vcd
```

It writes `occupancy_vs_time.png`, `pointer_trajectory.png`, and `flag_timeline.png`, and prints max occupancy and full-assertion counts. Confirm those agree with the testbench's `MAX_OCCUPANCY` and `FULL_ASSERT_COUNT`.

### 9. Add Constraints and Run Synthesis

**Add Sources → Add or create constraints** → `files/async_fifo_top.xdc` (the two `create_clock` lines plus `set_clock_groups -asynchronous`). Then **Run Synthesis**. This is where the design is turned into a gate/LUT netlist.

### 10. Run Implementation

After synthesis, **Run Implementation** (place and route). When it finishes:

- Open the **Timing Summary** report and record WNS and WHS — with the two clocks properly declared asynchronous these should be clean/positive. This gives metrics 6 and 7 (synchronized WNS, and Fmax, derived from the achieved period on the limiting path).
- Open the **Utilization Report** for LUT/FF/BRAM — metric 9.

### 11. Run the CDC Report

**Reports → Report CDC** on the implemented design. This is a structural check separate from timing and makes a strong second screenshot showing the crossings are properly synchronized.

### 12. The "Before" Comparison Run

Create a second synthesis run (**Design Runs → add run**) whose only source is `files/naive_cdc_bridge.v`, with `files/naive_cdc_bridge.xdc` — same two `create_clock` lines but **no** `set_clock_groups`. Set `naive_cdc_bridge` as top for that run. Because the async grouping is missing, Vivado analyzes the single-flop crossing as if it were a synchronous path and reports a large negative WNS. Screenshot that number (metric 5) and run Report CDC on it too, so you have the before/after pair that tells the whole CDC story.

### 13. MTBF by Hand

Using the resolution time from the synchronized Timing Summary (roughly one receiving-clock period minus setup) and published or device τ/T0 values, compute MTBF with the formula in Section 8.5 of the spec. State clearly in the doc whether your τ/T0 are device-verified or a cited conservative value — metric 8.

---

## Batch Tcl Scripting (Non-Interactive)

`scripts/build_vivado.tcl` rebuilds the entire flow headless — no GUI required. It creates the project, runs simulation, synthesis, implementation, all reports, and the separate naive "before" run, all driven by variables at the top of the script.

### Basic Usage

From the project root (`FIFO-CDC/`), or use the absolute script path if you start Vivado elsewhere:

```bash
vivado -mode batch -source c:/KarDRIVE/Projects/Verilog/FIFO-CDC-Proj/FIFO-CDC/scripts/build_vivado.tcl
```

To override the target part or skip stages, pass positional args — `part`, `run_sim`, `run_impl`, `run_naive`:

```bash
vivado -mode batch -source c:/KarDRIVE/Projects/Verilog/FIFO-CDC-Proj/FIFO-CDC/scripts/build_vivado.tcl -tclargs xc7z020clg400-1 1 1 0
```

That example targets a Zynq part and skips the naive run.

### Where the Outputs Land

| Output | Location |
| --- | --- |
| Testbench `METRIC:` lines | `vivado.log` in your launch directory — pull with `grep METRIC: vivado.log` |
| WNS, WHS, computed Fmax | Printed to console at the end of the impl and naive sections |
| Report files | `build/reports/` (`impl_timing_summary.rpt`, `impl_utilization.rpt`, `impl_cdc.rpt`, `naive_timing_summary.rpt`, etc.) |
| Waveform | Copied to `build/async_fifo_waveform.vcd`; the script prints the exact Python command to run on it |

### Design Decisions

**No bitstream.** The flow stops at implementation plus reports. Every metric in the contract (WNS, Fmax, utilization, CDC, MTBF inputs) is available post-implementation, and skipping bitstream generation means unconstrained-I/O DRC checks never block the run — no pin-placement XDC needed just to get numbers.

**Fmax derivation.** The console printout computes `1000 / (10.0 − WNS)` for the write-clock domain as a quick figure. For the authoritative number, read `impl_timing_summary.rpt` directly, since the limiting path could be in either clock domain.

**Naive run is synthesis-only.** The naive bridge only goes through synthesis, not implementation. Synthesis with the missing `set_clock_groups` is already enough for Vivado to analyze the crossing as synchronous and report the large negative slack — and it sidesteps any place-and-route fuss on a two-flop design.

**Caveat.** The script's Tcl control flow, path handling, and WNS/Fmax arithmetic have been validated with stubbed commands. The actual Vivado command behavior depends on your installed version. These are all stable, long-standing commands, so it should run clean — but if a `launch_simulation` runtime property or a `report_cdc` option ever complains on your specific version, those are isolated lines you can adjust without touching the rest.

---

After that, transcribe the numbers into `docs/metrics.md` (leaving anything a run hasn't yet produced blank) and you have the full contract filled: two directed tests plus a 10,000-transaction randomized run with coverage, the backpressure watermark accuracy, the before/after WNS pair, Fmax, MTBF, and utilization.

### PowerShell Quick Run

```powershell
& ..\.venv\Scripts\Activate.ps1
Set-Location .\scripts
python .\vcd_parser.py
```
