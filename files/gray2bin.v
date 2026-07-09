//==============================================================================
// gray2bin.v  -- Gray-to-Binary Converter (combinational)
//
// Converts a synchronized Gray pointer back to binary so occupancy (fill
// level) can be computed for the backpressure controller.
//
// Algorithm: MSB passes through unchanged; each lower bit is the XOR of the
// corresponding Gray bit with the already-computed next-higher BINARY bit
// (ripple XOR from MSB down to LSB). Implemented with a generate/for loop so
// it scales with the parameterized WIDTH. Note: continuous assigns are
// order-independent, so the loop may be written ascending.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module gray2bin #(
    parameter WIDTH = 5
)(
    input  wire [WIDTH-1:0] gray_in,
    output wire [WIDTH-1:0] bin_out
);

    // MSB passes through unchanged.
    assign bin_out[WIDTH-1] = gray_in[WIDTH-1];

    genvar i;
    generate
        for (i = 0; i <= WIDTH-2; i = i + 1) begin : g2b
            assign bin_out[i] = gray_in[i] ^ bin_out[i+1];
        end
    endgenerate

endmodule

`default_nettype wire
