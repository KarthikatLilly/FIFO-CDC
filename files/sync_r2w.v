//==============================================================================
// sync_r2w.v  -- Read Pointer -> Write Domain Synchronizer
//
// Brings the read pointer (Gray-coded) into the write clock domain safely.
//
// SAFETY ASSUMPTION (why multi-bit synchronization is legal here):
//   The pointer is GRAY-CODED, so between any two consecutive values exactly
//   ONE bit changes. If the receiving flops sample mid-transition, at most one
//   bit is metastable and the captured value is either the old or the new
//   pointer -- never a spurious intermediate. This is the ONLY reason it is
//   safe to push the whole bus through a simple double-flop synchronizer.
//   A plain binary counter must NEVER be synchronized this way.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module sync_r2w #(
    parameter ADDR_WIDTH  = 4,
    parameter SYNC_STAGES = 2
)(
    input  wire                  wclk,
    input  wire                  wrst_n_sync,
    input  wire [ADDR_WIDTH:0]   rptr_gray_in,        // from rptr_empty.v
    output reg  [ADDR_WIDTH:0]   rptr_gray_sync_out   // registered, wclk domain
);

    localparam PW = ADDR_WIDTH + 1;   // pointer width

    // SYNC_STAGES-deep chain packed into one vector. The ENTIRE Gray bus moves
    // as one unit per stage -- individual bits are never synchronized apart.
    reg [SYNC_STAGES*PW-1:0] chain;

    always @(posedge wclk or negedge wrst_n_sync) begin
        if (!wrst_n_sync)
            chain <= {(SYNC_STAGES*PW){1'b0}};
        else
            chain <= {chain[(SYNC_STAGES-1)*PW-1:0], rptr_gray_in};
    end

    // Output is the deepest (oldest) stage -> full SYNC_STAGES of latency.
    always @(*) rptr_gray_sync_out = chain[SYNC_STAGES*PW-1 -: PW];

endmodule

`default_nettype wire
