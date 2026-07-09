//==============================================================================
// async_fifo_top.v  -- Top-Level Async FIFO CDC Bridge
//
// Cummings dual-clock FIFO: Gray-coded pointers + double-flop synchronizers,
// plus a per-domain reset synchronizer and a hysteresis backpressure
// controller. Data crosses from the fast write domain (wclk) to the slow read
// domain (rclk).
//
// Instantiates: 2x rst_sync, wptr_full, rptr_empty, sync_r2w, sync_w2r,
// fifomem, backpressure_ctrl. Write/read gating is computed here at the top.
//------------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module async_fifo_top #(
    parameter DATA_WIDTH     = 8,
    parameter ADDR_WIDTH     = 4,
    parameter ALMOST_FULL_HI = 14,
    parameter ALMOST_FULL_LO = 10,
    parameter SYNC_STAGES    = 2
)(
    input  wire                  rst_n,         // single async top-level reset

    // Write domain
    input  wire                  wclk,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,
    output wire                  almost_full,
    output wire                  stall,
    output wire [ADDR_WIDTH:0]   wr_occupancy,  // debug/monitor + Python script

    // Read domain
    input  wire                  rclk,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  rd_valid,
    output wire                  empty
);

    //--------------------------------------------------------------------------
    // Per-domain reset synchronizers. rst_sync is the ONLY place the raw
    // async rst_n is allowed to be used directly.
    //--------------------------------------------------------------------------
    wire wrst_n_sync;
    wire rrst_n_sync;

    rst_sync #(.SYNC_STAGES(SYNC_STAGES)) u_wrst (
        .clk         (wclk),
        .async_rst_n (rst_n),
        .sync_rst_n  (wrst_n_sync)
    );

    rst_sync #(.SYNC_STAGES(SYNC_STAGES)) u_rrst (
        .clk         (rclk),
        .async_rst_n (rst_n),
        .sync_rst_n  (rrst_n_sync)
    );

    //--------------------------------------------------------------------------
    // Cross-domain pointer buses.
    //--------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] wptr_bin;
    wire [ADDR_WIDTH:0] wptr_gray;
    wire [ADDR_WIDTH:0] rptr_bin;
    wire [ADDR_WIDTH:0] rptr_gray;

    wire [ADDR_WIDTH:0] wptr_gray_sync;  // wptr in read domain
    wire [ADDR_WIDTH:0] rptr_gray_sync;  // rptr in write domain

    //--------------------------------------------------------------------------
    // Write-pointer domain logic (counter + full + occupancy).
    //--------------------------------------------------------------------------
    wptr_full #(.ADDR_WIDTH(ADDR_WIDTH)) u_wptr_full (
        .wclk           (wclk),
        .wrst_n_sync    (wrst_n_sync),
        .wr_en          (wr_en),
        .rptr_gray_sync (rptr_gray_sync),
        .wptr_bin       (wptr_bin),
        .wptr_gray      (wptr_gray),
        .full           (full),
        .wr_occupancy   (wr_occupancy)
    );

    //--------------------------------------------------------------------------
    // Read-pointer domain logic (counter + empty).
    //--------------------------------------------------------------------------
    rptr_empty #(.ADDR_WIDTH(ADDR_WIDTH)) u_rptr_empty (
        .rclk           (rclk),
        .rrst_n_sync    (rrst_n_sync),
        .rd_en          (rd_en),
        .wptr_gray_sync (wptr_gray_sync),
        .rptr_bin       (rptr_bin),
        .rptr_gray      (rptr_gray),
        .empty          (empty)
    );

    //--------------------------------------------------------------------------
    // Pointer synchronizers.
    //--------------------------------------------------------------------------
    sync_r2w #(.ADDR_WIDTH(ADDR_WIDTH), .SYNC_STAGES(SYNC_STAGES)) u_sync_r2w (
        .wclk               (wclk),
        .wrst_n_sync        (wrst_n_sync),
        .rptr_gray_in       (rptr_gray),
        .rptr_gray_sync_out (rptr_gray_sync)
    );

    sync_w2r #(.ADDR_WIDTH(ADDR_WIDTH), .SYNC_STAGES(SYNC_STAGES)) u_sync_w2r (
        .rclk               (rclk),
        .rrst_n_sync        (rrst_n_sync),
        .wptr_gray_in       (wptr_gray),
        .wptr_gray_sync_out (wptr_gray_sync)
    );

    //--------------------------------------------------------------------------
    // Write/read gating (computed here at the top level).
    //--------------------------------------------------------------------------
    wire wr_en_gated = wr_en & ~full;
    wire rd_en_gated = rd_en & ~empty;

    //--------------------------------------------------------------------------
    // Dual-port memory.
    //--------------------------------------------------------------------------
    fifomem #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) u_fifomem (
        .wclk        (wclk),
        .wr_en_gated (wr_en_gated),
        .wr_addr     (wptr_bin[ADDR_WIDTH-1:0]),
        .wr_data     (wr_data),
        .rclk        (rclk),
        .rd_en_gated (rd_en_gated),
        .rd_addr     (rptr_bin[ADDR_WIDTH-1:0]),
        .rd_data     (rd_data),
        .rd_valid    (rd_valid)
    );

    //--------------------------------------------------------------------------
    // Hysteresis backpressure controller.
    //--------------------------------------------------------------------------
    backpressure_ctrl #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .ALMOST_FULL_HI (ALMOST_FULL_HI),
        .ALMOST_FULL_LO (ALMOST_FULL_LO)
    ) u_bp (
        .wclk         (wclk),
        .wrst_n_sync  (wrst_n_sync),
        .wr_occupancy (wr_occupancy),
        .almost_full  (almost_full),
        .stall        (stall)
    );

endmodule

`default_nettype wire
