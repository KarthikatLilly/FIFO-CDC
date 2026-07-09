//==============================================================================
// gray_counter.v  -- Binary + Gray Pointer Counter
//
// Single source of truth for a domain's pointer. Binary form (for memory
// addressing / occupancy math) and Gray form (for safe CDC crossing) are
// BOTH registered from the SAME next-state value in the SAME cycle. Do NOT
// compute gray_out combinationally from an already-registered bin_out in a
// separate always block -- that introduces a one-cycle mismatch bug.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module gray_counter #(
    parameter WIDTH = 5   // = ADDR_WIDTH+1 by default
)(
    input  wire             clk,
    input  wire             rst_n,     // synchronized domain reset
    input  wire             en,        // increment enable (gated upstream)
    output reg  [WIDTH-1:0] bin_out,   // binary pointer
    output reg  [WIDTH-1:0] gray_out   // Gray-coded pointer
);

    wire [WIDTH-1:0] bin_next  = bin_out + (en ? 1'b1 : 1'b0);
    wire [WIDTH-1:0] gray_next = (bin_next >> 1) ^ bin_next;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_out  <= {WIDTH{1'b0}};
            gray_out <= {WIDTH{1'b0}};
        end else begin
            bin_out  <= bin_next;
            gray_out <= gray_next;
        end
    end

endmodule

`default_nettype wire
