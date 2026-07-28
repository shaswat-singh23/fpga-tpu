#include "xaxidma.h"
#include "xparameters.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include <xaxidma_hw.h>
#include <xstatus.h>
#include<unistd.h>

#define TRANSFER_LEN 64

u8 tx_buf_a[64] __attribute__((aligned(64)));
u8 tx_buf_b[64] __attribute__((aligned(64)));
u32 rx_buf_one[32] __attribute__((aligned(64)));
u32 rx_buf_two[32] __attribute__((aligned(64)));
#define N 16

u8  A_full[N*N] __attribute__((aligned(64)));   // 256 bytes
u8  B_full[N*N] __attribute__((aligned(64)));   // 256 bytes
u32 C_full[N*N] __attribute__((aligned(64)));   // 1024 bytes
u32 C_golden[N*N] __attribute__((aligned(64))); // 1024 bytes, for the CPU-side check

XAxiDma AxiDma_A;
XAxiDma AxiDma_B;
XAxiDma AxiDma_R1;
XAxiDma AxiDma_R2;

int init_dmas() {
    XAxiDma_Config *CfgPtr_A, *CfgPtr_B, *CfgPtr_R1, *CfgPtr_R2;
    int Status;

    CfgPtr_A  = XAxiDma_LookupConfig(XPAR_XAXIDMA_0_BASEADDR);
    CfgPtr_B  = XAxiDma_LookupConfig(XPAR_XAXIDMA_1_BASEADDR);
    CfgPtr_R1 = XAxiDma_LookupConfig(XPAR_XAXIDMA_2_BASEADDR);
    CfgPtr_R2 = XAxiDma_LookupConfig(XPAR_XAXIDMA_3_BASEADDR);

    if (!CfgPtr_A)  { xil_printf("No config found for DMA0\r\n"); return XST_FAILURE; }
    if (!CfgPtr_B)  { xil_printf("No config found for DMA1\r\n"); return XST_FAILURE; }
    if (!CfgPtr_R1) { xil_printf("No config found for DMA2\r\n"); return XST_FAILURE; }
    if (!CfgPtr_R2) { xil_printf("No config found for DMA3\r\n"); return XST_FAILURE; }

    Status = XAxiDma_CfgInitialize(&AxiDma_A, CfgPtr_A);
    if (Status != XST_SUCCESS) { xil_printf("DMA_A init failed\r\n"); return XST_FAILURE; }
    Status = XAxiDma_CfgInitialize(&AxiDma_B, CfgPtr_B);
    if (Status != XST_SUCCESS) { xil_printf("DMA_B init failed\r\n"); return XST_FAILURE; }
    Status = XAxiDma_CfgInitialize(&AxiDma_R1, CfgPtr_R1);
    if (Status != XST_SUCCESS) { xil_printf("DMA_R1 init failed\r\n"); return XST_FAILURE; }
    Status = XAxiDma_CfgInitialize(&AxiDma_R2, CfgPtr_R2);
    if (Status != XST_SUCCESS) { xil_printf("DMA_R2 init failed\r\n"); return XST_FAILURE; }

    if (XAxiDma_HasSg(&AxiDma_A))  { xil_printf("DMA_A has SG mode on, expected simple mode\r\n"); return XST_FAILURE; }
    if (XAxiDma_HasSg(&AxiDma_B))  { xil_printf("DMA_B has SG mode on, expected simple mode\r\n"); return XST_FAILURE; }
    if (XAxiDma_HasSg(&AxiDma_R1)) { xil_printf("DMA_R1 has SG mode on, expected simple mode\r\n"); return XST_FAILURE; }
    if (XAxiDma_HasSg(&AxiDma_R2)) { xil_printf("DMA_R2 has SG mode on, expected simple mode\r\n"); return XST_FAILURE; }

    XAxiDma_IntrDisable(&AxiDma_A,  XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&AxiDma_B,  XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&AxiDma_R1, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrDisable(&AxiDma_R2, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    return XST_SUCCESS;
}

void extract_tile(u8* src, u8* tile, int row0, int col0) {
    for (int i=0; i<8; i++){
        for (int j=0; j<8; j++){
            tile[i*8 + j] = src[(row0 +i) * N + col0 + j];
        }
    }
}

void accumulate_tile(u32* C, int row0, int col0) {
    for (int k = 0; k < 16; k++) {
        C[(row0+k/2) * N + col0 + 4*(k%2)] += rx_buf_one[2*k];
        C[(row0+k/2) * N + col0 + 4*(k%2) + 1] += rx_buf_one[2*k+1];
        C[(row0+k/2) * N + col0 + 4*(k%2) + 2] += rx_buf_two[2*k];
        C[(row0+k/2) * N + col0 + 4*(k%2) + 3] += rx_buf_two[2*k+1];
    }
}

void run_one_tile() {
    int Status;
    Xil_DCacheFlushRange((UINTPTR)tx_buf_a, TRANSFER_LEN);
    Xil_DCacheFlushRange((UINTPTR)tx_buf_b, TRANSFER_LEN);
    Xil_DCacheFlushRange((UINTPTR)rx_buf_one, 128);
    Xil_DCacheFlushRange((UINTPTR)rx_buf_two, 128);

    Status = XAxiDma_SimpleTransfer(&AxiDma_A, (UINTPTR)tx_buf_a, TRANSFER_LEN, XAXIDMA_DMA_TO_DEVICE);
    if (Status != XST_SUCCESS) xil_printf("tile: DMA_A submit failed\r\n");
    Status = XAxiDma_SimpleTransfer(&AxiDma_B, (UINTPTR)tx_buf_b, TRANSFER_LEN, XAXIDMA_DMA_TO_DEVICE);
    if (Status != XST_SUCCESS) xil_printf("tile: DMA_B submit failed\r\n");

    while (XAxiDma_Busy(&AxiDma_A, XAXIDMA_DMA_TO_DEVICE) || XAxiDma_Busy(&AxiDma_B, XAXIDMA_DMA_TO_DEVICE)){}

    Status = XAxiDma_SimpleTransfer(&AxiDma_R1, (UINTPTR)rx_buf_one, 128, XAXIDMA_DEVICE_TO_DMA);
    if (Status != XST_SUCCESS) xil_printf("tile: DMA_R1 submit failed\r\n");
    Status = XAxiDma_SimpleTransfer(&AxiDma_R2, (UINTPTR)rx_buf_two, 128, XAXIDMA_DEVICE_TO_DMA);
    if (Status != XST_SUCCESS) xil_printf("tile: DMA_R2 submit failed\r\n");

    while (XAxiDma_Busy(&AxiDma_R1, XAXIDMA_DEVICE_TO_DMA) || XAxiDma_Busy(&AxiDma_R2, XAXIDMA_DEVICE_TO_DMA)){}

    Xil_DCacheInvalidateRange((UINTPTR)rx_buf_one, 128);
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf_two, 128);
}

void matmul_tiled(u8* A, u8* B, u32* C) {
    int t = 8;
    memset(C, 0, N*N*sizeof(u32));
    for (int i = 0; i < N; i += t) {
        for (int j = 0; j < N; j += t) {
            for (int k = 0; k < N; k += t) {
                extract_tile(A, tx_buf_a, i, k);   // writes into global tx_buf_a
                extract_tile(B, tx_buf_b, k, j);   // writes into global tx_buf_b

                run_one_tile();  // no params needed now — uses tx_buf_a/tx_buf_b/rx_buf_one/rx_buf_two globals directly

                accumulate_tile(C, i, j);  // reads from rx_buf_one/rx_buf_two globals, writes into C
            }
        }
    }
}



int main(){
    if (init_dmas() != XST_SUCCESS) return XST_FAILURE;

    for (int i = 0; i < N*N; i++) A_full[i] = (i % 250) + 1;
    for (int i = 0; i < N*N; i++) B_full[i] = ((i % 250) + 1) * 3 % 251;
    
    memset(C_golden, 0, sizeof(C_golden));
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
            for (int k = 0; k < N; k++)
                C_golden[i*N+j] += (u32)A_full[i*N+k] * (u32)B_full[k*N+j];


    matmul_tiled(A_full, B_full, C_full);

    int fail = 0;
    for (int i = 0; i < N*N; i++) {
        if (C_full[i] != C_golden[i]) {
            xil_printf("FAIL C[%d][%d]: got %u expected %u\r\n", i/N, i%N, C_full[i], C_golden[i]);
            fail++;
        }
    }
    if (fail == 0) xil_printf("PASS: all %d elements match golden model\r\n", N*N);
    else xil_printf("FAIL: %d mismatches out of %d\r\n", fail, N*N);
    
    return XST_SUCCESS;
}