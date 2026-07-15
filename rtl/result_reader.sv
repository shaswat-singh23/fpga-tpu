`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/14/2026 11:21:29 PM
// Design Name: 
// Module Name: result_reader
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


module result_reader #(parameter N=8, ACC_WIDTH=32)
(input logic clk, rst, start_read,
output logic read_valid, read_done,
output logic [ACC_WIDTH-1:0] read_data,
input [ACC_WIDTH-1:0] results [0:N-1][0:N-1]
    );
    typedef enum logic [1:0] {IDLE, READING, FINISHED} state_t;
    state_t state;
    
    localparam TOTAL_ELEMENTS = N*N;
    logic [$clog2(TOTAL_ELEMENTS)-1:0] index;
    
    always_ff @(posedge clk) begin
        if (rst) begin
            read_valid<=0;
            read_done<=0;
            state<= IDLE;
            index<=0;
        end else begin
            case(state)
                IDLE: begin
                    read_valid<=0;
                    read_done<=0;
                    if (start_read) begin
                        state<= READING;
                        index<=0;
                    end
                end
                READING: begin
                    read_valid<=1;
                    read_data<= results[index/N][index%N];
                    if (index<TOTAL_ELEMENTS-1)
                        index<=index+1;
                    else
                        state<=FINISHED;
                end
                FINISHED: begin
                    read_valid<=0;
                    read_done<=1;
                    state<=IDLE;
                end
               endcase 
        end
    end
endmodule
