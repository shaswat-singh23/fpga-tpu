`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/12/2026 07:11:43 PM
// Design Name: 
// Module Name: processing_element_tb
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


module processing_element_tb();
parameter DATA_WIDTH =8;
parameter ACC_WIDTH = 32;
logic clk, rst;
logic [DATA_WIDTH-1:0] a_in, b_in, a_out, b_out;
logic [ACC_WIDTH-1:0] result;
processing_element #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) uut(
.a_in(a_in),
.a_out(a_out),
.b_in(b_in),
.b_out(b_out),
.result(result),
.clk(clk),
.rst(rst)
);
always #5 clk = ~clk;
initial begin
    clk =0;
    rst = 1;
    a_in =0; b_in=0;
    #10;
    rst=0;
    a_in = 3; b_in =4;
    #10;
    a_in =2; b_in =5;
    #10;
    a_in =10; b_in=26;
    #10;
    rst=1; #10;
    $finish;
    
end
endmodule
