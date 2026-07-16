# Async FIFO Clock-Domain-Crossing Bridge — The Complete Guide

*A from-scratch explanation of the project, the problem it solves, every RTL
module, what we proved, and a top-10 interview Q&A.*

Repository: `KarthikatLilly/FIFO-CDC` · Target: AMD/Xilinx Zynq-7000
`xc7z020clg484-1` (ZedBoard) · Tool: Vivado 2022.2

---

## 0. How to read this document

This guide assumes **no prior FPGA or digital-design knowledge** and builds up
to the full project. If you already know the basics, skip to Part V (the RTL
walk-through) or Part VI (what we proved). Terms in **bold** on first use are
defined in the Glossary (Part X). The interview Q&A is Part XI.

The through-line of the whole project is a single sentence:

> **Moving a stream of data from a circuit running on one clock to a circuit
> running on a different, unrelated clock is dangerous, and this project builds
> — and proves correct — the standard safe solution (an asynchronous FIFO),
> alongside a deliberately broken version that shows what goes wrong.**

---

## Part I — Foundations from scratch

### 1.1 What an FPGA is

A **Field-Programmable Gate Array (FPGA)** is a chip filled with a large number
of small, reconfigurable hardware resources:

- **Look-Up Tables (LUTs)** — tiny truth tables that can implement any small
  logic function (AND, OR, adders, comparators, etc.).
- **Flip-flops (FFs)** — one-bit memory elements. Each stores a single bit and
  updates it on a clock edge.
- **Block RAM (BRAM)** — dedicated on-chip memory blocks for larger storage.
- **Clock buffers (BUFG)** — special resources that distribute clock signals.
- A programmable **routing fabric** — the wires connecting everything.

Unlike a CPU, an FPGA does not "execute instructions." You **describe a
circuit**, and the FPGA physically rearranges its LUTs, flip-flops, and wires to
*become* that circuit. Once configured, all parts of the circuit operate
**simultaneously and continuously** — this parallelism is the fundamental
difference from software.

### 1.2 What RTL and Verilog are

You describe the circuit in a **Hardware Description Language (HDL)**. This
project uses **Verilog** (the `.v` files) and **SystemVerilog** for the testbench
(the `.sv` file).

The design style is **Register Transfer Level (RTL)**. You describe:

1. **Registers** (flip-flops) that hold state, and
2. **Combinational logic** (LUTs) that computes new values from current ones.

The core idiom is: *"on each rising edge of the clock, register X takes the value
of expression Y."* In Verilog:

```verilog
always @(posedge clk)
    q <= d;      // on every rising clock edge, flip-flop q captures d
```

This is **not** a sequential program. It describes a physical flip-flop that
exists in hardware and updates every clock cycle, forever, in parallel with
everything else.

### 1.3 The clock and synchronous design

A **clock** is a signal that toggles at a fixed frequency (e.g., 100 MHz = 100
million cycles per second = one cycle every 10 nanoseconds). In **synchronous
design**, all flip-flops update on the same clock edge. Between edges,
combinational logic computes the next values; on the edge, they are all captured
at once.

For this to work, every signal must be **stable** at each flip-flop input for a
small window around the clock edge:

- **Setup time (t_su):** the input must be steady for this long *before* the edge.
- **Hold time (t_h):** the input must stay steady for this long *after* the edge.

If the logic between two flip-flops is too slow, the data arrives late and misses
setup — a **timing violation**. The tool's job (see 1.4) is to verify no such
violations exist. The margin by which a path passes is its **slack**.

### 1.4 Vivado and the design flow

**Vivado** is AMD/Xilinx's toolchain. The flow this project uses:

| Stage | What it does | Output |
|-------|--------------|--------|
| **Behavioral Simulation** | Runs the RTL in software; no chip. Checks logic. | Waveforms, pass/fail |
| **Synthesis** | Converts RTL into a netlist of real FPGA primitives (LUTs, FFs). | Gate-level netlist |
| **Implementation** | Places primitives on the chip and routes wires. | Placed & routed design |
| **Static Timing Analysis (STA)** | Checks every path meets setup/hold. | Timing report (WNS/WHS) |
| **Report CDC** | Structurally checks clock-domain crossings for safety. | CDC report |

This project stops before generating a bitstream (programming the physical
board), because every deliverable metric — timing, resource usage, CDC safety —
comes out of implementation and its reports.

---

