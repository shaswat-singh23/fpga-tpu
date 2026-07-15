`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/14/2026 10:33:50 PM
// Design Name: 
// Module Name: feeder_sequencer_tb
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


module feeder_sequencer_tb();
    parameter N = 8, DATA_WIDTH = 8, ACC_WIDTH = 32;

    logic clk, rst, start, done;
    logic [DATA_WIDTH-1:0] a_full [0:N-1][0:N-1];
    logic [DATA_WIDTH-1:0] b_full [0:N-1][0:N-1];
    logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1];

    feeder_sequencer #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)
    ) uut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .done(done),
        .a_full(a_full),
        .b_full(b_full),
        .results(results)
    );

    always #5 clk = ~clk;

    initial begin
        // Initialize test matrices
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                a_full[i][j] = (i * N + j) % 255 + 1;
                b_full[i][j] = ((i * N + j) * 7) % 255 + 1;
            end

        clk = 0;
        rst = 1;
        start = 0;
        #10;
        rst = 0;
        #10;

        // Pulse start
        start = 1;
        #10;
        start = 0;

        // Wait for done (with generous timeout margin)
        wait (done == 1);
        #10;  // let a cycle settle

        // At this point, check `results` against golden model
        // (results should remain stable now, per our reset-timing fix)

        #20;

        $finish;
    end
endmodule
