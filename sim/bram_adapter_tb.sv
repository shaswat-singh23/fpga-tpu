`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/07/2026 11:38:32 PM
// Design Name: 
// Module Name: bram_adapter_tb
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


module bram_adapter_tb();
  logic clk=0, rst, start, dest;
  logic [13:0] bram_addr;
  logic done;
  logic [63:0] s_tdata;
  logic s_tvalid, s_tlast;
  logic s_tready;
  logic weA, weB;
  logic [13:0] waddr;
  logic [63:0] wdata;

  bram_adapter dut(
    .clk(clk), .rst(rst), .start(start), .dest(dest), .bram_addr(bram_addr),
    .done(done),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
    .weA(weA), .weB(weB), .waddr(waddr), .wdata(wdata)
  );

  always #5 clk = ~clk;

  logic [63:0] memA [0:16383];
  logic [63:0] memB [0:16383];
  always_ff @(posedge clk) begin
    if (weA) memA[waddr] <= wdata;
    if (weB) memB[waddr] <= wdata;
    if (weA && weB) $display("[%0t] FAIL: weA and weB both high", $time);
  end

  function [63:0] pattern(input [13:0] base, input int i, input logic d);
    pattern = {36'd0, base, i[13:0]} ^ (d ? 64'hA5A5_A5A5_A5A5_A5A5 : 64'h0);
  endfunction

  // one beat, respecting s_tready (hold data until accepted)
  task automatic beat(input [63:0] data, input logic last);
    s_tvalid = 1; s_tdata = data; s_tlast = last;
    do @(negedge clk); while (!s_tready);   // wait until accepted
  endtask

  task automatic run_load(input [13:0] base, input logic d, input int n,
                          input int stall_every, input string name);
    @(negedge clk);
    bram_addr = base; dest = d; start = 1;
    @(negedge clk); start = 0;

    for (int i=0;i<n;i++) begin
      if (stall_every>0 && i>0 && (i % stall_every)==0) begin
        s_tvalid = 0; s_tlast = 0; @(negedge clk);   // deliberate stall
      end
      beat(pattern(base,i,d), i==n-1);
    end
    s_tvalid = 0; s_tlast = 0;

    while (!done) @(negedge clk);   // wait for completion
    @(negedge clk);

    begin
      automatic int fails=0;
      for (int i=0;i<n;i++) begin
        automatic logic [63:0] got = d ? memB[base+i] : memA[base+i];
        if (got !== pattern(base,i,d)) begin
          if (fails<5) $display("  %s addr %0d got %h exp %h", name, base+i, got, pattern(base,i,d));
          fails++;
        end
      end
      $display("%s : %s", name, (fails==0)?"PASS":"FAIL");
    end
  endtask

  initial begin
    rst=1; start=0; s_tvalid=0; s_tlast=0; dest=0; bram_addr=0; s_tdata=0;
    repeat(3) @(negedge clk); rst=0;

    run_load(14'd0,   1'b0, 8,  0, "A short");
    run_load(14'd100, 1'b1, 8,  0, "B short");
    run_load(14'd200, 1'b0, 8,  0, "A re-arm");
    run_load(14'd0,   1'b1, 32, 0, "B larger");
    run_load(14'd500, 1'b0, 16, 3, "A stalls/3");
    run_load(14'd600, 1'b1, 20, 4, "B stalls/4");

    $display("done");
    $finish;
  end
endmodule
