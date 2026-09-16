`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/16/2026 05:50:33 PM
// Design Name: 
// Module Name: gemm_sequencer_perf
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// gemm_sequencer_perf_tb.sv
// Cycle-count / throughput testbench for gemm_sequencer.
// Sweeps N = 16..128 (step 16), loads A/B into the tile BRAMs, pulses start,
// counts clock cycles from start to done, checks the result against a golden
// model, and prints sustained GOPS at F_MHZ (set this to your post-impl fmax).
//
// Reported numbers EXCLUDE the BRAM load phase - this is "sustained GEMM
// throughput with operands on-chip", say so on the resume.

`timescale 1ns/1ps
module gemm_sequencer_perf_tb();
  parameter MAX_N      = 128;
  parameter DATA_WIDTH = 8;
  parameter ACC_WIDTH  = 32;
  parameter ARRAY_N    = 8;
  parameter real F_MHZ = 52.6;      // <-- achieved post-implementation clock (WNS >= 0)
  parameter N_MIN = 16, N_MAX = 128, N_STEP = 16;

  logic clk = 0, rst, start;
  logic [4:0] tiles;
  logic accumulating;
  logic signed [63:0]  rdataA, rdataB;
  logic signed [255:0] rdataC_in;
  logic [13:0] addrAoffset, addrBoffset, addrCoffset;
  logic [13:0] raddrA, waddrC;
  logic [10:0] raddrB;
  logic [13:0] raddrC_out;
  logic weC, done;
  logic signed [255:0] wdataC;

  logic weA, weB;
  logic [13:0] waddrA, raddrC;
  logic [10:0] waddrB;
  logic signed [63:0]  wdataA, wdataB;
  logic signed [255:0] rdataC;

  // Sized for MAX_N; only the [0:N-1] corner is used per run.
  logic signed [7:0]  A      [0:MAX_N-1][0:MAX_N-1];
  logic signed [7:0]  B      [0:MAX_N-1][0:MAX_N-1];
  logic signed [31:0] C_gold [0:MAX_N-1][0:MAX_N-1];
  logic signed [31:0] C_got  [0:MAX_N-1][0:MAX_N-1];
  logic               C_seen [0:MAX_N-1][0:MAX_N-1];

  int N, TILES;
  int total_fails = 0;

  // ---- cycle counters ----
  logic counting = 0;
  longint cyc_total   = 0;   // start -> done
  longint cyc_first_w = -1;  // start -> first C write (fill latency)
  longint cyc_last_w  = -1;  // start -> last C write (drain)
  longint n_writes    = 0;

  gemm_sequencer #(.MAX_N(MAX_N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .ARRAY_N(ARRAY_N)) dut (
    .clk(clk), .rst(rst), .start(start), .tiles(tiles),
    .accumulating(accumulating),
    .rdataA(rdataA), .rdataB(rdataB), .rdataC(rdataC_in),
    .addrAoffset(addrAoffset), .addrBoffset(addrBoffset), .addrCoffset(addrCoffset),
    .raddrA(raddrA), .raddrB(raddrB), .waddrC(waddrC), .raddrC(raddrC_out),
    .weC(weC), .done(done), .wdataC(wdataC)
  );

  assign accumulating = 1'b0;
  assign rdataC_in    = 256'd0;

  tile_bram #(.WIDTH(64),  .DEPTH(MAX_N*MAX_N/8)) A_buf(.clk(clk), .we(weA), .waddr(waddrA), .raddr(raddrA), .wdata(wdataA), .rdata(rdataA));
  tile_bram #(.WIDTH(64),  .DEPTH(MAX_N*MAX_N/8)) B_buf(.clk(clk), .we(weB), .waddr(waddrB), .raddr(raddrB), .wdata(wdataB), .rdata(rdataB));
  tile_bram #(.WIDTH(256), .DEPTH(MAX_N*MAX_N/8)) C_buf(.clk(clk), .we(weC), .waddr(waddrC), .raddr(raddrC), .wdata(wdataC), .rdata(rdataC));

  always #5 clk = ~clk;   // period irrelevant; we count cycles, not time

  // Count cycles while the GEMM is in flight
  always @(posedge clk) begin
    if (counting) begin
      cyc_total++;
      if (weC) begin
        n_writes++;
        if (cyc_first_w < 0) cyc_first_w = cyc_total;
        cyc_last_w = cyc_total;
      end
    end
  end

  // Capture C writes (same tile/column decode as the original TB)
  always @(posedge clk) begin
    if (weC) begin
      automatic int tile_idx = waddrC / ARRAY_N;
      automatic int col      = waddrC % ARRAY_N;
      automatic int tj = tile_idx / TILES;
      automatic int ti = tile_idx % TILES;
      for (int r = 0; r < ARRAY_N; r++) begin
        C_got [ti*ARRAY_N+r][tj*ARRAY_N+col] = wdataC[r*32 +: 32];
        C_seen[ti*ARRAY_N+r][tj*ARRAY_N+col] = 1;
      end
    end
  end

  task automatic run_size(int n);
    int fails, missing;
    real cycles, secs, gops, peak_gops, util, ideal_cycles;

    N = n; TILES = n / ARRAY_N;

    // fresh random operands + golden model
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++) begin
        A[r][c] = $urandom_range(0, 255) - 128;
        B[r][c] = $urandom_range(0, 255) - 128;
      end
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++) begin
        C_gold[r][c] = 0; C_seen[r][c] = 0; C_got[r][c] = 0;
        for (int kk = 0; kk < N; kk++)
          C_gold[r][c] += A[r][kk] * B[kk][c];
      end

    // reset between sizes so each measurement is independent
    rst = 1; start = 0; weA = 0; weB = 0; raddrC = 0; counting = 0;
    @(negedge clk); @(negedge clk);
    rst = 0;
    tiles = TILES;
    addrAoffset = 0; addrBoffset = 0; addrCoffset = 0;

    // ---- load A (row-tiles) ----
    for (int ti = 0; ti < TILES; ti++)
      for (int tk = 0; tk < TILES; tk++)
        for (int r = 0; r < ARRAY_N; r++) begin
          @(negedge clk);
          weA = 1;
          waddrA = ti*TILES*ARRAY_N + tk*ARRAY_N + r;
          for (int c = 0; c < ARRAY_N; c++)
            wdataA[c*8 +: 8] = A[ti*ARRAY_N+r][tk*ARRAY_N+c];
        end
    @(negedge clk); weA = 0;

    // ---- load B (column-tiles) ----
    for (int tj = 0; tj < TILES; tj++)
      for (int tk = 0; tk < TILES; tk++)
        for (int col = 0; col < ARRAY_N; col++) begin
          @(negedge clk);
          weB = 1;
          waddrB = tj*TILES*ARRAY_N + tk*ARRAY_N + col;
          for (int p = 0; p < ARRAY_N; p++)
            wdataB[p*8 +: 8] = B[tk*ARRAY_N+p][tj*ARRAY_N+col];
        end
    @(negedge clk); weB = 0;

    // ---- timed region: start -> done ----
    cyc_total = 0; cyc_first_w = -1; cyc_last_w = -1; n_writes = 0;
    @(negedge clk);
    start = 1; counting = 1;
    @(negedge clk);
    start = 0;

    fork
      begin wait(done); end
      begin #(longint'(N)*N*N*10 + 100000); $display("  TIMEOUT at N=%0d", N); total_fails++; end
    join_any
    disable fork;
    @(posedge clk); counting = 0;   // include the cycle in which done rose

    repeat (4) @(negedge clk);

    // ---- correctness ----
    fails = 0; missing = 0;
    for (int r = 0; r < N; r++)
      for (int c = 0; c < N; c++) begin
        if (!C_seen[r][c]) missing++;
        else if (C_got[r][c] !== C_gold[r][c]) begin
          if (fails < 3) $display("  MISMATCH C[%0d][%0d] got %0d exp %0d", r, c, C_got[r][c], C_gold[r][c]);
          fails++;
        end
      end
    if (fails || missing) total_fails++;

    // ---- throughput ----
    cycles       = cyc_total;
    secs         = cycles / (F_MHZ * 1.0e6);
    gops         = (2.0 * N * N * N) / secs / 1.0e9;
    peak_gops    = 2.0 * ARRAY_N * ARRAY_N * F_MHZ / 1.0e3;
    ideal_cycles = (1.0 * N * N * N) / (ARRAY_N * ARRAY_N);   // 1 MAC/PE/cycle, no fill/drain
    util         = ideal_cycles / cycles;

    $display("N=%3d  %s  cycles=%0d  ideal=%0.0f  util=%5.1f%%  first_wr=%0d  last_wr=%0d  writes=%0d  |  %.3f GOPS sustained @ %.1f MHz (peak %.3f)",
             N, (fails||missing) ? "FAIL" : "PASS", cyc_total, ideal_cycles, util*100.0,
             cyc_first_w, cyc_last_w, n_writes, gops, F_MHZ, peak_gops);
  endtask

  initial begin
    $display("gemm_sequencer throughput sweep  ARRAY_N=%0d  F=%.1f MHz", ARRAY_N, F_MHZ);
    $display("(cycles measured start->done, operands preloaded in BRAM)");
    for (int n = N_MIN; n <= N_MAX; n += N_STEP) run_size(n);
    $display("========================================");
    if (total_fails == 0) $display("ALL SIZES PASS");
    else                  $display("%0d SIZES FAILED -- throughput numbers for failed sizes are meaningless", total_fails);
    $finish;
  end
endmodule
