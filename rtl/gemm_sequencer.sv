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


module gemm_sequencer #(parameter MAX_N = 128, DATA_WIDTH = 8, ACC_WIDTH=32, ARRAY_N=8)(
input logic clk, rst, start,
input logic [4:0] tiles,
input logic signed [63:0] rdataA, rdataB,
input logic [13:0] addrAoffset,
input logic [13:0] addrCoffset,
output logic [13:0] raddrA,
output logic [10:0] raddrB,
output logic [13:0] waddrC,
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
    logic signed [ACC_WIDTH -1: 0] results1 [0:ARRAY_N-1][0:ARRAY_N-1];
    logic signed [ACC_WIDTH -1: 0] results2 [0:ARRAY_N-1][0:ARRAY_N-1];
    logic [2*ARRAY_N-2:0] pingpongrst, pingpong, enable;
    logic load_complete;
    logic arrayrst;
    logic [7:0] newtilecycle;
    logic [4:0] i, j, k, i_next, j_next, k_next, i_prev, j_prev;
    logic j_parity, j_parity_prev;
    logic drain_active, drained_any, drain_consumed;
    logic [2:0] drain_row; 
    logic loaded_pulse;
    logic load_complete_d;
    always_ff @(posedge clk) begin
        if (rst || start) begin
            if (start) begin
                running<=1;
                stagger<=0;
            end
            //cycle_count <= 0;
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
            drained_any<=0;
            drain_row <=0;
            load_complete_d<=0;
            drain_consumed <=0;
            drain_counter<=0;
            for (int row=0; row<ARRAY_N; row++) begin
                for (int col=0; col<ARRAY_N; col++) begin
                    a_full [row][col]<=0;
                    b_full [row][col]<=0;
                end
            end
            //some a_full and b_full are zeroed out
        end else if (running) begin
            if (!load_complete) begin
                stagger<=stagger_next;
                i<=i_next;
                j<=j_next;
                k<=k_next;
            end else if (load_complete) begin
                if (drain_counter==tiles*tiles)
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
            if (newtilecycle == ARRAY_N-1 && drained_any) begin
                drain_active<=1;
                drain_row<=0;
            end else if (drain_active) begin
                if (drain_row == ARRAY_N -1)begin
                    drain_active<=0;
                    drain_consumed<=1;
                end else 
                    drain_row<=drain_row+1;
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
        if (done)
            running<=0;
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
            if (k==tiles-1) begin
                j_next = (j==tiles-1)? 0: j+1;
                if (j==tiles-1) i_next = i+1;
            end
            k_next = (k==tiles-1)? 0: k+1;
        end 
    end
    assign raddrA = (start || rst)? addrAoffset: addrAoffset + i_next*tiles*8 + k_next*8 + stagger_next; 
    assign raddrB = (start || rst)? 0: k_next*8 + j_next*8*tiles + stagger_next;
    assign load_complete = stagger==3'b111 && i==tiles-1 && j==tiles-1 && k==tiles-1;
    //assign pingpong[stagger] = (k%2)? 1:0 ;
    
    genvar d;
    generate 
        for (d=0; d<2*ARRAY_N-1; d++) begin: enable_gen
            assign enable[d] = (running) && (end_count<=d+1);
            assign pingpong[d] = (newtilecycle>=d)? j_parity:j_parity_prev;
            assign pingpongrst[d] = drain_active && (d==(drain_row)) || (!drain_active && drain_row==ARRAY_N-1 && d>=ARRAY_N-1 && drain_consumed);
            // && (d<=(drain_row-1)+ARRAY_N-1)
        end
    endgenerate
    
    always_comb begin
        wdataC = 0;
        for (int c=0; c<ARRAY_N; c++) begin
            wdataC[c*ACC_WIDTH +: ACC_WIDTH] = 
                pingpong[drain_row]? results1[drain_row][c] : results2[drain_row][c];
        end
    end
    
    assign weC = drain_active;
    assign waddrC = addrCoffset + (i_prev*tiles + j_prev)*ARRAY_N + drain_row;
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
endmodule
