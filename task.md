# TASK.md — Remaining Work for the Async FIFO CDC Bridge

**Audience:** GitHub Copilot (agent mode) running on the project owner's machine.
**Goal:** Finish the remaining verification/implementation deliverables and fill
in all documentation. The RTL is complete and *already verified and implemented
with clean timing.* What's left is (a) one more Vivado run for the "before"
comparison, (b) reading a few numbers out of Vivado reports, (c) a hand
calculation, and (d) transcribing everything into the docs.

> **IMPORTANT — read this first.** Some tasks are pure file/edit/calculation work
> that you (Copilot) can and should do directly. Others require running the
> Xilinx **Vivado GUI**, which you **cannot** do — those must be performed
> manually by a human, and their outputs (report files + screenshots) must be
> saved into the repo before you can complete the dependent doc tasks. Each task
> below is tagged **[COPILOT]** or **[HUMAN — VIVADO GUI]**. Do not fabricate any
> number that is supposed to come from a Vivado run — if the report file or value
> is missing, leave the placeholder and add a `TODO:` note instead.

---

## 0. Environment & repo assumptions (verify before starting)

- OS: Windows. Vivado is installed and licensed on this machine (evidence: the
  design is already implemented for part `xc7z020clg484-1`, a ZedBoard Zynq-7000).
- Project files were **restructured** from the original three-folder layout into
  a flatter one. Confirm the actual current layout with a directory listing
  before editing paths. The known/expected layout is:

  ```
  <repo-root>/
    files/                     <- all RTL *.v AND both *.xdc now live here
      async_fifo_top.v
      rst_sync.v  gray_counter.v  gray2bin.v  sync_r2w.v  sync_w2r.v
      wptr_full.v  rptr_empty.v  fifomem.v  backpressure_ctrl.v
      naive_cdc_bridge.v
      async_fifo_top.xdc
      naive_cdc_bridge.xdc
    tb_async_fifo.sv           <- testbench at repo root
    scripts/
      build_vivado.tcl
      vcd_parser.py
    docs/
      design_doc.md
      metrics.md
    results/                   <- screenshots live here (create if missing)
      post_implementation_report.png
      rtl_schematic.png
      timing_clock_summary.png
      timing_wns_whs.png
  ```

  **First action:** run a recursive listing and reconcile the real paths with the
  above. If the folder names differ (e.g. `src/` instead of `files/`, or a
  `results/`/`reports/` variant), adapt all path edits in the tasks below to the
  real names. Note in your PR description any deviation you found.

### Known-good values already captured (use these; do NOT recompute or overwrite)

From the completed behavioral simulation:

| Metric | Value |
|---|---|
| TOTAL_WRITES_ACCEPTED | 1965 |
| TOTAL_READS_VALID | 1965 |
| SCOREBOARD_MISMATCHES | 0 |
| MAX_OCCUPANCY | 16 / 16 |
| FULL_ASSERT_COUNT | 1756 |
| ALMOST_FULL_ASSERT_COUNT | 3 |
| EMPTY_ASSERT_COUNT | 3 |
| COVERAGE_PCT | 100.00 |
| Watermark assert / deassert | 14 / 10 (exact) |

From the completed implementation (`impl_1`, part `xc7z020clg484-1`):

| Metric | Value |
|---|---|
| WNS (setup) — synchronized design | **6.036 ns** |
| WHS (hold) — synchronized design | **0.110 ns** |
| TNS / THS | 0.000 / 0.000 |
| Failing endpoints | 0 (all constraints met) |
| WPWS (pulse width) | 3.750 ns |
| Clocks | wclk 10.000 ns / 100.000 MHz, rclk 27.000 ns / 37.037 MHz |
| Total on-chip power | 0.11 W (dynamic 0.006 W) |
| Utilization (post-impl, %) | LUT 1%, LUTRAM 1%, FF 1%, IO 16%, BUFG 6% |

---

## Summary: which tasks need the GUI vs. which you can do now

