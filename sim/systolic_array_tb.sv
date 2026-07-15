`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/13/2026 03:25:45 PM
// Design Name: 
// Module Name: systolic_array_tb
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


module systolic_array_tb();
    parameter N=16, DATA_WIDTH = 8, ACC_WIDTH = 32;

    logic clk, rst;
    logic [2*N-2:0] enable;
    logic [DATA_WIDTH-1:0] a_mat [0:N-1];
    logic [DATA_WIDTH-1:0] b_mat [0:N-1];
    logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1];

    logic [DATA_WIDTH-1:0] a_full [0:N-1][0:N-1];
    logic [DATA_WIDTH-1:0] b_full [0:N-1][0:N-1];

    int cycle_count;

    systolic_array #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH))
    uut (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .results(results),
        .a_mat(a_mat),
        .b_mat(b_mat)
    );

    // Clock generation
    always #5 clk = ~clk;

    // Cycle counter
    always_ff @(posedge clk) begin
        if (rst) cycle_count <= 0;
        else cycle_count <= cycle_count + 1;
    end

    // Enable generation (one bit per diagonal)
    genvar d;
    generate
        for (d = 0; d < 2*N-1; d++) begin : enable_gen
            assign enable[d] = (cycle_count >= d) && (cycle_count <= d + N - 1);
        end
    endgenerate

    // Staggered data feeding
    always_comb begin
        for (int i = 0; i < N; i++) begin
            if (cycle_count >= i && cycle_count < i + N)
                a_mat[i] = a_full[i][cycle_count - i];
            else
                a_mat[i] = 0;
        end
        for (int j = 0; j < N; j++) begin
            if (cycle_count >= j && cycle_count < j + N)
                b_mat[j] = b_full[cycle_count - j][j];
            else
                b_mat[j] = 0;
        end
    end

    // Test sequence: only handles test data setup and reset, NOT enable/a_mat/b_mat
    initial begin
    for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) begin
        a_full[i][j] = (i * N + j) % 255 + 1;
        b_full[i][j] = ((i * N + j) * 7) % 255 + 1;  // different multiplier for distinct values
    end


        clk = 0;
        rst = 1;
        #10;
        rst = 0;

        // Let simulation run long enough for all diagonals to complete
        // Last diagonal (d=2N-2) finishes at cycle (2N-2)+(N-1) = 3N-3
        // Add buffer cycles
        #((3*N+2) * 10);

        rst = 1;
        #10;

        $finish;
    end
endmodule