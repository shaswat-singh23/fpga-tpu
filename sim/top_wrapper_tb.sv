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
    parameter N=8, DATA_WIDTH=8, ACC_WIDTH=32;
    logic clk, rst, start, feeder_done, m_axis_tlast, m_axis_tready;
    logic [DATA_WIDTH-1:0] a_full [0:N-1][0:N-1];
    logic [DATA_WIDTH-1:0] b_full [0:N-1][0:N-1];
    logic [ACC_WIDTH-1:0] results [0:N-1][0:N-1];
    
    logic [ACC_WIDTH-1:0] read_data;
    logic read_valid, read_done;
    feeder_sequencer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH))
    feeder_inst(
        .clk(clk),
        .rst(rst),
        .start(start),
        .done(feeder_done),
        .a_full(a_full),
        .b_full(b_full),
        .results(results)
    );
    
    result_reader #(.ACC_WIDTH(ACC_WIDTH), .N(N))
    reader_inst (
        .clk(clk),
        .rst(rst),
        .start_read(feeder_done),
        .results(results),
        .m_axis_tdata(read_data),
        .m_axis_tvalid(read_valid),
        .read_done(read_done),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );
    logic [31:0] counter = 0;
    always_ff @(posedge clk) begin
        if (read_valid && m_axis_tready)
        counter<=counter+1;
     
    end
    
    int fire_count;
    int tlast_count;
    always # 5 clk = ~clk;
    
always @(posedge clk) begin
    if (read_valid && m_axis_tready) begin
        fire_count <= fire_count + 1;
        if (m_axis_tlast)
            tlast_count <= tlast_count + 1;
    end
end
    
    initial begin
    // fire/tlast tracking

    fire_count = 0;
    tlast_count = 0;

    for (int j=0; j<N; j++)
        for (int i=0; i<N; i++) begin
            a_full[i][j] = (i*N+j)%255+1;
            b_full[i][j] = ((i*N+j)*7)%255 +1;
        end

    clk = 0;
    m_axis_tready = 1;
    rst = 1;
    start = 0;
    #10;
    rst = 0;
    #10;
    start = 1;
    #10;
    start = 0;

    // wait until reading has actually started
    wait (reader_inst.state == 2'b01); 

    //stalls at first element
    @(posedge clk);
    m_axis_tready = 0;
    repeat (3) @(posedge clk);
    m_axis_tready = 1;

    //toggles mid burst
    wait (reader_inst.index == 8'd30);
    @(posedge clk);
    m_axis_tready = 0;
    repeat (4) @(posedge clk);
    m_axis_tready = 1;

    wait (reader_inst.index == (N*N-1));
    @(posedge clk);
    m_axis_tready = 0;
    repeat (5) @(posedge clk);
    m_axis_tready = 1;

    wait (read_done == 1);
    #20;

    $display("fire_count = %0d (expect %0d)", fire_count, N*N);
    $display("tlast_count = %0d (expect 1)", tlast_count);
    if (fire_count !== N*N)
        $display("FAIL: fire count mismatch");
    if (tlast_count !== 1)
        $display("FAIL: tlast count mismatch");

    $finish;
end


endmodule
