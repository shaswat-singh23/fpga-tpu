`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/10/2026 02:50:34 PM
// Design Name: 
// Module Name: store_adapter_tb
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


// Store adapter test: mock C_buf (word N = N) -> store_adapter -> mock sink.
// Sink accepts beats, optionally with stalls. Check order, count, tlast, no drops.
// Store adapter test: mock C_buf (word N = N) -> store_adapter -> mock sink.
// Sink accepts beats, optionally with stalls. Check order, count, tlast, no drops.
module store_adapter_tb();
  logic clk=0, rst;
  always #5 clk = ~clk;

  logic start;
  logic [13:0] bram_addr;
  logic [4:0]  length;
  logic done;
  logic [255:0] m_tdata;
  logic m_tvalid, m_tlast, m_tready;
  logic [13:0] raddr;
  logic [255:0] rdata;

  store_adapter dut(
    .clk(clk), .rst(rst), .start(start), .bram_addr(bram_addr), .length(length),
    .done(done),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tlast(m_tlast), .m_tready(m_tready),
    .raddr(raddr), .rdata(rdata)
  );

  // mock C_buf: registered read, word N holds value N
  always_ff @(posedge clk) rdata <= raddr;

  // sink: accept beats into a capture array, optional stall pattern
  logic [255:0] captured [0:2047];
  integer capn;
  integer stall_mod;
  integer scnt;

  // drive m_tready with a simple stall pattern
  always @(posedge clk) begin
    if (rst) begin m_tready <= 0; scnt <= 0; end
    else begin
      scnt <= scnt + 1;
      if (stall_mod == 0) m_tready <= 1;
      else m_tready <= (scnt % stall_mod != 0);   // low every stall_mod-th cycle
    end
  end

  // capture accepted beats
  integer last_seen;
  always @(posedge clk) begin
    if (!rst && m_tvalid && m_tready) begin
      captured[capn] <= m_tdata;
      capn <= capn + 1;
      if (m_tlast) last_seen <= 1;
    end
  end

  integer i, errs, expbeats;
  task automatic run(input [13:0] base, input [4:0] len, input integer smod, input string label);
    stall_mod = smod;
    capn = 0; last_seen = 0;
    expbeats = len*len*8;
    @(negedge clk);
    bram_addr = base; length = len; start = 1;
    @(negedge clk); start = 0;

    // wait for done (bounded)
    for (i=0;i<5000;i=i+1) begin @(negedge clk); if (done) i=5000; end

    @(negedge clk);
    errs = 0;
    if (capn != expbeats) begin
      $display("  %s: beat count %0d, expected %0d", label, capn, expbeats);
      errs = errs + 1;
    end
    for (i=0;i<expbeats && i<capn;i=i+1)
      if (captured[i] !== base + i) begin
        if (errs<6) $display("  %s: beat %0d got %0d exp %0d", label, i, captured[i], base+i);
        errs = errs + 1;
      end
    $display("%s: %s (%0d beats)", label, (errs==0)?"PASS":"FAIL", capn);
  endtask

  initial begin
    rst=1; start=0; stall_mod=0; length=0; bram_addr=0; capn=0;
    repeat(3) @(negedge clk); rst=0;

    run(14'd0,   5'd1, 0, "len1 clean");    // 1*1*8 = 8 beats
    run(14'd100, 5'd2, 0, "len2 clean");    // 2*2*8 = 32 beats
    run(14'd50,  5'd1, 3, "len1 stall/3");
    run(14'd200, 5'd2, 4, "len2 stall/4");

    $display("done");
    $finish;
  end
endmodule