## Part II — The core problem: crossing clock domains

### 2.1 One clock is easy; two clocks are hard

Inside a **single clock domain**, the tools guarantee correctness: they measure
every path and confirm data always settles before the next edge. Everything is
coordinated by one clock.

A **clock domain** is a set of flip-flops driven by the same clock. When a signal
generated in one domain must be read by flip-flops in a **different** domain whose
clock is **asynchronous** (unrelated frequency, drifting phase), the tools can no
longer guarantee the source is stable at the destination's clock edge. This is a
**Clock Domain Crossing (CDC)**.

In this project the two domains are:

- **Write domain** — `wclk`, 10.000 ns period, **100 MHz**.
- **Read domain** — `rclk`, 27.000 ns period, **~37.037 MHz**.

The 10:27 ratio is deliberately non-integer so the edges drift against each
other, faithfully modeling a real asynchronous crossing.

### 2.2 Metastability — the physical danger

A flip-flop reliably captures its input only if the input is stable through the
setup/hold window. If the input **changes during that window** (which is
unavoidable when the source is in an unrelated clock domain), the flip-flop can
enter a **metastable** state: its output sits at an invalid, in-between voltage
and takes an unpredictable amount of time to resolve to a valid 0 or 1.

The classic analogy: a ball balanced exactly on the peak of a hill. It *will*
roll to one side eventually, but you cannot predict *when* or *which side*.

Metastability cannot be eliminated — it is a physical consequence of asynchronous
sampling. If a metastable value propagates into downstream logic before it
resolves, you get **random, non-reproducible data corruption** — the infamous
"works in simulation, fails intermittently on hardware" bug. CDC errors are among
the most common and hardest-to-debug failures in real silicon.

We can't outlaw metastability, but we can do two things:

1. Make the **probability** that a metastable event ever causes a visible failure
   astronomically small (→ the two-flop synchronizer).
2. Guarantee that a metastable event can never corrupt a **multi-bit** value
   (→ Gray coding).

---

## Part III — The building blocks of the solution

### 3.1 The two-flop synchronizer (handles ONE bit)

Route the crossing signal through **two flip-flops back-to-back** in the
destination domain before any logic uses it:

```
source domain  |  destination domain (rclk)
   signal ----->[ FF1 ]---->[ FF2 ]----> safe to use
                  ^ may go       ^ has one full clock
                  metastable     period to settle
```

FF1 might catch a metastable value, but it has an entire destination-clock period
to resolve before FF2 samples it. By then it is (with overwhelming probability) a
clean 0 or 1. The cost is **one cycle of latency**; the benefit is a gigantic
reliability improvement. This is why `SYNC_STAGES = 2` is the industry-standard
default.

### 3.2 MTBF — quantifying "how safe"

**Mean Time Between Failures (MTBF)** puts a number on synchronizer reliability:

```
MTBF = exp(t_r / τ) / (T0 × f_clk × f_data)
```

- `t_r` — resolution time available (≈ one destination clock period minus setup).
- `τ` — device metastability time constant (how fast it decays).
- `T0` — device metastability window constant.
- `f_clk` — destination clock frequency.
- `f_data` — rate of asynchronous events crossing.

For this design, using the faster receiving clock (`wclk`, the worst case) and
conservative cited 7-series constants (`t_r ≈ 9.5 ns`, `τ ≈ 0.20 ns`,
`T0 ≈ 1e-11 s`, `f_clk = 100 MHz`, `f_data ≈ 10 MHz`):

```
exp(9.5/0.20) = exp(47.5) ≈ 4.3e20
denominator   = 1e-11 × 1e8 × 1e7 = 1e4
MTBF ≈ 4.3e20 / 1e4 = 4.3e16 s ≈ 1.4 × 10⁹ years
```

**MTBF ≈ 1.4 billion years.** (τ and T0 are conservative cited constants, not
device-measured, so this is an order-of-magnitude engineering estimate — but the
takeaway is unambiguous: two flops is far more than enough here.)

### 3.3 Gray code (handles a whole BUS)

A synchronizer protects one bit. But a FIFO's pointers are **multi-bit**. If you
naively synchronize each bit of a binary counter independently, the bits can
resolve to old-or-new values *independently*, and you can read a value the
counter never held.

Worst case, a binary counter incrementing 7 → 8: `0111` → `1000`. **All four bits
flip at once.** Sample mid-transition and you might latch `0000`, `1111`, or any
garbage — none of which was ever the real count.

