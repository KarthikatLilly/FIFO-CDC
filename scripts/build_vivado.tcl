#===============================================================================
# build_vivado.tcl  --  Non-interactive Vivado build for the Async FIFO CDC Bridge
#
# Automates README Section 8: create project, add sources, behavioral sim,
# synthesis, implementation, timing/utilization/CDC reports, and the separate
# "before" naive single-flop run.
#
# RUN IT FROM ANYWHERE:
#   vivado -mode batch -source scripts/build_vivado.tcl
#
# Optional overrides via -tclargs (positional):
#   vivado -mode batch -source scripts/build_vivado.tcl -tclargs <part> <run_sim> <run_impl> <run_naive>
#   e.g.  ... -tclargs xc7a35tcpg236-1 1 1 1
#
# All console output (including the testbench's METRIC: lines) is written to
# vivado.log in the directory you launch from. Report files land in build/reports/.
#
# NOTE: this flow stops at implementation + reports. It does NOT generate a
# bitstream (not needed for any of the metrics), so unconstrained-I/O DRCs never
# block it.
#===============================================================================

#-------------------------------------------------------------------------------
# 0. Configuration
#-------------------------------------------------------------------------------
# Resolve paths relative to THIS script, so launch directory doesn't matter.
set script_dir [file normalize [file dirname [info script]]]
set proj_root  [file normalize [file join $script_dir ..]]

# Defaults (override with -tclargs).
set PART      "xc7z020clg484-1" ;# ZedBoard Zynq-7000; any 7-series/Zynq part is fine
set RUN_SIM   1
set RUN_IMPL  1
set RUN_NAIVE 1

if {$argc >= 1} { set PART      [lindex $argv 0] }
if {$argc >= 2} { set RUN_SIM   [lindex $argv 1] }
if {$argc >= 3} { set RUN_IMPL  [lindex $argv 2] }
if {$argc >= 4} { set RUN_NAIVE [lindex $argv 3] }

# Clock periods (must match the XDC) -- used for the Fmax printout only.
set WCLK_PERIOD 10.0
set RCLK_PERIOD 27.0

set build_dir   [file join $proj_root build]
set reports_dir [file join $build_dir reports]
file mkdir $reports_dir

puts "============================================================"
puts " Async FIFO CDC build"
puts "   project root : $proj_root"
puts "   part         : $PART"
puts "   run sim/impl/naive : $RUN_SIM / $RUN_IMPL / $RUN_NAIVE"
puts "============================================================"

#-------------------------------------------------------------------------------
# 1. Create the main project
#-------------------------------------------------------------------------------
set proj_name  "async_fifo_cdc"
set proj_dir   [file join $build_dir $proj_name]
create_project $proj_name $proj_dir -part $PART -force

#-------------------------------------------------------------------------------
# 2. Add design sources (all files/*.v). naive_cdc_bridge.v is added too but stays
#    an unreferenced module under the async_fifo_top hierarchy -- that's expected.
#-------------------------------------------------------------------------------
set rtl_files [glob [file join $proj_root files *.v]]
add_files -norecurse $rtl_files
set_property top async_fifo_top [current_fileset]

#-------------------------------------------------------------------------------
# 3. Add the simulation-only source (SystemVerilog testbench)
#-------------------------------------------------------------------------------
add_files -fileset sim_1 -norecurse [file join $proj_root tb_async_fifo.sv]
set_property top tb_async_fifo [get_filesets sim_1]

#-------------------------------------------------------------------------------
# 4. Add timing constraints (async clock groups)
#-------------------------------------------------------------------------------
add_files -fileset constrs_1 -norecurse \
    [file join $proj_root files async_fifo_top.xdc]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

#-------------------------------------------------------------------------------
# 5. Behavioral simulation (XSIM). Run to $finish and copy the VCD out.
#-------------------------------------------------------------------------------
if {$RUN_SIM} {
    puts "\n--- Launching behavioral simulation (XSIM) ---"
    # Run until the testbench calls $finish (or events run out).
    set_property -name {xsim.simulate.runtime} -value {-all} \
        -objects [get_filesets sim_1]
    launch_simulation
    # Belt-and-suspenders: keep running in case runtime property was ignored.
    catch { run all }

    # The VCD is written into the sim run dir; copy it next to the project root.
    set sim_dir [get_property DIRECTORY [current_sim]]
    set vcd_src [file join $sim_dir async_fifo_waveform.vcd]
    if {[file exists $vcd_src]} {
        file copy -force $vcd_src [file join $build_dir async_fifo_waveform.vcd]
        puts "Copied VCD -> [file join $build_dir async_fifo_waveform.vcd]"
        puts "Run the Python parser on it:"
        puts "   pip install vcdvcd matplotlib"
        puts "   python [file join $proj_root scripts vcd_parser.py] [file join $build_dir async_fifo_waveform.vcd]"
    } else {
        puts "WARNING: VCD not found at $vcd_src (check sim log)."
    }
    close_sim
    puts "--- Simulation done. Grep the log:  grep METRIC: vivado.log ---"
}

