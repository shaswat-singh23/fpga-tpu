`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/14/2026 11:48:13 PM
// Design Name: 
// Module Name: top_wrapper_tb
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


module top_wrapper_tb();
    parameter N = 8, DATA_WIDTH = 8, ACC_WIDTH =32;
    localparam TOTAL = N*N;

    logic clk, rst;
    logic s_axis_a_tvalid, s_axis_a_tready, s_axis_a_tlast;
    logic [DATA_WIDTH-1:0] s_axis_a_tdata;
    logic s_axis_b_tvalid, s_axis_b_tready, s_axis_b_tlast;
    logic [DATA_WIDTH-1:0] s_axis_b_tdata;
    logic [DATA_WIDTH-1:0] a_full [0:N-1][0:N-1];
    logic [DATA_WIDTH-1:0] b_full [0:N-1][0:N-1];
    logic load_done;
    logic calc_done;
    logic [DATA_WIDTH-1:0] a_gold [0:TOTAL-1];
    logic [DATA_WIDTH-1:0] b_gold [0:TOTAL-1];
    logic [$clog2(TOTAL)-1:0] a_idx, b_idx;
    logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1];
    logic not_reading;
    logic feeder_start;
    logic reader_downstream_ready;
    logic read_done;
    logic read_valid, read_last;
    logic [ACC_WIDTH-1:0] read_data;
    matrix_loader #(.N(N), .DATA_WIDTH(DATA_WIDTH)) dut (
        .clk(clk), .rst(rst),
        .s_axis_a_tvalid(s_axis_a_tvalid), .s_axis_a_tready(s_axis_a_tready),
        .s_axis_a_tdata(s_axis_a_tdata), .s_axis_a_tlast(s_axis_a_tlast),
        .s_axis_b_tvalid(s_axis_b_tvalid), .s_axis_b_tready(s_axis_b_tready),
        .s_axis_b_tdata(s_axis_b_tdata), .s_axis_b_tlast(s_axis_b_tlast),
        .a_full(a_full), .b_full(b_full),
        .load_done(load_done), .consumed(calc_done)
    );

    feeder_sequencer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) feeder_inst(
    .clk(clk), .rst(rst),
    .done(calc_done),
    .a_full(a_full),
    .b_full(b_full),
    .results(results),
    .start(feeder_start)
    );

    result_reader #(.N(N), .ACC_WIDTH(ACC_WIDTH)) reader_inst(
    .clk(clk), .rst(rst), .start_read(calc_done),
    .m_axis_tready(reader_downstream_ready),
    .read_done(read_done),
    .results(results),
    .m_axis_tvalid(read_valid),
    .m_axis_tlast(read_last),
    .m_axis_tdata(read_data)
    );

    assign s_axis_a_tdata = a_gold[a_idx];
    assign s_axis_a_tlast = (a_idx == TOTAL-1);
    assign s_axis_b_tdata = b_gold[b_idx];
    assign s_axis_b_tlast = (b_idx == TOTAL-1);

    always_ff @(posedge clk) begin
        if (rst) begin
            not_reading<=1;
        end else begin
            if(read_done)
                not_reading<=1;
            else if (feeder_start)
                not_reading<=0;
        end
    end
    assign feeder_start = not_reading&&load_done;
    always_ff @(posedge clk) begin
        if (rst) begin
            a_idx <= 0;
            s_axis_a_tvalid <= 0;
        end else if (s_axis_a_tvalid && s_axis_a_tready) begin
            if (a_idx == TOTAL-1) begin
                s_axis_a_tvalid <= 0;
            end else begin
                a_idx <= a_idx + 1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            b_idx <= 0;
            s_axis_b_tvalid <= 0;
        end else if (s_axis_b_tvalid && s_axis_b_tready) begin
            if (b_idx == TOTAL-1) begin
                s_axis_b_tvalid <= 0;
            end else begin
                b_idx <= b_idx + 1;
            end
        end
    end

    always #5 clk = ~clk;

    initial begin
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                a_gold[i*N+j] = (i*N+j) % 255 + 1;
                b_gold[i*N+j] = ((i*N+j)*7) % 255 + 1;
            end

        clk = 0;
        rst = 1;
        s_axis_a_tvalid = 0;
        s_axis_b_tvalid = 0;
        reader_downstream_ready =1;
        #10;
        rst = 0;
        #10;

        s_axis_a_tvalid = 1;
        s_axis_b_tvalid = 1;

        wait (read_done == 1);
        #20;
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                a_gold[i*N+j] = ((i*N+j) * 3) % 255 + 2;
                b_gold[i*N+j] = ((i*N+j) * 5) % 255 + 2;
            end
        
        // manually rearm the source
        a_idx = 0;
        b_idx = 0;
        #10;
        s_axis_a_tvalid = 1;
        s_axis_b_tvalid = 1;
        
        wait (read_done == 1);
        #20;
        
        $display("run 2 done at time %0t", $time);
        $finish;
    end
endmodule