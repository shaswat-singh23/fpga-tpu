`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/07/2026 10:48:32 PM
// Design Name: 
// Module Name: bram_adapter
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


module bram_adapter(
    // instruction unit
    input  logic clk, rst, start,
    input  logic [1:0]  dest,          // 00 = A_buf, 01 = B_buf, 10 = bias_buf, 11 = scale factor
    input  logic [13:0] bram_addr,
    output logic done,
    // m_axis_mm2s (from DataMover)
    input  logic [63:0] s_tdata,
    input  logic        s_tvalid, s_tlast,
    output logic        s_tready,
    // bram write enables (one-hot per destination)
    output logic        weA, weB, weBias, weScale,
    output logic [13:0] waddr,
    output logic [63:0] wdata
);
    logic transfer;
    logic [1:0] destnew;

    assign transfer = (s_tvalid && s_tready);
    assign wdata    = s_tdata;

    // one-hot write enables based on the latched destination
    assign weA    = (transfer && (destnew == 2'b00) && !done) ? 1'b1 : 1'b0;
    assign weB    = (transfer && (destnew == 2'b01) && !done) ? 1'b1 : 1'b0;
    assign weBias = (transfer && (destnew == 2'b10) && !done) ? 1'b1 : 1'b0;
    assign weScale = (transfer && (destnew == 2'b11) && !done) ? 1'b1 : 1'b0;


    always_ff @(posedge clk) begin
        if (rst) begin
            done     <= 0;
            waddr    <= 0;
            s_tready <= 0;
            destnew  <= 0;
        end else begin
            if (transfer) begin
                waddr <= waddr + 1;
                if (s_tlast) done <= 1;
            end
            if (start) begin
                waddr    <= bram_addr;
                destnew  <= dest;
                s_tready <= 1;
                done     <= 0;
            end
            else if (done)
                s_tready <= 0;
        end
    end
endmodule 