`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/28/2026 09:17:19 PM
// Design Name: 
// Module Name: tile_bram_tb
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


module tile_bram_tb();
    localparam WIDTH = 64;
    localparam DEPTH = 16;
    localparam AWIDTH = $clog2(DEPTH);

    logic clk = 0;
    logic we;
    logic [AWIDTH-1:0] waddr, raddr;
    logic [WIDTH-1:0] wdata, rdata;

    logic [WIDTH-1:0] expected [0:DEPTH-1];

    tile_bram #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk), .we(we),
        .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata)
    );

    always #5 clk = ~clk;

    initial begin
        we = 0; waddr = 0; wdata = 0; raddr = 0;

        // 1. write known pattern to every address
        for (int i = 0; i < DEPTH; i++) begin
            expected[i] = i;
            @(negedge clk);
            we = 1; waddr = i; wdata = expected[i];
        end
        @(negedge clk);
        we = 0;

        // 2. read every address back, check correctness + 1-cycle latency
        raddr = 0;
        @(negedge clk); // raddr=0 now presented to the BRAM
        
        for (int i = 0; i < DEPTH; i++) begin
            // At this point, rdata reflects the PREVIOUS raddr (or garbage on i==0, first read)
            if (i > 0 && rdata !== expected[i-1])
                $display("FAIL: latency check, at step %0d rdata=%h expected old value %h", i, rdata, expected[i-1]);
        
            if (i < DEPTH-1) raddr = i+1; // set up next address while checking current
            @(negedge clk);
        
            // Now rdata should reflect address i
            if (rdata !== expected[i])
                $display("FAIL: read addr %0d got %h expected %h", i, rdata, expected[i]);
            else
                $display("PASS: read addr %0d = %h", i, rdata);
        end 

        // 3. simultaneous write addr 7, read addr 3 (independent ports)
        @(negedge clk);
        we = 1; waddr = 7; wdata = 64'hCAFECAFECAFECAFE;
        raddr = 3;
        @(negedge clk);
        we = 0;
        if (rdata !== expected[3])
            $display("FAIL: concurrent read/write corrupted addr 3, got %h expected %h", rdata, expected[3]);
        else
            $display("PASS: addr 3 unaffected by concurrent write to addr 7");

        @(negedge clk);
        raddr = 7;
        @(negedge clk);
        if (rdata !== 64'hCAFECAFECAFECAFE)
            $display("FAIL: addr 7 write during concurrent read did not take, got %h", rdata);
        else
            $display("PASS: addr 7 correctly updated");

        // 4. same-address write+read collision: write X, read X same cycle
        @(negedge clk);
        we = 1; waddr = 2; wdata = 64'h1111111111111111;
        raddr = 2; // same address as the write, same cycle
        @(negedge clk);
        we = 0;
        // rdata now reflects what was sampled last cycle (should be OLD value: expected[2])
        if (rdata === expected[2])
            $display("PASS: same-address collision reads OLD value (write-after-read behavior)");
        else if (rdata === 64'h1111111111111111)
            $display("NOTE: same-address collision reads NEW value (write-first behavior) - confirm this matches synthesis");
        else
            $display("FAIL: same-address collision produced unexpected value %h", rdata);

        $display("tile_bram_tb done at time %0t", $time);
        $finish;
    end
endmodule
