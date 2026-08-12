`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/10/2026 10:27:12 AM
// Design Name: 
// Module Name: store_adapter
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



// Reads C_buf (256-bit) and streams it to the S2MM width converter.
// AXI-Stream MASTER. C_buf read is registered (1-cycle latency).
//
// A 2-entry FIFO sits between the registered BRAM read and the output stream.
// Depth 2 is required to cover the 1-cycle read latency plus one word in
// flight, so a downstream stall never drops or duplicates a word. Verified
// against a cycle-accurate model (clean + stall patterns, in-order, no loss).
module store_adapter(
    input  logic clk, rst, start,
    input  logic [13:0] bram_addr,
    input  logic [4:0]  length,
    output logic done,
    // m_axis_s2mm (master)
    output logic [255:0] m_tdata,
    output logic m_tvalid, m_tlast,
    input  logic m_tready,
    // C_buf read port (registered, 1-cycle latency)
    output logic [13:0] raddr,
    input  logic [255:0] rdata
);
    typedef enum logic [1:0] {IDLE, RUN} state_t;
    state_t state;

    logic [17:0] target;    // total 256-bit words
    logic [17:0] sent;      // words accepted
    logic [17:0] fetched;   // read-addresses issued
    logic        inflight;  // a read was issued last cycle; data arrives this cycle

    // 2-entry FIFO
    logic [255:0] fifo0, fifo1;
    logic [1:0]   fcount;   // 0,1,2

    wire accept = m_tvalid && m_tready;

    assign raddr    = bram_addr + fetched;
    assign m_tdata  = fifo0;
    assign m_tvalid = (fcount != 0);
    assign m_tlast  = m_tvalid && (sent == target - 1);

    // may we issue a read this cycle? need FIFO room (count < 2) and words left.
    wire can_fetch = (fetched < target) && (fcount < 2);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            target <= 0; sent <= 0; fetched <= 0; inflight <= 0;
            fifo0 <= 0; fifo1 <= 0; fcount <= 0; done <= 0;
        end else begin
            // NOTE: done is a LEVEL held until the next `start`, same
            // discipline as datamover_cmd -- do NOT clear it every cycle
            // unconditionally, or it becomes a one-cycle pulse that the
            // s_done = s_cmd_done && s_adapter_done AND-gate can miss
            // entirely (exactly the bug this fixes).
            case (state)
                IDLE: begin
                    sent <= 0; fetched <= 0; inflight <= 0; fcount <= 0;
                    if (start) begin
                        target   <= length * length * 8;
                        state    <= RUN;
                        done     <= 0;   // clear only on a NEW transfer
                        // issue read #0 immediately (fetched 0 -> raddr=bram_addr)
                        fetched  <= 1;
                        inflight <= 1;
                    end
                end

                RUN: begin
                    // ---- compute FIFO next-state ----
                    // pop on accept, push on arriving read data.
                    // Handle the four combinations explicitly to keep fifo0
                    // always the head.
                    logic arriving;
                    logic [1:0] nfcount;
                    logic [255:0] nf0, nf1;

                    arriving = inflight;
                    nf0 = fifo0; nf1 = fifo1; nfcount = fcount;

                    // pop
                    if (accept) begin
                        nf0 = fifo1;          // shift down
                        nfcount = fcount - 1;
                        sent <= sent + 1;
                        if (sent == target - 1) begin
                            done  <= 1;        // STAYS high until next start
                            state <= IDLE;
                        end
                    end

                    // push arriving word into the tail
                    if (arriving) begin
                        if (nfcount == 0) begin
                            nf0 = rdata;
                        end else begin
                            nf1 = rdata;
                        end
                        nfcount = nfcount + 1;
                    end

                    fifo0 <= nf0; fifo1 <= nf1; fcount <= nfcount;

                    // ---- issue next read ----
                    // room after this cycle: use the post-update count (nfcount)
                    if ((fetched < target) && (nfcount < 2)) begin
                        fetched  <= fetched + 1;
                        inflight <= 1;
                    end else begin
                        inflight <= 0;
                    end
                end
            endcase
        end
    end
endmodule