| # | Task | Who | Blocks |
|---|------|-----|--------|
| 1 | Fix `build_vivado.tcl` paths for the new `files/` layout | **[COPILOT]** | — |
| 2 | Make README Vivado command portable (remove hardcoded absolute path) | **[COPILOT]** | — |
| 3 | Fix `vcd_parser.py` axis label (ps vs ns) | **[COPILOT]** | — |
| 4 | MTBF hand-calculation → write into `design_doc.md` §6 | **[COPILOT]** | — |
| 5 | Fill `design_doc.md` sections that only use already-known numbers | **[COPILOT]** | — |
| 6 | **Naive-bridge synthesis run → get WNS (metric #5)** | **[HUMAN — VIVADO GUI]** | 8, 10 |
| 7 | **Fmax per-clock lookup (metric #7)** | **[HUMAN — VIVADO GUI]** | 8, 10 |
| 8 | **Utilization absolute counts + confirm no-BRAM (metric #9)** | **[HUMAN — VIVADO GUI]** | 8, 10 |
| 9 | **Report CDC on synchronized + naive designs (screenshots)** | **[HUMAN — VIVADO GUI]** | 10 |
| 10 | Fill remaining `metrics.md` / `design_doc.md` from GUI outputs | **[COPILOT]** (after 6–9) | — |

Do all **[COPILOT]** tasks that are unblocked (1–5) immediately. Tasks 6–9 must
be done by a human in Vivado; once their report files/screenshots are committed,
finish task 10.

---

## Task 1 — [COPILOT] Fix `build_vivado.tcl` for the new folder layout

The script currently globs the old split layout and will fail. Update the source
collection so it works with the flattened `files/` layout **and** the new
testbench location.

**File:** `scripts/build_vivado.tcl`

**What to change:** the three `add_files` blocks and any `glob`/path joins.

- RTL design sources: was `glob [file join $proj_root rtl *.v]` → change to
  `glob [file join $proj_root files *.v]`.
  - **Caution:** this glob now also picks up `naive_cdc_bridge.v`. That's fine for
    the main project (it stays an unreferenced module), but keep `set_property top
    async_fifo_top [current_fileset]` so the top is explicit.
- Testbench sim source: was `[file join $proj_root tb tb_async_fifo.sv]` → change
  to `[file join $proj_root tb_async_fifo.sv]`.
- Top constraint: was `[file join $proj_root constraints async_fifo_top.xdc]` →
  `[file join $proj_root files async_fifo_top.xdc]`.
- Naive comparison section: RTL `[file join $proj_root files naive_cdc_bridge.v]`,
  XDC `[file join $proj_root files naive_cdc_bridge.xdc]`.
  - For the naive project's synthesis fileset, make sure only
    `naive_cdc_bridge.v` is added (do **not** glob `files/*.v`, or you'll pull the
    whole design in). Add that single file explicitly.

**Acceptance:** a dry read shows every referenced path resolves against the real
tree. If you can run `tclsh` (not Vivado) with the Vivado commands stubbed, the
control flow should parse without path errors. Do **not** attempt to actually
launch Vivado.

---

## Task 2 — [COPILOT] Make the README Vivado command portable

The README's example was changed to a machine-specific absolute path
(`c:/KarDRIVE/Projects/Verilog/FIFO-CDC-Proj/...`). Replace it with a
repo-relative command so it works on any machine:

```
vivado -mode batch -source scripts/build_vivado.tcl
```

Optionally document the `-tclargs` overrides (part, run_sim, run_impl, run_naive)
already supported by the script. **File:** `README.md`. Search for the absolute
path and any `c:/` occurrences and replace them.

**Acceptance:** no absolute/user-specific filesystem paths remain in `README.md`.

---

## Task 3 — [COPILOT] Fix the VCD plot axis label (ps vs ns)

`scripts/vcd_parser.py` labels the time axis `"time (ns)"`, but VCD timestamps
are emitted in the timescale **precision** unit, which for this project is **1 ps**
(`` `timescale 1ns/1ps ``). So the numbers are picoseconds, not nanoseconds, and
the current label is off by 1000×.

**Preferred fix (accurate):** read the `$timescale` from the VCD header and scale
timestamps to nanoseconds before plotting, keeping the `"time (ns)"` label
correct. `vcdvcd` exposes the timescale (e.g. `vcd.timescale`); if the API
differs in the installed version, parse the `$timescale ... $end` line from the
raw file. Divide all times by (precision_in_ns) so, e.g., 10000 ps → 10 ns.

**Minimum-effort fallback (acceptable):** if reliably reading the timescale is
awkward, relabel the axis to `"time (ps)"` and add a one-line comment explaining
the unit. Do **not** leave it labeled "ns" with ps values.

**Acceptance:** regenerating the plots against the existing
`async_fifo_waveform.vcd` yields an x-axis whose maximum reads ~104,800 ns (if
scaled) or ~1.048e8 ps (if relabeled) — internally consistent either way.
(Only run this if `vcdvcd` + `matplotlib` are installed; otherwise just make the
code correct and note that plots need regenerating.)

---

## Task 4 — [COPILOT] MTBF calculation → `design_doc.md` §6 (metric #8)

Compute the synchronizer MTBF and write it into `docs/design_doc.md` Section 6.
Use the standard formula already in the doc:

```
MTBF = exp(t_r / tau) / (T0 * f_clk * f_data)
```

**Worst-case domain:** the read→write synchronizer (`sync_r2w`) is clocked by the
**faster** clock, `wclk` (100 MHz), so that is the worst case — use it.

**Inputs (label clearly as cited/assumed, NOT device-measured):**
- `t_r` = metastability resolution time available ≈ (wclk period) − (setup +
  clock-to-Q of the first sync flop). Use a conservative
  `t_r ≈ 10.0 ns − 0.5 ns = 9.5 ns`. (If the owner wants precision, they can
  substitute the exact `t_su` from the FF's data sheet; note this.)
- `tau` = resolution time constant. Cited 7-series-class value: **≈ 0.20 ns**.
- `T0` = **≈ 1e-11 s** (cited).
- `f_clk` = receiving clock = **100e6 Hz** (wclk).
- `f_data` = asynchronous event (pointer-change) rate. Conservative: **≈ 10e6 Hz**.

**Worked result (verify the arithmetic yourself and show the steps):**
- `exp(9.5 / 0.20) = exp(47.5) ≈ 4.3e20`
- denominator `= 1e-11 * 1e8 * 1e7 = 1e4`
- `MTBF ≈ 4.3e20 / 1e4 = 4.3e16 s`
- `4.3e16 s / 3.156e7 s/yr ≈ 1.4e9 years` (~1.4 billion years)

Write the formula, the input table, the steps, and the final figure into §6.
**Mandatory caveat to include verbatim in spirit:** state that `tau`/`T0` are
conservative cited constants, not device-verified for this specific silicon, so
the MTBF is an order-of-magnitude engineering estimate. The takeaway — MTBF is
astronomically large, i.e. the 2-flop synchronizer is more than sufficient — is
the point; do not overstate precision.

**Acceptance:** §6 has no `[ ]` placeholders; the number and its caveat are
present; metrics.md row #8 is updated with the same figure and an "(estimate,
cited τ/T0)" note.

---

## Task 5 — [COPILOT] Fill `design_doc.md` sections using already-known numbers

Complete every bracketed `[ ]` in `docs/design_doc.md` that depends only on
values already known (see the tables in §0). Specifically:

- **§3 Parameter Justification** — fill the rationale column. Suggested, accurate
  content (rephrase in your own words, keep it technical and honest):
  - `DATA_WIDTH = 8`: byte-oriented payload; arbitrary/parameterizable, chosen for
    a compact demonstrator.
  - `ADDR_WIDTH = 4 (DEPTH 16)`: small enough to exercise wraparound many times in
    simulation, large enough to show meaningful occupancy/backpressure behavior.
  - `SYNC_STAGES = 2`: two flops give the standard metastability-hardening depth;
    the MTBF calc (§6) confirms it is more than sufficient at these frequencies.
  - `ALMOST_FULL_HI = 14`: leaves 2 slots of write-latency headroom below full (16)
    so an upstream producer has time to react to `stall`.
  - `ALMOST_FULL_LO = 10`: a 4-deep hysteresis band prevents `almost_full`
    chattering around the threshold.
- **§4 Clocking / CDC Strategy** — already mostly written; just add the two Report
  CDC screenshot references once task 9 provides them (leave a `TODO:` if not yet
  available).
- **§5 Timing Results** — fill the *synchronized* row now: WNS `6.036`, WHS
  `0.110`, Fmax = **TODO from task 7** (leave the naive row blank until task 6).
- **§8 Verification Summary** — fill: randomized test = **1965** transactions,
  **100%** functional coverage, **0** mismatches; two directed tests (burst
  overflow, backpressure/slow-drain); list the three Python plots; reference the
  simulation waveform screenshot (`results/Sim_waveform.png` if present).

**Acceptance:** the only remaining `[ ]`/`TODO:` markers in `design_doc.md` are
the ones genuinely blocked on tasks 6–9 (naive WNS, Fmax, utilization counts, CDC
screenshots).

---

## Task 6 — [HUMAN — VIVADO GUI] Naive-bridge synthesis → WNS (metric #5)

**Why a human:** this launches Vivado synthesis; Copilot cannot run it.

This is the single most important missing result — it produces the "before"
number that contrasts with the synchronized design's clean +6.036 ns and proves
why the Gray-code + double-flop synchronizers matter.

**Two ways to do it; pick one:**

**Option A — GUI, new scratch project:**
1. Vivado → Create Project → RTL project, part `xc7z020clg484-1`.
2. Add design source: `files/naive_cdc_bridge.v` only. Set `naive_cdc_bridge` as
   top.
3. Add constraint: `files/naive_cdc_bridge.xdc` (this file **deliberately omits**
   `set_clock_groups -asynchronous` — do not "fix" it; the omission is the point).
4. Run Synthesis. (Implementation not required; synthesis timing already shows the
   violation.)
5. Open Synthesized Design → Timing → Design Timing Summary. Record **WNS** — it
   should be a large **negative** number.
6. Screenshot the timing summary → save as `results/naive_timing_wns.png`.

**Option B — Vivado Tcl console (faster, reproducible):** paste this into the
Vivado Tcl console (adjust `<repo-root>`):
```tcl
create_project naive_demo <repo-root>/build/naive_demo -part xc7z020clg484-1 -force
add_files -norecurse <repo-root>/files/naive_cdc_bridge.v
set_property top naive_cdc_bridge [current_fileset]
add_files -fileset constrs_1 -norecurse <repo-root>/files/naive_cdc_bridge.xdc
launch_runs synth_1 -jobs 4
wait_on_run synth_1
open_run synth_1
report_timing_summary -file <repo-root>/results/naive_timing_summary.rpt
puts "NAIVE WNS = [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]"
```
Then commit `results/naive_timing_summary.rpt` and screenshot the console/summary.

**Deliverable for Copilot:** the numeric naive WNS and the report file
`results/naive_timing_summary.rpt` committed to the repo.

**Acceptance:** naive WNS is negative and captured in a committed file/screenshot.

---

## Task 7 — [HUMAN — VIVADO GUI] Fmax per-clock (metric #7)

**Why a human:** requires opening the implemented design in Vivado.

The overall WNS is 6.036 ns, but Fmax must be computed from the *worst path in a
given clock domain*. Determine which clock owns the limiting intra-clock path,
then compute Fmax for the fast domain (wclk), which is the headline number.

**Steps (implemented design already open, or re-open `impl_1`):**
1. Timing window → **Intra-Clock Paths** → expand `wclk` and `rclk`; note each
   group's setup WNS.
2. Or paste into the Tcl console:
   ```tcl
   set wclk_wns [get_property SLACK [get_timing_paths -setup -to [get_clocks wclk] -max_paths 1 -nworst 1]]
   set rclk_wns [get_property SLACK [get_timing_paths -setup -to [get_clocks rclk] -max_paths 1 -nworst 1]]
   puts "wclk WNS=$wclk_wns  -> Fmax=[expr {1000.0/(10.0-$wclk_wns)}] MHz"
   puts "rclk WNS=$rclk_wns  -> Fmax=[expr {1000.0/(27.0-$rclk_wns)}] MHz"
   ```
3. Record both Fmax values and the per-clock WNS.

**Deliverable for Copilot:** the two per-clock WNS values and computed Fmax
numbers (paste into a committed note file, e.g. `results/fmax_note.txt`, or the
PR description).

**Acceptance:** Fmax for the wclk domain is captured; Copilot will put it in
`metrics.md` #7 and `design_doc.md` §5.

---

## Task 8 — [HUMAN — VIVADO GUI] Utilization counts + BRAM check (metric #9)

**Why a human:** requires the Vivado utilization report.

Percentages are known (LUT 1%, LUTRAM 1%, FF 1%, IO 16%, BUFG 6%) but the doc
needs absolute used/available counts, and there's an important detail to confirm.

**Steps:**
1. Implemented design → Reports → Report Utilization, or Tcl:
   ```tcl
   report_utilization -file <repo-root>/results/impl_utilization.rpt
   ```
2. Read the LUT, LUTRAM/SLICEM, FF, BRAM (RAMB36/RAMB18), IO, BUFG rows: used and
   available counts.
3. **Confirm and note:** BRAM used = **0**. The 16×8 (=128-bit) memory is far
   below the block-RAM threshold, so Vivado maps `fifomem` to **distributed RAM
   (LUTRAM)**, not BRAM. This is expected and correct — write a one-line
   explanation for the doc.

**Deliverable for Copilot:** committed `results/impl_utilization.rpt` (Copilot
will parse counts from it) plus a note confirming BRAM = 0.

**Acceptance:** `impl_utilization.rpt` is in the repo; BRAM=0 with the
distributed-RAM explanation is recorded.

---

## Task 9 — [HUMAN — VIVADO GUI] Report CDC on both designs (screenshots)

**Why a human:** `report_cdc` runs inside Vivado.

1. On the **implemented synchronized** design: Reports → Report CDC (or
   `report_cdc -file <repo-root>/results/impl_cdc.rpt`). It should classify the
   pointer crossings as safe multi-flop synchronizers (no critical unsafe
   crossings). Screenshot → `results/cdc_synchronized.png`.
2. On the **naive** project (from task 6): run `report_cdc` there too; it should
   flag the unsynchronized single-flop crossing. Screenshot →
   `results/cdc_naive.png`.

**Deliverable for Copilot:** two committed screenshots + optional `.rpt` files.

**Acceptance:** both CDC reports captured; the contrast (safe vs. flagged) is
visible.

---

## Task 10 — [COPILOT] Fill remaining docs from GUI outputs (after 6–9)

Once the human has committed the outputs from tasks 6–9, complete the docs:

- `docs/metrics.md`:
  - #5 naive WNS ← task 6
  - #7 Fmax ← task 7
  - #9 LUT/FF/BRAM counts (parse `results/impl_utilization.rpt`) ← task 8; include
    the BRAM=0 / distributed-RAM note.
  - Confirm #8 (MTBF) row matches what you wrote in Task 4.
- `docs/design_doc.md`:
  - §4: add the two Report CDC screenshot references (task 9).
  - §5: complete the naive row (WNS from task 6; WHS/Fmax "N/A — fails timing" is
    acceptable for the naive row) and the synchronized Fmax (task 7).
  - §7 Utilization table: fill used/available/% from `impl_utilization.rpt`.
- Verify no stray `[ ]` or `TODO:` remain anywhere in `docs/`.

**Acceptance:** `metrics.md` has all 10 rows filled; `design_doc.md` has no
placeholders; every screenshot referenced in the docs exists in `results/`.

---

## Guardrails (apply to every task)

- **Never invent Vivado numbers.** If a report/value is not yet in the repo, leave
  a `TODO:` and say so in the PR. Only tasks 1–5 can be fully completed without new
  Vivado output.
- **Do not modify RTL** (`files/*.v`) or the testbench logic — they are verified.
  The only code edits in scope are the script/path/label fixes in tasks 1–3.
- **Do not remove the missing `set_clock_groups` from `naive_cdc_bridge.xdc`** —
  that omission is intentional.
- Keep edits minimal and reviewable; one logical change per commit where possible.
- In the PR description, list which tasks were completed, which are blocked on the
  human Vivado tasks, and any path deviations you found in §0.