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
input logic clk, rst,
input logic s_axis_tlast, s_axis_tvalid, m_axis_tready,
input logic [63:0] s_axis_tdata,
input logic [63:0] placeholderforinstruction,
output logic [63:0] m_axis_tdata,
output logic m_axis_tlast, m_axis_tvalid, s_axis_tready
    );
    
    logic weA, weB, weC;
    logic [$clog2(N*N/8)-1:0] waddrA, raddrA, waddrB, raddrB;
    logic [$clog2(N*N/8)-1:0] waddrC, raddrC;
    logic [63:0]  wdataA, rdataA, wdataB, rdataB;
    logic [63:0] wdataC, rdataC;
    
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
    
    tile_bram #(.WIDTH(64), .DEPTH(N*N/2)) C_buf(
    .clk(clk),
    .we(weC),
    .waddr(waddrC),
    .raddr(raddrC),
    .wdata(wdataC),
    .rdata(rdataC)
    );
endmodule
