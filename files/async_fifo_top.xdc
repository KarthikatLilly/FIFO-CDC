#===============================================================================
# async_fifo_top.xdc  -- Constraints for the SYNCHRONIZED design
#
# Two independent clocks declared as an asynchronous clock group so Vivado does
# NOT time paths between them. With the Gray-code + double-flop synchronizers in
# place, this is the correct, timing-clean declaration.
#
# TARGET-PART INDEPENDENT: these are logical timing constraints only. They are
# identical for Basys3 (xc7a35tcpg236-1) and ZedBoard Zynq-7000 (xc7z020clg484-1)
# -- you switch parts when creating the project (-part), NOT here. Adjust
# get_ports only if you rename the top-level clock ports (they match
# async_fifo_top.v as-is).
#===============================================================================

create_clock -name wclk -period 10.000 [get_ports wclk]
create_clock -name rclk -period 27.000 [get_ports rclk]

set_clock_groups -asynchronous \
    -group [get_clocks wclk] \
    -group [get_clocks rclk]

# Optional (recommended) CDC hardening once the synchronizer nets are named in
# your netlist -- left commented so the base flow stays clean:
# set_max_delay -datapath_only -from [get_clocks rclk] -to [get_clocks wclk] 10.000
# set_max_delay -datapath_only -from [get_clocks wclk] -to [get_clocks rclk] 10.000

#-------------------------------------------------------------------------------
# PHYSICAL CONSTRAINTS -- only needed if you build a BITSTREAM to run on real
# ZedBoard hardware. The metrics flow (synth + impl + timing/CDC/util reports)
# does NOT need these, so they are intentionally left out. Notes if you do go to
# hardware:
#   - ZedBoard exposes a single 100 MHz PL clock (bank 13, pin Y9). A second,
#     asynchronous 37 MHz clock does not exist on-board, so wclk/rclk would come
#     from a Clocking Wizard / MMCM, and you would constrain the generated clocks
#     with create_generated_clock instead of driving rclk from a package pin.
#   - The ~35 data/flag I/O (wr_data[7:0], rd_data[7:0], wr_occupancy[4:0],
#     wr_en, rd_en, full, almost_full, stall, empty, rd_valid) would each need a
#     PACKAGE_PIN + IOSTANDARD, e.g.:
#       # set_property PACKAGE_PIN Y9  [get_ports wclk]
#       # set_property IOSTANDARD LVCMOS33 [get_ports wclk]
#-------------------------------------------------------------------------------
