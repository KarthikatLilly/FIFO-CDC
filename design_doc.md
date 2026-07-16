# Async FIFO CDC Bridge — Design Document

> Template. Fill bracketed `[ ... ]` items after the first Vivado run.
> Attach screenshots where noted.

## 1. Overview

A parameterizable dual-clock asynchronous FIFO that safely moves data from a
fast write domain (`wclk`, 100 MHz) to a slow read domain (`rclk`, ~37 MHz).
It follows the Cummings dual-clock architecture: binary+Gray pointer counters,
Gray-coded pointer crossing through double-flop synchronizers, registered
full/empty flags, and a per-domain reset synchronizer. A hysteresis
backpressure controller raises `almost_full`/`stall` before the FIFO overflows.

A standalone, intentionally broken single-flop crossing (`naive_cdc_bridge.v`)
is included only to produce a "before" static-timing number for contrast.

## 2. Architecture

```
        wclk domain                         rclk domain
   ┌───────────────────┐               ┌───────────────────┐
   │  wptr_full        │  wptr_gray    │  rptr_empty       │
   │  (gray_counter,   ├──────────────►│  (gray_counter,   │
   │   full, occupancy)│   sync_w2r    │   empty)          │
   │        ▲          │◄──────────────┤        │          │
   │        │ rptr_gray│   sync_r2w    │        │          │
   │  backpressure_ctrl│               │        ▼          │
   └────────┬──────────┘               └────────┬──────────┘
            │ wr_en_gated                        │ rd_en_gated
            ▼                                    ▼
                        fifomem (dual-port)
```

- Reset: single async `rst_n` → `rst_sync` per domain → `wrst_n_sync`,
  `rrst_n_sync` (async assert, sync de-assert).
- Only the Gray-coded pointers cross domains (one-bit-change property makes
  multi-bit double-flop synchronization safe).

## 3. Parameter Justification

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `DATA_WIDTH` | 8 | Byte-oriented payload; kept small for a compact demonstrator while remaining fully parameterized. |
| `ADDR_WIDTH` | 4 (DEPTH 16) | Small enough to wrap often in simulation, large enough to exercise occupancy and backpressure behavior clearly. |
| `SYNC_STAGES` | 2 | Two flops are the standard metastability-hardening depth; the MTBF estimate in Section 6 shows that is more than sufficient here. |
| `ALMOST_FULL_HI` | 14 | Leaves 2 slots of write-latency headroom below full so an upstream producer can react to `stall` before overflow. |
| `ALMOST_FULL_LO` | 10 | A 4-deep hysteresis band prevents `almost_full` from chattering around the threshold. |

## 4. Clocking / CDC Strategy

- `wclk` = 10.000 ns, `rclk` = 27.000 ns, non-integer ratio.
- Constrained with `create_clock` + `set_clock_groups -asynchronous`.
- Gray pointers + 2-stage synchronizers per direction.

Screenshot: [Report CDC — synchronized](results/cdc_synchronized.png) ([raw report](results/cdc_synchronized.rpt))
Screenshot: [Report CDC — naive](results/cdc_naive.png) ([raw report](results/cdc_naive.rpt))

### 4.1 Why the naive report_cdc is empty, not "unsafe"

`naive_cdc_bridge.xdc` deliberately omits `set_clock_groups -asynchronous` (see
§5). Without that constraint, Vivado does not know `wclk` and `rclk` are
unrelated, so it treats the crossing as a related/synchronous path and times it
with ordinary setup/hold analysis instead of flagging it as a clock-domain
crossing. `report_cdc` on that design (`results/cdc_naive.rpt`) is therefore
empty — "All paths are Safely Timed," 0 violations — because from `report_cdc`'s
point of view there is no CDC to analyze in the first place.

The danger of the naive bridge does not disappear; it just shows up in a
different report. It surfaces as a static-timing failure instead: WNS
-0.395 ns across 8 failing setup endpoints on the `wclk`→`rclk` path into
`rd_data_bad_reg[*]` (§5), because Vivado is holding an unsynchronized,
single-flop inter-clock path to a synchronous 1.000 ns setup requirement it
cannot actually meet.