**Gray code** is a binary encoding where **consecutive values differ by exactly
one bit**:

| Decimal | Binary | Gray |
|---------|--------|------|
| 0 | 000 | 000 |
| 1 | 001 | 001 |
| 2 | 010 | 011 |
| 3 | 011 | 010 |
| 4 | 100 | 110 |
| 5 | 101 | 111 |
| 6 | 110 | 101 |
| 7 | 111 | 100 |

Because only one bit changes per increment, sampling mid-change yields **either
the old value or the new value — never a spurious intermediate.** The single
changing bit may be metastable, but that is exactly the one-bit case the two-flop
synchronizer already handles. **Gray coding is what makes it safe to send a
multi-bit pointer across the domain boundary.**

Conversion is cheap:
- Binary → Gray: `gray = binary ^ (binary >> 1)`
- Gray → Binary: ripple-XOR from the MSB down (`gray2bin.v`).

### 3.4 The key architectural insight

Data buses are too wide (many bits changing) to synchronize directly. So the
async FIFO **never synchronizes the data**. Instead:

- Data sits in a **dual-port memory**, written by one clock and read by the other.
- Only the **Gray-coded pointers** cross domains, safely, via two-flop
  synchronizers.
- A memory location is only ever **read after** the pointer logic guarantees its
  write has fully completed — so the data path itself never experiences
  metastability.

---

## Part IV — The asynchronous FIFO

### 4.1 What a FIFO is

A **FIFO (First-In, First-Out)** is a hardware queue: data comes out in the same
order it went in, like a pipe. It consists of:

- a block of **memory** (here 16 entries × 8 bits),
- a **write pointer** (`wptr`) — the next slot to write,
- a **read pointer** (`rptr`) — the next slot to read,
- **full** and **empty** flags.

Writes advance `wptr`; reads advance `rptr`. When the write side has filled every
slot the reader hasn't yet consumed, the FIFO is **full** (writes must stop). When
the reader has consumed everything written, it is **empty** (reads must stop).

### 4.2 What makes it *asynchronous*

An **asynchronous FIFO** has its write side on one clock and read side on another.
This is the canonical, industry-standard bridge for a *stream* of data across
clock domains, because it solves everything at once:

- The producer writes at its own rate; the consumer reads at its own rate; the
  FIFO **absorbs the rate mismatch** (here, a 100 MHz writer outrunning a 37 MHz
  reader — the FIFO stays near-full and applies backpressure).
- The data never needs synchronizing (it lives in memory).
- Only the two pointers cross, and they are Gray-coded.

### 4.3 How full and empty are detected across domains

Each side needs to know where the *other* pointer is:

- The **write side** must know the read pointer to detect **full** → the read
  pointer is Gray-coded and synchronized into the write domain (`sync_r2w`).
- The **read side** must know the write pointer to detect **empty** → the write
  pointer is Gray-coded and synchronized into the read domain (`sync_w2r`).

### 4.4 The extra-MSB "wrap" trick

For a 16-deep FIFO you only need **4 address bits** to index memory (`2⁴ = 16`).
But the pointers carry **5 bits** (`ADDR_WIDTH + 1`). Why?

When `wptr` and `rptr` are equal, the FIFO could be either **empty** (reader
caught up to writer) or **full** (writer lapped the reader exactly once). The
lower 4 bits alone can't distinguish these. The **extra MSB** acts as a "wrap"
flag that toggles each time a pointer laps the memory:

- **Empty:** the two pointers are *completely* equal (all 5 bits).
- **Full:** the lower bits are equal **but the wrap MSB differs** — i.e. the
  writer is one full lap ahead of the reader.

In Gray-coded form the full test compares the write pointer's next value against
the synchronized read pointer with the **top two bits inverted** — the standard
Cummings formulation. Empty is a plain Gray equality.

### 4.5 Occupancy and hysteresis backpressure

Beyond binary full/empty, the write side computes **occupancy** (how many entries
are in use) by converting the synchronized read pointer back to binary
(`gray2bin`) and subtracting from the write pointer.

The **backpressure controller** raises `almost_full`/`stall` *before* the FIFO is
truly full, giving an upstream producer time to pause. It uses **hysteresis** —
two thresholds instead of one:

- Assert `almost_full` when occupancy rises to **14** (`ALMOST_FULL_HI`).
- De-assert when occupancy falls to **10** (`ALMOST_FULL_LO`).

