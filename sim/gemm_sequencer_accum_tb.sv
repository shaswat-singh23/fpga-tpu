`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/18/2026 11:44:15 AM
// Design Name: 
// Module Name: gemm_sequencer_accum_tb
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


module gemm_sequencer_accum_tb();
parameter MAX_N=128, ARRAY_N=8;
parameter N = 64;
parameter TILES = N / ARRAY_N;

logic clk=0, rst, start;
logic [4:0] tiles;
logic accumulating;
logic signed [63:0] rdataA, rdataB;
logic signed [255:0] rdataC_in;
logic [13:0] addrAoffset, addrBoffset, addrCoffset;
logic [13:0] raddrA, waddrC, raddrC_out;
logic [13:0] raddrB;
logic weC, done;
logic signed [255:0] wdataC;

logic weA, weB;
logic [13:0] waddrA;
logic [13:0] waddrB;
logic signed [63:0] wdataA, wdataB;
logic signed [255:0] rdataC;

logic signed [7:0]  A [0:N-1][0:N-1];
logic signed [7:0]  B [0:N-1][0:N-1];
logic signed [31:0] C_gold [0:N-1][0:N-1];
logic signed [31:0] C_got  [0:N-1][0:N-1];
logic C_seen [0:N-1][0:N-1];

int total_fails = 0;

gemm_sequencer #(.MAX_N(MAX_N), .DATA_WIDTH(8), .ACC_WIDTH(32), .ARRAY_N(8)) dut(
  .clk(clk), .rst(rst), .start(start), .tiles(tiles),
  .accumulating(accumulating),
  .rdataA(rdataA), .rdataB(rdataB), .rdataC(rdataC_in),
  .addrAoffset(addrAoffset), .addrBoffset(addrBoffset), .addrCoffset(addrCoffset),
  .raddrA(raddrA), .raddrB(raddrB), .waddrC(waddrC), .raddrC(raddrC_out),
  .weC(weC), .done(done), .wdataC(wdataC)
);

tile_bram #(.WIDTH(64),  .DEPTH(N*N/8)) A_buf(.clk(clk), .we(weA), .waddr(waddrA), .raddr(raddrA), .wdata(wdataA), .rdata(rdataA));
tile_bram #(.WIDTH(64),  .DEPTH(N*N/8)) B_buf(.clk(clk), .we(weB), .waddr(waddrB), .raddr(raddrB), .wdata(wdataB), .rdata(rdataB));
tile_bram #(.WIDTH(256), .DEPTH(N*N/8)) C_buf(.clk(clk), .we(weC), .waddr(waddrC), .raddr(raddrC_out), .wdata(wdataC), .rdata(rdataC));

// C_buf feedback loop: DUT reads C_buf via raddrC_out, gets rdataC back
assign rdataC_in = rdataC;

always #5 clk = ~clk;

// Snoop C writes - same as your existing TB
always @(posedge clk) begin
  if (weC) begin
    automatic int tile_idx = waddrC / ARRAY_N;
    automatic int col      = waddrC % ARRAY_N;
    automatic int tj = tile_idx / TILES;
    automatic int ti = tile_idx % TILES;
    for (int r = 0; r < ARRAY_N; r++) begin
      C_got [ti*8+r][tj*8+col] = wdataC[r*32 +: 32];
      C_seen[ti*8+r][tj*8+col] = 1;
    end
  end
end

task load_AB();
  for (int ti = 0; ti < TILES; ti++)
    for (int tk = 0; tk < TILES; tk++)
      for (int r = 0; r < ARRAY_N; r++) begin
        @(negedge clk);
        weA = 1;
        waddrA = ti*TILES*ARRAY_N + tk*ARRAY_N + r;
        for (int c = 0; c < ARRAY_N; c++)
          wdataA[c*8 +: 8] = A[ti*8+r][tk*8+c];
      end
  @(negedge clk); weA = 0;

  for (int tj = 0; tj < TILES; tj++)
    for (int tk = 0; tk < TILES; tk++)
      for (int col = 0; col < ARRAY_N; col++) begin
        @(negedge clk);
        weB = 1;
        waddrB = tj*TILES*ARRAY_N + tk*ARRAY_N + col;
        for (int p = 0; p < ARRAY_N; p++)
          wdataB[p*8 +: 8] = B[tk*8+p][tj*8+col];
      end
  @(negedge clk); weB = 0;
endtask

task compute_gold(bit accum);
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      if (!accum) C_gold[r][c] = 0;
      for (int kk = 0; kk < N; kk++)
        C_gold[r][c] += A[r][kk] * B[kk][c];
    end
endtask

task run_matmul(bit accum, string label);
  int fails, missing;

  accumulating = accum;
  tiles = TILES;
  addrAoffset = 0; addrBoffset = 0; addrCoffset = 0;

  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      C_seen[r][c] = 0;
      C_got[r][c]  = 0;
    end

  @(negedge clk); start = 1;
  @(negedge clk); start = 0;

  fork
    begin wait(done); end
    begin #(N*N*N*10 + 100000); $display("TIMEOUT: %s", label); total_fails++; end
  join_any
  disable fork;

  repeat (4) @(negedge clk);

  fails = 0; missing = 0;
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      if (!C_seen[r][c]) missing++;
      else if (C_got[r][c] !== C_gold[r][c]) begin
        if (fails < 10)
          $display("  MISMATCH %s C[%0d][%0d] got %0d exp %0d", label, r, c, C_got[r][c], C_gold[r][c]);
        fails++;
      end
    end

  if (fails == 0 && missing == 0)
    $display("%s  PASS  (%0d elements)", label, N*N);
  else begin
    $display("%s  FAIL  missing=%0d mismatches=%0d", label, missing, fails);
    total_fails++;
  end
endtask

initial begin
  rst = 1; start = 0; accumulating = 0;
  weA = 0; weB = 0;
  @(negedge clk); @(negedge clk);
  rst = 0;

  // --- Generate A1, B1 ---
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      A[r][c] = $urandom_range(0, 255) - 128;
      B[r][c] = $urandom_range(0, 255) - 128;
    end

  // T1: baseline non-accumulate - C = A1*B1
  load_AB();
  compute_gold(0);
  run_matmul(0, "T1:A1*B1,acc=0");

  // T2: same A1*B1 again, accumulate=1 - C = 2*(A1*B1)
  // A_buf/B_buf still hold A1,B1, no reload
  compute_gold(1);
  run_matmul(1, "T2:A1*B1,acc=1");

  // --- Generate A2, B2 ---
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      A[r][c] = $urandom_range(0, 255) - 128;
      B[r][c] = $urandom_range(0, 255) - 128;
    end

  // T3: different data, accumulate=1 - C = 2*(A1*B1) + A2*B2
  load_AB();
  compute_gold(1);
  run_matmul(1, "T3:A2*B2,acc=1");

  // T4: accumulate=0 overwrite - C = A2*B2 (proves acc=0 still overwrites)
  // A_buf/B_buf still hold A2,B2
  compute_gold(0);
  run_matmul(0, "T4:A2*B2,acc=0");

  $display("========================================");
  if (total_fails == 0) $display("ALL TRIALS PASS");
  else                  $display("%0d TRIALS FAILED", total_fails);
  $finish;
end

initial begin
  #50000000;
  $display("GLOBAL TIMEOUT");
  $finish;
end
endmodule
