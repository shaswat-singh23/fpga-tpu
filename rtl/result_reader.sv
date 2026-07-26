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
(input logic clk, rst, start_read, m_axis_one_tready, m_axis_two_tready,
output logic m_axis_one_tvalid, m_axis_two_tvalid, read_done, m_axis_one_tlast, m_axis_two_tlast,
output logic [ACC_WIDTH*2-1:0] m_axis_one_tdata,
output logic [ACC_WIDTH*2-1:0] m_axis_two_tdata,
input logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1]
    );
    typedef enum logic [1:0] {IDLE, READING, FINISHED} state_t;
    state_t state;
    
    localparam TOTAL_ELEMENTS = N*N;
    logic [$clog2(TOTAL_ELEMENTS>>2)-1:0] index;
    localparam LAST_IDX = (TOTAL_ELEMENTS>>2)-1;
    wire [$clog2(TOTAL_ELEMENTS)-1:0] base ={index, 2'b00};
    
    wire transferone = m_axis_one_tvalid && m_axis_one_tready;
    wire transfertwo = m_axis_two_tvalid && m_axis_two_tready;

    logic one_accepted, two_accepted;
    
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            index <= 0;
            one_accepted <= 0;
            two_accepted <= 0;
            read_done <= 0;
        end else begin
            case (state)
                IDLE: begin
                    read_done <= 0;
                    one_accepted <= 0;
                    two_accepted <= 0;
                    if (start_read) begin
                        state <= READING;
                        index <= 0;
                    end
                end
                READING: begin
                    if (transferone) one_accepted <= 1;
                    if (transfertwo) two_accepted <= 1;
                    if ((one_accepted || transferone) && (two_accepted || transfertwo)) begin
                        if (index == LAST_IDX) begin
                            state <= FINISHED;
                        end else begin
                            index <= index + 1;
                            one_accepted <= 0;
                            two_accepted <= 0;
                        end
                    end
                end
                FINISHED: begin
                    read_done <= 1;
                    state <= IDLE;
                end
            endcase
        end
    end

    assign m_axis_one_tvalid = (state == READING) && !one_accepted;
    assign m_axis_two_tvalid = (state == READING) && !two_accepted;
    assign m_axis_one_tlast  = m_axis_one_tvalid && (index == (TOTAL_ELEMENTS>>2) - 1);
    assign m_axis_two_tlast  = m_axis_two_tvalid && (index == (TOTAL_ELEMENTS>>2) - 1);
    assign m_axis_one_tdata = {results[base/N][(base%N)+1],results[base/N][base%N]};
    assign m_axis_two_tdata = {results[base/N][(base%N)+3],results[base/N][(base%N)+2]};



endmodule
