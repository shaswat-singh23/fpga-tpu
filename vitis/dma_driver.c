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

XAxiDma AxiDma_A;
XAxiDma AxiDma_B;
XAxiDma AxiDma_R1;
XAxiDma AxiDma_R2;

int main(){
    XAxiDma_Config* CfgPtr_A;
    XAxiDma_Config* CfgPtr_B;
    XAxiDma_Config* CfgPtr_R1;
    XAxiDma_Config* CfgPtr_R2;
    int Status;

    CfgPtr_A = XAxiDma_LookupConfig(XPAR_XAXIDMA_0_BASEADDR);
    CfgPtr_B = XAxiDma_LookupConfig(XPAR_XAXIDMA_1_BASEADDR);
    CfgPtr_R1 = XAxiDma_LookupConfig(XPAR_XAXIDMA_2_BASEADDR);
    CfgPtr_R2 = XAxiDma_LookupConfig(XPAR_XAXIDMA_3_BASEADDR);

    if (!CfgPtr_A){
        xil_printf("No config found for DMA0\r\n");
        return XST_FAILURE;
    }
    if (!CfgPtr_B){
        xil_printf("No config found for DMA1\r\n");
        return XST_FAILURE;
    }
    if (!CfgPtr_R1){
        xil_printf("No config found for DMA2\r\n");
        return XST_FAILURE;
    }
    if (!CfgPtr_R2){
        xil_printf("No config found for DMA3\r\n");
        return XST_FAILURE;
    }

    Status = XAxiDma_CfgInitialize(&AxiDma_A, CfgPtr_A);
    if (Status != XST_SUCCESS){
        xil_printf("DMA_A init failed\r\n");
        return XST_FAILURE;
    }
    Status = XAxiDma_CfgInitialize(&AxiDma_B, CfgPtr_B);
    if (Status != XST_SUCCESS){
        xil_printf("DMA_B init failed\r\n");
        return XST_FAILURE;
    }
    Status = XAxiDma_CfgInitialize(&AxiDma_R1, CfgPtr_R1);
    if (Status != XST_SUCCESS){
        xil_printf("DMA_R1 init failed\r\n");
        return XST_FAILURE;
    }
    Status = XAxiDma_CfgInitialize(&AxiDma_R2, CfgPtr_R2);
    if (Status != XST_SUCCESS){
        xil_printf("DMA_R2 init failed\r\n");
        return XST_FAILURE;
    }

    if (XAxiDma_HasSg(&AxiDma_A)){
        xil_printf("DMA_A has SG mode on, expected simple mode\r\n");
        return XST_FAILURE;
    }
    if (XAxiDma_HasSg(&AxiDma_B)){
        xil_printf("DMA_B has SG mode on, expected simple mode\r\n");
        return XST_FAILURE;
    }
    if (XAxiDma_HasSg(&AxiDma_R1)){
        xil_printf("DMA_R1 has SG mode on, expected simple mode\r\n");
        return XST_FAILURE;
    }
    if (XAxiDma_HasSg(&AxiDma_R2)){
        xil_printf("DMA_R2 has SG mode on, expected simple mode\r\n");
        return XST_FAILURE;
    }

    XAxiDma_IntrDisable(&AxiDma_R1, XAXIDMA_IRQ_ALL_MASK,
			    XAXIDMA_DEVICE_TO_DMA);
	XAxiDma_IntrDisable(&AxiDma_A, XAXIDMA_IRQ_ALL_MASK,
			    XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&AxiDma_R2, XAXIDMA_IRQ_ALL_MASK,
			    XAXIDMA_DEVICE_TO_DMA);
	XAxiDma_IntrDisable(&AxiDma_B, XAXIDMA_IRQ_ALL_MASK,
			    XAXIDMA_DMA_TO_DEVICE);

    for (int i=0; i<TRANSFER_LEN; i++){
        tx_buf_a[i] = i+1;
    }
    for (int i=0; i<TRANSFER_LEN; i++){
        tx_buf_b[i] = (i+1)*3;
    }

    Xil_DCacheFlushRange((UINTPTR)tx_buf_a, TRANSFER_LEN);
    Xil_DCacheFlushRange((UINTPTR)tx_buf_b, TRANSFER_LEN);
    Xil_DCacheFlushRange((UINTPTR)rx_buf_one, 128);
    Xil_DCacheFlushRange((UINTPTR)rx_buf_two, 128);

    Status = XAxiDma_SimpleTransfer(&AxiDma_A, (UINTPTR)tx_buf_a, TRANSFER_LEN, XAXIDMA_DMA_TO_DEVICE);
    if (Status!=XST_SUCCESS){
        xil_printf("DMA_A transfer submit failed");
        return XST_FAILURE;
    }
    Status = XAxiDma_SimpleTransfer(&AxiDma_B, (UINTPTR)tx_buf_b, TRANSFER_LEN, XAXIDMA_DMA_TO_DEVICE);
    if (Status!=XST_SUCCESS){
        xil_printf("DMA_B transfer submit failed");
        return XST_FAILURE;
    }
    
    while (XAxiDma_Busy(&AxiDma_A, XAXIDMA_DMA_TO_DEVICE) || XAxiDma_Busy(&AxiDma_B, XAXIDMA_DMA_TO_DEVICE)){}
    //usleep(100);
    Status = XAxiDma_SimpleTransfer(&AxiDma_R1, (UINTPTR)rx_buf_one, 128, XAXIDMA_DEVICE_TO_DMA);
    if (Status!=XST_SUCCESS){
        xil_printf("DMA_R1 transfer submit failed");
        return XST_FAILURE;
    }
    Status = XAxiDma_SimpleTransfer(&AxiDma_R2, (UINTPTR)rx_buf_two, 128, XAXIDMA_DEVICE_TO_DMA);
    if (Status!=XST_SUCCESS){
        xil_printf("DMA_R2 transfer submit failed");
        return XST_FAILURE;
    }

    while (XAxiDma_Busy(&AxiDma_R1, XAXIDMA_DEVICE_TO_DMA) || XAxiDma_Busy(&AxiDma_R2, XAXIDMA_DEVICE_TO_DMA)){}
    //usleep(100);
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf_one, 128);
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf_two, 128);
    xil_printf("All transfers complete\r\n");


    // CPU-side comparison
    u32 expected[8][8];
    for (int i = 0; i < 8; i++)
        for (int j = 0; j < 8; j++) {
            u32 sum = 0;
            for (int k = 0; k < 8; k++)
                sum += (u32)tx_buf_a[i*8+k] * (u32)tx_buf_b[k*8+j];
            expected[i][j] = sum;
        }


    //   rx_buf_one[2k]   = C[row][col_base+0]
    //   rx_buf_one[2k+1] = C[row][col_base+1]
    //   rx_buf_two[2k]   = C[row][col_base+2]
    //   rx_buf_two[2k+1] = C[row][col_base+3]
    int fail = 0;
    for (int k = 0; k < 16; k++) {
        int row = k / 2;
        int cb = (4 * k) % 8;
        u32 e0 = expected[row][cb+0], g0 = rx_buf_one[2*k];
        u32 e1 = expected[row][cb+1], g1 = rx_buf_one[2*k+1];
        u32 e2 = expected[row][cb+2], g2 = rx_buf_two[2*k];
        u32 e3 = expected[row][cb+3], g3 = rx_buf_two[2*k+1];
        if (g0 != e0) { xil_printf("FAIL C[%d][%d]: got %u expected %u\r\n", row, cb+0, g0, e0); fail++; }
        if (g1 != e1) { xil_printf("FAIL C[%d][%d]: got %u expected %u\r\n", row, cb+1, g1, e1); fail++; }
        if (g2 != e2) { xil_printf("FAIL C[%d][%d]: got %u expected %u\r\n", row, cb+2, g2, e2); fail++; }
        if (g3 != e3) { xil_printf("FAIL C[%d][%d]: got %u expected %u\r\n", row, cb+3, g3, e3); fail++; }
    }
    if (fail == 0) xil_printf("PASS: all 64 elements match golden model\r\n");
    else            xil_printf("FAIL: %d mismatches out of 64\r\n", fail);
    
    return XST_SUCCESS;
}