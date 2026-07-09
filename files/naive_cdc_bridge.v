//==============================================================================
// naive_cdc_bridge.v  -- Intentionally Broken Reference (demo only, standalone)
//
// *** NOT part of async_fifo_top's datapath. ***
//
// A single write-domain register sampled directly by a single read-domain flop
// with NO Gray coding and NO multi-stage synchronizer. This exists purely so
// Vivado's static timing analysis (and report_cdc) can produce a large
// negative-slack "before" number to contrast against the properly synchronized
// design. Do NOT use this crossing in real logic.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module naive_cdc_bridge #(
    parameter DATA_WIDTH = 8
)(
    input  wire                  wclk,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  rclk,
    output reg  [DATA_WIDTH-1:0] rd_data_bad
);

    reg [DATA_WIDTH-1:0] data_reg;

    always @(posedge wclk) data_reg    <= wr_data;
    always @(posedge rclk) rd_data_bad <= data_reg;   // <-- unsynchronized CDC

endmodule

`default_nettype wire
