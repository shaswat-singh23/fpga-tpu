`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/28/2026 11:01:20 PM
// Design Name: 
// Module Name: accelerator_top
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


module accelerator_top #(parameter N=64)(
input logic clk, rst
    );
    
    logic weA, weB, weC;
    logic [$clog2(N*N/8)-1:0] waddrA, raddrA, waddrB, raddrB;
    logic [$clog2(N*N/8)-1:0] waddrC, raddrC;
    logic [63:0]  wdataA, rdataA, wdataB, rdataB;
    logic [255:0] wdataC, rdataC;
    
    tile_bram #(.WIDTH(64), .DEPTH(N*N/8)) A_buf(
    .clk(clk),
    .we(weA),
    .waddr(waddrA),
    .raddr(raddrA),
    .wdata(wdataA),
    .rdata(rdataA)
    );
    
    tile_bram #(.WIDTH(64), .DEPTH(N*N/8)) B_buf(
    .clk(clk),
    .we(weB),
    .waddr(waddrB),
    .raddr(raddrB),
    .wdata(wdataB),
    .rdata(rdataB)
    );
    
    tile_bram #(.WIDTH(256), .DEPTH(N*N/8)) C_buf(
    .clk(clk),
    .we(weC),
    .waddr(waddrC),
    .raddr(raddrC),
    .wdata(wdataC),
    .rdata(rdataC)
    );
endmodule
