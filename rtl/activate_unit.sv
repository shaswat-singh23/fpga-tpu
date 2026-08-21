`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/12/2026 06:28:57 PM
// Design Name: 
// Module Name: activate_unit
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


module activate_unit (
    input  logic clk, rst, start,
    input  logic [13:0] c_addr,
    input  logic [13:0] bias_addr,
    input  logic [4:0]  length,
    input  logic [2:0]  mode,
    input  logic        bias_en,
    output logic        done,
    output logic [13:0] raddrC,
    input  logic signed [255:0] rdataC,
    output logic        weC,
    output logic [13:0] waddrC,
    output logic signed [255:0] wdataC,
    output logic [13:0] bias_raddr,
    input  logic signed [63:0]  bias_rdata
);

    logic [13:0] c_off, bias_off;
    logic [4:0]  len_lat;
    logic [2:0]  mode_lat;
    logic        bias_en_lat;

    logic running, done_d;
    logic [4:0] i_reg, j_reg, k_reg;
    logic [13:0] waddrC_reg;

    assign raddrC     = running ? (c_off + (j_reg * len_lat + i_reg) * 8 + k_reg) : c_addr;
    assign bias_raddr = running ? (bias_off + i_reg) : bias_addr;
    assign waddrC     = waddrC_reg;
    assign weC        = running;

    // bias_rdata's 8 lanes now align 1:1 with rdataC's 8 lanes (both are
    // "8 neurons" under column-major C) -- straight elementwise add, no
    // per-lane selection needed.
    always_comb begin
        wdataC = rdataC;
        for (int lane = 0; lane < 8; lane++) begin
            logic signed [7:0]  b8;
            logic signed [31:0] c_val, bias_ext, sum, out;
            b8       = bias_rdata[lane*8 +: 8];
            bias_ext = {{24{b8[7]}}, b8};
            c_val    = rdataC[lane*32 +: 32];
            sum      = c_val + (bias_en_lat ? bias_ext : 32'sd0);
            out      = (mode_lat == 3'd0) ? ((sum < 0) ? 32'sd0 : sum) : sum;
            wdataC[lane*32 +: 32] = out;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            running     <= 0;
            done        <= 0;
            done_d      <= 0;
            i_reg       <= 0; j_reg <= 0; k_reg <= 0;
            waddrC_reg  <= 0;
            c_off       <= 0; bias_off <= 0;
            len_lat     <= 0; mode_lat <= 0; bias_en_lat <= 0;
        end else begin
            waddrC_reg <= raddrC;

            if (start) begin
                c_off       <= c_addr;
                bias_off    <= bias_addr;
                len_lat     <= length;
                mode_lat    <= mode;
                bias_en_lat <= bias_en;
                i_reg <= 0; j_reg <= 0; k_reg <= 1;
                running <= 1;
                done    <= 0;
                done_d  <= 0;
            end else if (running) begin
                if (i_reg == len_lat - 1 && j_reg == len_lat - 1 && k_reg == 7) begin
                    done_d <= 1;
                end else begin
                    if (k_reg == 7) begin
                        k_reg <= 0;
                        if (j_reg == len_lat - 1) begin
                            j_reg <= 0;
                            i_reg <= i_reg + 1;
                        end else begin
                            j_reg <= j_reg + 1;
                        end
                    end else begin
                        k_reg <= k_reg + 1;
                    end
                end

                if (done_d) begin
                    done    <= 1;
                    running <= 0;
                end
            end
        end
    end
endmodule

