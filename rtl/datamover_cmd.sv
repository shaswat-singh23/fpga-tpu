`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/06/2026 04:16:39 PM
// Design Name: 
// Module Name: datamover_cmd
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


// Drives one AXI DataMover command/status channel (MM2S or S2MM).
// instruction_unit hands: start, ddr_addr, length(tile count).
// build the 72-bit command, send it, wait for the status word, raise done.
module datamover_cmd #(
    parameter BYTES_PER_TILECT_SQ = 64   // 64 for A/B (8-bit), 256 for C (32-bit)
)(
    input  logic clk, rst,

    // ---- from instruction_unit ----
    input  logic        start,          // one-cycle pulse: do a transfer
    input  logic [31:0] ddr_addr,       // where in DDR
    input  logic [4:0]  length,         // tile count per side (N/8)
    output logic        done,           // one-cycle pulse: transfer finished

    // ---- to DataMover command stream (S_AXIS_*_CMD) ----
    output logic [71:0] cmd_tdata,
    output logic        cmd_tvalid,
    input  logic        cmd_tready,

    // ---- from DataMover status stream (M_AXIS_*_STS) ----
    input  logic [7:0]  sts_tdata,
    input  logic        sts_tvalid,
    output logic        sts_tready,

    output logic        err             // status came back not-OKAY
);

    // byte count = length^2 * constant.  length is 0..16, so length^2 fits in 9 bits.
    logic [8:0]  len_sq;
    logic [22:0] btt;
    assign len_sq = length * length;
    assign btt    = len_sq * BYTES_PER_TILECT_SQ;   // fits in 23 bits

    // The 72-bit command word, fields per the datasheet table.
    // [22:0]=BTT, [23]=Type(1=INCR), [29:24]=DSA(0), [30]=EOF(1),
    // [31]=DRR(0), [63:32]=SADDR, [67:64]=TAG(0), [71:68]=RSVD(0).
    logic [71:0] cmd_word;
    assign cmd_word = {
        4'b0,          // RSVD
        4'b0,          // TAG
        ddr_addr,      // SADDR (32 bits)
        1'b0,          // DRR
        1'b1,          // EOF
        6'b0,          // DSA
        1'b1,          // Type = INCR
        btt            // BTT (23 bits)
    };

    typedef enum logic [1:0] {IDLE, SEND, WAITSTS} state_t;
    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            cmd_tvalid <= 0; sts_tready <= 0; done <= 0; err <= 0;
        end else begin
            // REMOVED: done <= 0;    <-- was here, delete it
            case (state)
                IDLE: begin
                    if (start) begin
                        cmd_tdata  <= cmd_word;
                        cmd_tvalid <= 1;
                        done       <= 0;      // <-- ADD: clear on new transfer
                        state      <= SEND;
                    end
                end
                SEND: begin
                    if (cmd_tvalid && cmd_tready) begin
                        cmd_tvalid <= 0;
                        sts_tready <= 1;
                        state      <= WAITSTS;
                    end
                end
                WAITSTS: begin
                    if (sts_tvalid && sts_tready) begin
                        sts_tready <= 0;
                        err   <= ~sts_tdata[7];
                        done  <= 1;           // now STAYS high until next start
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule
