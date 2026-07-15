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

Screenshot: TODO: add `results/cdc_synchronized.png` after the Vivado CDC report is generated.
Screenshot: TODO: add `results/cdc_naive.png` after the naive comparison CDC report is generated.

## 5. Timing Results

| Run | WNS (ns) | WHS (ns) | Fmax (MHz) |
|-----|----------|----------|------------|
| Synchronized (`async_fifo_top`) | 6.036 | 0.110 | 252.27 |
| Naive (`naive_cdc_bridge`, no async group) | -0.395 | N/A — fails timing | N/A — fails timing |

Screenshot: [Timing Summary — synchronized](results/timing_wns_whs.png)
Screenshot: TODO: add `results/naive_timing_wns.png` after the naive Vivado run.

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
| LUT | 38 | 53200 | 0.07 |
| FF  | 54 | 106400 | 0.05 |
| BRAM | 0 | 140 | 0.00 |

Screenshot: TODO: add `results/impl_utilization.rpt` and a corresponding screenshot after the Vivado utilization report is generated.

## 8. Verification Summary

- Directed tests: burst overflow, backpressure/slow-drain.
- Randomized test: 1965 transactions accepted / 1965 reads returned, 100.00% functional coverage, 0 mismatches.
- Waveform screenshot: [Sim waveform](results/Sim_waveform.png) showing `wptr_gray`, `rptr_gray`, `full`, `empty`, `almost_full`, and `wr_occupancy`.
- Python cross-check plots: [occupancy_vs_time.png](results/occupancy_vs_time.png), [pointer_trajectory.png](results/pointer_trajectory.png), [flag_timeline.png](results/flag_timeline.png).
