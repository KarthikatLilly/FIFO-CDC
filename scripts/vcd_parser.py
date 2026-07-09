#!/usr/bin/env python3
"""
vcd_parser.py -- Post-process the async FIFO simulation waveform.

Reads async_fifo_waveform.vcd (produced by tb_async_fifo.sv), extracts the key
signals, produces three plots, and prints summary statistics that can be
cross-checked against the testbench's own METRIC: lines as an independent
consistency check.

Usage:
    pip install vcdvcd matplotlib
    python vcd_parser.py [path/to/async_fifo_waveform.vcd]

Note: XSIM prefixes signal names with the instance hierarchy (e.g.
"tb_async_fifo.wr_occupancy[4:0]"). This script inspects the VCD header and
fuzzy-matches by leaf name, so you should not need to hardcode paths -- but if
a signal is missed, print `vcd.references_to_ids.keys()` and adjust
LEAF_SIGNALS below.
"""

import sys
import os

# Watermarks / depth -- keep in sync with the RTL parameters.
ALMOST_FULL_LO = 10
ALMOST_FULL_HI = 14
DEPTH          = 16

# Leaf signal names we want to pull out of the VCD (hierarchy-agnostic).
LEAF_SIGNALS = [
    "wclk", "rclk", "wr_en", "rd_en",
    "full", "empty", "almost_full",
    "wr_occupancy", "wptr_bin", "rptr_bin",
]


def _import_deps():
    try:
        from vcdvcd import VCDVCD
    except ImportError:
        sys.exit("ERROR: vcdvcd not installed. Run: pip install vcdvcd")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        sys.exit("ERROR: matplotlib not installed. Run: pip install matplotlib")
    return VCDVCD, plt


def _leaf_name(ref):
    """Strip hierarchy and bit-range: 'tb.dut.sig[4:0]' -> 'sig'."""
    base = ref.split(".")[-1]
    if "[" in base:
        base = base[: base.index("[")]
    return base


def build_signal_map(vcd):
    """Map each desired leaf name to its full VCD reference string."""
    mapping = {}
    for ref in vcd.references_to_ids.keys():
        leaf = _leaf_name(ref)
        if leaf in LEAF_SIGNALS and leaf not in mapping:
            mapping[leaf] = ref
    return mapping


def to_int(val):
    """Convert a VCD sample string (may contain x/z) to int or None."""
    if val is None:
        return None
    v = val.strip().lower().lstrip("b")
    if v in ("x", "z") or "x" in v or "z" in v:
        return None
    try:
        return int(v, 2)
    except ValueError:
        try:
            return int(v)
        except ValueError:
            return None


def sampled_series(vcd, ref):
    """Return (times[], values[]) as step data from a VCD signal's tv list."""
    tv = vcd[ref].tv  # list of (time, value_str)
    times, vals = [], []
    for t, v in tv:
        iv = to_int(v)
        times.append(t)
        vals.append(iv)
    return times, vals


def step_fill(times, vals, t_end):
    """Expand step-change (time,value) pairs into a dense step function."""
    xs, ys = [], []
    for i, (t, v) in enumerate(zip(times, vals)):
        xs.append(t)
        ys.append(v)
        nxt = times[i + 1] if i + 1 < len(times) else t_end
        xs.append(nxt)
        ys.append(v)
    return xs, ys


def frac_asserted(times, vals, t_end):
    """Fraction of simulated time a 1-bit signal was == 1."""
    if not times:
        return 0.0
    total = 0.0
    for i, (t, v) in enumerate(zip(times, vals)):
        nxt = times[i + 1] if i + 1 < len(times) else t_end
        if v == 1:
            total += (nxt - t)
    span = t_end - times[0]
    return (total / span) if span > 0 else 0.0


