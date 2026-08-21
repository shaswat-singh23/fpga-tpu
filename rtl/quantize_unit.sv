`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/15/2026 01:21:51 PM
// Design Name: 
// Module Name: quantize_unit
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


// Reads C_buf (int32, 256-bit words), scales+clamps to int8, writes B_buf
// (64-bit words). Per-neuron scale (M) read from scale_buf, one 64-bit word
// per tile-row (8 packed uint8 M values), matching bias_buf's pattern
// exactly. shift is a single scalar for the whole instruction.
/*module quantize_unit (
    input  logic clk, rst, start,
    input  logic [13:0] c_addr, b_addr, scale_addr,
    input  logic [4:0]  length,
    input  logic [4:0]  shift,
    output logic        done,
    // C_buf read port (256-bit, 1-cycle registered read)
    output logic [13:0] raddrC,
    input  logic signed [255:0] rdataC,
    // B_buf write port (64-bit)
    output logic        weB,
    output logic [13:0] waddrB,
    output logic signed [63:0] wdataB,
    // scale buffer read port (64-bit, 8 packed uint8 per word)
    output logic [13:0] scale_raddr,
    input  logic [63:0] scale_rdata
);
    logic [13:0] c_off, b_off, scale_off;
    logic [4:0]  len_lat, shift_lat;

    logic running, done_d;
    logic [4:0] i_reg, j_reg, k_reg;
    logic [13:0] rel_reg;   // relative tile-grid index, delayed 1 cycle for
                             // the write side (read/write bases differ, so
                             // the full address can't be delayed the way
                             // activate_unit delays waddrC directly)

    wire [13:0] rel_now = (j_reg * len_lat + i_reg) * 8 + k_reg;

    assign raddrC      = running ? (c_off + rel_now) : c_addr;
    assign scale_raddr = running ? (scale_off + i_reg) : scale_addr;
    assign waddrB       = b_off + rel_reg;
    assign weB           = running;

    always_comb begin
        for (int lane = 0; lane < 8; lane++) begin
            logic signed [31:0] c_val;
            logic [7:0]         m_val;
            logic signed [47:0] product, shifted;
            logic signed [7:0]  out;

            c_val   = rdataC[lane*32 +: 32];
            m_val   = scale_rdata[lane*8 +: 8];   // unsigned: scale is always positive
            product = c_val * $signed({1'b0, m_val});
            shifted = product >>> shift_lat;

            if (shifted > 48'sd127)       out = 8'sd127;
            else if (shifted < -48'sd128) out = -8'sd128;
            else                          out = shifted[7:0];

            wdataB[lane*8 +: 8] = out;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            running <= 0; done <= 0; done_d <= 0;
            i_reg <= 0; j_reg <= 0; k_reg <= 0;
            rel_reg <= 0;
            c_off <= 0; b_off <= 0; scale_off <= 0;
            len_lat <= 0; shift_lat <= 0;
        end else begin
            rel_reg <= rel_now;

            if (start) begin
                c_off     <= c_addr;
                b_off     <= b_addr;
                scale_off <= scale_addr;
                len_lat   <= length;
                shift_lat <= shift;
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
endmodule*/

module quantize_unit (
    input  logic clk, rst, start,
    input  logic [13:0] c_addr, b_addr, scale_addr,
    input  logic [4:0]  length,
    input  logic [4:0]  shift,
    output logic        done,
    output logic [13:0] raddrC,
    input  logic signed [255:0] rdataC,
    output logic        weB,
    output logic [13:0] waddrB,
    output logic signed [63:0] wdataB,
    output logic [13:0] scale_raddr,
    input  logic [63:0] scale_rdata
);
    logic [13:0] c_off, b_off, scale_off;
    logic [4:0]  len_lat, shift_lat;
    logic        running;

    // ---- address generation: pure increment, no multiply ----
    logic [2:0]  k_cnt;      // 0..7, within-tile column
    logic [4:0]  i_cnt;      // 0..len_lat-1, neuron-tile row (drives scale_raddr), wraps every 8 cycles
    logic [4:0]  j_cnt;      // 0..len_lat-1, outer sweep -- completion tracking only, not used for any address
    logic [13:0] addr_cnt;   // flat relative address, +1 each cycle while running

    wire k_last     = (k_cnt == 3'd7);
    wire i_last     = (i_cnt == len_lat - 1);
    wire j_last     = (j_cnt == len_lat - 1);
    wire last_cycle = running && k_last && i_last && j_last;

    assign raddrC      = running ? (c_off + addr_cnt) : c_addr;
    assign scale_raddr = running ? (scale_off + i_cnt) : scale_addr;

    // ---- stage 1: multiply, registered; also tag valid + "is this the last one" ----
    logic signed [47:0] product_reg [0:7];
    logic [13:0] addr_s1;
    logic        valid_s1, last_s1;

    logic [13:0] addr_cnt_d1;
    always_ff @(posedge clk) begin
        if (rst) addr_cnt_d1 <= 0;
        else     addr_cnt_d1 <= addr_cnt;
    end
    
    logic draining;
    always_ff @(posedge clk) begin
        if (rst) draining <= 0;
        else     draining <= running && last_cycle;
    end
    wire read_active = running || start || draining;

    always_ff @(posedge clk) begin
        if (rst) begin
        valid_s1 <= 0; last_s1 <= 0;
        end else begin
            valid_s1 <= read_active;
            last_s1  <= draining;     
            addr_s1  <= addr_cnt_d1;
            for (int lane = 0; lane < 8; lane++) begin
                logic signed [31:0] c_val;
                logic [7:0]         m_val;
                c_val = rdataC[lane*32 +: 32];
                m_val = scale_rdata[lane*8 +: 8];
                product_reg[lane] <= c_val * $signed({1'b0, m_val});
            end
        end
    end



    // ---- stage 2: shift + clamp, combinational off product_reg; latch valid/last again ----
    logic        valid_s2, last_s2;
    logic [13:0] addr_s2;
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_s2 <= 0; last_s2 <= 0;
        end else begin
            valid_s2 <= valid_s1;
            last_s2  <= last_s1;
            addr_s2  <= addr_s1;
        end
    end

    always_comb begin
        for (int lane = 0; lane < 8; lane++) begin
            logic signed [47:0] shifted;
            logic signed [7:0]  out;
            shifted = product_reg[lane] >>> shift_lat;
            if (shifted > 48'sd127)       out = 8'sd127;
            else if (shifted < -48'sd128) out = -8'sd128;
            else                          out = shifted[7:0];
            wdataB[lane*8 +: 8] = out;
        end
    end

    assign weB    = valid_s1;
    assign waddrB = b_off + addr_s1;

    // ---- control ----
    always_ff @(posedge clk) begin
        if (rst) begin
            running <= 0; done <= 0;
            i_cnt <= 0; j_cnt <= 0; k_cnt <= 0; addr_cnt <= 0;
            c_off <= 0; b_off <= 0; scale_off <= 0;
            len_lat <= 0; shift_lat <= 0;
        end else begin
            if (start) begin
                c_off     <= c_addr;
                b_off     <= b_addr;
                scale_off <= scale_addr;
                len_lat   <= length;
                shift_lat <= shift;
                i_cnt <= 0; j_cnt <= 0; k_cnt <= 1; addr_cnt <= 1;  // preload offset, same convention as before
                running <= 1;
                done    <= 0;
            end else if (running) begin
                if (last_cycle) begin
                    addr_cnt <=0;
                    running <= 0;   // stop issuing NEW reads -- pipeline still has 2 in flight
                end else begin
                    addr_cnt <= addr_cnt + 1;
                    if (k_last) begin
                        k_cnt <= 0;
                        if (i_last) begin i_cnt <= 0; j_cnt <= j_cnt + 1; end
                        else i_cnt <= i_cnt + 1;
                    end else k_cnt <= k_cnt + 1;
                end
            end

            // done fires only once the LAST write has actually landed, not when the last read fired
            if (valid_s1 && last_s1) done <= 1;
        end
    end
endmodule
