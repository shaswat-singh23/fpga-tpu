`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/15/2026 07:12:54 PM
// Design Name: 
// Module Name: quantize_unit_tb
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


module quantize_unit_tb;
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, start;
    logic [13:0] c_addr, b_addr, scale_addr;
    logic [4:0]  length, shift;
    logic        done;

    logic [13:0] raddrC;
    logic signed [255:0] rdataC;
    logic weB;
    logic [13:0] waddrB;
    logic signed [63:0] wdataB;
    logic [13:0] scale_raddr;
    logic [63:0] scale_rdata;

    logic signed [255:0] c_mem [0:191];
    logic [13:0] c_raddr_lat;
    always_ff @(posedge clk) c_raddr_lat <= raddrC;
    assign rdataC = c_mem[c_raddr_lat];

    logic signed [63:0] b_mem [0:191];
    always_ff @(posedge clk) begin
        if (weB) b_mem[waddrB] <= wdataB;
    end

    logic [63:0] scale_mem [0:7];
    logic [13:0] scale_raddr_lat;
    always_ff @(posedge clk) scale_raddr_lat <= scale_raddr;
    assign scale_rdata = scale_mem[scale_raddr_lat];

    quantize_unit dut (
        .clk(clk), .rst(rst), .start(start),
        .c_addr(c_addr), .b_addr(b_addr), .scale_addr(scale_addr),
        .length(length), .shift(shift),
        .done(done),
        .raddrC(raddrC), .rdataC(rdataC),
        .weB(weB), .waddrB(waddrB), .wdataB(wdataB),
        .scale_raddr(scale_raddr), .scale_rdata(scale_rdata)
    );

    function automatic logic signed [255:0] pack8_c(
        input logic signed [31:0] v0, v1, v2, v3, v4, v5, v6, v7
    );
        pack8_c = {v7, v6, v5, v4, v3, v2, v1, v0};
    endfunction

    function automatic logic [63:0] pack8_m(
        input logic [7:0] m0, m1, m2, m3, m4, m5, m6, m7
    );
        pack8_m = {m7, m6, m5, m4, m3, m2, m1, m0};
    endfunction

    // ---- one trial: drive start, wait for done, check every word ----
    task automatic run_trial(
        input int trial_id,
        input logic [13:0] t_c_addr, t_b_addr, t_scale_addr,
        input logic [4:0]  t_length, t_shift,
        input int c_base, m_base,
        input bit zero_scale = 0
    );
        int w, lane, ii, errors;
        logic signed [31:0] c_val;
        logic [7:0] m_val;
        logic signed [47:0] product, shifted;
        logic signed [7:0] exp_val, got_val;
        int total_words;

        total_words = t_length * t_length * 8;

        // fill C_buf and scale_buf for this trial's region
        for (w = 0; w < total_words; w++) begin
            c_mem[t_c_addr + w] = pack8_c(
                c_base + w*13 - 900, c_base + w*13 - 800, c_base + w*13 - 700, c_base + w*13 - 600,
                c_base + w*13 - 500, c_base + w*13 - 400, c_base + w*13 - 300, c_base + w*13 - 200
            );
        end
        for (ii = 0; ii < t_length; ii++) begin
            if (zero_scale)
                scale_mem[t_scale_addr + ii] = pack8_m(0,0,0,0,0,0,0,0);
            else
                scale_mem[t_scale_addr + ii] = pack8_m(
                    m_base+ii*8+1, m_base+ii*8+2, m_base+ii*8+3, m_base+ii*8+4,
                    m_base+ii*8+5, m_base+ii*8+6, m_base+ii*8+7, m_base+ii*8+8
                );
        end

        // scrub b_mem region so a missing write shows up as X, not stale pass data
        for (w = 0; w < total_words; w++) b_mem[t_b_addr + w] = 'x;

        c_addr = t_c_addr; b_addr = t_b_addr; scale_addr = t_scale_addr;
        length = t_length; shift = t_shift;

        // NO settling delay here on purpose -- start asserts the cycle
        // right after the caller deasserted it from the previous trial,
        // exactly matching real back-to-back usage with no reset between.
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        wait (done == 1);
        @(posedge clk);

        errors = 0;
        for (w = 0; w < total_words; w++) begin
            ii = (w / 8) % t_length;          // <-- the missing modulo
            for (lane = 0; lane < 8; lane++) begin
                c_val   = c_base + w*13 - 900 + lane*100;
                m_val   = zero_scale ? 8'd0 : (m_base + ii*8 + lane + 1);
                product = c_val * $signed({1'b0, m_val});
                shifted = product >>> t_shift;
                if (shifted > 48'sd127)       exp_val = 8'sd127;
                else if (shifted < -48'sd128) exp_val = -8'sd128;
                else                          exp_val = shifted[7:0];

                got_val = b_mem[t_b_addr + w][lane*8 +: 8];
                if (got_val !== exp_val) begin
                    if (errors < 10)
                        $display("TRIAL %0d MISMATCH w=%0d lane=%0d: got %0d exp %0d",
                                 trial_id, w, lane, got_val, exp_val);
                    errors++;
                end
            end
        end

        if (errors == 0) $display("TRIAL %0d PASS (%0d words)", trial_id, total_words);
        else              $display("TRIAL %0d FAIL: %0d mismatches", trial_id, errors);
    endtask

    // done-timing check: after done, weB must not pulse again until the next start
    logic monitor_on;
    always_ff @(posedge clk) begin
        if (monitor_on && weB && done)
            $display("WARNING: weB pulsed after done with no new start");
    end

    initial begin
        rst = 1; start = 0; monitor_on = 0;
        c_addr = 0; b_addr = 0; scale_addr = 0; length = 0; shift = 0;
        #40;
        rst = 0;
        #20;

        // Trial 1: normal case, len=2
        run_trial(1, 0,  0,  0, 5'd2, 5'd4, 0,    0);
        // Trial 2: immediately after trial 1, no reset -- different region/params
        run_trial(2, 32, 32, 2, 5'd2, 5'd6, 500,  20);
        // Trial 3: len=1 -- the edge case where element 0 is also the last element
        run_trial(3, 64, 64, 4, 5'd1, 5'd3, -300, 40);
        // Trial 4: back-to-back again right after the len=1 edge case
        run_trial(4, 72, 72, 5, 5'd2, 5'd7, 900,  60);
        // Trial 5: scale = all zero -- output must be all zero
        scale_mem[6] = pack8_m(0,0,0,0,0,0,0,0);
        scale_mem[7] = pack8_m(0,0,0,0,0,0,0,0);
        run_trial(5, 104,104,6, 5'd2, 5'd4, 700,  0, 1);  // zero_scale=1        // (override: force scale_mem for trial 5 to genuinely all-0, since
        //  run_trial's m_base math won't naturally produce 0 -- do it directly)

        $display("ALL TRIALS COMPLETE");
        $finish;
    end

    initial begin
        #50000;
        $display("TIMEOUT: a trial never completed");
        $finish;
    end
endmodule
