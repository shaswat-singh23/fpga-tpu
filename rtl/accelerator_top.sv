`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/28/2026 11:01:20 PM
// Design Name: 
// Module Name: accelerator_top
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


module accelerator_top #(
    parameter INSTR_ADDR_WIDTH = 9,   // 512 instruction slots
    parameter BRAM_ADDR_WIDTH = 14,
    // Sized for the full 2-layer MNIST MLP resident simultaneously,
    // batch=64. Layer 1 (784->64, K-tiled at tiles=8/64-cube, 13
    // K-chunks of 64x64, padded contraction 832) + Layer 2 (64->16,
    // single 64-cube call, no K-tiling needed since K=64 fits exactly).
    parameter A_BUF_DEPTH = 7168,   // 64-bit words: (13*64*64 + 1*64*64) / 8
    parameter B_BUF_DEPTH = 6656,   // same shape as A_buf
    parameter C_BUF_DEPTH = 512     // 256-bit words: max(64*64,64*64)/8 -- transient, reused per layer
)(
    input  logic clk, rst,

    input  logic run,
    output logic program_done,
    input  logic                        instr_we,
    input  logic [INSTR_ADDR_WIDTH-1:0] instr_waddr,
    input  logic [63:0]                 instr_wdata,
    input  logic [INSTR_ADDR_WIDTH-1:0] instr_raddr,
    output logic [63:0]                 instr_rdata,
    input  logic [BRAM_ADDR_WIDTH-1:0]  dbg_raddr,
    output logic [63:0]                 dbg_rdata,

    input  logic        dbg_cmd_start,
    input  logic [31:0] dbg_cmd_ddr_addr,
    input  logic [4:0]  dbg_cmd_length,
    output logic [1:0]  dbg_cmd_state,
    output logic        dbg_cmd_done,
    output logic        dbg_cmd_err,
    output logic [1:0]  dbg_store_cmd_state,
    output logic        dbg_store_cmd_done,
    output logic        dbg_store_cmd_err,
    output logic        dbg_store_adapter_done,

    output logic [71:0] mm2s_cmd_tdata,
    output logic        mm2s_cmd_tvalid,
    input  logic        mm2s_cmd_tready,
    input  logic [7:0]  mm2s_sts_tdata,
    input  logic        mm2s_sts_tvalid,
    output logic        mm2s_sts_tready,
    input  logic [63:0] mm2s_tdata,
    input  logic        mm2s_tvalid,
    input  logic        mm2s_tlast,
    output logic        mm2s_tready,

    output logic [71:0] s2mm_cmd_tdata,
    output logic        s2mm_cmd_tvalid,
    input  logic        s2mm_cmd_tready,
    input  logic [7:0]  s2mm_sts_tdata,
    input  logic        s2mm_sts_tvalid,
    output logic        s2mm_sts_tready,
    output logic [255:0] s2mm_tdata,
    output logic         s2mm_tvalid,
    output logic         s2mm_tlast,
    input  logic         s2mm_tready
);

    // ================= instruction memory =================
    logic [INSTR_ADDR_WIDTH-1:0] pc;
    logic [63:0] instr_mem_rdata;
    logic [INSTR_ADDR_WIDTH-1:0] instr_mem_raddr;
    logic running;

    assign instr_mem_raddr = running ? pc : instr_raddr;
    assign instr_rdata = instr_mem_rdata;

    logic [63:0] instr;
    assign instr = instr_mem_rdata;

    tile_bram #(.WIDTH(64), .DEPTH(1<<INSTR_ADDR_WIDTH)) instr_mem(
        .clk(clk), .we(instr_we), .waddr(instr_waddr),
        .raddr(instr_mem_raddr), .wdata(instr_wdata), .rdata(instr_mem_rdata)
    );

    always_ff @(posedge clk) begin
        if (rst) running <= 1'b0;
        else if (run) running <= 1'b1;
        else if (program_done) running <= 1'b0;
    end

    // ================= instruction_unit =================
    logic mm_start; logic [4:0] mm_tiles; logic [13:0] mm_a_addr, mm_b_addr;
    logic mm_accumulate; logic [13:0] mm_c_addr; logic mm_done;
    logic l_start_iu, s_start;
    logic [1:0]  l_dest;
    logic [31:0] l_ddr_addr_iu, s_ddr_addr;
    logic [13:0] l_bram_addr, s_bram_addr;
    logic [4:0]  l_length_iu, s_length;
    logic l_done, s_done;
    logic act_start; logic [13:0] act_c_addr, act_bias_addr;
    logic act_bias_en; logic [4:0] act_length; logic [2:0] act_mode; logic act_done;
    logic qz_start; logic [13:0] qz_c_addr, qz_b_addr, qz_scale_addr;
    logic [4:0] qz_length, qz_shift; logic qz_done;

    instruction_unit #(.INSTR_ADDR_WIDTH(INSTR_ADDR_WIDTH)) iu(
        .clk(clk), .rst(rst), .run(run), .pc(pc), .instr(instr),
        .mm_start(mm_start), .mm_tiles(mm_tiles), .mm_a_addr(mm_a_addr), .mm_b_addr(mm_b_addr),
        .mm_accumulate(mm_accumulate), .mm_c_addr(mm_c_addr), .mm_done(mm_done),
        .l_start(l_start_iu), .s_start(s_start), .l_dest(l_dest),
        .l_ddr_addr(l_ddr_addr_iu), .s_ddr_addr(s_ddr_addr),
        .l_bram_addr(l_bram_addr), .s_bram_addr(s_bram_addr),
        .l_length(l_length_iu), .s_length(s_length), .l_done(l_done), .s_done(s_done),
        .act_start(act_start), .act_c_addr(act_c_addr),
        .act_bias_addr(act_bias_addr), .act_bias_en(act_bias_en),
        .act_length(act_length), .act_mode(act_mode), .act_done(act_done),
        .qz_start(qz_start), .qz_c_addr(qz_c_addr), .qz_b_addr(qz_b_addr),
        .qz_scale_addr(qz_scale_addr), .qz_length(qz_length), .qz_shift(qz_shift),
        .qz_done(qz_done),
        .program_done(program_done)
    );

    // ================= LOAD path (LOAD_A, LOAD_B, LOAD_BIAS, LOAD_SCALE) =================
    logic l_start;
    logic [31:0] l_ddr_addr;
    logic [4:0]  l_length;

    assign l_start    = l_start_iu   | dbg_cmd_start;
    assign l_ddr_addr = dbg_cmd_start ? dbg_cmd_ddr_addr : l_ddr_addr_iu;
    assign l_length   = dbg_cmd_start ? dbg_cmd_length   : l_length_iu;

    logic l_cmd_done, l_cmd_err, l_adapter_done;
    assign l_done = l_cmd_done && l_adapter_done;
    assign dbg_cmd_done = l_cmd_done;
    assign dbg_cmd_err  = l_cmd_err;

    datamover_cmd #(.BYTES_PER_TILECT_SQ(64)) load_cmd(
        .clk(clk), .rst(rst),
        .start(l_start), .ddr_addr(l_ddr_addr), .length(l_length), .done(l_cmd_done),
        .cmd_tdata(mm2s_cmd_tdata), .cmd_tvalid(mm2s_cmd_tvalid), .cmd_tready(mm2s_cmd_tready),
        .sts_tdata(mm2s_sts_tdata), .sts_tvalid(mm2s_sts_tvalid), .sts_tready(mm2s_sts_tready),
        .err(l_cmd_err)
    );

    assign dbg_cmd_state = load_cmd.state;

    logic weA, weB_load, weBias, weScale;
    logic [13:0] load_waddr;
    logic [63:0] load_wdata;
    bram_adapter load_adp(
        .clk(clk), .rst(rst), .start(l_start), .dest(l_dest), .bram_addr(l_bram_addr),
        .done(l_adapter_done),
        .s_tdata(mm2s_tdata), .s_tvalid(mm2s_tvalid), .s_tlast(mm2s_tlast), .s_tready(mm2s_tready),
        .weA(weA), .weB(weB_load), .weBias(weBias), .weScale(weScale),
        .waddr(load_waddr), .wdata(load_wdata)
    );

    // ================= STORE path =================
    logic s_cmd_done, s_cmd_err, s_adapter_done;
    assign s_done = s_cmd_done && s_adapter_done;
    assign dbg_store_cmd_done     = s_cmd_done;
    assign dbg_store_cmd_err      = s_cmd_err;
    assign dbg_store_adapter_done = s_adapter_done;

    datamover_cmd #(.BYTES_PER_TILECT_SQ(256)) store_cmd(
        .clk(clk), .rst(rst),
        .start(s_start), .ddr_addr(s_ddr_addr), .length(s_length), .done(s_cmd_done),
        .cmd_tdata(s2mm_cmd_tdata), .cmd_tvalid(s2mm_cmd_tvalid), .cmd_tready(s2mm_cmd_tready),
        .sts_tdata(s2mm_sts_tdata), .sts_tvalid(s2mm_sts_tvalid), .sts_tready(s2mm_sts_tready),
        .err(s_cmd_err)
    );
    assign dbg_store_cmd_state = store_cmd.state;

    logic [13:0] store_raddr;
    logic [255:0] c_rdata_store;
    store_adapter store_adp(
        .clk(clk), .rst(rst), .start(s_start), .bram_addr(s_bram_addr), .length(s_length),
        .done(s_adapter_done),
        .m_tdata(s2mm_tdata), .m_tvalid(s2mm_tvalid), .m_tlast(s2mm_tlast), .m_tready(s2mm_tready),
        .raddr(store_raddr), .rdata(c_rdata_store)
    );

    // ================= BRAMs =================

    logic [13:0] gs_raddrA;
    logic signed [63:0] gs_rdataA;
    logic [13:0] a_raddr_mux;
    logic [63:0] a_rdata_raw;
    assign a_raddr_mux = running ? gs_raddrA : dbg_raddr;
    assign dbg_rdata   = a_rdata_raw;
    assign gs_rdataA   = a_rdata_raw;

    tile_bram #(.WIDTH(64), .DEPTH(A_BUF_DEPTH)) A_buf(
        .clk(clk), .we(weA), .waddr(load_waddr), .raddr(a_raddr_mux),
        .wdata(load_wdata), .rdata(a_rdata_raw)
    );

    // `quantizing` latch, same shape as `activating`/`storing` -- gates
    // B_buf's write mux and joins C_buf's read mux (quantize_unit reads
    // C_buf, writes B_buf).
    logic quantizing;
    always_ff @(posedge clk) begin
        if (rst) quantizing <= 1'b0;
        else if (qz_start) quantizing <= 1'b1;
        else if (qz_done)  quantizing <= 1'b0;
    end

    logic qz_weB;
    logic [13:0] qz_waddrB;
    logic signed [63:0] qz_wdataB;

    logic weB_mux;
    logic [13:0] waddrB_mux;
    logic [63:0] wdataB_mux;
    assign weB_mux    = quantizing ? qz_weB    : weB_load;
    assign waddrB_mux = quantizing ? qz_waddrB : load_waddr;
    assign wdataB_mux = quantizing ? qz_wdataB : load_wdata;

    logic [13:0] gs_raddrB;
    logic signed [63:0] gs_rdataB;

    tile_bram #(.WIDTH(64), .DEPTH(B_BUF_DEPTH)) B_buf(
        .clk(clk), .we(weB_mux), .waddr(waddrB_mux), .raddr(gs_raddrB),
        .wdata(wdataB_mux), .rdata(gs_rdataB)
    );

    logic [13:0] bias_raddr_from_act;
    logic signed [63:0] bias_rdata_from_bram;
    tile_bram #(.WIDTH(64), .DEPTH(128)) bias_buf(
        .clk(clk), .we(weBias), .waddr(load_waddr), .raddr(bias_raddr_from_act),
        .wdata(load_wdata), .rdata(bias_rdata_from_bram)
    );

    // scale_buf: same shape as bias_buf -- 8 packed uint8 M values per word,
    // one word per tile-row, DEPTH=16 for MAX_N=128.
    logic [13:0] scale_raddr_from_qz;
    logic [63:0] scale_rdata_from_bram;
    tile_bram #(.WIDTH(64), .DEPTH(128)) scale_buf(
        .clk(clk), .we(weScale), .waddr(load_waddr), .raddr(scale_raddr_from_qz),
        .wdata(load_wdata), .rdata(scale_rdata_from_bram)
    );

    // -- C_buf: written by gemm_sequencer or activate_unit; read by
    // store_adapter, gemm_sequencer, activate_unit, and quantize_unit. --
    logic        gs_weC;
    logic [13:0] gs_waddrC;
    logic signed [255:0] gs_wdataC;
    logic [13:0] gs_raddrC;
    logic signed [255:0] gs_rdataC;

    logic storing;
    always_ff @(posedge clk) begin
        if (rst) storing <= 1'b0;
        else if (s_start) storing <= 1'b1;
        else if (s_done)  storing <= 1'b0;
    end

    logic activating;
    always_ff @(posedge clk) begin
        if (rst) activating <= 1'b0;
        else if (act_start) activating <= 1'b1;
        else if (act_done)  activating <= 1'b0;
    end

    logic [13:0] act_raddrC, act_waddrC;
    logic        act_weC;
    logic signed [255:0] act_wdataC;
    logic signed [255:0] act_rdataC;

    logic [13:0] qz_raddrC;
    logic signed [255:0] qz_rdataC;

    // C_buf READ mux: 4-way priority (quantize > activate > store > gemm).
    // Mutually exclusive in simple mode -- see the DAE hazard note for why
    // this priority scheme won't generalize as-is once instructions can
    // truly overlap.
    logic [13:0]  c_raddr_mux;
    logic [255:0] c_rdata_raw;
    assign c_raddr_mux = quantizing ? qz_raddrC :
                         activating ? act_raddrC :
                         storing    ? store_raddr :
                                      gs_raddrC;
    assign c_rdata_store = c_rdata_raw;
    assign gs_rdataC     = c_rdata_raw;
    assign act_rdataC    = c_rdata_raw;
    assign qz_rdataC     = c_rdata_raw;

    // C_buf WRITE mux: 2-way (gemm vs activate; quantize writes B_buf, not C_buf).
    logic        c_we_mux;
    logic [13:0] c_waddr_mux;
    logic signed [255:0] c_wdata_mux;
    assign c_we_mux    = activating ? act_weC    : gs_weC;
    assign c_waddr_mux = activating ? act_waddrC : gs_waddrC;
    assign c_wdata_mux = activating ? act_wdataC : gs_wdataC;

    tile_bram #(.WIDTH(256), .DEPTH(C_BUF_DEPTH)) C_buf(
        .clk(clk), .we(c_we_mux), .waddr(c_waddr_mux), .raddr(c_raddr_mux),
        .wdata(c_wdata_mux), .rdata(c_rdata_raw)
    );

    // ================= gemm_sequencer =================
    gemm_sequencer #(
        .MAX_N(128), .DATA_WIDTH(8), .ACC_WIDTH(32), .ARRAY_N(8)
    ) gs(
        .clk(clk), .rst(rst), .start(mm_start),
        .tiles(mm_tiles),
        .accumulating(mm_accumulate),
        .rdataA(gs_rdataA),
        .rdataB(gs_rdataB),
        .rdataC(gs_rdataC),
        .addrAoffset(mm_a_addr),
        .addrBoffset(mm_b_addr),
        .addrCoffset(mm_c_addr),
        .raddrA(gs_raddrA),
        .raddrB(gs_raddrB),
        .waddrC(gs_waddrC),
        .raddrC(gs_raddrC),
        .weC(gs_weC),
        .done(mm_done),
        .wdataC(gs_wdataC)
    );

    // ================= activate_unit =================
    activate_unit act(
        .clk(clk), .rst(rst), .start(act_start),
        .c_addr(act_c_addr), .bias_addr(act_bias_addr),
        .length(act_length), .mode(act_mode), .bias_en(act_bias_en),
        .done(act_done),
        .raddrC(act_raddrC), .rdataC(act_rdataC),
        .weC(act_weC), .waddrC(act_waddrC), .wdataC(act_wdataC),
        .bias_raddr(bias_raddr_from_act), .bias_rdata(bias_rdata_from_bram)
    );

    // ================= quantize_unit =================
    quantize_unit qz(
        .clk(clk), .rst(rst), .start(qz_start),
        .c_addr(qz_c_addr), .b_addr(qz_b_addr), .scale_addr(qz_scale_addr),
        .length(qz_length), .shift(qz_shift),
        .done(qz_done),
        .raddrC(qz_raddrC), .rdataC(qz_rdataC),
        .weB(qz_weB), .waddrB(qz_waddrB), .wdataB(qz_wdataB),
        .scale_raddr(scale_raddr_from_qz), .scale_rdata(scale_rdata_from_bram)
    );

endmodule
