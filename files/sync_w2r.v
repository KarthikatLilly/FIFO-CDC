//==============================================================================
// sync_w2r.v  -- Write Pointer -> Read Domain Synchronizer
//
// Exact mirror of sync_r2w.v. Brings the Gray-coded write pointer into the
// read clock domain. Safe for the same reason: one-bit-change-per-increment
// Gray encoding guarantees the sampled value is always old-or-new, never a
// spurious intermediate. The whole bus is synchronized as a single vector.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module sync_w2r #(
    parameter ADDR_WIDTH  = 4,
    parameter SYNC_STAGES = 2
)(
    input  wire                  rclk,
    input  wire                  rrst_n_sync,
    input  wire [ADDR_WIDTH:0]   wptr_gray_in,        // from wptr_full.v
    output reg  [ADDR_WIDTH:0]   wptr_gray_sync_out   // registered, rclk domain
);

    localparam PW = ADDR_WIDTH + 1;   // pointer width

    reg [SYNC_STAGES*PW-1:0] chain;

    always @(posedge rclk or negedge rrst_n_sync) begin
        if (!rrst_n_sync)
            chain <= {(SYNC_STAGES*PW){1'b0}};
        else
            chain <= {chain[(SYNC_STAGES-1)*PW-1:0], wptr_gray_in};
    end

    always @(*) wptr_gray_sync_out = chain[SYNC_STAGES*PW-1 -: PW];

endmodule

`default_nettype wire
