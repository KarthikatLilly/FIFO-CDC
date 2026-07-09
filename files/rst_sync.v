//==============================================================================
// rst_sync.v  -- Reset Synchronizer
//
// Converts one async active-low reset into a per-domain reset that asserts
// ASYNCHRONOUSLY (immediately) but de-asserts SYNCHRONOUSLY, avoiding
// reset-removal (recovery/removal) timing violations.
//
// Style: asynchronous assert, synchronous de-assert.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module rst_sync #(
    parameter SYNC_STAGES = 2
)(
    input  wire clk,          // domain clock
    input  wire async_rst_n,  // raw async active-low reset
    output wire sync_rst_n    // domain-synchronized active-low reset
);

    reg [SYNC_STAGES-1:0] sync_chain;

    always @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n)
            sync_chain <= {SYNC_STAGES{1'b0}};
        else
            sync_chain <= {sync_chain[SYNC_STAGES-2:0], 1'b1};
    end

    assign sync_rst_n = sync_chain[SYNC_STAGES-1];

endmodule

`default_nettype wire
