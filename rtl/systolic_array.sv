`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/12/2026 09:50:04 PM
// Design Name: 
// Module Name: systolic_array
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


module systolic_array #(parameter N = 8, DATA_WIDTH = 16, ACC_WIDTH =32)(
input logic clk,
input logic rst,
input logic [2*N-2:0] enable,
input logic [DATA_WIDTH-1:0] a_mat[0:N-1],
input logic[DATA_WIDTH-1:0] b_mat [0:N-1],
output logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1]
    );
    logic [DATA_WIDTH-1:0] awire [0:N-1][0:N];
    logic [DATA_WIDTH-1:0] bwire [0:N][0:N-1];
    genvar i, j;
    generate
        for (i = 0; i<N; i++) begin:rows
            for (j = 0; j<N; j++) begin: cols
                if (j==0) assign awire[i][0] = a_mat[i];
                if (i==0) assign bwire[0][j] = b_mat[j];
                processing_element #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH))
                    pe (.a_in(awire[i][j]),
                      .b_in(bwire[i][j]),
                      .enable(enable[i+j]),
                      .clk(clk),
                      .rst(rst),
                      .result(results[i][j]),
                      .a_out(awire[i][j+1]),
                      .b_out(bwire[i+1][j])
                      );
            end
        end
    endgenerate
endmodule
