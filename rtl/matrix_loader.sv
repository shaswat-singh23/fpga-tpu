`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/15/2026 08:14:43 PM
// Design Name: 
// Module Name: matrix_loader
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


module matrix_loader #(parameter N=8, DATA_WIDTH=8)(
input logic clk, rst,
//slave port A
input logic s_axis_a_tvalid,
output logic s_axis_a_tready,
input logic [DATA_WIDTH-1:0] s_axis_a_tdata,
input logic s_axis_a_tlast,
//slave port B
input logic s_axis_b_tvalid,
output logic s_axis_b_tready,
input logic [DATA_WIDTH-1:0] s_axis_b_tdata,
input logic s_axis_b_tlast,
output logic [DATA_WIDTH-1:0] a_full [0:N-1][0:N-1],
output logic [DATA_WIDTH-1:0] b_full [0:N-1][0:N-1],
output logic load_done,
input logic consumed
    );
    localparam TOTAL_ELEMENTS = N*N;
    logic [$clog2(TOTAL_ELEMENTS)-1:0] a_count, b_count;
    logic a_done, b_done;
    
    assign s_axis_a_tready = !a_done;
    assign s_axis_b_tready = !b_done;
    
    wire a_transfer = s_axis_a_tready && s_axis_a_tvalid;
    wire b_transfer = s_axis_b_tready && s_axis_b_tvalid;
    
    logic a_frame_err, b_frame_err;
    always_ff @(posedge clk) begin
        if (rst) begin
            a_done <=0; b_done<=0;
            a_count <=0; b_count<=0;
            a_frame_err<=0; b_frame_err<=0;
        end else begin
            if (a_transfer) begin
                a_full[a_count/N][a_count%N] <= s_axis_a_tdata;
                if (a_count==TOTAL_ELEMENTS-1)begin
                    if (!s_axis_a_tlast) a_frame_err <= 1;
                    a_done<=1;
                end else begin
                    a_count<=a_count+1;
                    if (s_axis_a_tlast) a_frame_err <= 1;
                end
            end
            if (b_transfer) begin
                b_full[b_count/N][b_count%N] <= s_axis_b_tdata;
                if (b_count==TOTAL_ELEMENTS-1)begin
                    if (!s_axis_b_tlast) b_frame_err <= 1;
                    b_done<=1;
                end else begin
                    b_count<=b_count+1;
                    if (s_axis_b_tlast) b_frame_err <= 1;
                end
            end
            if (consumed) begin
                a_done <=0; b_done<=0;
                a_count <=0; b_count<=0;
            end
        end
    end
    assign load_done = a_done && b_done;
endmodule
