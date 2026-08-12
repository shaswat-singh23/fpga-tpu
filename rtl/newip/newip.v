
`timescale 1 ns / 1 ps

	module newip #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line


		// Parameters of Axi Slave Bus Interface S00_AXI
		parameter integer C_S00_AXI_DATA_WIDTH	= 32,
		parameter integer C_S00_AXI_ADDR_WIDTH	= 6
	)
	(
		// Users to add ports here

		// User ports ends
		// Do not modify the ports beyond this line


		// Ports of Axi Slave Bus Interface S00_AXI
		input wire  s00_axi_aclk,
		input wire  s00_axi_aresetn,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
		input wire [2 : 0] s00_axi_awprot,
		input wire  s00_axi_awvalid,
		output wire  s00_axi_awready,
		input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
		input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
		input wire  s00_axi_wvalid,
		output wire  s00_axi_wready,
		output wire [1 : 0] s00_axi_bresp,
		output wire  s00_axi_bvalid,
		input wire  s00_axi_bready,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
		input wire [2 : 0] s00_axi_arprot,
		input wire  s00_axi_arvalid,
		output wire  s00_axi_arready,
		output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
		output wire [1 : 0] s00_axi_rresp,
		output wire  s00_axi_rvalid,
		input wire  s00_axi_rready,
		output wire        run_out,
        input  wire        program_done_in,
        output wire [13:0] dbg_raddr_out,
        input  wire [63:0] dbg_rdata_in,
        output wire        instr_we_pulse,
        output wire [6:0]  instr_waddr_out,
        output wire [63:0] instr_wdata_out,
        output wire [6:0]  instr_raddr_out,
        input  wire [63:0] instr_rdata_in
        ,
    output wire        dbg_cmd_start_out,
    output wire [31:0] dbg_cmd_ddr_addr_out,
    output wire [4:0]  dbg_cmd_length_out,
    input  wire [1:0]  dbg_cmd_state_in,
    input  wire        dbg_cmd_done_in,
    input  wire        dbg_cmd_err_in,
    input wire [1:0] dbg_store_cmd_state_in, input wire dbg_store_cmd_done_in, input wire dbg_store_cmd_err_in, input wire dbg_store_adapter_done_in
	);
// Instantiation of Axi Bus Interface S00_AXI
	newip_slave_lite_v1_0_S00_AXI # ( 
		.C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
	) newip_slave_lite_v1_0_S00_AXI_inst (
		.S_AXI_ACLK(s00_axi_aclk),
		.S_AXI_ARESETN(s00_axi_aresetn),
		.S_AXI_AWADDR(s00_axi_awaddr),
		.S_AXI_AWPROT(s00_axi_awprot),
		.S_AXI_AWVALID(s00_axi_awvalid),
		.S_AXI_AWREADY(s00_axi_awready),
		.S_AXI_WDATA(s00_axi_wdata),
		.S_AXI_WSTRB(s00_axi_wstrb),
		.S_AXI_WVALID(s00_axi_wvalid),
		.S_AXI_WREADY(s00_axi_wready),
		.S_AXI_BRESP(s00_axi_bresp),
		.S_AXI_BVALID(s00_axi_bvalid),
		.S_AXI_BREADY(s00_axi_bready),
		.S_AXI_ARADDR(s00_axi_araddr),
		.S_AXI_ARPROT(s00_axi_arprot),
		.S_AXI_ARVALID(s00_axi_arvalid),
		.S_AXI_ARREADY(s00_axi_arready),
		.S_AXI_RDATA(s00_axi_rdata),
		.S_AXI_RRESP(s00_axi_rresp),
		.S_AXI_RVALID(s00_axi_rvalid),
		.S_AXI_RREADY(s00_axi_rready),
		.run_out(run_out),
		.program_done_in(program_done_in),
		.dbg_raddr_out(dbg_raddr_out),
		.dbg_rdata_in(dbg_rdata_in),
		.instr_we_pulse(instr_we_pulse),
		.instr_waddr_out(instr_waddr_out),
		.instr_wdata_out(instr_wdata_out),
		.instr_raddr_out(instr_raddr_out),
		.instr_rdata_in(instr_rdata_in),
		.dbg_cmd_start_out(dbg_cmd_start_out),
        .dbg_cmd_ddr_addr_out(dbg_cmd_ddr_addr_out),
        .dbg_cmd_length_out(dbg_cmd_length_out),
        .dbg_cmd_state_in(dbg_cmd_state_in),
        .dbg_cmd_done_in(dbg_cmd_done_in),
        .dbg_cmd_err_in(dbg_cmd_err_in),
        .dbg_store_cmd_state_in(dbg_store_cmd_state_in), 
        .dbg_store_cmd_done_in(dbg_store_cmd_done_in), 
        .dbg_store_cmd_err_in(dbg_store_cmd_err_in),
        .dbg_store_adapter_done_in(dbg_store_adapter_done_in)
	);

	// Add user logic here

	// User logic ends

	endmodule