def main():
    VCDVCD, plt = _import_deps()

    default_path = os.path.join("..", "results", "async_fifo_waveform.vcd")
    path = sys.argv[1] if len(sys.argv) > 1 else default_path
    if not os.path.isfile(path):
        sys.exit(f"ERROR: VCD not found at '{path}'. Pass the path as arg 1.")

    print(f"Parsing {path} ...")
    vcd = VCDVCD(path)
    sigmap = build_signal_map(vcd)

    missing = [s for s in LEAF_SIGNALS if s not in sigmap]
    if missing:
        print(f"WARNING: could not locate signals: {missing}")
        print("Available references (first 40):")
        for r in list(vcd.references_to_ids.keys())[:40]:
            print("   ", r)

    # Determine simulation end time.
    t_end = 0
    for ref in sigmap.values():
        tv = vcd[ref].tv
        if tv:
            t_end = max(t_end, tv[-1][0])
    t_end = t_end if t_end > 0 else 1

    # ---- Plot 1: occupancy vs time -----------------------------------------
    if "wr_occupancy" in sigmap:
        t, v = sampled_series(vcd, sigmap["wr_occupancy"])
        v = [0 if x is None else x for x in v]
        xs, ys = step_fill(t, v, t_end)
        plt.figure(figsize=(11, 4))
        plt.plot(xs, ys, drawstyle="steps-post", label="wr_occupancy")
        for lvl, lab, c in [(ALMOST_FULL_LO, "ALMOST_FULL_LO", "tab:green"),
                            (ALMOST_FULL_HI, "ALMOST_FULL_HI", "tab:orange"),
                            (DEPTH, "DEPTH", "tab:red")]:
            plt.axhline(lvl, linestyle="--", color=c, label=lab)
        plt.xlabel("time (ns)"); plt.ylabel("occupancy")
        plt.title("FIFO Occupancy vs Time")
        plt.legend(loc="upper right"); plt.tight_layout()
        plt.savefig("occupancy_vs_time.png", dpi=130); plt.close()
        print("wrote occupancy_vs_time.png")

    # ---- Plot 2: pointer trajectory ----------------------------------------
    if "wptr_bin" in sigmap and "rptr_bin" in sigmap:
        tw, vw = sampled_series(vcd, sigmap["wptr_bin"])
        tr, vr = sampled_series(vcd, sigmap["rptr_bin"])
        vw = [0 if x is None else (x & (DEPTH - 1)) for x in vw]
        vr = [0 if x is None else (x & (DEPTH - 1)) for x in vr]
        xw, yw = step_fill(tw, vw, t_end)
        xr, yr = step_fill(tr, vr, t_end)
        plt.figure(figsize=(11, 4))
        plt.plot(xw, yw, drawstyle="steps-post", label="wptr_bin (addr)")
        plt.plot(xr, yr, drawstyle="steps-post", label="rptr_bin (addr)")
        plt.xlabel("time (ns)"); plt.ylabel("address (mod DEPTH)")
        plt.title("Pointer Trajectory (sawtooth wraparound)")
        plt.legend(loc="upper right"); plt.tight_layout()
        plt.savefig("pointer_trajectory.png", dpi=130); plt.close()
        print("wrote pointer_trajectory.png")

    # ---- Plot 3: flag timeline ---------------------------------------------
    flags = [f for f in ("full", "empty", "almost_full") if f in sigmap]
    if flags:
        plt.figure(figsize=(11, 1.4 * len(flags) + 1))
        for i, f in enumerate(flags):
            t, v = sampled_series(vcd, sigmap[f])
            v = [0 if x is None else x for x in v]
            xs, ys = step_fill(t, v, t_end)
            ys = [y + i * 1.5 for y in ys]   # vertical offset per lane
            plt.plot(xs, ys, drawstyle="steps-post", label=f)
        plt.yticks([i * 1.5 + 0.5 for i in range(len(flags))], flags)
        plt.xlabel("time (ns)")
        plt.title("Flag Timeline (logic-analyzer view)")
        plt.tight_layout()
        plt.savefig("flag_timeline.png", dpi=130); plt.close()
        print("wrote flag_timeline.png")

    # ---- Independent statistics (cross-check vs testbench METRICs) ----------
    print("\n--- Independent cross-check statistics ---")
    for f in ("full", "empty", "almost_full"):
        if f in sigmap:
            t, v = sampled_series(vcd, sigmap[f])
            v = [0 if x is None else x for x in v]
            print(f"  % time {f:<12} asserted : {100*frac_asserted(t, v, t_end):6.2f}%")

    if "wr_occupancy" in sigmap:
        t, v = sampled_series(vcd, sigmap["wr_occupancy"])
        v = [x for x in v if x is not None]
        print(f"  max occupancy reached   : {max(v) if v else 0}  (expect <= {DEPTH})")

    if "full" in sigmap:
        t, v = sampled_series(vcd, sigmap["full"])
        v = [0 if x is None else x for x in v]
        events = sum(1 for i in range(1, len(v)) if v[i] == 1 and v[i-1] == 0)
        print(f"  full assertion events   : {events}")

    print("\nCross-check MAX_OCCUPANCY and event counts against the "
          "testbench's METRIC: lines in the Vivado log.")


if __name__ == "__main__":
    main()
