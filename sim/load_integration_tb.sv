`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/09/2026 01:47:02 AM
// Design Name: 
// Module Name: load_integration_tb
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


// Integration test: instruction_unit -> datamover_cmd + bram_adapter
// -> mock DataMover -> real tile_bram (A_buf).
// Runs a LOAD_A program, then reads A_buf back and prints got vs expected.
// Two runs: clean stream, then stream with stalls.

// Integration: instruction_unit -> datamover_cmd + bram_adapter
// -> mock DataMover -> real tile_bram (A_buf).
// LOAD_A program, then read A_buf back: expect A_buf[base+i] == i.

// Integration: instruction_unit -> datamover_cmd + bram_adapter
// -> mock DataMover -> real tile_bram (A_buf).
// LOAD_A program, then read A_buf back: expect A_buf[base+i] == i.

module load_integration_tb();
  logic clk=0, rst;
  always #5 clk = ~clk;

  logic run;
  logic [6:0] pc;
  logic [63:0] instr;
  logic mm_start; logic [4:0] mm_tiles; logic [13:0] mm_a_addr, mm_b_addr; logic mm_accumulate; logic [13:0] mm_c_addr; logic mm_done;
  logic l_start, s_start, l_dest;
  logic [31:0] l_ddr_addr, s_ddr_addr;
  logic [13:0] l_bram_addr, s_bram_addr;
  logic [4:0] l_length, s_length;
  logic l_done, s_done;
  logic act_start; logic [13:0] act_c_addr; logic [4:0] act_length; logic [2:0] act_mode; logic act_done;
  logic qz_start; logic [13:0] qz_c_addr, qz_a_addr; logic [4:0] qz_length; logic qz_done;
  logic program_done;

  instruction_unit #(.INSTR_ADDR_WIDTH(7)) iu(
    .clk(clk), .rst(rst), .run(run), .pc(pc), .instr(instr),
    .mm_start(mm_start), .mm_tiles(mm_tiles), .mm_a_addr(mm_a_addr), .mm_b_addr(mm_b_addr),
    .mm_accumulate(mm_accumulate), .mm_c_addr(mm_c_addr), .mm_done(mm_done),
    .l_start(l_start), .s_start(s_start), .l_dest(l_dest),
    .l_ddr_addr(l_ddr_addr), .s_ddr_addr(s_ddr_addr),
    .l_bram_addr(l_bram_addr), .s_bram_addr(s_bram_addr),
    .l_length(l_length), .s_length(s_length), .l_done(l_done), .s_done(s_done),
    .act_start(act_start), .act_c_addr(act_c_addr), .act_length(act_length), .act_mode(act_mode), .act_done(act_done),
    .qz_start(qz_start), .qz_c_addr(qz_c_addr), .qz_a_addr(qz_a_addr), .qz_length(qz_length), .qz_done(qz_done),
    .program_done(program_done)
  );

  logic [63:0] imem [0:127];
  always_ff @(posedge clk) instr <= imem[pc];

  logic [71:0] cmd_tdata; logic cmd_tvalid, cmd_tready;
  logic [7:0]  sts_tdata; logic sts_tvalid, sts_tready;
  logic cmd_done, cmd_err;

  datamover_cmd #(.BYTES_PER_TILECT_SQ(64)) dmc(
    .clk(clk), .rst(rst),
    .start(l_start), .ddr_addr(l_ddr_addr), .length(l_length), .done(cmd_done),
    .cmd_tdata(cmd_tdata), .cmd_tvalid(cmd_tvalid), .cmd_tready(cmd_tready),
    .sts_tdata(sts_tdata), .sts_tvalid(sts_tvalid), .sts_tready(sts_tready),
    .err(cmd_err)
  );

  logic [63:0] mm_tdata; logic mm_tvalid, mm_tready, mm_tlast;
  logic weA, weB;
  logic [13:0] waddr;
  logic [63:0] wdata;
  logic adapter_done;

  bram_adapter adp(
    .clk(clk), .rst(rst), .start(l_start), .dest(l_dest), .bram_addr(l_bram_addr),
    .done(adapter_done),
    .s_tdata(mm_tdata), .s_tvalid(mm_tvalid), .s_tlast(mm_tlast), .s_tready(mm_tready),
    .weA(weA), .weB(weB), .waddr(waddr), .wdata(wdata)
  );

  assign l_done = cmd_done && adapter_done;

  logic [63:0] a_rdata;
  logic [13:0] a_raddr;
  tile_bram #(.WIDTH(64), .DEPTH(16384)) A_buf(
    .clk(clk), .we(weA), .waddr(waddr), .raddr(a_raddr), .wdata(wdata), .rdata(a_rdata)
  );

  // ================= mock DataMover =================
  // Accept command, remember beat count, then a separate task streams the
  // beats explicitly.  Keeping it procedural (task-driven) is far simpler to
  // reason about than an FSM here.
  assign cmd_tready = 1;
  integer beats;
  always @(posedge clk) if (cmd_tvalid && cmd_tready) beats = cmd_tdata[22:0] >> 3;

  integer stall_mod;

  // stream `n` beats of pattern=index into the adapter, respecting tready,
  // optionally stalling every stall_mod-th beat.
  task automatic stream_beats(input integer n);
    integer k;
    k = 0;
    while (k < n) begin
      if (stall_mod != 0 && k != 0 && (k % stall_mod == 0)) begin
        mm_tvalid <= 0; @(posedge clk);        // one stall cycle
      end else begin
        mm_tvalid <= 1; mm_tdata <= k; mm_tlast <= (k == n-1);
        @(posedge clk);
        if (mm_tready) k = k + 1;              // advance only when accepted
      end
    end
    mm_tvalid <= 0; mm_tlast <= 0;
  endtask

  // issue one OKAY status word after the command's data has streamed
  task automatic send_status;
    sts_tvalid <= 1; sts_tdata <= 8'h80;
    @(posedge clk);
    while (!sts_tready) @(posedge clk);
    sts_tvalid <= 0;
  endtask

  integer i, errs;
  task automatic check_load(input [13:0] base, input integer nbeats, input string label);
    errs = 0;
    for (i=0;i<nbeats;i=i+1) begin
      a_raddr = base + i;
      @(posedge clk); #1;
      if (a_rdata !== i) begin
        $display("  MISMATCH %s addr %0d got %h exp %0d", label, base+i, a_rdata, i);
        errs = errs + 1;
      end
    end
    $display("%s: %s (%0d beats)", label, (errs==0)?"PASS":"FAIL", nbeats);
  endtask

  initial begin
    rst=1; run=0; stall_mod=0;
    mm_tvalid=0; mm_tlast=0; mm_tdata=0; sts_tvalid=0; sts_tdata=0;
    mm_done=0; s_done=0; act_done=0; qz_done=0; beats=0;
    #35 rst=0;

    // RUN 1: clean. LOAD_A ddr=0x1000 bram=0x40 len=2 -> BTT 256 -> 32 beats
    imem[0] = {3'b000, 32'h00001000, 14'h040, 5'd2, 10'b0};
    imem[1] = {3'b110, 61'b0};
    stall_mod = 0;
    #10 run=1; #10 run=0;
    @(posedge cmd_tvalid);                     // wait until command issued
    @(posedge clk);
    stream_beats(beats);
    send_status;
    wait(program_done);
    #20 check_load(14'h040, 32, "RUN1 clean");

    $display("done");
    $finish;
  end
endmodule