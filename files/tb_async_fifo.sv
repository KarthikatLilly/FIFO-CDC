//==============================================================================
// tb_async_fifo.sv  -- Testbench for async_fifo_top
//
// Three scenarios:
//   Test 1  Burst overflow  -- fill to full, keep writing while full (must be
//                              ignored), then drain and scoreboard-check order.
//   Test 2  Backpressure    -- fast writes + slow intermittent reads; confirm
//                              almost_full asserts at ALMOST_FULL_HI and
//                              deasserts at ALMOST_FULL_LO (occupancy logged).
//   Test 3  Randomized dual-clock stress -- NUM_RANDOM_TRANSACTIONS wclk cycles
//                              of randomized wr/rd with a golden-queue scoreboard.
//
// SystemVerilog constructs (queues, covergroup) are XSIM-supported.
//==============================================================================
`timescale 1ns/1ps

module tb_async_fifo;

    //--------------------------------------------------------------------------
    // Parameters
    //--------------------------------------------------------------------------
    localparam int DATA_WIDTH             = 8;
    localparam int ADDR_WIDTH             = 4;
    localparam int DEPTH                  = (1 << ADDR_WIDTH);   // 16
    localparam int ALMOST_FULL_HI         = 14;
    localparam int ALMOST_FULL_LO         = 10;
    localparam int SYNC_STAGES            = 2;
    localparam int NUM_RANDOM_TRANSACTIONS = 10000;
    localparam int WR_PROB                = 70;   // % chance wr_en per wclk
    localparam int RD_PROB                = 50;   // % chance rd_en per rclk

    localparam real WCLK_PERIOD = 10.0;   // 100 MHz
    localparam real RCLK_PERIOD = 27.0;   // ~37 MHz (non-integer ratio)

    //--------------------------------------------------------------------------
    // DUT I/O
    //--------------------------------------------------------------------------
    logic                  wclk, rclk, rst_n;
    logic                  wr_en, rd_en;
    logic [DATA_WIDTH-1:0] wr_data;
    logic                  full, almost_full, stall, empty, rd_valid;
    logic [DATA_WIDTH-1:0] rd_data;
    logic [ADDR_WIDTH:0]   wr_occupancy;

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    async_fifo_top #(
        .DATA_WIDTH     (DATA_WIDTH),
        .ADDR_WIDTH     (ADDR_WIDTH),
        .ALMOST_FULL_HI (ALMOST_FULL_HI),
        .ALMOST_FULL_LO (ALMOST_FULL_LO),
        .SYNC_STAGES    (SYNC_STAGES)
    ) dut (
        .rst_n        (rst_n),
        .wclk         (wclk),
        .wr_en        (wr_en),
        .wr_data      (wr_data),
        .full         (full),
        .almost_full  (almost_full),
        .stall        (stall),
        .wr_occupancy (wr_occupancy),
        .rclk         (rclk),
        .rd_en        (rd_en),
        .rd_data      (rd_data),
        .rd_valid     (rd_valid),
        .empty        (empty)
    );

    //--------------------------------------------------------------------------
    // Clock generation
    //--------------------------------------------------------------------------
    initial begin wclk = 1'b0; forever #(WCLK_PERIOD/2.0) wclk = ~wclk; end
    initial begin rclk = 1'b0; forever #(RCLK_PERIOD/2.0) rclk = ~rclk; end

    //--------------------------------------------------------------------------
    // Metric counters / bookkeeping
    //--------------------------------------------------------------------------
    int total_writes_accepted = 0;
    int total_reads_valid     = 0;
    int mismatch_count        = 0;
    int max_occupancy         = 0;
    int full_assert_count     = 0;
    int almost_full_assert_count = 0;
    int empty_assert_count    = 0;

    logic prev_full = 1'b0, prev_afull = 1'b0, prev_empty = 1'b1;
    logic prev_afull_log = 1'b0;
    int   prev_occ = 0;   // occupancy one cycle earlier (the value that triggers a watermark edge)

    // Golden-reference scoreboard queue.
    bit [DATA_WIDTH-1:0] sb [$];
    logic [DATA_WIDTH-1:0] expected;

    //--------------------------------------------------------------------------
    // Combinational coverage helpers (valid at the sampling clock edge)
    //--------------------------------------------------------------------------
    wire wr_accept  = rst_n & wr_en & ~full;
    wire wrap_event = wr_accept & (dut.wptr_bin[ADDR_WIDTH-1:0] == {ADDR_WIDTH{1'b1}});
    wire wr_rd_same = wr_accept & rd_valid;

    //--------------------------------------------------------------------------
    // Functional coverage (sampled every wclk)
    //--------------------------------------------------------------------------
    covergroup cg_fifo @(posedge wclk);
        cp_full : coverpoint full        iff (rst_n) { bins asserted = {1'b1}; }
        cp_empty: coverpoint empty       iff (rst_n) { bins asserted = {1'b1}; }
        cp_afull: coverpoint almost_full iff (rst_n) { bins asserted = {1'b1}; }
        cp_occ  : coverpoint wr_occupancy iff (rst_n) {
            bins q0 = {[0        : DEPTH/4-1     ]};
            bins q1 = {[DEPTH/4  : DEPTH/2-1     ]};
            bins q2 = {[DEPTH/2  : 3*DEPTH/4-1   ]};
            bins q3 = {[3*DEPTH/4: DEPTH         ]};
        }
        cp_wrap : coverpoint wrap_event  iff (rst_n) { bins ev = {1'b1}; }
        cp_wrrd : coverpoint wr_rd_same  iff (rst_n) { bins ev = {1'b1}; }
    endgroup

    cg_fifo cg = new();

    //--------------------------------------------------------------------------
    // Monitor: accepted writes -> push scoreboard
    //--------------------------------------------------------------------------
    always @(posedge wclk) begin
        if (rst_n && wr_en && !full) begin
            total_writes_accepted <= total_writes_accepted + 1;
            sb.push_back(wr_data);
        end
    end

    //--------------------------------------------------------------------------
    // Monitor: valid reads -> pop scoreboard and compare
    //--------------------------------------------------------------------------
    always @(posedge rclk) begin
        if (rst_n && rd_valid) begin
            total_reads_valid <= total_reads_valid + 1;
            if (sb.size() == 0) begin
                $error("[%0t] Scoreboard UNDERFLOW: rd_valid asserted but scoreboard empty", $time);
                mismatch_count <= mismatch_count + 1;
            end else begin
                expected = sb.pop_front();
                if (rd_data !== expected) begin
                    $error("[%0t] MISMATCH: got 0x%0h expected 0x%0h", $time, rd_data, expected);
                    mismatch_count <= mismatch_count + 1;
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // Monitor: occupancy peak + full/almost_full assert edges (wclk domain)
    //--------------------------------------------------------------------------
    always @(posedge wclk) begin
        if (rst_n) begin
            if (wr_occupancy > max_occupancy) max_occupancy <= wr_occupancy;
            if (full && !prev_full)               full_assert_count        <= full_assert_count + 1;
            if (almost_full && !prev_afull)       almost_full_assert_count <= almost_full_assert_count + 1;

            // Watermark accuracy log (metric #4): report the occupancy that
            // TRIGGERED the edge (the value one cycle before the registered
            // flag flips), so it reads exactly ALMOST_FULL_HI / ALMOST_FULL_LO.
            if (almost_full && !prev_afull_log)
                $display("METRIC: ALMOST_FULL_ASSERT_AT_OCC = %0d (expect %0d)",
                         prev_occ, ALMOST_FULL_HI);
            if (!almost_full && prev_afull_log)
                $display("METRIC: ALMOST_FULL_DEASSERT_AT_OCC = %0d (expect %0d)",
                         prev_occ, ALMOST_FULL_LO);

            prev_full      <= full;
            prev_afull     <= almost_full;
            prev_afull_log <= almost_full;
            prev_occ       <= wr_occupancy;
        end
    end

    //--------------------------------------------------------------------------
    // Monitor: empty assert edges (rclk domain)
    //--------------------------------------------------------------------------
    always @(posedge rclk) begin
        if (rst_n) begin
            if (empty && !prev_empty) empty_assert_count <= empty_assert_count + 1;
            prev_empty <= empty;
        end
    end

    //--------------------------------------------------------------------------
    // Random / slow-read stimulus drivers (gated by run flags)
    //--------------------------------------------------------------------------
    logic run_wr_rand   = 1'b0;
    logic run_rd_rand   = 1'b0;
    logic run_slow_read = 1'b0;
    int   rand_cycles   = 0;
    int   slow_cnt      = 0;

    always @(posedge wclk) begin
        if (run_wr_rand) begin
            wr_en       <= ($urandom_range(0,99) < WR_PROB);
            wr_data     <= $urandom_range(0, (1<<DATA_WIDTH)-1);
            rand_cycles <= rand_cycles + 1;
        end
    end

    always @(posedge rclk) begin
        if (run_rd_rand)
            rd_en <= ($urandom_range(0,99) < RD_PROB);
        else if (run_slow_read) begin
            slow_cnt <= slow_cnt + 1;
            rd_en    <= (slow_cnt % 4 == 0);   // one read every 4 rclk cycles
        end
    end

    //--------------------------------------------------------------------------
    // Directed-test tasks
    //--------------------------------------------------------------------------
    task automatic test_burst_overflow;
        begin
            $display("[%0t] --- Test 1: Burst Overflow ---", $time);
            rd_en = 1'b0;
            @(posedge wclk);
            wr_en   <= 1'b1;
            wr_data <= 8'd1;
            // Write an incrementing pattern until full asserts.
            do begin
                @(posedge wclk);
                wr_data <= wr_data + 8'd1;
            end while (!full);
            // Keep writing several cycles while full -- hardware must ignore these.
            repeat (8) begin
                @(posedge wclk);
                wr_data <= wr_data + 8'd1;
            end
            @(posedge wclk);
            wr_en <= 1'b0;
        end
    endtask

    task automatic test_backpressure;
        begin
            $display("[%0t] --- Test 2: Backpressure / Slow Drain ---", $time);
            @(posedge wclk);
            wr_en       <= 1'b1;
            wr_data     <= 8'hA0;
            run_slow_read <= 1'b1;      // reads only ~every 4th rclk
            // Let occupancy climb past HI and get gated by full.
            repeat (250) begin
                @(posedge wclk);
                wr_data <= wr_data + 8'd1;
            end
            wr_en         <= 1'b0;
            run_slow_read <= 1'b0;
            @(posedge rclk);
            rd_en <= 1'b0;
        end
    endtask

    task automatic drain_fifo;
        begin
            wr_en <= 1'b0;
            @(posedge rclk);
            rd_en <= 1'b1;
            // Poll each rclk until FIFO empty AND scoreboard fully checked out.
            while (!(empty && (sb.size() == 0)))
                @(posedge rclk);
            repeat (4) @(posedge rclk);    // flush rd_valid pipeline
            rd_en <= 1'b0;
            @(posedge rclk);
        end
    endtask

    task automatic report_metrics;
        begin
            $display("========================================================");
            $display("METRIC: TOTAL_WRITES_ACCEPTED = %0d", total_writes_accepted);
            $display("METRIC: TOTAL_READS_VALID = %0d", total_reads_valid);
            $display("METRIC: SCOREBOARD_MISMATCHES = %0d", mismatch_count);
            $display("METRIC: MAX_OCCUPANCY = %0d", max_occupancy);
            $display("METRIC: FULL_ASSERT_COUNT = %0d", full_assert_count);
            $display("METRIC: ALMOST_FULL_ASSERT_COUNT = %0d", almost_full_assert_count);
            $display("METRIC: EMPTY_ASSERT_COUNT = %0d", empty_assert_count);
            $display("METRIC: COVERAGE_PCT = %0.2f", cg.get_coverage());
            $display("========================================================");
        end
    endtask

    //--------------------------------------------------------------------------
    // Main sequence
    //--------------------------------------------------------------------------
    initial begin
        // Init
        wr_en = 1'b0; rd_en = 1'b0; wr_data = '0;
        rst_n = 1'b0;

        // Reset: hold low for 100 ns, then release.
        #100;
        rst_n = 1'b1;
        repeat (5) @(posedge wclk);

        // Test 1
        test_burst_overflow();
        drain_fifo();

        // Test 2
        test_backpressure();
        drain_fifo();

        // Test 3 -- randomized dual-clock stress
        $display("[%0t] --- Test 3: Randomized Dual-Clock Stress (%0d cycles) ---",
                 $time, NUM_RANDOM_TRANSACTIONS);
        run_wr_rand = 1'b1;
        run_rd_rand = 1'b1;
        while (rand_cycles < NUM_RANDOM_TRANSACTIONS)
            @(posedge wclk);
        run_wr_rand = 1'b0;
        @(posedge wclk); wr_en <= 1'b0;
        run_rd_rand = 1'b0;
        @(posedge rclk); rd_en <= 1'b0;

        // Final drain + scoreboard check
        drain_fifo();
        repeat (20) @(posedge rclk);

        report_metrics();
        if (mismatch_count == 0)
            $display("[%0t] RESULT: PASS -- 0 scoreboard mismatches", $time);
        else
            $display("[%0t] RESULT: FAIL -- %0d mismatches", $time, mismatch_count);

        $finish;
    end

    //--------------------------------------------------------------------------
    // Simulation timeout guard
    //--------------------------------------------------------------------------
    initial begin
        #5_000_000;   // 5 ms
        $display("METRIC: SCOREBOARD_MISMATCHES = %0d", mismatch_count);
        $fatal(1, "[%0t] TIMEOUT -- simulation did not finish", $time);
    end

    //--------------------------------------------------------------------------
    // Waveform dump
    //--------------------------------------------------------------------------
    initial begin
        $dumpfile("async_fifo_waveform.vcd");
        $dumpvars(0, tb_async_fifo);
    end

endmodule
