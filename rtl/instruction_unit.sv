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
    input  logic run,                          // AXI-Lite go bit, level or pulse

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

    // to load/store path (DataMover command gen) for LOAD_A/LOAD_B/STORE_C
    output logic l_start, s_start,
    output logic l_dest,                 // which of LOAD_A/LOAD_B
    output logic [31:0] l_ddr_addr, s_ddr_addr,           // or wider, depending on DDR map
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
    output logic program_done                  // all instructions executed, HALT reached
);
    
    typedef enum logic [1:0] {IDLE, FETCH, DECODE, WAITING} state_t;
    state_t state;
    
    logic [2:0] curr_instr;
    logic mm_start_pulse, l_start_pulse, s_start_pulse, act_start_pulse, qz_start_pulse;
    logic mm_start_pulse_d, l_start_pulse_d, s_start_pulse_d, act_start_pulse_d, qz_start_pulse_d;

    always_ff @(posedge clk) begin
        if (rst) begin
            state<= IDLE;
            pc<=0;
            mm_start_pulse_d <=0; l_start_pulse_d <=0; s_start_pulse_d<=0; act_start_pulse_d <=0; qz_start_pulse <=0;
        end else begin
            case (state) 
                IDLE: begin
                    //program_done<=0;
                    if (run) begin
                        program_done <=0;
                        state <= DECODE;
                    end
                end
                FETCH: begin
                    state <= DECODE;
                end
                DECODE: begin
                    if (instr[63:61] == 3'b000 || instr[63:61] == 3'b001) begin
                        l_start_pulse_d <=1;
                    end else if (instr[63:61] == 3'b010) begin
                        mm_start_pulse_d<=1;
                    end else if (instr[63:61] == 3'b011) begin
                        s_start_pulse_d<=1;
                    end else if (instr[63:61] == 3'b100) begin
                        act_start_pulse_d<=1;
                    end else if (instr[63:61] == 3'b101) begin
                        qz_start_pulse_d<=1;
                    end 
                
                    curr_instr <= instr[63:61];
                    if (instr[63:61] == 3'b110) begin
                        state <= IDLE;
                        program_done <= 1;
                    end else 
                        state <= WAITING;
                end
                WAITING: begin
                //if condition to determine which sample is being waited on
                    if (curr_instr == 3'b000 && l_done || 
                        curr_instr == 3'b001 && l_done ||
                        curr_instr == 3'b010 && mm_done ||
                        curr_instr == 3'b011 && s_done ||
                        curr_instr == 3'b100 && act_done ||
                        curr_instr == 3'b101 && qz_done) begin
                        state <= FETCH;
                        pc <= pc+1;
                    end
                end
            endcase
        end
    end
    

    
    always_comb begin
        //combinational decode logic
        assign mm_start = 0;
        assign mm_tiles = 0;
        assign mm_a_addr = 0;
        assign mm_b_addr = 0;
        assign mm_c_addr = 0;
        assign l_start = 0;
        assign s_start = 0;
        assign l_ddr_addr = 0;
        assign l_bram_addr = 0;
        assign s_bram_addr =0;
        assign s_ddr_addr = 0;
        assign l_length = 0;
        assign s_length = 0;
        assign l_dest = (instr[63:61]==3'b001);
        assign act_start = 0;
        assign act_c_addr = 0;
        assign act_length = 0;
        assign act_mode = 0;
        assign qz_start = 0;
        assign qz_c_addr = 0;
        assign qz_a_addr = 0;
        assign qz_length = 0;
        assign mm_accumulate = 0;
        
        if (instr[63:61] == 3'b000) begin
            assign l_start_pulse = 1;
            assign l_start = l_start_pulse && !l_start_pulse_d;
            assign l_ddr_addr = instr[60:29];
            assign l_bram_addr = instr[28:15];
            assign l_length = instr[14:10];
        end else if (instr[63:61] == 3'b001) begin
            assign l_start_pulse = 1;
            assign l_start = l_start_pulse && !l_start_pulse_d;
            assign l_ddr_addr = instr[60:29];
            assign l_bram_addr = instr[28:15];
            assign l_length = instr[14:10];
        end else if (instr[63:61] == 3'b010) begin
            assign mm_start_pulse = 1;
            assign mm_start = mm_start_pulse && !mm_start_pulse_d;
            assign mm_tiles = instr[18:14];
            assign mm_a_addr = instr[60:47];
            assign mm_b_addr = instr[46:33];
            assign mm_c_addr = instr[32:19];
            assign mm_accumulate = instr[13];
        end else if (instr[63:61] == 3'b011) begin
            assign s_start_pulse = 1;
            assign s_start = s_start_pulse && !s_start_pulse_d;
            assign s_ddr_addr = instr[60:29];
            assign s_bram_addr = instr[28:15];
            assign s_length = instr[14:10];
        end else if (instr[63:61] == 3'b100) begin
            assign act_start_pulse=1;
            assign act_start = act_start_pulse && !act_start_pulse_d;
            assign act_c_addr = instr[60:47];
            assign act_length = instr[18:14];
            assign act_mode = instr[13:11];
        end else if (instr[63:61] == 3'b101) begin
            assign qz_start_pulse =1;
            assign qz_start = qz_start_pulse && !qz_start_pulse_d;
            assign qz_c_addr = instr[60:47];
            assign qz_a_addr = instr[32:19];
            assign qz_length = instr[18:14]; 
        end
    end
    
    
endmodule
