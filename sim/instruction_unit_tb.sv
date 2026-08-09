`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/09/2026 01:28:32 AM
// Design Name: 
// Module Name: instruction_unit_tb
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


module instruction_unit_tb();
  logic clk=0, rst, run;
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

  instruction_unit #(.INSTR_ADDR_WIDTH(7)) dut(
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

  always #5 clk = ~clk;

  // print every dispatch as it happens
  always @(posedge clk) begin
    if (l_start)   $display("[%0t] LOAD%s ddr=%h bram=%h len=%0d", $time, l_dest?"B":"A", l_ddr_addr, l_bram_addr, l_length);
    if (mm_start)  $display("[%0t] MATMUL a=%h b=%h c=%h tiles=%0d acc=%b", $time, mm_a_addr, mm_b_addr, mm_c_addr, mm_tiles, mm_accumulate);
    if (s_start)   $display("[%0t] STOREC ddr=%h bram=%h len=%0d", $time, s_ddr_addr, s_bram_addr, s_length);
    if (program_done) $display("[%0t] PROGRAM_DONE", $time);
  end

  initial begin
    rst=1; run=0; mm_done=0; l_done=0; s_done=0; act_done=0; qz_done=0;
    #35 rst=0;

    // LOAD_B, LOAD_A, MATMUL, STORE_C, HALT
    imem[0] = {3'b001, 32'h1000, 14'd0,   5'd2, 10'b0};
    imem[1] = {3'b000, 32'h2000, 14'd100, 5'd2, 10'b0};
    imem[2] = {3'b010, 14'd100, 14'd0, 14'd50, 5'd2, 1'b0, 13'b0};
    imem[3] = {3'b011, 32'h3000, 14'd50, 5'd2, 10'b0};
    imem[4] = {3'b110, 61'b0};

    #10 run=1; #10 run=0;

    // give each instruction its done pulse, spaced out
    #40 l_done=1; #10 l_done=0;   // LOAD_B
    #40 l_done=1; #10 l_done=0;   // LOAD_A
    #40 mm_done=1; #10 mm_done=0; // MATMUL
    #40 s_done=1; #10 s_done=0;   // STORE_C

    #100 $display("--- end ---");
    $finish;
  end
endmodule
