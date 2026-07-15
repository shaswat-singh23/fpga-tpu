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
(input logic clk, rst, start_read, m_axis_tready,
output logic m_axis_tvalid, read_done, m_axis_tlast,
output logic [ACC_WIDTH-1:0] m_axis_tdata,
input logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1]
    );
    typedef enum logic [1:0] {IDLE, READING, FINISHED} state_t;
    state_t state;
    
    localparam TOTAL_ELEMENTS = N*N;
    logic [$clog2(TOTAL_ELEMENTS)-1:0] index;
    wire transfer = m_axis_tvalid && m_axis_tready;
    
    always_ff @(posedge clk) begin
        if (rst) begin
            m_axis_tvalid<=0;
            read_done<=0;
            state<= IDLE;
            index<=0;
        end else begin
            case(state)
                IDLE: begin
                    read_done<=0;
                    if (start_read) begin
                        state<= READING;
                        index<=0;
                        m_axis_tvalid<=1;
                    end
                end
                READING: begin
                    if (transfer) begin
                        if (index==TOTAL_ELEMENTS-1) begin
                            state<=FINISHED;
                            m_axis_tvalid<=0;
                        end else begin
                            index<=index+1;
                        end
                    end
                end
                FINISHED: begin
                    read_done<=1;
                    state<=IDLE;
                end
               endcase 
        end
    end
    assign m_axis_tdata = results[index/N][index%N];
    assign m_axis_tlast = m_axis_tvalid && (index==TOTAL_ELEMENTS-1);
endmodule
