//==============================================================================
// backpressure_ctrl.v  -- Hysteresis Backpressure Controller
//
// Asserts almost_full/stall BEFORE the FIFO is truly full, using two
// watermarks (hysteresis) so the signal doesn't chatter at the boundary:
//   - assert  when occupancy rises to >= ALMOST_FULL_HI
//   - deassert when occupancy falls to <= ALMOST_FULL_LO
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module backpressure_ctrl #(
    parameter ADDR_WIDTH     = 4,
    parameter ALMOST_FULL_HI = 14,
    parameter ALMOST_FULL_LO = 10
)(
    input  wire                 wclk,
    input  wire                 wrst_n_sync,
    input  wire [ADDR_WIDTH:0]  wr_occupancy,   // from wptr_full.v
    output reg                  almost_full,
    output wire                 stall           // = almost_full (kept separate)
);

    always @(posedge wclk or negedge wrst_n_sync) begin
        if (!wrst_n_sync)
            almost_full <= 1'b0;
        else if (!almost_full && (wr_occupancy >= ALMOST_FULL_HI))
            almost_full <= 1'b1;
        else if ( almost_full && (wr_occupancy <= ALMOST_FULL_LO))
            almost_full <= 1'b0;
        // else: hold (inside the hysteresis band)
    end

    assign stall = almost_full;

endmodule

`default_nettype wire
