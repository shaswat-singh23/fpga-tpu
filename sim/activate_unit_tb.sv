`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/12/2026 11:27:59 PM
// Design Name: 
// Module Name: activate_unit_tb
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


module activate_unit_tb;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, start;
    logic [13:0] c_addr, bias_addr;
    logic [4:0]  length;
    logic [2:0]  mode;
    logic        bias_en;
    logic        done;

    logic [13:0] raddrC, waddrC;
    logic signed [255:0] rdataC, wdataC;
    logic weC;

    logic [13:0] bias_raddr;
    logic signed [63:0] bias_rdata;

    logic signed [255:0] c_mem [0:31];
    logic [13:0] c_raddr_lat;
    always_ff @(posedge clk) begin
        c_raddr_lat <= raddrC;
        if (weC) c_mem[waddrC] <= wdataC;
    end
    assign rdataC = c_mem[c_raddr_lat];

    logic signed [63:0] bias_mem [0:1];
    logic [13:0] bias_raddr_lat;
    always_ff @(posedge clk) bias_raddr_lat <= bias_raddr;
    assign bias_rdata = bias_mem[bias_raddr_lat];

    activate_unit dut (
        .clk(clk), .rst(rst), .start(start),
        .c_addr(c_addr), .bias_addr(bias_addr),
        .length(length), .mode(mode), .bias_en(bias_en),
        .done(done),
        .raddrC(raddrC), .rdataC(rdataC),
        .weC(weC), .waddrC(waddrC), .wdataC(wdataC),
        .bias_raddr(bias_raddr), .bias_rdata(bias_rdata)
    );

    function automatic logic signed [255:0] pack8_c(
        input logic signed [31:0] v0, v1, v2, v3, v4, v5, v6, v7
    );
        pack8_c = {v7, v6, v5, v4, v3, v2, v1, v0};
    endfunction

    function automatic logic signed [63:0] pack8_bias(
        input logic signed [7:0] b0, b1, b2, b3, b4, b5, b6, b7
    );
        pack8_bias = {b7, b6, b5, b4, b3, b2, b1, b0};
    endfunction

    logic signed [31:0] c_val, exp_val, got_val, sum;
    logic signed [7:0]  b_val;
    int errors, w, lane, ii, tile_idx, neuron;

    initial begin
        rst = 1; start = 0;
        c_addr = 0; bias_addr = 0; length = 0; mode = 0; bias_en = 0;
        #40;
        rst = 0;
        #20;

        for (w = 0; w < 32; w++) begin
            c_mem[w] = pack8_c(
                w*8+0 - 60, w*8+1 - 60, w*8+2 - 60, w*8+3 - 60,
                w*8+4 - 60, w*8+5 - 60, w*8+6 - 60, w*8+7 - 60
            );
        end

        // bias for output neuron n = n (0..15), one word per tile-row i
        bias_mem[0] = pack8_bias(0, 1, 2, 3, 4, 5, 6, 7);        // neurons 0..7 (i=0)
        bias_mem[1] = pack8_bias(8, 9, 10, 11, 12, 13, 14, 15);  // neurons 8..15 (i=1)

        c_addr    = 0;
        bias_addr = 0;
        length    = 2;
        mode      = 0;
        bias_en   = 1;
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        wait (done == 1);
        @(posedge clk);

        errors = 0;
        for (w = 0; w < 32; w++) begin
            // raddrC formula is now (j*len+i)*8+k -- tile_idx = w/8 = j*len+i,
            // so i is the REMAINDER of tile_idx/length, not w/16 as before.
            tile_idx = w / 8;
            ii = tile_idx % length;
            for (lane = 0; lane < 8; lane++) begin
                // under column-major C, the lane itself is the neuron
                // offset within the tile-row -- bias index = i*8+lane,
                // not i*8+kk (kk no longer determines neuron identity).
                neuron  = ii * 8 + lane;
                b_val   = neuron;
                c_val   = w*8 + lane - 60;
                sum     = c_val + b_val;
                exp_val = (sum < 0) ? 32'sd0 : sum;
                got_val = c_mem[w][lane*32 +: 32];
                if (got_val !== exp_val) begin
                    if (errors < 10) begin
                        $display("MISMATCH w=%0d(i=%0d) lane=%0d: got %0d exp %0d (c=%0d neuron=%0d bias=%0d sum=%0d)",
                                 w, ii, lane, got_val, exp_val, c_val, neuron, b_val, sum);
                    end
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0) $display("PASS: all 256 elements match");
        else             $display("FAIL: %0d mismatches", errors);

        $finish;
    end

    initial begin
        #10000;
        $display("TIMEOUT: done never asserted");
        $finish;
    end
endmodule