The 4-entry gap prevents the flag from **chattering** (rapidly toggling) when
occupancy hovers exactly at a single threshold.

### 4.6 Reset synchronization

Reset needs care in a multi-clock design too. A **reset synchronizer**
(`rst_sync`) makes each domain's reset assert **immediately** (asynchronously) but
de-assert **synchronously** with that domain's clock. This avoids a subtle hazard
called **reset removal recovery** failure, where flip-flops coming out of reset at
slightly different times cause an inconsistent startup state.

---

## Part V — The RTL, module by module

### 5.1 Hierarchy

```
async_fifo_top                (top level — wires everything together)
├── rst_sync   (×2)           reset synchronizer, one per clock domain
├── wptr_full                 write-domain: write pointer + full + occupancy
│   ├── gray_counter          binary+Gray write pointer
│   └── gray2bin              read-pointer Gray→binary for occupancy math
├── rptr_empty                read-domain: read pointer + empty
│   └── gray_counter          binary+Gray read pointer
├── sync_r2w                  read pointer → write domain (2-FF synchronizer)
├── sync_w2r                  write pointer → read domain (2-FF synchronizer)
├── fifomem                   dual-port memory (16 × 8)
└── backpressure_ctrl         hysteresis almost_full / stall

naive_cdc_bridge              standalone "wrong way" counter-example (not in top)
```

### 5.2 Each module

**`gray_counter.v`** — The single source of truth for a pointer. It outputs both
the **binary** form (used to address memory and compute occupancy) and the
**Gray** form (used to cross domains), and crucially both are **registered from
the same next-state value in the same cycle** so they can never disagree by a
cycle. Increment is enabled by an external `en`.

**`gray2bin.v`** — Combinational Gray→binary converter (ripple-XOR from the MSB).
Needed because, after synchronizing the *other* domain's Gray pointer in, you must
convert it to binary to compute occupancy (`wptr_bin − rptr_bin`).

**`sync_r2w.v` / `sync_w2r.v`** — The two-flop synchronizers, one per direction.
`r2w` carries the Gray read pointer into the write domain; `w2r` carries the Gray
write pointer into the read domain. These are the physical realization of the
two-flop synchronizer (3.1), and they are safe to pass a whole bus **only because**
the pointers are Gray-coded (3.3).

**`wptr_full.v`** — The write-domain "brain." Instantiates a `gray_counter` for
the write pointer, computes the registered **full** flag from the write pointer's
next value versus the synchronized read pointer (Cummings full test), and computes
**occupancy** via `gray2bin` + subtraction. Gating (`wr_en & ~full`) ensures the
pointer never advances past a full FIFO.

**`rptr_empty.v`** — The read-domain "brain." Instantiates a `gray_counter` for
the read pointer and computes the registered **empty** flag as a Gray equality
between the read pointer's next value and the synchronized write pointer. Gating
(`rd_en & ~empty`) prevents reading an empty FIFO.

**`fifomem.v`** — The dual-port storage (16 deep, 8 wide). Written on `wclk`, read
on `rclk`, with a one-cycle registered read (`rd_valid` marks when `rd_data` is
valid). Because it is only 128 bits, Vivado maps it to **distributed RAM (LUTRAM)**
rather than a Block RAM tile.

**`rst_sync.v`** — Reset synchronizer (async assert, sync de-assert), instantiated
once per clock domain in the top level.

**`backpressure_ctrl.v`** — Watches occupancy and drives `almost_full`/`stall`
with hysteresis (assert at 14, release at 10).

**`async_fifo_top.v`** — Connects all of the above: two reset syncs, both pointer
domains, both synchronizers, the memory, the backpressure controller, and the
read/write gating logic. This is the module that is synthesized, implemented, and
CDC-checked.

**`naive_cdc_bridge.v`** — The counter-example. A **single** flip-flop capturing
an 8-bit bus straight across the two clocks, with **no Gray coding and no
synchronizer**. It exists only to demonstrate what goes wrong (Part VI). It is not
part of `async_fifo_top`.

