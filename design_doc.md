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
| `DATA_WIDTH` | 8 | [why] |
| `ADDR_WIDTH` | 4 (DEPTH 16) | [why] |
| `SYNC_STAGES` | 2 | [why 2 flops sufficient for this Fmax/MTBF] |
| `ALMOST_FULL_HI` | 14 | [headroom before full] |
| `ALMOST_FULL_LO` | 10 | [hysteresis band width] |

## 4. Clocking / CDC Strategy

- `wclk` = 10.000 ns, `rclk` = 27.000 ns, non-integer ratio.
- Constrained with `create_clock` + `set_clock_groups -asynchronous`.
- Gray pointers + 2-stage synchronizers per direction.

Screenshot: [Report CDC — synchronized design]
Screenshot: [Report CDC — naive bridge]

## 5. Timing Results

| Run | WNS (ns) | WHS (ns) | Fmax (MHz) |
|-----|----------|----------|------------|
| Synchronized (`async_fifo_top`) | [ ] | [ ] | [ ] |
| Naive (`naive_cdc_bridge`, no async group) | [ ] | [ ] | [ ] |

Screenshot: [Timing Summary — synchronized]
Screenshot: [Timing Summary — naive]

## 6. MTBF Calculation

Formula (Section 8.5):

```
MTBF = e^(t_r / τ) / (T0 × f_clk × f_data)
```

- `t_r` (resolution time available) = [from Timing Summary] ns
- `τ`  = [device/published value, cite source]
- `T0` = [device/published value, cite source]
- `f_clk` = [receiving clock] Hz
- `f_data` = [data toggle rate] Hz
- **MTBF = [M] years**  (state clearly whether τ/T0 are device-verified or a
  cited conservative academic value — do not present as device-verified if it
  is not).

## 7. Utilization

| Resource | Used | Available | % |
|----------|------|-----------|---|
| LUT | [ ] | [ ] | [ ] |
| FF  | [ ] | [ ] | [ ] |
| BRAM | [ ] | [ ] | [ ] |

Screenshot: [Utilization report]

## 8. Verification Summary

- Directed tests: burst overflow, backpressure/slow-drain.
- Randomized test: [N] transactions, [X]% functional coverage, 0 mismatches.
- Waveform screenshot: [wptr_gray, rptr_gray, full, empty, almost_full,
  wr_occupancy].
- Python cross-check plots: `occupancy_vs_time.png`, `pointer_trajectory.png`,
  `flag_timeline.png`.
