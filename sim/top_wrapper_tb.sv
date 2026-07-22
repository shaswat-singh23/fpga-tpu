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
    logic [DATA_WIDTH*8-1:0] s_axis_a_tdata;
    logic s_axis_b_tvalid, s_axis_b_tready, s_axis_b_tlast;
    logic [DATA_WIDTH*8-1:0] s_axis_b_tdata;
    logic [DATA_WIDTH-1:0] a_full [0:N-1][0:N-1];
    logic [DATA_WIDTH-1:0] b_full [0:N-1][0:N-1];
    logic load_done;
    logic calc_done;
    logic [DATA_WIDTH-1:0] a_gold [0:TOTAL-1];
    logic [DATA_WIDTH-1:0] b_gold [0:TOTAL-1];
    logic [$clog2(TOTAL)-1:0] a_idx, b_idx;
    logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1];
    logic feeder_start;
    logic reader_downstream_ready;
    logic reader_downstream_readytwo;

    logic read_done;
    logic read_valid, read_validtwo, read_last, read_lasttwo;
    logic [ACC_WIDTH*2-1:0] read_data, read_datatwo;
    logic loader_consumed;
    
    pipeline_ctrl ctrl_inst(
    .clk (clk), .rst(rst),
    .load_done(load_done),
    .calc_done(calc_done),
    .read_done(read_done),
    .feeder_start(feeder_start),
    .loader_consumed(loader_consumed)
    );
    
    matrix_loader #(.N(N), .DATA_WIDTH(DATA_WIDTH)) dut (
        .clk(clk), .rst(rst),
        .s_axis_a_tvalid(s_axis_a_tvalid), .s_axis_a_tready(s_axis_a_tready),
        .s_axis_a_tdata(s_axis_a_tdata), .s_axis_a_tlast(s_axis_a_tlast),
        .s_axis_b_tvalid(s_axis_b_tvalid), .s_axis_b_tready(s_axis_b_tready),
        .s_axis_b_tdata(s_axis_b_tdata), .s_axis_b_tlast(s_axis_b_tlast),
        .a_full(a_full), .b_full(b_full),
        .load_done(load_done), .consumed(loader_consumed)
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
    .m_axis_one_tready(reader_downstream_ready), .m_axis_two_tready(reader_downstream_readytwo),
    .read_done(read_done),
    .results(results),
    .m_axis_one_tvalid(read_valid), .m_axis_two_tvalid(read_validtwo),
    .m_axis_one_tlast(read_last), .m_axis_two_tlast(read_lasttwo),
    .m_axis_one_tdata(read_data), .m_axis_two_tdata(read_datatwo)
    );

    assign s_axis_a_tdata = {a_gold[a_idx*8+7], a_gold[a_idx*8+6],a_gold[a_idx*8+5],a_gold[a_idx*8+4],a_gold[a_idx*8+3],a_gold[a_idx*8+2],a_gold[a_idx*8+1],a_gold[a_idx*8]};
    assign s_axis_a_tlast = (a_idx == (TOTAL>>3)-1);
    assign s_axis_b_tdata = {b_gold[b_idx*8+7], b_gold[b_idx*8+6],b_gold[b_idx*8+5],b_gold[b_idx*8+4],b_gold[b_idx*8+3],b_gold[b_idx*8+2],b_gold[b_idx*8+1],b_gold[b_idx*8]};
    assign s_axis_b_tlast = (b_idx == (TOTAL>>3)-1);


    always_ff @(posedge clk) begin
        if (rst) begin
            a_idx <= 0;
            s_axis_a_tvalid <= 0;
        end else if (s_axis_a_tvalid && s_axis_a_tready) begin
            if (a_idx == (TOTAL>>3)-1) begin
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
            if (b_idx == (TOTAL>>3)-1) begin
                s_axis_b_tvalid <= 0;
            end else begin
                b_idx <= b_idx + 1;
            end
        end
    end

    always #5 clk = ~clk;

    int fire_one, fire_two;
    int tlast_one_count, tlast_two_count;

    always @(posedge clk) begin
        if (read_valid && reader_downstream_ready) begin
            fire_one <= fire_one + 1;
            if (read_last) tlast_one_count <= tlast_one_count + 1;
        end
        if (read_validtwo && reader_downstream_readytwo) begin
            fire_two <= fire_two + 1;
            if (read_lasttwo) tlast_two_count <= tlast_two_count + 1;
        end
    end

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
        reader_downstream_ready = 1;
        reader_downstream_readytwo = 1;  
        fire_one = 0; fire_two = 0;
        tlast_one_count = 0; tlast_two_count = 0;
        #10;
        rst = 0;
        #10;
    
        s_axis_a_tvalid = 1;
        s_axis_b_tvalid = 1;
    
        wait (read_done == 1);
        #20;
    
        $display("run 1: fire_one=%0d fire_two=%0d (expect %0d each)",
                  fire_one, fire_two, (N*N)>>2);
        $display("run 1: tlast_one=%0d tlast_two=%0d (expect 1 each)",
                  tlast_one_count, tlast_two_count);
        if (fire_one !== (N*N)>>2) $display("FAIL: fire_one count mismatch");
        if (fire_two !== (N*N)>>2) $display("FAIL: fire_two count mismatch");
        if (tlast_one_count !== 1) $display("FAIL: tlast_one count mismatch");
        if (tlast_two_count !== 1) $display("FAIL: tlast_two count mismatch");
    
        $display("run 1 done at time %0t", $time);
        $finish;
    end
    
endmodule