### 5.3 Parameters and why they were chosen

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `DATA_WIDTH` | 8 | Byte-oriented payload; small but fully parameterized. |
| `ADDR_WIDTH` | 4 (DEPTH 16) | Small enough to wrap often in sim, large enough to show occupancy/backpressure. |
| `SYNC_STAGES` | 2 | Standard metastability depth; MTBF (3.2) confirms it is more than sufficient. |
| `ALMOST_FULL_HI` | 14 | Two slots of headroom below full so a producer can react to `stall`. |
| `ALMOST_FULL_LO` | 10 | A 4-deep hysteresis band prevents `almost_full` chatter. |

---

## Part VI — What we proved

The project proves the correct design works on **three independent axes**, and
that the naive design fails — which is the whole point.

### 6.1 Simulation (functional correctness)

A self-checking SystemVerilog testbench (`tb_async_fifo.sv`) ran three scenarios:
a burst-overflow directed test, a backpressure/slow-drain directed test, and a
**10,000-cycle randomized dual-clock stress test**. It uses a **scoreboard** — a
golden reference queue: every accepted write pushes the expected byte; every valid
read pops the front and compares it to the hardware output.

| Metric | Result |
|--------|--------|
| Transactions accepted / read back | 1965 / 1965 |
| **Scoreboard mismatches** | **0** |
| Functional coverage | **100.00%** |
| Max occupancy | 16 / 16 (never overflowed) |
| Watermark assert / de-assert | exactly 14 / 10 |

Zero mismatches over thousands of randomized operations is a **machine-checked**
proof of data integrity — not eyeballing a waveform. 100% functional coverage
means the interesting corners (full, empty, almost-full, every occupancy quartile,
pointer wraparound, simultaneous read+write) were actually exercised.

### 6.2 Static Timing Analysis (is it fast enough?)

After implementation on `xc7z020clg484-1`:

| Run | WNS | WHS | Failing endpoints | Fmax |
|-----|-----|-----|-------------------|------|
| **Synchronized** (`async_fifo_top`) | **+6.036 ns** | +0.110 ns | **0 (all met)** | **252.27 MHz** (wclk domain) |
| Naive (`naive_cdc_bridge`) | **−0.395 ns** | −0.093 ns | 8 setup | N/A (fails) |

The synchronized design passes with large positive slack — `Fmax = 1000 /
(10 − 6.036) ≈ 252 MHz`, far above the 100 MHz requirement.

### 6.3 Report CDC (is the crossing structurally safe?)

Vivado's dedicated CDC structural checker on the synchronized design:

| From → To | Endpoints | Safe | Unsafe | Unknown |
|-----------|-----------|------|--------|---------|
| wclk → rclk | 13 | 13 | 0 | 0 |
| rclk → wclk | 5 | 5 | 0 | 0 |

**All 18 crossings classified Safe, 0 Unsafe.** (The report also notes 10
endpoints "No ASYNC_REG" — a best-practice advisory to tag synchronizer flops,
not a safety failure; see Future Work.)

### 6.4 Resource usage

| Resource | Used | Available | % |
|----------|------|-----------|---|
| Slice LUTs | 38 | 53,200 | 0.07 |
| — as Logic | 32 | | |
| — as Memory (distributed RAM) | 6 | | |
| Flip-Flops | 54 | 106,400 | 0.05 |
| **Block RAM** | **0** | 140 | **0.00** |
| I/O (IOB) | 31 | 200 | 15.50 |
| BUFG | 2 | 32 | 6.25 |

The 6 "LUT as Memory" entries are `fifomem` — a 128-bit array is below the BRAM
threshold, so it maps to distributed RAM. **BRAM = 0** confirms this.

### 6.5 The before/after story — and the subtle lesson

This is the crux of what the project demonstrates, and it is more nuanced than
"good one safe, bad one unsafe":

- The **synchronized** design passes **both** lenses: clean STA (+6.036 ns) *and*
  all 18 crossings certified Safe by `report_cdc`.
- The **naive** design **fails STA** at −0.395 ns on 8 endpoints
  (`data_reg_reg[*]` → `rd_data_bad_reg[*]`, wclk→rclk, 1.000 ns setup
  requirement) — **but its `report_cdc` is empty** ("All paths Safely Timed").

Why is the naive CDC report empty rather than screaming "unsafe"? Because
`naive_cdc_bridge.xdc` **deliberately omits** `set_clock_groups -asynchronous`.
Without that declaration, Vivado assumes `wclk` and `rclk` are *related* and times
the crossing as an ordinary synchronous path (which fails), and `report_cdc`
never even recognizes it as a crossing to analyze.

**The lesson: STA and CDC analysis are two different lenses, and the missing
constraint determines which one catches the bug.**

