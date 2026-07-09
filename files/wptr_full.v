//==============================================================================
// wptr_full.v  -- Write Pointer Domain Logic
//
// Owns the write-domain pointer counter, the FULL flag, and the occupancy
// count used by the backpressure controller.
//
// FULL is computed from the NEXT Gray pointer value (canonical Cummings form)
// so it is correct one cycle before the counter itself updates.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module wptr_full #(
    parameter ADDR_WIDTH = 4
)(
    input  wire                 wclk,
    input  wire                 wrst_n_sync,
    input  wire                 wr_en,           // requested write enable (ungated)
    input  wire [ADDR_WIDTH:0]  rptr_gray_sync,  // from sync_r2w.v
    output wire [ADDR_WIDTH:0]  wptr_bin,        // to fifomem addr + occupancy
    output wire [ADDR_WIDTH:0]  wptr_gray,       // to sync_w2r.v
    output reg                  full,            // registered full flag
    output wire [ADDR_WIDTH:0]  wr_occupancy     // fill level (write domain)
);

    // Enable is gated by full so we never advance the pointer past a full FIFO.
    wire wen = wr_en & ~full;

    //--------------------------------------------------------------------------
    // Pointer counter (single source of truth for wptr_bin / wptr_gray).
    //--------------------------------------------------------------------------
    gray_counter #(
        .WIDTH (ADDR_WIDTH+1)
    ) u_wcnt (
        .clk      (wclk),
        .rst_n    (wrst_n_sync),
        .en       (wen),
        .bin_out  (wptr_bin),
        .gray_out (wptr_gray)
    );

    //--------------------------------------------------------------------------
    // Full detection from the counter's NEXT state (mirrors gray_counter's
    // internal next-state math exactly, so the flag leads the pointer by one
    // cycle as intended).
    //--------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] wbin_next  = wptr_bin + (wen ? 1'b1 : 1'b0);
    wire [ADDR_WIDTH:0] wgray_next = (wbin_next >> 1) ^ wbin_next;

    // Canonical Cummings full test: top two Gray bits inverted, remainder equal.
    wire is_full = (wgray_next == {~rptr_gray_sync[ADDR_WIDTH:ADDR_WIDTH-1],
                                     rptr_gray_sync[ADDR_WIDTH-2:0]});

    always @(posedge wclk or negedge wrst_n_sync) begin
        if (!wrst_n_sync) full <= 1'b0;
        else              full <= is_full;
    end

    //--------------------------------------------------------------------------
    // Occupancy: convert the synchronized read Gray pointer back to binary,
    // then plain-subtract. Both are (ADDR_WIDTH+1)-bit extended pointers, so
    // modulo wraparound arithmetic makes this correct with no manual wrap
    // correction (standard trick).
    //--------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] rptr_bin_sync;

    gray2bin #(
        .WIDTH (ADDR_WIDTH+1)
    ) u_g2b (
        .gray_in (rptr_gray_sync),
        .bin_out (rptr_bin_sync)
    );

    assign wr_occupancy = wptr_bin - rptr_bin_sync;

endmodule

`default_nettype wire
