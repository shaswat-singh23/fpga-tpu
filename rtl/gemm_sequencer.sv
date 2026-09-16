`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/31/2026 06:14:51 PM
// Design Name: 
// Module Name: gemm_sequencer
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

/*
module gemm_sequencer #(parameter MAX_N = 128, DATA_WIDTH = 8, ACC_WIDTH=32, ARRAY_N=8)(
input logic clk, rst, start,
input logic [4:0] tiles,
input logic accumulating,
input logic signed [63:0] rdataA, rdataB,
input logic signed [255:0] rdataC,
input logic [13:0] addrAoffset,
input logic [13:0] addrBoffset,
input logic [13:0] addrCoffset,
output logic [13:0] raddrA,
output logic [13:0] raddrB,
output logic [13:0] waddrC,
output logic [13:0] raddrC,
output logic weC, done,
output logic signed [255:0] wdataC
    );
    logic [3:0] end_count;
    logic [2:0] stagger, stagger_next;
    logic running;
    logic [$clog2(MAX_N*MAX_N)-1:0] drain_counter;
    logic signed [DATA_WIDTH-1 : 0] a_full [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [DATA_WIDTH-1 : 0] b_full [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [DATA_WIDTH -1: 0] a_mat [0:ARRAY_N-1];
    logic signed [DATA_WIDTH -1: 0] b_mat [0:ARRAY_N-1];
    logic signed [ACC_WIDTH - 1:0] cprev [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [ACC_WIDTH -1: 0] results1 [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [ACC_WIDTH -1: 0] results2 [0:ARRAY_N-1][0:ARRAY_N-1];
    logic [2*ARRAY_N-2:0] pingpongrst, pingpong, enable;
    logic load_complete;
    logic arrayrst;
    logic [7:0] newtilecycle;
    logic [4:0] i, j, k, i_next, j_next, k_next, i_prev, j_prev;
    logic j_parity, j_parity_prev;
    logic drain_active, drained_any, drain_consumed, read_active;
    logic [2:0] drain_col;
    logic [2:0] readfetch; 
    logic loaded_pulse;
    logic load_complete_d;
    logic acclatch;
    logic [13:0] addrAl;
    logic [13:0] addrBl;
    logic [13:0] addrCl;
    logic [4:0] tilel;
    logic [9:0] numtiles;
    logic [7:0] tiletoelem;
    always_ff @(posedge clk) begin
        if (rst || start) begin
            if (start) begin
                addrAl <= addrAoffset;
                addrBl <= addrBoffset;
                addrCl <= addrCoffset;
                tilel <= tiles;
                numtiles <= tiles*tiles;
                tiletoelem <= tiles <<3;
                running<=1;
                stagger<=0;
                acclatch <= accumulating;
            end else begin
            running<=0;
            acclatch<=0;
            addrAl <= 0;
            addrBl <= 0;
            addrCl <= 0;
            tilel<=0;
            numtiles <= 0;
            tiletoelem <= 0;
            end
            
            i<=0;
            j<=0;
            k<=0;
            i_prev<=0;
            j_prev<=0;
            end_count<=0;
            done <= 0;
            newtilecycle<=0;
            j_parity<=0;
            j_parity_prev<=0;
            drain_active<=0;
            read_active <=0;
            drained_any<=0;
            drain_col <=0;
            readfetch <= 0;
            load_complete_d<=0;
            drain_consumed <=0;
            drain_counter<=0;
            
            for (int row=0; row<ARRAY_N; row++) begin
                for (int col=0; col<ARRAY_N; col++) begin
                    a_full [row][col]<=0;
                    b_full [row][col]<=0;
                end
            end
            
        end else if (running) begin
            if (!load_complete) begin
                stagger<=stagger_next;
                i<=i_next;
                j<=j_next;
                k<=k_next;
            end else if (load_complete) begin
                if (drain_counter==numtiles)
                    done <=1;
                    
                if (end_count!=4'hF) begin
                    end_count <= end_count+1;
                end
                
            end
            
            load_complete_d <= load_complete;
            
            if ((j_next != j && !load_complete) || loaded_pulse) begin
                j_prev <=j;
                i_prev<=i;
                newtilecycle<=0;
                j_parity_prev <= j_parity;
                j_parity <= ~j_parity;
                drained_any<=1;
            end else begin
                newtilecycle<= newtilecycle+1;
            end
            if (drain_consumed)begin
                drain_consumed<=0;
                drain_counter<=drain_counter+1;
            end
            
            if (newtilecycle == ARRAY_N-2 && drained_any) begin
                readfetch <= 0;
                read_active <= 1;
            end else if (read_active) begin
                if (readfetch == ARRAY_N -1) begin
                    read_active <=0;
                end else
                    readfetch <= readfetch+1;
            end
            
            if (newtilecycle == ARRAY_N-1 && drained_any) begin
                drain_active<=1;
                drain_col<=0;
            end else if (drain_active) begin
                if (drain_col == ARRAY_N -1)begin
                    drain_active<=0;
                    drain_consumed<=1;
                end else 
                    drain_col<=drain_col+1;
            end                
                
            a_full[stagger][7] <= rdataA[63:56];
            a_full[stagger][6] <= rdataA[55:48];
            a_full[stagger][5] <= rdataA[47:40];
            a_full[stagger][4] <= rdataA[39:32];
            a_full[stagger][3] <= rdataA[31:24];
            a_full[stagger][2] <= rdataA[23:16];
            a_full[stagger][1] <= rdataA[15: 8];
            a_full[stagger][0] <= rdataA[ 7: 0];
            b_full[7][stagger] <= rdataB[63:56];
            b_full[6][stagger] <= rdataB[55:48];
            b_full[5][stagger] <= rdataB[47:40];
            b_full[4][stagger] <= rdataB[39:32];
            b_full[3][stagger] <= rdataB[31:24];
            b_full[2][stagger] <= rdataB[23:16];
            b_full[1][stagger] <= rdataB[15: 8];
            b_full[0][stagger] <= rdataB[ 7: 0];
            
        end
        if (done && !(start||rst)) begin
            running<=0;
            acclatch<=0;
        end

    end 

    always_comb begin
        for (int ia=0; ia<ARRAY_N; ia++) begin
            if (load_complete_d) a_mat[ia] =  (8+newtilecycle<=7+ia)? a_full[ia][ 8+newtilecycle-ia ]:0;
            else a_mat[ia] = (ia==stagger)? rdataA[7:0] : a_full[ia][3'(stagger-ia)];
        end
        for (int jb=0; jb<ARRAY_N; jb++) begin
            if (load_complete_d) b_mat[jb] =  (8+newtilecycle<=7+jb)? b_full[8+newtilecycle-jb][jb]: 0;
            else b_mat[jb] = (jb==stagger)? rdataB[7:0] : b_full[3'(stagger-jb)][jb];
        end
    end
    
    always_comb begin
        stagger_next = (load_complete)? stagger: stagger+1;
        i_next = i; j_next = j; k_next = k;
        if (running && stagger == 3'b111 && !load_complete) begin
            if (k==tilel-1) begin
                j_next = (j==tilel-1)? 0: j+1;
                if (j==tilel-1) i_next = i+1;
            end
            k_next = (k==tilel-1)? 0: k+1;
        end 
    end
    
    logic start_d;
    always_ff @(posedge clk) start_d <= start & ~rst;
    //assign raddrA = (start || rst)? addrAl: addrAl + i_next*tiletoelem + k_next*8 + stagger_next; 
    //assign raddrB = (start || rst)? addrBl: addrBl + k_next*8 + j_next*tiletoelem + stagger_next;
    assign load_complete = stagger==3'b111 && i==tilel-1 && j==tilel-1 && k==tilel-1;
    
    genvar d;
    generate 
        for (d=0; d<2*ARRAY_N-1; d++) begin: enable_gen
            assign enable[d] = (running) && (end_count<=d+1);
            assign pingpong[d] = (newtilecycle>=d)? j_parity:j_parity_prev;
            assign pingpongrst[d] = drain_active && (d==(drain_col)) || (!drain_active && drain_col==ARRAY_N-1 && d>=ARRAY_N-1 && drain_consumed);
        end
    endgenerate
    
    always_comb begin
        wdataC = 0;
        for (int c=0; c<ARRAY_N; c++) begin
            if (acclatch) begin
            wdataC[c*ACC_WIDTH +: ACC_WIDTH] =
                pingpong[drain_col]? (results1[c][drain_col] + (rdataC[c*ACC_WIDTH +: ACC_WIDTH])) : (results2[c][drain_col] + (rdataC[c*ACC_WIDTH +: ACC_WIDTH]));
            end else
            wdataC[c*ACC_WIDTH +: ACC_WIDTH] = 
                pingpong[drain_col]? results1[c][drain_col] : results2[c][drain_col];
        end
    end
    
    assign weC = drain_active;
    assign raddrC = (addrCl + (j_prev*tilel + i_prev)*ARRAY_N + readfetch);
    assign waddrC = addrCl + (j_prev*tilel + i_prev)*ARRAY_N + drain_col;
    assign loaded_pulse = load_complete && !load_complete_d;
    assign arrayrst = rst || start;
    systolic_array #(.N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) array(
    .clk(clk),
    .rst(arrayrst),
    .pingpongrst(pingpongrst),
    .pingpong(pingpong),
    .enable(enable),
    .a_mat(a_mat),
    .b_mat(b_mat),
    .results1(results1),
    .results2(results2)
    );
endmodule*/


// gemm_sequencer_pipelined.sv
// Same module name / same ports as the verified gemm_sequencer, so testbenches
// and accelerator_top need no changes. Swap this file for the original in the
// simulation source set; do not overwrite the original until the sweep passes.
//
// Changes vs. the verified version (everything else is verbatim):
//   1. raddrA / raddrB are now pure registered counters (no multiplies, no
//      next-state logic, no mux in front of the BRAM address ports).
//   2. FSM runs off start_d (start delayed one cycle) so the address counters
//      get a one-cycle head start; data timing seen by the FSM is unchanged.
//      done still drops on the *start* edge, so external handshake is unchanged.
//   3. waddrC / raddrC use a registered tile base (cbase) instead of
//      (j_prev*tilel + i_prev)*8 -- one 14-bit add each.
//   4. a_full / b_full capture is gated with !load_complete_d (the original
//      relied on the frozen last address re-reading the same word).
//   5. Latched offsets widened to 14 bits (previous version truncated bit 13).

module gemm_sequencer #(parameter MAX_N = 128, DATA_WIDTH = 8, ACC_WIDTH=32, ARRAY_N=8)(
input logic clk, rst, start,
input logic [4:0] tiles,
input logic accumulating,
input logic signed [63:0] rdataA, rdataB,
input logic signed [255:0] rdataC,
input logic [13:0] addrAoffset,
input logic [13:0] addrBoffset,
input logic [13:0] addrCoffset,
output logic [13:0] raddrA,
output logic [13:0] raddrB,
output logic [13:0] waddrC,
output logic [13:0] raddrC,
output logic weC, done,
output logic signed [255:0] wdataC
    );
    logic [3:0] end_count;
    logic [2:0] stagger, stagger_next;
    logic running;
    logic [$clog2(MAX_N*MAX_N)-1:0] drain_counter;
    logic signed [DATA_WIDTH-1 : 0] a_full [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [DATA_WIDTH-1 : 0] b_full [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [DATA_WIDTH -1: 0] a_mat [0:ARRAY_N-1];
    logic signed [DATA_WIDTH -1: 0] b_mat [0:ARRAY_N-1];
    logic signed [ACC_WIDTH - 1:0] cprev [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [ACC_WIDTH -1: 0] results1 [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [ACC_WIDTH -1: 0] results2 [0:ARRAY_N-1][0:ARRAY_N-1];
    logic [2*ARRAY_N-2:0] pingpongrst, pingpong, enable;
    logic load_complete;
    logic arrayrst;
    logic [7:0] newtilecycle;
    logic [4:0] i, j, k, i_next, j_next, k_next, i_prev, j_prev;
    logic j_parity, j_parity_prev;
    logic drain_active, drained_any, drain_consumed, read_active;
    logic [2:0] drain_col;
    logic [2:0] readfetch;
    logic loaded_pulse;
    logic load_complete_d;
    logic acclatch;

    // ---- latched per-GEMM constants (captured on start, one cycle before the FSM resets) ----
    logic        start_d;
    logic [13:0] addrBl;
    logic [13:0] addrCl;
    logic [4:0]  tilel;
    logic [9:0]  numtiles;
    logic [7:0]  tiletoelem;   // tiles*8
    logic [7:0]  t8_m1;        // tiles*8 - 1
    logic [12:0] nt8_m1;       // tiles*tiles*8 - 1

    // ---- registered address counters ----
    logic [13:0] raddrA_q, rowbaseA;
    logic [7:0]  posA;         // 0 .. tiles*8-1
    logic [4:0]  repA;         // 0 .. tiles-1   (row-block is re-read once per j)
    logic [13:0] raddrB_q;
    logic [12:0] posB;         // 0 .. tiles*tiles*8-1
    logic        addr_run;

    // ---- registered C tile base ----
    logic [13:0] cbase, crow;

    always_ff @(posedge clk) start_d <= start & ~rst;

    // Constants + counter load. Fires on the real start so everything is valid
    // during the start_d cycle, when the FSM resets and the BRAMs see address 0.
    always_ff @(posedge clk) begin
        if (rst) begin
            addrBl <= 0; addrCl <= 0; tilel <= 0; numtiles <= 0; tiletoelem <= 0;
            t8_m1 <= 0; nt8_m1 <= 0;
            acclatch <= 0;
            raddrA_q <= 0; rowbaseA <= 0; posA <= 0; repA <= 0;
            raddrB_q <= 0; posB <= 0;
        end else if (start) begin
            addrBl     <= addrBoffset;
            addrCl     <= addrCoffset;
            tilel      <= tiles;
            numtiles   <= tiles*tiles;
            tiletoelem <= tiles << 3;
            t8_m1      <= (tiles << 3) - 1;
            nt8_m1     <= ((tiles*tiles) << 3) - 1;
            acclatch   <= accumulating;
            raddrA_q <= addrAoffset; rowbaseA <= addrAoffset; posA <= 0; repA <= 0;
            raddrB_q <= addrBoffset; posB <= 0;
        end else begin
            if (done) acclatch <= 0;
            if (addr_run) begin
                // ---- A: walk one row-block (tiles*8 words), repeat it `tiles` times, then advance ----
                if (posA == t8_m1) begin
                    posA <= 0;
                    if (repA == tilel-1) begin
                        repA     <= 0;
                        rowbaseA <= raddrA_q + 1;
                        raddrA_q <= raddrA_q + 1;
                    end else begin
                        repA     <= repA + 1;
                        raddrA_q <= rowbaseA;
                    end
                end else begin
                    posA     <= posA + 1;
                    raddrA_q <= raddrA_q + 1;
                end
                // ---- B: contiguous sweep of tiles*tiles*8 words, restarted for each i ----
                if (posB == nt8_m1) begin
                    posB     <= 0;
                    raddrB_q <= addrBl;
                end else begin
                    posB     <= posB + 1;
                    raddrB_q <= raddrB_q + 1;
                end
            end
        end
    end

    assign addr_run = start_d || (running && !load_complete);
    assign raddrA   = raddrA_q;
    assign raddrB   = raddrB_q;

    always_ff @(posedge clk) begin
        if (rst || start_d) begin
            if (start_d) begin
                running<=1;
                stagger<=0;
            end else begin
                running<=0;
            end

            i<=0;
            j<=0;
            k<=0;
            i_prev<=0;
            j_prev<=0;
            end_count<=0;
            done <= 0;
            newtilecycle<=0;
            j_parity<=0;
            j_parity_prev<=0;
            drain_active<=0;
            read_active <=0;
            drained_any<=0;
            drain_col <=0;
            readfetch <= 0;
            load_complete_d<=0;
            drain_consumed <=0;
            drain_counter<=0;
            cbase <= 0;
            crow  <= 0;

            for (int row=0; row<ARRAY_N; row++) begin
                for (int col=0; col<ARRAY_N; col++) begin
                    a_full [row][col]<=0;
                    b_full [row][col]<=0;
                end
            end

        end else if (running) begin
            if (!load_complete) begin
                stagger<=stagger_next;
                i<=i_next;
                j<=j_next;
                k<=k_next;
            end else if (load_complete) begin
                if (drain_counter==numtiles)
                    done <=1;

                if (end_count!=4'hF) begin
                    end_count <= end_count+1;
                end

            end

            load_complete_d <= load_complete;

            if ((j_next != j && !load_complete) || loaded_pulse) begin
                j_prev <=j;
                i_prev<=i;
                newtilecycle<=0;
                j_parity_prev <= j_parity;
                j_parity <= ~j_parity;
                drained_any<=1;
                // cbase = addrCl + (j*tiles + i)*8 for the tile just finished (i, j)
                if (j == 0) begin
                    cbase <= drained_any ? crow + 8 : addrCl;
                    crow  <= drained_any ? crow + 8 : addrCl;
                end else begin
                    cbase <= cbase + tiletoelem;
                end
            end else begin
                newtilecycle<= newtilecycle+1;
            end
            if (drain_consumed)begin
                drain_consumed<=0;
                drain_counter<=drain_counter+1;
            end

            if (newtilecycle == ARRAY_N-2 && drained_any) begin
                readfetch <= 0;
                read_active <= 1;
            end else if (read_active) begin
                if (readfetch == ARRAY_N -1) begin
                    read_active <=0;
                end else
                    readfetch <= readfetch+1;
            end

            if (newtilecycle == ARRAY_N-1 && drained_any) begin
                drain_active<=1;
                drain_col<=0;
            end else if (drain_active) begin
                if (drain_col == ARRAY_N -1)begin
                    drain_active<=0;
                    drain_consumed<=1;
                end else
                    drain_col<=drain_col+1;
            end

            if (!load_complete_d) begin
                a_full[stagger][7] <= rdataA[63:56];
                a_full[stagger][6] <= rdataA[55:48];
                a_full[stagger][5] <= rdataA[47:40];
                a_full[stagger][4] <= rdataA[39:32];
                a_full[stagger][3] <= rdataA[31:24];
                a_full[stagger][2] <= rdataA[23:16];
                a_full[stagger][1] <= rdataA[15: 8];
                a_full[stagger][0] <= rdataA[ 7: 0];
                b_full[7][stagger] <= rdataB[63:56];
                b_full[6][stagger] <= rdataB[55:48];
                b_full[5][stagger] <= rdataB[47:40];
                b_full[4][stagger] <= rdataB[39:32];
                b_full[3][stagger] <= rdataB[31:24];
                b_full[2][stagger] <= rdataB[23:16];
                b_full[1][stagger] <= rdataB[15: 8];
                b_full[0][stagger] <= rdataB[ 7: 0];
            end

        end

        // done must fall on the *start* edge (as before), not one cycle later on
        // start_d, so a top-level "pulse start, wait(done)" handshake is unchanged.
        if (start && !rst) done <= 0;

        if (done && !(start_d||rst)) begin
            running<=0;
        end

    end

    always_comb begin
        for (int ia=0; ia<ARRAY_N; ia++) begin
            if (load_complete_d) a_mat[ia] = /*(!newtilecycle && ia==ARRAY_N-1)? rdataA[7:0] :*/ (8+newtilecycle<=7+ia)? a_full[ia][ 8+newtilecycle-ia ]:0;
            else a_mat[ia] = (ia==stagger)? rdataA[7:0] : a_full[ia][3'(stagger-ia)];
        end
        for (int jb=0; jb<ARRAY_N; jb++) begin
            if (load_complete_d) b_mat[jb] = /*(!newtilecycle && jb==ARRAY_N-1)? rdataB[7:0] :*/ (8+newtilecycle<=7+jb)? b_full[8+newtilecycle-jb][jb]: 0;
            else b_mat[jb] = (jb==stagger)? rdataB[7:0] : b_full[3'(stagger-jb)][jb];
        end
    end

    always_comb begin
        stagger_next = (load_complete)? stagger: stagger+1;
        i_next = i; j_next = j; k_next = k;
        if (running && stagger == 3'b111 && !load_complete) begin
            if (k==tilel-1) begin
                j_next = (j==tilel-1)? 0: j+1;
                if (j==tilel-1) i_next = i+1;
            end
            k_next = (k==tilel-1)? 0: k+1;
        end
    end
    assign load_complete = stagger==3'b111 && i==tilel-1 && j==tilel-1 && k==tilel-1;

    genvar d;
    generate
        for (d=0; d<2*ARRAY_N-1; d++) begin: enable_gen
            assign enable[d] = (running) && (end_count<=d+1);
            assign pingpong[d] = (newtilecycle>=d)? j_parity:j_parity_prev;
            assign pingpongrst[d] = drain_active && (d==(drain_col)) || (!drain_active && drain_col==ARRAY_N-1 && d>=ARRAY_N-1 && drain_consumed);
        end
    endgenerate

    always_comb begin
        wdataC = 0;
        for (int c=0; c<ARRAY_N; c++) begin
            if (acclatch) begin
            wdataC[c*ACC_WIDTH +: ACC_WIDTH] =
                pingpong[drain_col]? (results1[c][drain_col] + (rdataC[c*ACC_WIDTH +: ACC_WIDTH])) : (results2[c][drain_col] + (rdataC[c*ACC_WIDTH +: ACC_WIDTH]));
            end else
            wdataC[c*ACC_WIDTH +: ACC_WIDTH] =
                pingpong[drain_col]? results1[c][drain_col] : results2[c][drain_col];
        end
    end

    assign weC = drain_active;
    assign raddrC = cbase + readfetch;
    assign waddrC = cbase + drain_col;
    assign loaded_pulse = load_complete && !load_complete_d;
    assign arrayrst = rst || start_d;
    systolic_array #(.N(ARRAY_N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) array(
    .clk(clk),
    .rst(arrayrst),
    .pingpongrst(pingpongrst),
    .pingpong(pingpong),
    .enable(enable),
    .a_mat(a_mat),
    .b_mat(b_mat),
    .results1(results1),
    .results2(results2)
    );
endmodule