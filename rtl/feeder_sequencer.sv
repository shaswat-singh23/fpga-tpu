`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/14/2026 05:48:13 PM
// Design Name: 
// Module Name: feeder_sequencer
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


module feeder_sequencer #(parameter N=8, DATA_WIDTH = 8, ACC_WIDTH = 32)(
input logic clk, rst, start,
output logic done,
input logic [DATA_WIDTH-1:0] a_full [0:N-1][0:N-1],
input logic [DATA_WIDTH-1:0] b_full [0:N-1][0:N-1],
output logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1]
    );
    
    localparam TOTAL_CYCLES = 3*N-2;
    typedef enum logic [1:0] {IDLE, RUNNING, DONE_STATE} state_t;
    state_t state;
    
    logic [DATA_WIDTH -1: 0] a_mat [0:N-1];
    logic [DATA_WIDTH -1: 0] b_mat [0:N-1];
    logic arrayrst;
    logic [2*N-2:0] enable;
    logic [$clog2(TOTAL_CYCLES)-1:0] cycle_count;
    
    //fsm
    always_ff @(posedge clk) begin
        if (rst) begin
            state<= IDLE;
            done<= 0;
            cycle_count<=0;
        end else begin
            case (state)
                IDLE: begin
                    done<=0;
                    if (start) begin
                        state<= RUNNING;
                        cycle_count<=0;
                    end
                end
                RUNNING: begin
                    if (cycle_count<TOTAL_CYCLES-1) begin
                        cycle_count<= cycle_count+1;
                    end else begin
                        done<=1;
                        state<=DONE_STATE;
                    end
                end
                DONE_STATE: begin
                    state<=IDLE;
                end
            endcase
        end
    end
    
    assign arrayrst = rst || (state==IDLE && start);
    
    genvar d;
    generate 
        for (d=0; d<2*N-1; d++) begin: enable_gen
            assign enable[d] = (state==RUNNING)&&(cycle_count>=d)&&(cycle_count<d+N);
        end
    endgenerate
    
    always_comb begin
        for (int i=0; i<N; i++) begin
            if (state==RUNNING && cycle_count>=i && cycle_count<i+N)
                a_mat[i] = a_full[i][cycle_count-i];
            else
                a_mat[i]=0;
        end
        for (int j=0; j<N; j++) begin
            if (state==RUNNING && cycle_count>=j && cycle_count<j+N)
                b_mat[j] = b_full[cycle_count-j][j];
            else
                b_mat[j] = 0;
        end
    end
    
    systolic_array #(
    .N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH))
    array_instance0 (
    .clk(clk),
    .rst(arrayrst),
    .enable(enable),
    .a_mat(a_mat),
    .b_mat(b_mat),
    .results(results));
    
endmodule
