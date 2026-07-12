`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/11/2026 11:00:15 PM
// Design Name: 
// Module Name: processing_element
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


module processing_element #(parameter DATA_WIDTH = 8, parameter ACC_WIDTH = 32)(
input logic [DATA_WIDTH-1:0] a_in,
input logic [DATA_WIDTH-1:0] b_in,
input logic clk,
input logic rst,
output logic [ACC_WIDTH-1:0] result,
output logic [DATA_WIDTH-1:0] a_out,
output logic [DATA_WIDTH-1:0] b_out
    );
endmodule
