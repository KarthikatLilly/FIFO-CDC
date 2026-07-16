# Metrics — Resume Contract

> Fill each value from the stated source after a Vivado run. **Do not fabricate
> any value** — leave it blank until the corresponding run produces it.

| # | Metric | Source | Value |
|---|--------|--------|-------|
| 1 | Random transactions run, 0 mismatches | `tb_async_fifo.sv` METRIC prints (`TOTAL_WRITES_ACCEPTED`, `SCOREBOARD_MISMATCHES`) | writes = 1965, mismatches = 0 |
| 2 | Functional coverage % | `COVERAGE_PCT` METRIC print | 100.00 % |
| 3 | Max occupancy reached / DEPTH | `MAX_OCCUPANCY` print + Python cross-check | 16 / 16 |
| 4 | Backpressure watermark accuracy | `ALMOST_FULL_ASSERT_AT_OCC` / `..._DEASSERT_AT_OCC` prints | assert @ 14, deassert @ 10 (expect 14 / 10) |
| 5 | WNS — naive single-flop crossing | Vivado Timing Summary, naive run | -0.395 ns |
| 6 | WNS — synchronized design | Vivado Timing Summary, top run | 6.036 ns |
| 7 | Fmax achieved post-implementation | Vivado Timing Summary | 252.27 MHz (wclk domain) |
| 8 | Synchronizer MTBF (years) | Section 8.5 hand calc | ~1.4e9 years (estimate, cited τ/T0) |
| 9 | LUT / FF / BRAM utilization | Vivado Utilization Report (`results/impl_utilization.rpt`) | LUT 38/53200 (0.07%, of which 32 logic + 6 memory), FF 54/106400 (0.05%), BRAM 0/140 (0.00% — `fifomem` maps to distributed RAM, not BRAM) |
| 10 | Directed + randomized test scenarios | Testbench structure | 2 directed + 1 randomized (10,000-cycle) |
| 11 | report_cdc — synchronized design | Vivado Report CDC (`results/cdc_synchronized.rpt`) | 18 endpoints total (13 wclk→rclk, 5 rclk→wclk), all Safe, 0 Unsafe, 0 Unknown (10 flagged "No ASYNC_REG" — advisory, see design_doc.md §9) |
| 12 | report_cdc — naive design | Vivado Report CDC (`results/cdc_naive.rpt`) | Empty — "All paths are Safely Timed," 0 violations. This is expected, not a pass: the missing `set_clock_groups -asynchronous` in `naive_cdc_bridge.xdc` means Vivado never classifies the crossing as CDC in the first place; the naive bridge's failure shows up in STA (row 5) instead — see design_doc.md §4.1 |

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