#-------------------------------------------------------------------------------
# 6. Synthesis
#-------------------------------------------------------------------------------
puts "\n--- Running synthesis (async_fifo_top) ---"
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis failed -- see synth_1 log."
}
open_run synth_1 -name synth_1
report_utilization -file [file join $reports_dir synth_utilization.rpt]
report_cdc         -file [file join $reports_dir synth_cdc.rpt]
puts "Post-synth reports written to $reports_dir"

#-------------------------------------------------------------------------------
# 7. Implementation + post-impl reports (WNS / WHS / Fmax / utilization / CDC)
#-------------------------------------------------------------------------------
if {$RUN_IMPL} {
    puts "\n--- Running implementation ---"
    launch_runs impl_1 -jobs 4
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        error "Implementation failed -- see impl_1 log."
    }
    open_run impl_1

    report_timing_summary -delay_type min_max -max_paths 10 \
        -file [file join $reports_dir impl_timing_summary.rpt]
    report_utilization -file [file join $reports_dir impl_utilization.rpt]
    report_cdc         -file [file join $reports_dir impl_cdc.rpt]

    # Extract headline numbers for the metrics table.
    set wns [get_property STATS.WNS [get_runs impl_1]]
    set whs [get_property STATS.WHS [get_runs impl_1]]
    if {$wns eq ""} {
        # Fallback: pull worst setup slack directly.
        set p [get_timing_paths -max_paths 1 -nworst 1 -setup]
        if {$p ne ""} { set wns [get_property SLACK $p] }
    }
    puts "============================================================"
    puts " SYNCHRONIZED DESIGN RESULTS"
    puts "   WNS (setup) = $wns ns"
    puts "   WHS (hold)  = $whs ns"
    if {$wns ne ""} {
        set fmax [expr {1000.0 / ($WCLK_PERIOD - $wns)}]
        puts "   Fmax (wclk domain) ~= [format %.2f $fmax] MHz  (period ${WCLK_PERIOD}ns - WNS)"
    }
    puts "   Reports: $reports_dir"
    puts "============================================================"
}

#-------------------------------------------------------------------------------
# 8. "BEFORE" comparison: naive single-flop crossing, WITHOUT async grouping.
#    Separate lightweight project so it can't disturb the main one. Synthesis is
#    enough -- Vivado analyzes the crossing as synchronous and reports a large
#    negative WNS.
#-------------------------------------------------------------------------------
if {$RUN_NAIVE} {
    puts "\n--- Building naive_cdc_bridge comparison project ---"
    set naive_name "naive_cdc_bridge_demo"
    set naive_dir  [file join $build_dir $naive_name]
    create_project $naive_name $naive_dir -part $PART -force

    add_files -norecurse [file join $proj_root files naive_cdc_bridge.v]
    set_property top naive_cdc_bridge [current_fileset]
    add_files -fileset constrs_1 -norecurse \
        [file join $proj_root files naive_cdc_bridge.xdc]
    update_compile_order -fileset sources_1

    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        error "Naive synthesis failed -- see synth_1 log."
    }
    open_run synth_1 -name naive_synth
    report_timing_summary -delay_type min_max -max_paths 10 \
        -file [file join $reports_dir naive_timing_summary.rpt]
    report_cdc -file [file join $reports_dir naive_cdc.rpt]

    # Worst setup slack on the intentionally-unconstrained crossing.
    set np [get_timing_paths -max_paths 1 -nworst 1 -setup]
    set nwns ""
    if {$np ne ""} { set nwns [get_property SLACK $np] }
    puts "============================================================"
    puts " NAIVE (BROKEN) CROSSING RESULT"
    puts "   WNS (setup) = $nwns ns   <-- expect large NEGATIVE"
    puts "   Reports: $reports_dir"
    puts "============================================================"
}

puts "\nAll requested steps complete."
puts "Metrics to transcribe into metrics.md:"
puts "  #1-4,10 : grep METRIC: vivado.log"
puts "  #5      : naive WNS (above)"
puts "  #6,7    : synchronized WNS / Fmax (above)"
puts "  #9      : $reports_dir/impl_utilization.rpt"
puts "  #8      : MTBF -- hand calc per design_doc.md Section 6"
