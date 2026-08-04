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

(* use_dsp = "yes" *)
module processing_element #(parameter DATA_WIDTH = 8, parameter ACC_WIDTH = 32)(
input logic signed [DATA_WIDTH-1:0] a_in,
input logic signed [DATA_WIDTH-1:0] b_in,
input logic clk,
input logic rst,
input logic pingpong,
input logic pingpongrst,
input logic enable,
output logic signed [ACC_WIDTH-1:0] result1,
output logic signed [ACC_WIDTH-1:0] result2,
output logic signed [DATA_WIDTH-1:0] a_out,
output logic signed [DATA_WIDTH-1:0] b_out
    );
    
    //logic [ACC_WIDTH-1:0] partialsum;
    //logic [DATA_WIDTH-1:0] a
    always_ff @(posedge clk) begin
        if (rst) begin
            result1<=0; result2<=0; a_out<=0; b_out<=0;
        end else begin
            if (enable) begin
                a_out<=a_in;
                b_out<=b_in;
                if (pingpong) result2 <= result2 + (a_in*b_in);
                else          result1 <= result1 + (a_in*b_in);
            end
            if (pingpongrst) begin
                if (pingpong) result1 <= 0;
                else          result2 <= 0;
            end
        end
    end
endmodule
