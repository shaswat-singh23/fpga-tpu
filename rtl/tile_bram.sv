`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/28/2026 07:51:18 PM
// Design Name: 
// Module Name: tile_bram
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


module tile_bram #(parameter WIDTH = 64, DEPTH = 512)(
input logic clk,
input logic we,
input logic [$clog2(DEPTH)-1:0] waddr,
input logic [WIDTH-1:0] wdata,
input logic [$clog2(DEPTH)-1:0] raddr,
output logic [WIDTH-1:0] rdata
);
logic [WIDTH-1:0] mem [0: DEPTH-1];
always @(posedge clk) begin
    if (we)
        mem[waddr]<= wdata;
    rdata<= mem[raddr];
end
endmodule
