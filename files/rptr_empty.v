//==============================================================================
// rptr_empty.v  -- Read Pointer Domain Logic
//
// Owns the read-domain pointer counter and the EMPTY flag. EMPTY uses an exact
// Gray-code equality against the synchronized write pointer (no inversion,
// unlike FULL), computed from the counter's NEXT state.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module rptr_empty #(
    parameter ADDR_WIDTH = 4
)(
    input  wire                 rclk,
    input  wire                 rrst_n_sync,
    input  wire                 rd_en,           // requested read enable (ungated)
    input  wire [ADDR_WIDTH:0]  wptr_gray_sync,  // from sync_w2r.v
    output wire [ADDR_WIDTH:0]  rptr_bin,        // to fifomem addr
    output wire [ADDR_WIDTH:0]  rptr_gray,       // to sync_r2w.v
    output reg                  empty            // registered empty flag
);

    // Enable gated by empty so we never read from an empty FIFO.
    wire ren = rd_en & ~empty;

    //--------------------------------------------------------------------------
    // Pointer counter.
    //--------------------------------------------------------------------------
    gray_counter #(
        .WIDTH (ADDR_WIDTH+1)
    ) u_rcnt (
        .clk      (rclk),
        .rst_n    (rrst_n_sync),
        .en       (ren),
        .bin_out  (rptr_bin),
        .gray_out (rptr_gray)
    );

    //--------------------------------------------------------------------------
    // Empty detection from the counter's NEXT state.
    //--------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] rbin_next  = rptr_bin + (ren ? 1'b1 : 1'b0);
    wire [ADDR_WIDTH:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    wire is_empty = (rgray_next == wptr_gray_sync);

    always @(posedge rclk or negedge rrst_n_sync) begin
        if (!rrst_n_sync) empty <= 1'b1;   // FIFO starts empty
        else              empty <= is_empty;
    end

endmodule

`default_nettype wire