- Constraint **missing** (naive): STA fails, CDC report empty.
- Constraint **present** (synchronized): STA clean, CDC report certifies safety.

You cannot get *both* a failing WNS and a flagged-unsafe CDC from a single naive
run — a genuinely sophisticated point that shows real understanding of the tools.

---

## Part VII — Reproducing the flow

```
# One-shot headless build (project → sim → synth → impl → reports → naive run)
vivado -mode batch -source scripts/build_vivado.tcl

# Post-process the simulation waveform into plots + independent cross-check
pip install vcdvcd matplotlib
python scripts/vcd_parser.py results/async_fifo_waveform.vcd
```

The GUI equivalent: add `files/*.v` as design sources and `tb_async_fifo.sv` as a
simulation source; set `async_fifo_top` and `tb_async_fifo` as the respective
tops; add `files/async_fifo_top.xdc`; Run Simulation (`run all` to `$finish`),
then Run Synthesis, Run Implementation, and open the Timing/Utilization/CDC
reports. Do the naive run as a separate project with `files/naive_cdc_bridge.v`
and the ungrouped `files/naive_cdc_bridge.xdc`.

---

## Part VIII — Future work (documented, not implemented)

Neither of these is applied, because either would change the netlist and make the
committed reports stale:

1. **Tag synchronizer flops with `ASYNC_REG`.** The synchronized CDC report flags
   10 endpoints "No ASYNC_REG." Adding `(* ASYNC_REG = "TRUE" *)` to the chain
   registers in `sync_r2w.v`/`sync_w2r.v` tells the placer to pack them tightly.
   It is a placement hint, not a functional change.
2. **A second naive run *with* `set_clock_groups -asynchronous`.** That would flip
   the lens: STA would go clean, but `report_cdc` would then flag the single-flop,
   un-Gray-coded crossing as **Unsafe** (a CDC-1 violation) — giving the complete
   before/after matrix (constraint present/absent × STA/CDC).

---

## Part IX — Why this design is credible (summary)

The design follows the **Clifford Cummings** dual-clock FIFO methodology (the
canonical reference for async FIFO design): binary+Gray pointers, two-flop
synchronizers, registered flags, the extra-MSB wrap bit, and reset
synchronization. On top of that baseline it adds an occupancy-based **hysteresis
backpressure controller**. It is verified by a self-checking, coverage-driven
testbench, and independently signed off by both static timing and Vivado's CDC
checker — with a deliberately broken counter-example to make the contrast
concrete.

---

## Part X — Glossary

- **Asynchronous clocks** — clocks with no fixed phase/frequency relationship.
- **BRAM** — dedicated on-chip Block RAM.
- **CDC** — Clock Domain Crossing; a signal passing between unrelated clocks.
- **Combinational logic** — logic with no memory; output depends only on current
  inputs.
- **Distributed RAM (LUTRAM)** — small memory built from LUTs instead of BRAM.
- **FIFO** — First-In-First-Out queue.
- **Flip-flop (FF)** — one-bit clocked memory element.
- **Fmax** — maximum clock frequency at which the design meets timing.
- **Gray code** — encoding where consecutive values differ by exactly one bit.
- **Hysteresis** — using two thresholds to prevent a signal from chattering.
- **LUT** — Look-Up Table; implements small logic functions.
- **Metastability** — a flip-flop's unstable state after a setup/hold violation.
- **MTBF** — Mean Time Between Failures.
- **Occupancy** — number of entries currently stored in the FIFO.
- **RTL** — Register Transfer Level design style.
- **Setup/Hold time** — the stable window a FF input needs around a clock edge.
- **Slack** — margin by which a timing path passes (positive) or fails (negative).
- **STA** — Static Timing Analysis.
- **Synchronizer** — a chain of flops that lets a signal cross domains safely.
- **WNS / WHS** — Worst Negative Slack (setup) / Worst Hold Slack.
- **XDC** — Xilinx Design Constraints file (clocks, timing exceptions).

---

## Part XI — Top 10 interview Q&A

Use these to explain the project confidently. Each answer is written to be spoken
aloud in ~30–60 seconds, then expanded if the interviewer probes.

**Q1. What problem does this project solve, in one breath?**
It safely moves a stream of data between two circuits on unrelated clocks (100 MHz
and 37 MHz) using an asynchronous FIFO, and it *proves* the crossing is safe via
simulation, static timing, and Vivado's CDC checker — with a deliberately broken
single-flop version to show what happens if you skip the proper techniques.

