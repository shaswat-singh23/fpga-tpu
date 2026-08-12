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


// Stripped accelerator_top for the FIRST PS-PL trial: LOAD ONLY.
// Goal: prove the PS-PL bridge + DataMover MM2S path on real silicon.
// Program the PS runs: one LOAD_A, then HALT. PS reads A_buf back through a
// debug read port and confirms the loaded data matches what it put in DDR.
//
// STORE, compute, and B_buf are intentionally out. Add them in later trials
// once this passes.
// Stripped accelerator_top for the FIRST PS-PL trial: LOAD ONLY.
// Goal: prove the PS-PL bridge + DataMover MM2S path on real silicon.
// Program the PS runs: one LOAD_A, then HALT. PS reads A_buf back through a
// debug read port and confirms the loaded data matches what it put in DDR.
//
// STORE, compute, and B_buf are intentionally out. Add them in later trials
// once this passes.
// Stripped accelerator_top for the FIRST PS-PL trial: LOAD ONLY.
// Goal: prove the PS-PL bridge + DataMover MM2S path on real silicon.
// Program the PS runs: one LOAD_A, then HALT. PS reads A_buf back through a
// debug read port and confirms the loaded data matches what it put in DDR.
//
// STORE, compute, and B_buf are intentionally out. Add them in later trials
module accelerator_top #(
    parameter N = 64,
    parameter INSTR_ADDR_WIDTH = 7,
    parameter BRAM_ADDR_WIDTH = 14
)(
    input  logic clk, rst,

    // ---- control (newip AXI-Lite) ----
    input  logic run,
    output logic program_done,
    input  logic                        instr_we,
    input  logic [INSTR_ADDR_WIDTH-1:0] instr_waddr,
    input  logic [63:0]                 instr_wdata,
    input  logic [INSTR_ADDR_WIDTH-1:0] instr_raddr,
    output logic [63:0]                 instr_rdata,
    input  logic [BRAM_ADDR_WIDTH-1:0]  dbg_raddr,
    output logic [63:0]                 dbg_rdata,

    // ---- debug: direct datamover_cmd bypass ----
    input  logic        dbg_cmd_start,
    input  logic [31:0] dbg_cmd_ddr_addr,
    input  logic [4:0]  dbg_cmd_length,
    output logic [1:0]  dbg_cmd_state,
    output logic        dbg_cmd_done,
    output logic        dbg_cmd_err,
    // ---- debug: store path visibility (mirrors the load path debug) ----
    output logic [1:0]  dbg_store_cmd_state,
    output logic        dbg_store_cmd_done,
    output logic        dbg_store_cmd_err,
    output logic        dbg_store_adapter_done,

    // ---- MM2S (load) DataMover command / status ----
    output logic [71:0] mm2s_cmd_tdata,
    output logic        mm2s_cmd_tvalid,
    input  logic        mm2s_cmd_tready,
    input  logic [7:0]  mm2s_sts_tdata,
    input  logic        mm2s_sts_tvalid,
    output logic        mm2s_sts_tready,
    // ---- MM2S (load) data stream in ----
    input  logic [63:0] mm2s_tdata,
    input  logic        mm2s_tvalid,
    input  logic        mm2s_tlast,
    output logic        mm2s_tready,

    // ---- S2MM (store) DataMover command / status ----
    output logic [71:0] s2mm_cmd_tdata,
    output logic        s2mm_cmd_tvalid,
    input  logic        s2mm_cmd_tready,
    input  logic [7:0]  s2mm_sts_tdata,
    input  logic        s2mm_sts_tvalid,
    output logic        s2mm_sts_tready,
    // ---- S2MM (store) data stream out (256-bit, to width converter) ----
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
    logic l_start_iu, s_start, l_dest;
    logic [31:0] l_ddr_addr_iu, s_ddr_addr;
    logic [13:0] l_bram_addr, s_bram_addr;
    logic [4:0]  l_length_iu, s_length;
    logic l_done, s_done;
    logic act_start; logic [13:0] act_c_addr; logic [4:0] act_length; logic [2:0] act_mode; logic act_done;
    logic qz_start; logic [13:0] qz_c_addr, qz_a_addr; logic [4:0] qz_length; logic qz_done;

    // units not yet built: tie done low
    assign act_done = 1'b0;
    assign qz_done  = 1'b0;

    instruction_unit #(.INSTR_ADDR_WIDTH(INSTR_ADDR_WIDTH)) iu(
        .clk(clk), .rst(rst), .run(run), .pc(pc), .instr(instr),
        .mm_start(mm_start), .mm_tiles(mm_tiles), .mm_a_addr(mm_a_addr), .mm_b_addr(mm_b_addr),
        .mm_accumulate(mm_accumulate), .mm_c_addr(mm_c_addr), .mm_done(mm_done),
        .l_start(l_start_iu), .s_start(s_start), .l_dest(l_dest),
        .l_ddr_addr(l_ddr_addr_iu), .s_ddr_addr(s_ddr_addr),
        .l_bram_addr(l_bram_addr), .s_bram_addr(s_bram_addr),
        .l_length(l_length_iu), .s_length(s_length), .l_done(l_done), .s_done(s_done),
        .act_start(act_start), .act_c_addr(act_c_addr), .act_length(act_length),
        .act_mode(act_mode), .act_done(act_done),
        .qz_start(qz_start), .qz_c_addr(qz_c_addr), .qz_a_addr(qz_a_addr),
        .qz_length(qz_length), .qz_done(qz_done),
        .program_done(program_done)
    );

    // ================= LOAD path =================
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

    logic weA, weB;
    logic [13:0] load_waddr;
    logic [63:0] load_wdata;
    bram_adapter load_adp(
        .clk(clk), .rst(rst), .start(l_start), .dest(l_dest), .bram_addr(l_bram_addr),
        .done(l_adapter_done),
        .s_tdata(mm2s_tdata), .s_tvalid(mm2s_tvalid), .s_tlast(mm2s_tlast), .s_tready(mm2s_tready),
        .weA(weA), .weB(weB), .waddr(load_waddr), .wdata(load_wdata)
    );

    // ================= STORE path =================
    logic s_cmd_done, s_cmd_err, s_adapter_done;
    assign s_done = s_cmd_done && s_adapter_done;
    assign dbg_store_cmd_done    = s_cmd_done;
    assign dbg_store_cmd_err     = s_cmd_err;
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

    // -- A_buf: written by load adapter (weA), read by gemm_sequencer --
    logic [13:0] gs_raddrA;
    logic signed [63:0] gs_rdataA;
    // mux A_buf read port: gemm_sequencer during execution, PS debug otherwise
    logic [13:0] a_raddr_mux;
    logic [63:0] a_rdata_raw;
    assign a_raddr_mux = running ? gs_raddrA : dbg_raddr;
    assign dbg_rdata   = a_rdata_raw;
    assign gs_rdataA   = a_rdata_raw;

    tile_bram #(.WIDTH(64), .DEPTH(N*N/8)) A_buf(
        .clk(clk), .we(weA), .waddr(load_waddr), .raddr(a_raddr_mux),
        .wdata(load_wdata), .rdata(a_rdata_raw)
    );

    // -- B_buf: written by load adapter (weB), read by gemm_sequencer --
    logic [13:0] gs_raddrB;
    logic signed [63:0] gs_rdataB;

    tile_bram #(.WIDTH(64), .DEPTH(N*N/8)) B_buf(
        .clk(clk), .we(weB), .waddr(load_waddr), .raddr(gs_raddrB),
        .wdata(load_wdata), .rdata(gs_rdataB)
    );

    // -- C_buf: written by gemm_sequencer, read by store_adapter --
    // C_buf is 256-bit wide (8x 32-bit accumulators per word).
    // store_adapter reads via store_raddr; gemm_sequencer writes via gs_waddrC.
    logic        gs_weC;
    logic [13:0] gs_waddrC;
    logic signed [255:0] gs_wdataC;
    logic [13:0] gs_raddrC;
    logic signed [255:0] gs_rdataC;

    // `storing` latches for the FULL STORE_C duration -- s_start is only a
    // one-cycle pulse, so keying the mux directly off it would fall back to
    // gemm_sequencer's stale address after the first cycle.
    logic storing;
    always_ff @(posedge clk) begin
        if (rst) storing <= 1'b0;
        else if (s_start) storing <= 1'b1;
        else if (s_done) storing <= 1'b0;
    end

    logic [13:0] c_raddr_mux;
    logic [255:0] c_rdata_raw;
    assign c_raddr_mux  = storing ? store_raddr : gs_raddrC;
    assign c_rdata_store = c_rdata_raw;
    assign gs_rdataC     = c_rdata_raw;

    tile_bram #(.WIDTH(256), .DEPTH(N*N/8)) C_buf(
        .clk(clk), .we(gs_weC), .waddr(gs_waddrC), .raddr(c_raddr_mux),
        .wdata(gs_wdataC), .rdata(c_rdata_raw)
    );

    // ================= gemm_sequencer =================
    gemm_sequencer #(
        .MAX_N(N), .DATA_WIDTH(8), .ACC_WIDTH(32), .ARRAY_N(8)
    ) gs(
        .clk(clk), .rst(rst), .start(mm_start),
        .tiles(mm_tiles),
        .accumulating(1'b0),           // not yet implemented
        .rdataA(gs_rdataA),
        .rdataB(gs_rdataB),
        .rdataC(256'd0),               // accumulate read not yet wired
        .addrAoffset(mm_a_addr),
        .addrBoffset(mm_b_addr),
        .addrCoffset(mm_c_addr),
        .raddrA(gs_raddrA),
        .raddrB(gs_raddrB),
        .waddrC(gs_waddrC),
        .raddrC(gs_raddrC),            // unused for now
        .weC(gs_weC),
        .done(mm_done),
        .wdataC(gs_wdataC)
    );

endmodule