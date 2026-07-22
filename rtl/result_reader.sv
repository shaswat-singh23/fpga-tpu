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
    logic one_done;
    logic two_done;
    
    wire transferone = m_axis_one_tvalid && m_axis_one_tready;
    wire transfertwo = m_axis_two_tvalid && m_axis_two_tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_axis_one_tvalid<=0;
            m_axis_two_tvalid<=0;
            read_done<=0;
            state<= IDLE;
            index<=0;
            one_done<=0;
            two_done<=0;
        end else begin
            case(state)
                IDLE: begin
                    read_done<=0;
                    one_done<=0;
                    two_done<=0;
                    if (start_read) begin
                        state<= READING;
                        index<=0;
                        m_axis_one_tvalid<=1;
                        m_axis_two_tvalid<=1;
                    end
                end
                READING: begin
                    if (transferone) begin
                        if ((index<<2) == TOTAL_ELEMENTS-4) begin
                            m_axis_one_tvalid <= 0;
                            one_done <= 1;
                        end
                    end
                    if (transfertwo) begin
                        if ((index<<2) == TOTAL_ELEMENTS-4) begin
                            m_axis_two_tvalid <= 0;
                            two_done <= 1;
                        end
                    end
                    if (transferone && transfertwo && (index<<2) != TOTAL_ELEMENTS-4) begin
                        index <= index + 1;
                    end
                    if (one_done && two_done) begin
                        state <= FINISHED;
                    end
                end
                FINISHED: begin
                    read_done<=1;
                    state<=IDLE;
                end
               endcase 
        end
    end
    assign m_axis_one_tdata = {results[(index<<2)/N][((index<<2)%N)+1],results[(index<<2)/N][(index<<2)%N]};
    assign m_axis_two_tdata = {results[(index<<2)/N][((index<<2)%N)+3],results[(index<<2)/N][((index<<2)%N)+2]};

    assign m_axis_one_tlast = m_axis_one_tvalid && ((index<<2)==TOTAL_ELEMENTS-4);
    assign m_axis_two_tlast = m_axis_two_tvalid && ((index<<2)==TOTAL_ELEMENTS-4);

endmodule
