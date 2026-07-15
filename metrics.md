# Metrics — Resume Contract

> Fill each value from the stated source after a Vivado run. **Do not fabricate
> any value** — leave it blank until the corresponding run produces it.

| # | Metric | Source | Value |
|---|--------|--------|-------|
| 1 | Random transactions run, 0 mismatches | `tb_async_fifo.sv` METRIC prints (`TOTAL_WRITES_ACCEPTED`, `SCOREBOARD_MISMATCHES`) | writes = 1965, mismatches = 0 |
| 2 | Functional coverage % | `COVERAGE_PCT` METRIC print | 100.00 % |
| 3 | Max occupancy reached / DEPTH | `MAX_OCCUPANCY` print + Python cross-check | 16 / 16 |
| 4 | Backpressure watermark accuracy | `ALMOST_FULL_ASSERT_AT_OCC` / `..._DEASSERT_AT_OCC` prints | assert @ 14, deassert @ 10 (expect 14 / 10) |
| 5 | WNS — naive single-flop crossing | Vivado Timing Summary, naive run | [ ] ns |
| 6 | WNS — synchronized design | Vivado Timing Summary, top run | [ ] ns |
| 7 | Fmax achieved post-implementation | Vivado Timing Summary | [ ] MHz |
| 8 | Synchronizer MTBF (years) | Section 8.5 hand calc | [ ] years |
| 9 | LUT / FF / BRAM utilization % | Vivado Utilization Report | LUT [ ]%, FF [ ]%, BRAM [ ]% |
| 10 | Directed + randomized test scenarios | Testbench structure | 2 directed + 1 randomized (10,000-cycle) |

## Raw METRIC lines captured from the simulation log

```
METRIC: TOTAL_WRITES_ACCEPTED = 1965
METRIC: TOTAL_READS_VALID = 1965
METRIC: SCOREBOARD_MISMATCHES = 0
METRIC: MAX_OCCUPANCY = 16
METRIC: FULL_ASSERT_COUNT = 1756
METRIC: ALMOST_FULL_ASSERT_COUNT = 3
METRIC: EMPTY_ASSERT_COUNT = 3
METRIC: COVERAGE_PCT = 100.00
```
