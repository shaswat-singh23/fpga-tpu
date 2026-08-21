`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/05/2026 04:21:14 PM
// Design Name: 
// Module Name: instruction_unit
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


module instruction_unit #(
    parameter INSTR_ADDR_WIDTH = 7
)(
    input  logic clk, rst,
    input  logic run,
    output logic [INSTR_ADDR_WIDTH-1:0] pc,
    input  logic [63:0] instr,
    output logic mm_start,
    output logic [4:0]  mm_tiles,
    output logic [13:0] mm_a_addr, mm_b_addr,
    output logic mm_accumulate,
    output logic [13:0] mm_c_addr,
    input  logic mm_done,
    output logic l_start, s_start,
    output logic [1:0]  l_dest,          // 00=A, 01=B, 10=bias, 11=scale
    output logic [31:0] l_ddr_addr, s_ddr_addr,
    output logic [13:0] l_bram_addr, s_bram_addr,
    output logic [4:0]  l_length, s_length,
    input  logic l_done, s_done,
    output logic act_start,
    output logic [13:0] act_c_addr,
    output logic [13:0] act_bias_addr,
    output logic        act_bias_en,
    output logic [4:0]  act_length,
    output logic [2:0]  act_mode,
    input  logic act_done,
    // quantize lane -- fields updated for the scale-buffer design (was
    // qz_a_addr/no shift; now b_addr + scale_addr + shift)
    output logic qz_start,
    output logic [13:0] qz_c_addr,
    output logic [13:0] qz_b_addr,
    output logic [13:0] qz_scale_addr,
    output logic [4:0]  qz_length,
    output logic [4:0]  qz_shift,
    input  logic qz_done,
    output logic program_done
);

    typedef enum logic [1:0] {IDLE, FETCH, DECODE, WAITING} state_t;
    state_t state;

    logic [3:0] curr_instr;
    logic [3:0] op;
    assign op = instr[63:60];

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            pc           <= 0;
            program_done <= 0;
            curr_instr   <= 4'b1111;
        end else begin
            case (state)
                IDLE: begin
                    if (run) begin
                        program_done <= 0;
                        state        <= DECODE;
                    end
                end
                FETCH: begin
                    state <= DECODE;
                end
                DECODE: begin
                    curr_instr <= op;
                    if (op == 4'b0110) begin
                        program_done <= 1;
                        state        <= IDLE;
                    end else begin
                        state <= WAITING;
                    end
                end
                WAITING: begin
                    // LOAD_BIAS (0111) and LOAD_SCALE (1000) share l_done
                    // with LOAD_A/LOAD_B -- all reuse the same load path.
                    if ((curr_instr == 4'b0000 && l_done) ||
                        (curr_instr == 4'b0001 && l_done) ||
                        (curr_instr == 4'b0111 && l_done) ||
                        (curr_instr == 4'b1000 && l_done) ||
                        (curr_instr == 4'b0010 && mm_done) ||
                        (curr_instr == 4'b0011 && s_done) ||
                        (curr_instr == 4'b0100 && act_done) ||
                        (curr_instr == 4'b0101 && qz_done)) begin
                        pc    <= pc + 1;
                        state <= FETCH;
                    end
                end
            endcase
        end
    end

    always_comb begin
        mm_start = 0; mm_tiles = 0; mm_a_addr = 0; mm_b_addr = 0;
        mm_c_addr = 0; mm_accumulate = 0;
        l_start = 0; s_start = 0;
        l_ddr_addr = 0; s_ddr_addr = 0;
        l_bram_addr = 0; s_bram_addr = 0;
        l_length = 0; s_length = 0;
        act_start = 0; act_c_addr = 0; act_length = 0; act_mode = 0;
        act_bias_addr = 0; act_bias_en = 0;
        qz_start = 0; qz_c_addr = 0; qz_b_addr = 0; qz_scale_addr = 0;
        qz_length = 0; qz_shift = 0;

        case (op)
            4'b0000: l_dest = 2'b00;
            4'b0001: l_dest = 2'b01;
            4'b0111: l_dest = 2'b10;
            4'b1000: l_dest = 2'b11;
            default: l_dest = 2'b00;
        endcase

        case (op)
            4'b0000, 4'b0001, 4'b0111, 4'b1000: begin  // LOAD_A/B/BIAS/SCALE
                l_ddr_addr  = instr[59:28];
                l_bram_addr = instr[27:14];
                l_length    = instr[13:9];
                l_start     = (state == DECODE);
            end
            4'b0010: begin                     // MATMUL
                mm_a_addr     = instr[59:46];
                mm_b_addr     = instr[45:32];
                mm_c_addr     = instr[31:18];
                mm_tiles      = instr[17:13];
                mm_accumulate = instr[12];
                mm_start      = (state == DECODE);
            end
            4'b0011: begin                     // STORE_C
                s_ddr_addr  = instr[59:28];
                s_bram_addr = instr[27:14];
                s_length    = instr[13:9];
                s_start     = (state == DECODE);
            end
            4'b0100: begin                     // ACTIVATE
                act_c_addr    = instr[59:46];
                act_bias_addr = instr[45:32];
                act_bias_en   = instr[31];
                act_length    = instr[17:13];
                act_mode      = instr[12:10];
                act_start     = (state == DECODE);
            end
            4'b0101: begin                     // QUANTIZE
                qz_c_addr     = instr[59:46];
                qz_b_addr     = instr[45:32];
                qz_scale_addr = instr[31:18];
                qz_length     = instr[17:13];
                qz_shift      = instr[12:8];
                qz_start      = (state == DECODE);
            end
            default: ;
        endcase
    end

endmodule