`report_cdc` and static timing analysis (STA) are two different lenses on the
same design:

- With the `set_clock_groups -asynchronous` constraint **missing** (the naive
  run): STA fails (negative WNS) because the tool wrongly assumes a timing
  relationship between the clocks, but `report_cdc` is empty/clean because it
  never gets flagged as an async crossing at all.
- With the constraint **present** (the synchronized run): STA is clean (positive
  WNS, §5) because the crossing is correctly excluded from synchronous timing,
  and `report_cdc` independently classifies all 18 real crossings (§4.2) as
  `Safe`, because they go through proper Gray-coded, multi-flop synchronizers.

You cannot get both a flagged-unsafe CDC report and a failing WNS from a single
naive run with this constraint style — the missing constraint determines which
one of the two lenses catches the problem.

### 4.2 Synchronized report_cdc summary

`results/cdc_synchronized.rpt` reports 18 endpoints total across the two
pointer-crossing directions, all classified `Safe`, 0 `Unsafe`, 0 `Unknown`:

| From → To | Endpoints | Safe | Unsafe | Unknown | No ASYNC_REG |
|-----------|-----------|------|--------|---------|--------------|
| wclk → rclk | 13 | 13 | 0 | 0 | 5 |
| rclk → wclk | 5 | 5 | 0 | 0 | 5 |

The "No ASYNC_REG" column (10 endpoints total, 5 per direction) is a
best-practice advisory, not a safety failure — see §9.

## 5. Timing Results

| Run | WNS (ns) | WHS (ns) | Failing endpoints | Fmax (MHz) |
|-----|----------|----------|--------------------|------------|
| Synchronized (`async_fifo_top`) | +6.036 | +0.110 | 0 (all constraints met) | 252.27 (wclk domain) |
| Naive (`naive_cdc_bridge`, no async group) | -0.395 | -0.093 | 8 setup / 8 hold | N/A — fails timing |

The naive failure is not a large violation — it is a small, single-flop-crossing
negative slack (-0.395 ns setup) driven by the clock-edge relationship Vivado
assumes once `set_clock_groups -asynchronous` is missing (a 1.000 ns setup
requirement from `rclk` rise@81.000 ns vs. `wclk` rise@80.000 ns) and trivial
logic (0 logic levels, `data_reg_reg[*]/C` → `rd_data_bad_reg[*]/D` direct).
See `results/naive_timing_summary.rpt` for the full path detail and
`results/naive_wns.txt` for the headline number.

This is the before/after story: the naive bridge fails STA and is invisible to
`report_cdc` (§4.1) because of the missing constraint; the synchronized design
passes STA cleanly and has all 18 of its real crossings independently verified
`Safe` by `report_cdc` (§4.2). Demonstrating both halves of that story —
STA and CDC structural analysis answering two different questions — is the
point of keeping the naive bridge in the repo.

Screenshot: [Timing Summary — synchronized](results/timing_wns_whs.png), [Clock Summary](results/timing_clock_summary.png)
Report: [naive_timing_summary.rpt](results/naive_timing_summary.rpt), [naive_wns.txt](results/naive_wns.txt)

## 6. MTBF Calculation

Formula (Section 8.5):

```
MTBF = exp(t_r / tau) / (T0 × f_clk × f_data)
```

Worst-case domain: `sync_r2w` is captured by the faster receiving clock, `wclk`, so that is the conservative case to use.

| Input | Value | Notes |
|------|-------|------|
| `t_r` | 9.5 ns | Conservative estimate: 10.0 ns clock period minus about 0.5 ns of setup/clock-to-Q margin. |
| `tau` | 0.20 ns | Conservative cited 7-series-class constant, not device-verified for this exact silicon. |
| `T0` | 1e-11 s | Conservative cited constant, not device-verified for this exact silicon. |
| `f_clk` | 100e6 Hz | Receiving clock (`wclk`). |
| `f_data` | 10e6 Hz | Conservative asynchronous event rate. |

Worked estimate:

