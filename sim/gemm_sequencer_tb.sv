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
logic signed [63:0] rdataA, rdataB;
logic [13:0] addrAoffset, addrCoffset;
logic [13:0] raddrA, waddrC;
logic [10:0] raddrB;
logic weC, done;
logic signed [255:0] wdataC;

logic weA, weB;
logic [13:0] waddrA, raddrC;
logic [10:0] waddrB;
logic signed [63:0] wdataA, wdataB;
logic signed [255:0] rdataC;

// full-size reference, sliced per run
logic signed [7:0]  A [0:MAX_N-1][0:MAX_N-1];
logic signed [7:0]  B [0:MAX_N-1][0:MAX_N-1];
logic signed [31:0] C_gold [0:MAX_N-1][0:MAX_N-1];
logic signed [31:0] C_got  [0:MAX_N-1][0:MAX_N-1];
logic C_seen [0:MAX_N-1][0:MAX_N-1];

int cur_N, cur_tiles;
int total_fails = 0;

gemm_sequencer #(.MAX_N(MAX_N), .DATA_WIDTH(8), .ACC_WIDTH(32), .ARRAY_N(8)) dut(
  .clk(clk), .rst(rst), .start(start), .tiles(tiles),
  .rdataA(rdataA), .rdataB(rdataB),
  .addrAoffset(addrAoffset), .addrCoffset(addrCoffset),
  .raddrA(raddrA), .raddrB(raddrB), .waddrC(waddrC),
  .weC(weC), .done(done), .wdataC(wdataC)
);

tile_bram #(.WIDTH(64),  .DEPTH(MAX_N*MAX_N/8)) A_buf(.clk(clk), .we(weA), .waddr(waddrA), .raddr(raddrA), .wdata(wdataA), .rdata(rdataA));
tile_bram #(.WIDTH(64),  .DEPTH(MAX_N*MAX_N/8)) B_buf(.clk(clk), .we(weB), .waddr(waddrB), .raddr(raddrB), .wdata(wdataB), .rdata(rdataB));
tile_bram #(.WIDTH(256), .DEPTH(MAX_N*MAX_N/8)) C_buf(.clk(clk), .we(weC), .waddr(waddrC), .raddr(raddrC), .wdata(wdataC), .rdata(rdataC));

always #5 clk = ~clk;

always @(posedge clk) begin
  if (weC) begin
    automatic int tile_idx = waddrC / ARRAY_N;
    automatic int row      = waddrC % ARRAY_N;
    automatic int ti = tile_idx / cur_tiles;
    automatic int tj = tile_idx % cur_tiles;
    for (int c = 0; c < ARRAY_N; c++) begin
      C_got [ti*8+row][tj*8+c] = wdataC[c*32 +: 32];
      C_seen[ti*8+row][tj*8+c] = 1;
    end
  end
end

task run_case(int N);
  int fails, missing;
  cur_N = N;
  cur_tiles = N/ARRAY_N;

  // golden model for this N
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      C_gold[r][c] = 0;
      C_seen[r][c] = 0;
      C_got[r][c]  = 0;
      for (int kk = 0; kk < N; kk++)
        C_gold[r][c] += A[r][kk] * B[kk][c];
    end

  rst = 1; start = 0;
  tiles = cur_tiles;
  addrAoffset = 0; addrCoffset = 0;
  weA = 0; weB = 0; raddrC = 0;
  @(negedge clk); @(negedge clk);
  rst = 0;

  // A: tile-major, row-major within tile
  for (int ti = 0; ti < cur_tiles; ti++)
    for (int tk = 0; tk < cur_tiles; tk++)
      for (int r = 0; r < ARRAY_N; r++) begin
        @(negedge clk);
        weA = 1;
        waddrA = ti*cur_tiles*ARRAY_N + tk*ARRAY_N + r;
        for (int c = 0; c < ARRAY_N; c++)
          wdataA[c*8 +: 8] = A[ti*8+r][tk*8+c];
      end
  @(negedge clk); weA = 0;

  // B: tile-major, column-major within tile
  for (int tj = 0; tj < cur_tiles; tj++)
    for (int tk = 0; tk < cur_tiles; tk++)
      for (int col = 0; col < ARRAY_N; col++) begin
        @(negedge clk);
        weB = 1;
        waddrB = tj*cur_tiles*ARRAY_N + tk*ARRAY_N + col;
        for (int p = 0; p < ARRAY_N; p++)
          wdataB[p*8 +: 8] = B[tk*8+p][tj*8+col];
      end
  @(negedge clk); weB = 0;

  @(negedge clk); start = 1;
  @(negedge clk); start = 0;

  fork
    begin wait(done); end
    begin #(N*N*N*10 + 100000); $display("N=%0d TIMEOUT", N); total_fails++; end
  join_any
  disable fork;

  repeat (4) @(negedge clk);

  fails = 0; missing = 0;
  for (int r = 0; r < N; r++)
    for (int c = 0; c < N; c++) begin
      if (!C_seen[r][c]) missing++;
      else if (C_got[r][c] !== C_gold[r][c]) begin
        if (fails < 5)
          $display("  N=%0d MISMATCH C[%0d][%0d] got %0d exp %0d", N, r, c, C_got[r][c], C_gold[r][c]);
        fails++;
      end
    end

  if (fails == 0 && missing == 0)
    $display("N=%0d  PASS  (%0d elements)", N, N*N);
  else begin
    $display("N=%0d  FAIL  missing=%0d mismatches=%0d of %0d", N, missing, fails, N*N);
    total_fails++;
  end
endtask

initial begin
  for (int r = 0; r < MAX_N; r++)
    for (int c = 0; c < MAX_N; c++) begin
      A[r][c] = $urandom_range(0, 255) - 128;
      B[r][c] = $urandom_range(0, 255) - 128;
    end

  for (int n = 16; n <= 128; n += 8)
    run_case(n);

  $display("========================================");
  if (total_fails == 0) $display("ALL CASES PASS");
  else                  $display("%0d CASES FAILED", total_fails);
  $finish;
end
endmodule
