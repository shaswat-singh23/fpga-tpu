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
    parameter INSTR_ADDR_WIDTH = 7    // 128-deep instruction memory
)(
    input  logic clk, rst,
    input  logic run,                          // AXI-Lite go bit
    // instruction memory read port
    output logic [INSTR_ADDR_WIDTH-1:0] pc,
    input  logic [63:0] instr,
    // to gemm_sequencer (MATMUL)
    output logic mm_start,
    output logic [4:0]  mm_tiles,
    output logic [13:0] mm_a_addr, mm_b_addr,
    output logic mm_accumulate,
    output logic [13:0] mm_c_addr,
    input  logic mm_done,
    // to load/store path
    output logic l_start, s_start,
    output logic l_dest,                 // 0 = LOAD_A (A_buf), 1 = LOAD_B (B_buf)
    output logic [31:0] l_ddr_addr, s_ddr_addr,
    output logic [13:0] l_bram_addr, s_bram_addr,
    output logic [4:0]  l_length, s_length,
    input  logic l_done, s_done,
    // to activate lane
    output logic act_start,
    output logic [13:0] act_c_addr,
    output logic [4:0]  act_length,
    output logic [2:0]  act_mode,
    input  logic act_done,
    // to quantize lane
    output logic qz_start,
    output logic [13:0] qz_c_addr,
    output logic [13:0] qz_a_addr,
    output logic [4:0]  qz_length,
    input  logic qz_done,
    // status to PS
    output logic program_done
);

    typedef enum logic [1:0] {IDLE, FETCH, DECODE, WAITING} state_t;
    state_t state;

    logic [2:0] curr_instr;

    // opcode of the instruction currently on the bus
    logic [2:0] op;
    assign op = instr[63:61];

    // ---- sequential control: PC, state, program_done, retire tracking ----
    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            pc           <= 0;
            program_done <= 0;
            curr_instr   <= 3'b111;
        end else begin
            case (state)
                IDLE: begin
                    if (run) begin
                        program_done <= 0;
                        state        <= DECODE;   // pc=0 instr already valid, skip FETCH
                    end
                end
                FETCH: begin
                    state <= DECODE;              // one-cycle BRAM-read-latency absorber
                end
                DECODE: begin
                    curr_instr <= op;
                    if (op == 3'b110) begin       // HALT
                        program_done <= 1;
                        state        <= IDLE;
                    end else begin
                        state <= WAITING;
                    end
                end
                WAITING: begin
                    if ((curr_instr == 3'b000 && l_done) ||
                        (curr_instr == 3'b001 && l_done) ||
                        (curr_instr == 3'b010 && mm_done) ||
                        (curr_instr == 3'b011 && s_done) ||
                        (curr_instr == 3'b100 && act_done) ||
                        (curr_instr == 3'b101 && qz_done)) begin
                        pc    <= pc + 1;
                        state <= FETCH;
                    end
                end
            endcase
        end
    end

    // ---- combinational decode / dispatch ----
    // start pulses are one cycle wide because DECODE lasts exactly one cycle.
    always_comb begin
        // defaults
        mm_start = 0; mm_tiles = 0; mm_a_addr = 0; mm_b_addr = 0;
        mm_c_addr = 0; mm_accumulate = 0;
        l_start = 0; s_start = 0;
        l_ddr_addr = 0; s_ddr_addr = 0;
        l_bram_addr = 0; s_bram_addr = 0;
        l_length = 0; s_length = 0;
        act_start = 0; act_c_addr = 0; act_length = 0; act_mode = 0;
        qz_start = 0; qz_c_addr = 0; qz_a_addr = 0; qz_length = 0;

        // l_dest is opcode-derived, valid whenever the bus holds a LOAD
        l_dest = (op == 3'b001);

        // field extraction + start pulse, only during the single DECODE cycle
        case (op)
            3'b000, 3'b001: begin              // LOAD_A / LOAD_B
                l_ddr_addr  = instr[60:29];
                l_bram_addr = instr[28:15];
                l_length    = instr[14:10];
                l_start     = (state == DECODE);
            end
            3'b010: begin                      // MATMUL
                mm_a_addr     = instr[60:47];
                mm_b_addr     = instr[46:33];
                mm_c_addr     = instr[32:19];
                mm_tiles      = instr[18:14];
                mm_accumulate = instr[13];
                mm_start      = (state == DECODE);
            end
            3'b011: begin                      // STORE_C
                s_ddr_addr  = instr[60:29];
                s_bram_addr = instr[28:15];
                s_length    = instr[14:10];
                s_start     = (state == DECODE);
            end
            3'b100: begin                      // ACTIVATE
                act_c_addr = instr[60:47];
                act_length = instr[18:14];
                act_mode   = instr[13:11];
                act_start  = (state == DECODE);
            end
            3'b101: begin                      // QUANTIZE
                qz_c_addr = instr[60:47];
                qz_a_addr = instr[32:19];
                qz_length = instr[18:14];
                qz_start  = (state == DECODE);
            end
            default: ;                         // HALT / reserved: no dispatch
        endcase
    end

endmodule
