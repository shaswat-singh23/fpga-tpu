`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/07/2026 02:21:48 PM
// Design Name: 
// Module Name: datamover_cmd_tb
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


module datamover_cmd_tb();
  localparam BYTES_AB = 64;   // A/B: 8-bit elements
  localparam BYTES_C  = 256;  // C:   32-bit elements

  logic clk=0, rst;

  // DUT under test: instantiate one for A/B sizing
  logic start; logic [31:0] ddr_addr; logic [4:0] length; logic done;
  logic [71:0] cmd_tdata; logic cmd_tvalid, cmd_tready;
  logic [7:0] sts_tdata; logic sts_tvalid, sts_tready;
  logic err;

  datamover_cmd #(.BYTES_PER_TILECT_SQ(BYTES_AB)) dut(
    .clk(clk), .rst(rst),
    .start(start), .ddr_addr(ddr_addr), .length(length), .done(done),
    .cmd_tdata(cmd_tdata), .cmd_tvalid(cmd_tvalid), .cmd_tready(cmd_tready),
    .sts_tdata(sts_tdata), .sts_tvalid(sts_tvalid), .sts_tready(sts_tready),
    .err(err)
  );

  always #5 clk = ~clk;

  // ---- mock DataMover: decode the command, check fields, stall a bit, respond ----
  int cmd_stall, sts_delay;
  logic [22:0] decoded_btt; logic decoded_type; logic decoded_eof;
  logic [5:0]  decoded_dsa; logic decoded_drr;
  logic [31:0] decoded_saddr; logic [3:0] decoded_tag; logic [3:0] decoded_rsvd;
  logic [71:0] captured_cmd;
  logic force_bad_status;

  int cmd_wait;
  always_ff @(posedge clk) begin
    if (rst) begin cmd_tready<=0; cmd_wait<=0; end
    else begin
      cmd_tready <= 0;
      if (cmd_tvalid && !cmd_tready) begin
        if (cmd_wait >= cmd_stall) begin
          cmd_tready <= 1;
          captured_cmd <= cmd_tdata;
          decoded_btt   <= cmd_tdata[22:0];
          decoded_type  <= cmd_tdata[23];
          decoded_dsa   <= cmd_tdata[29:24];
          decoded_eof   <= cmd_tdata[30];
          decoded_drr   <= cmd_tdata[31];
          decoded_saddr <= cmd_tdata[63:32];
          decoded_tag   <= cmd_tdata[67:64];
          decoded_rsvd  <= cmd_tdata[71:68];
          cmd_wait <= 0;
        end else cmd_wait <= cmd_wait + 1;
      end
    end
  end

  int sts_wait; logic await_sts;
  always_ff @(posedge clk) begin
    if (rst) begin sts_tvalid<=0; await_sts<=0; sts_wait<=0; end
    else begin
      if (cmd_tvalid && cmd_tready) begin await_sts<=1; sts_wait<=0; end
      if (await_sts) begin
        if (sts_wait >= sts_delay) begin
          sts_tvalid <= 1;
          sts_tdata  <= force_bad_status ? 8'h40 : 8'h80;  // OKAY=bit7, else SLVERR=bit6
          if (sts_tvalid && sts_tready) begin sts_tvalid<=0; await_sts<=0; end
        end else sts_wait <= sts_wait + 1;
      end
    end
  end
  assign sts_tready = 1;   // module side always accepts status promptly (per its own FSM)

  task automatic run_case(input [31:0] addr, input [4:0] len, input int stall, input int sdelay, input bad_status, input string name);
    automatic logic [22:0] exp_btt;
    cmd_stall=stall; sts_delay=sdelay; force_bad_status=bad_status;
    ddr_addr=addr; length=len;
    exp_btt = (len*len) * BYTES_AB;

    @(negedge clk); start=1; @(negedge clk); start=0;

    fork
      begin wait(done); end
      begin #2000; $display("[%0t] %s: TIMEOUT", $time, name); $finish; end
    join_any

    @(negedge clk);
    begin
      automatic int fails=0;
      if (decoded_saddr !== addr)      begin $display("  FAIL saddr got %h exp %h", decoded_saddr, addr); fails++; end
      if (decoded_btt   !== exp_btt)   begin $display("  FAIL btt got %0d exp %0d", decoded_btt, exp_btt); fails++; end
      if (decoded_type  !== 1'b1)      begin $display("  FAIL type got %b exp 1", decoded_type); fails++; end
      if (decoded_eof   !== 1'b1)      begin $display("  FAIL eof got %b exp 1", decoded_eof); fails++; end
      if (decoded_drr   !== 1'b0)      begin $display("  FAIL drr got %b exp 0", decoded_drr); fails++; end
      if (decoded_dsa   !== 6'b0)      begin $display("  FAIL dsa got %b exp 0", decoded_dsa); fails++; end
      if (decoded_tag   !== 4'b0)      begin $display("  FAIL tag got %b exp 0", decoded_tag); fails++; end
      if (decoded_rsvd  !== 4'b0)      begin $display("  FAIL rsvd got %b exp 0", decoded_rsvd); fails++; end
      if (err !== bad_status)          begin $display("  FAIL err got %b exp %b", err, bad_status); fails++; end
      $display("%s : %s", name, (fails==0)?"PASS":"FAIL");
    end
  endtask

  initial begin
    rst=1; start=0; cmd_stall=0; sts_delay=0; force_bad_status=0;
    repeat(3) @(negedge clk); rst=0;

    run_case(32'h1000_0000, 5'd16, 0, 0, 0, "N=128 clean, no stalls");
    run_case(32'h2000_0000, 5'd2,  0, 0, 0, "N=16 minimum, no stalls");
    run_case(32'h3000_0000, 5'd8,  3, 0, 0, "cmd_tready stalled 3 cycles");
    run_case(32'h4000_0000, 5'd8,  0, 5, 0, "status delayed 5 cycles");
    run_case(32'h5000_0000, 5'd8,  4, 6, 0, "both stalled/delayed");
    run_case(32'h6000_0000, 5'd8,  0, 0, 1, "slave error response");
    run_case(32'h0000_0000, 5'd16, 0, 0, 0, "ddr_addr = 0 edge case");

    $display("done");
    $finish;
  end
endmodule
