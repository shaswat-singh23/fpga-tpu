`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/18/2026 08:40:29 PM
// Design Name: 
// Module Name: pipeline_ctrl
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


module pipeline_ctrl(
input logic clk, rst, load_done, calc_done, read_done,
output logic feeder_start, loader_consumed
    );
    
    logic read_consumed;
    always_ff @(posedge clk) begin
        if (rst)
        read_consumed<= 1;
        else begin
        if(read_done)
        read_consumed<=1;
        else if (feeder_start)
        read_consumed<=0;
        end
    end
    assign feeder_start = load_done && read_consumed;
    assign loader_consumed = calc_done;
endmodule
