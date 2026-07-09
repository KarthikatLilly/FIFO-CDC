//==============================================================================
// fifomem.v  -- Dual-Port FIFO Memory
//
// Synchronous read (BRAM-inferable). Write port in the wclk domain, read port
// in the rclk domain. rd_data has one cycle of latency after rd_en_gated;
// rd_valid is a delayed-by-one copy of rd_en_gated marking rd_data valid.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module fifomem #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 4
)(
    // Write port (wclk domain)
    input  wire                   wclk,
    input  wire                   wr_en_gated,   // wr_en & ~full (from top)
    input  wire [ADDR_WIDTH-1:0]  wr_addr,       // wptr_bin[ADDR_WIDTH-1:0]
    input  wire [DATA_WIDTH-1:0]  wr_data,
    // Read port (rclk domain)
    input  wire                   rclk,
    input  wire                   rd_en_gated,   // rd_en & ~empty (from top)
    input  wire [ADDR_WIDTH-1:0]  rd_addr,       // rptr_bin[ADDR_WIDTH-1:0]
    output reg  [DATA_WIDTH-1:0]  rd_data,       // registered, 1-cycle latency
    output reg                    rd_valid       // marks rd_data valid
);

    // Storage array (inferred as BRAM by Vivado for the synchronous-read form).
    reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    // Write port
    always @(posedge wclk) begin
        if (wr_en_gated)
            mem[wr_addr] <= wr_data;
    end

    // Read port (synchronous read + valid pipeline)
    always @(posedge rclk) begin
        if (rd_en_gated)
            rd_data <= mem[rd_addr];
        rd_valid <= rd_en_gated;
    end

endmodule

`default_nettype wire
