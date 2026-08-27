`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/01/2026 10:34:38 PM
// Design Name: 
// Module Name: gemm_sequencer_tb
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


module gemm_sequencer_tb();
parameter MAX_N=128, DATA_WIDTH=8, ACC_WIDTH=32, ARRAY_N=8;

logic clk=0, rst, start;
logic [4:0] tiles;
logic        accumulating;
logic signed [63:0] rdataA, rdataB;
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
logic signed [63:0] wdataA, wdataB;
logic signed [255:0] rdataC;

parameter N = 64;
parameter TILES = N / ARRAY_N;

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

assign accumulating = 1'b0;
assign rdataC_in    = 256'd0;

tile_bram #(.WIDTH(64),  .DEPTH(N*N/8)) A_buf(.clk(clk), .we(weA), .waddr(waddrA), .raddr(raddrA), .wdata(wdataA), .rdata(rdataA));
tile_bram #(.WIDTH(64),  .DEPTH(N*N/8)) B_buf(.clk(clk), .we(weB), .waddr(waddrB), .raddr(raddrB), .wdata(wdataB), .rdata(rdataB));
tile_bram #(.WIDTH(256), .DEPTH(N*N/8)) C_buf(.clk(clk), .we(weC), .waddr(waddrC), .raddr(raddrC), .wdata(wdataC), .rdata(rdataC));

always #5 clk = ~clk;

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

task run_case(bit reset_first);
  int fails, missing;

  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      C_gold[r][c] = 0;
      C_seen[r][c] = 0;
      C_got[r][c]  = 0;
      for (int kk = 0; kk < N; kk++)
        C_gold[r][c] += A[r][kk] * B[kk][c];
    end

  if (reset_first) begin
    rst = 1; start = 0;
    weA = 0; weB = 0; raddrC = 0;
    @(negedge clk); @(negedge clk);
    rst = 0;
  end
  tiles = TILES;
  addrAoffset = 0; addrBoffset = 0; addrCoffset = 0;

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

  @(negedge clk); start = 1;
  @(negedge clk); start = 0;

  fork
    begin wait(done); end
    begin #(N*N*N*10 + 100000); $display("TIMEOUT (reset_first=%0d)", reset_first); total_fails++; end
  join_any
  disable fork;

  repeat (4) @(negedge clk);

  fails = 0; missing = 0;
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      if (!C_seen[r][c]) missing++;
      else if (C_got[r][c] !== C_gold[r][c]) begin
        if (fails < 5)
          $display("  MISMATCH C[%0d][%0d] got %0d exp %0d", r, c, C_got[r][c], C_gold[r][c]);
        fails++;
      end
    end

  if (fails == 0 && missing == 0)
    $display("reset_first=%0d  PASS  (%0d elements)", reset_first, N*N);
  else begin
    $display("reset_first=%0d  FAIL  missing=%0d mismatches=%0d of %0d", reset_first, missing, fails, N*N);
    total_fails++;
  end
endtask

initial begin
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      A[r][c] = $urandom_range(0, 255) - 128;
      B[r][c] = $urandom_range(0, 255) - 128;
    end

  $display("BACK-TO-BACK, NO RESET BETWEEN TRIGGERS (N=%0d)", N);
  run_case(1);   // one reset, establishes clean state
  run_case(0);   // 2nd trigger, no reset
  run_case(0);   // 3rd trigger, no reset -- this is the one that hung on hardware
  run_case(0);   // 4th, for margin

  $display("========================================");
  if (total_fails == 0) $display("ALL CASES PASS");
  else                  $display("%0d CASES FAILED", total_fails);
  $finish;
end
endmodule