1. `exp(9.5 / 0.20) = exp(47.5) ≈ 4.3e20`
2. Denominator `= 1e-11 × 1e8 × 1e7 = 1e4`
3. `MTBF ≈ 4.3e20 / 1e4 = 4.3e16 s`
4. `4.3e16 s / 3.156e7 s/yr ≈ 1.4e9 years`

**MTBF ≈ 1.4e9 years**. `tau` and `T0` above are conservative cited constants, not device-verified for this specific FPGA, so this is an order-of-magnitude engineering estimate. The takeaway is the point: the 2-flop synchronizer is far more than sufficient at these frequencies.

## 7. Utilization

| Resource | Used | Available | % |
|----------|------|-----------|---|
| Slice LUTs (total) | 38 | 53200 | 0.07 |
| — LUT as Logic | 32 | 53200 | 0.06 |
| — LUT as Memory (Distributed RAM) | 6 | 17400 | 0.03 |
| Slice Registers (FF) | 54 | 106400 | 0.05 |
| Block RAM Tile | 0 | 140 | 0.00 |
| Bonded IOB | 31 | 200 | 15.50 |
| BUFGCTRL | 2 | 32 | 6.25 |

Source: [`results/impl_utilization.rpt`](results/impl_utilization.rpt).

The 6 LUTs mapped as memory ("LUT as Distributed RAM") are `fifomem`: a 16×8
(128-bit) array is far below Xilinx's block-RAM threshold, so Vivado maps it to
distributed RAM (LUTRAM) built from `RAMD32`/`RAMS32` primitives rather than a
`RAMB18`/`RAMB36` tile. This is expected and correct — Block RAM Tile usage is
0, confirming no BRAM was needed or consumed.

## 8. Verification Summary

- Directed tests: burst overflow, backpressure/slow-drain.
- Randomized test: 1965 transactions accepted / 1965 reads returned, 100.00% functional coverage, 0 mismatches.
- Backpressure watermark: `almost_full` asserts at exactly occupancy 14 and deasserts at exactly occupancy 10, matching `ALMOST_FULL_HI`/`ALMOST_FULL_LO` (§3).
- Waveform screenshot: [Sim waveform](results/Sim_waveform.png) showing `wptr_gray`, `rptr_gray`, `full`, `empty`, `almost_full`, and `wr_occupancy`.
- Python cross-check plots: [occupancy_vs_time.png](results/occupancy_vs_time.png), [pointer_trajectory.png](results/pointer_trajectory.png), [flag_timeline.png](results/flag_timeline.png).

## 9. Known improvements / future work

These are documented as noted improvements, not implemented here — applying
either would change the netlist and require re-running Vivado synthesis/
implementation, which would make the currently committed reports under
`results/` stale. RTL and constraints are left untouched.

1. **Tag synchronizer registers with `ASYNC_REG`.** `results/cdc_synchronized.rpt`
   flags 10 endpoints (5 per direction, §4.2) as "No ASYNC_REG" — Vivado's
   best-practice advisory that the synchronizer chain's flip-flops aren't marked
   so the placer knows to pack them tightly and avoid inserting extra logic/skew
   between stages. The fix is to add the attribute to the synchronizer flops in
   `sync_r2w.v` and `sync_w2r.v`, e.g.:
   ```verilog
   (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] stage1;
   (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] stage2;
   ```
   This is a placement hint, not a functional change — it does not alter
   simulation behavior, only place-and-route of the existing flops.

2. **Second naive run with `set_clock_groups -asynchronous` added.** Adding the
   async grouping to `naive_cdc_bridge.xdc` would flip which lens catches the
   naive bridge's problem (§4.1): STA would go clean (the crossing is excluded
   from synchronous timing), but `report_cdc` would then classify the single,
   un-Gray-coded, single-flop crossing into `rd_data_bad` as `Unsafe` (a CDC-1
   class violation — a data bus with no synchronization at all). Running that
   variant alongside the current one would give a complete before/after matrix
   (constraint present/absent × STA/CDC result) and make the complementary
   failure mode visible in `report_cdc` output as well as in timing.
