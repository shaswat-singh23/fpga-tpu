`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/14/2026 11:48:13 PM
// Design Name: 
// Module Name: top_wrapper_tb
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


module top_wrapper_tb();
    parameter N=8, DATA_WIDTH=8, ACC_WIDTH=32;
    logic clk, rst, start, feeder_done;
    logic [DATA_WIDTH-1:0] a_full [0:N-1][0:N-1];
    logic [DATA_WIDTH-1:0] b_full [0:N-1][0:N-1];
    logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1];
    
    logic [ACC_WIDTH-1:0] read_data;
    logic read_valid, read_done;
    feeder_sequencer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH))
    feeder_inst(
        .clk(clk),
        .rst(rst),
        .start(start),
        .done(feeder_done),
        .a_full(a_full),
        .b_full(b_full),
        .results(results)
    );
    
    result_reader #(.ACC_WIDTH(ACC_WIDTH), .N(N))
    reader_inst (
        .clk(clk),
        .rst(rst),
        .start_read(feeder_done),
        .results(results),
        .read_data(read_data),
        .read_valid(read_valid),
        .read_done(read_done)
    );
    
    always # 5 clk = ~clk;
    initial begin
        for (int j=0; j<N; j++) 
            for (int i=0; i<N; i++)begin
                a_full[i][j] = (i*N+j)%255+1;
                b_full[i][j] = ((i*N+j)*7)%255 +1;
            end
            
        clk =0;
        rst =1;
        start = 0;
        #10;
        rst=0;
        #10;
        start=1;
        #10;
        start=0;
        wait(read_done==1);
        #20;
        
        $finish;
    end
endmodule
