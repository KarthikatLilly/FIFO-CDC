#===============================================================================
# naive_cdc_bridge.xdc  -- Constraints for the INTENTIONALLY BROKEN bridge
#
# Same two clocks as the real design, but the set_clock_groups -asynchronous
# line is DELIBERATELY OMITTED. Vivado will therefore try to time the
# single-flop rclk<-wclk crossing as if it were synchronous and report a large
# negative WNS. Screenshot that number as the "before" CDC-risk metric.
#
# DO NOT add set_clock_groups here -- the missing constraint is the point.
#
# Target-part independent: identical for Basys3 (xc7a35tcpg236-1) and ZedBoard
# Zynq-7000 (xc7z020clg484-1). Switch parts at project creation, not here.
#===============================================================================

create_clock -name wclk -period 10.000 [get_ports wclk]
create_clock -name rclk -period 27.000 [get_ports rclk]

# (No set_clock_groups -asynchronous on purpose.)