**Q2. What is metastability and why can't you just avoid it?**
When a flip-flop's input changes during its setup/hold window — unavoidable when
the source is on an unrelated clock — the flop can enter an invalid in-between
state that takes an unpredictable time to resolve. It's a physical phenomenon, so
you can't eliminate it; you can only reduce the probability it causes a visible
failure (two-flop synchronizer) and prevent it from corrupting multi-bit values
(Gray coding).

**Q3. Why Gray code for the pointers instead of plain binary?**
A synchronizer only protects one bit. Binary counters can flip many bits at once
(7→8 is `0111`→`1000`, all four bits), so sampling mid-transition could yield a
value the counter never held. Gray code changes exactly one bit per increment, so
a mid-transition sample is always either the old or the new value — never garbage
— and that single bit is exactly what the two-flop synchronizer handles.

**Q4. Why don't you synchronize the data bus the same way as the pointers?**
Because the data bus has many bits changing arbitrarily; you can't Gray-code
arbitrary data. The async FIFO's whole trick is that data never crosses through
synchronizers — it sits in a dual-port memory. Only the Gray-coded pointers cross.
A location is only read after the pointer logic guarantees its write completed, so
the data path never sees metastability.

**Q5. How are the full and empty flags generated across the two domains?**
Each side synchronizes the *other* side's Gray pointer in: the write side gets the
read pointer to detect full; the read side gets the write pointer to detect empty.
Empty is a full Gray equality of the pointers. Full is the Cummings test — the
next write pointer equals the synchronized read pointer with the top two bits
inverted, which encodes "one full lap ahead."

**Q6. Why do the pointers have one more bit than the address needs?**
With a 16-deep FIFO you need 4 address bits, but the pointers are 5 bits. The
extra MSB is a wrap flag. When the lower bits are equal, that extra bit
distinguishes empty (pointers fully equal) from full (lower bits equal, wrap bit
differs — the writer has lapped the reader once).

**Q7. Why two synchronizer flops — why not one or three?**
One flop can still be metastable when downstream logic samples it. Two gives the
first flop a full clock period to resolve before the second samples it, which
drops the failure probability astronomically — my MTBF estimate is on the order of
10⁹ years at these frequencies. Three flops would add latency for negligible extra
benefit here; you only go deeper at very high frequencies or for very stringent
MTBF targets.

**Q8. Your naive design fails timing at −0.395 ns but its CDC report is empty —
isn't that a contradiction?**
No — it's the key insight. The naive constraints omit `set_clock_groups
-asynchronous`, so Vivado assumes the clocks are related and times the crossing as
a synchronous path, which fails setup. Because it's treated as synchronous,
`report_cdc` doesn't see an async crossing to flag, so its report is empty. STA and
CDC analysis are two different lenses; the missing constraint moves the problem
into the timing report instead of the CDC report. You can't get both a failing WNS
*and* an unsafe-CDC flag from one naive run.

**Q9. How did you verify correctness, and why trust it?**
A self-checking testbench with a golden-reference scoreboard: every accepted write
pushes the expected byte, every valid read pops and compares. Over a 10,000-cycle
randomized dual-clock stress test plus two directed tests, I got 1,965
transactions with zero mismatches and 100% functional coverage. Zero mismatches is
machine-checked data integrity, and 100% coverage means the corner cases — full,
empty, almost-full, all occupancy quartiles, pointer wrap, simultaneous read+write
— were actually hit, not just the easy paths.

**Q10. Why is there no Block RAM, and is that a problem?**
The memory is 16×8 = 128 bits, far below the threshold where Vivado uses a
dedicated BRAM tile, so it maps to distributed RAM (LUTs configured as memory) —
that's the "6 LUTs as memory, 0 BRAM" in my utilization report. It's expected and
optimal at this size. For a deeper or wider FIFO you'd parameterize up and Vivado
would automatically infer BRAM instead; the RTL doesn't change.

**Bonus — what would you improve next?**
Tag the synchronizer flip-flops with the `ASYNC_REG` attribute so the placer packs
them tightly (the CDC report flags this as a best-practice advisory), and add a
second naive run *with* the async constraint so `report_cdc` also flags the
single-flop crossing as unsafe — giving a complete before/after matrix across both
STA and CDC.
