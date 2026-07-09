#===============================================================================
# async_fifo_top.xdc  -- Constraints for the SYNCHRONIZED design
#
# Two independent clocks declared as an asynchronous clock group so Vivado does
# NOT attempt to time paths between them. With the Gray-code + double-flop
# synchronizers in place, this is the correct, timing-clean declaration.
#
# Target example: xc7a35tcpg236-1 (Basys3). Adjust get_ports if your top-level
# clock port names differ (they match async_fifo_top.v here).
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
