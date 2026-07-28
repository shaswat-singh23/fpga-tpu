#include "xaxidma.h"
#include "xparameters.h"
#include "xparameters_ps.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include <xaxidma_hw.h>
#include <xstatus.h>
#include <unistd.h>
#include "xiltimer.h"
#include "xil_io.h"

#define GLOBAL_TMR_BASE   0xF8F00200
#define GTIMER_COUNTER_LO (GLOBAL_TMR_BASE + 0x00)
#define GTIMER_COUNTER_HI (GLOBAL_TMR_BASE + 0x04)
#define GTIMER_CONTROL    (GLOBAL_TMR_BASE + 0x08)

static void global_timer_start(void) {
    Xil_Out32(GTIMER_CONTROL, 0x0);          // disable while we set up
    Xil_Out32(GTIMER_COUNTER_LO, 0x0);       // clear counter
    Xil_Out32(GTIMER_COUNTER_HI, 0x0);
    Xil_Out32(GTIMER_CONTROL, 0x1);          // bit 0 = enable
}

static u64 global_timer_read(void) {
    u32 lo, hi, hi2;
    do {                                      // guard against rollover between reads
        hi  = Xil_In32(GTIMER_COUNTER_HI);
        lo  = Xil_In32(GTIMER_COUNTER_LO);
        hi2 = Xil_In32(GTIMER_COUNTER_HI);
    } while (hi != hi2);
    return (((u64)hi) << 32) | lo;
}

#define TRANSFER_LEN 64

u8 tx_buf_a[64] __attribute__((aligned(64)));
u8 tx_buf_b[64] __attribute__((aligned(64)));
u32 rx_buf_one[32] __attribute__((aligned(64)));
u32 rx_buf_two[32] __attribute__((aligned(64)));
#define N 64

u8  A_full[N*N] __attribute__((aligned(64)));   
u8  B_full[N*N] __attribute__((aligned(64)));   
u32 C_full[N*N] __attribute__((aligned(64)));  
u32 C_golden[N*N] __attribute__((aligned(64))); 

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


u8 A_tiled[N*N] __attribute__((aligned(64)));
u8 B_tiled[N*N] __attribute__((aligned(64)));

// One-time repack: row-major -> tile-major. Run once after populating A_full/B_full.
void repack_tiled(u8* src, u8* dst) {
    int tiles_per_row = N / 8;
    int tile_idx = 0;
    for (int ti = 0; ti < tiles_per_row; ti++) {
        for (int tj = 0; tj < tiles_per_row; tj++) {
            u8* dst_tile = dst + tile_idx * 64;
            for (int r = 0; r < 8; r++) {
                for (int c = 0; c < 8; c++) {
                    dst_tile[r*8 + c] = src[(ti*8 + r) * N + (tj*8 + c)];
                }
            }
            tile_idx++;
        }
    }
}

static inline u8* get_tile(u8* tiled_buf, int tile_row, int tile_col) {
    int tiles_per_row = N / 8;
    int tile_idx = tile_row * tiles_per_row + tile_col;
    return tiled_buf + tile_idx * 64;
}

static u32 tile_acc[64];
void accumulate_tile_local(void) {
    for (int k = 0; k < 16; k++) {
        int r = k/2;
        int c = 4*(k%2);
        tile_acc[r*8 + c]     += rx_buf_one[2*k];
        tile_acc[r*8 + c + 1] += rx_buf_one[2*k+1];
        tile_acc[r*8 + c + 2] += rx_buf_two[2*k];
        tile_acc[r*8 + c + 3] += rx_buf_two[2*k+1];
    }
}

void flush_tile_to_C(u32* C, int row0, int col0) {
    for (int r = 0; r < 8; r++)
        for (int c = 0; c < 8; c++)
            C[(row0+r)*N + col0+c] = tile_acc[r*8+c];
}


static u64 t_cache = 0, t_arm = 0, t_poll = 0;

void run_one_tile() {
    int Status;
    u64 a, b;

    a = global_timer_read();
    Xil_DCacheFlushRange((UINTPTR)tx_buf_a, TRANSFER_LEN);
    Xil_DCacheFlushRange((UINTPTR)tx_buf_b, TRANSFER_LEN);
    Xil_DCacheFlushRange((UINTPTR)rx_buf_one, 128);
    Xil_DCacheFlushRange((UINTPTR)rx_buf_two, 128);
    b = global_timer_read(); t_cache += b - a;

    a = b;
    Status = XAxiDma_SimpleTransfer(&AxiDma_A, (UINTPTR)tx_buf_a, TRANSFER_LEN, XAXIDMA_DMA_TO_DEVICE);
    if (Status != XST_SUCCESS) xil_printf("tile: DMA_A submit failed\r\n");
    Status = XAxiDma_SimpleTransfer(&AxiDma_B, (UINTPTR)tx_buf_b, TRANSFER_LEN, XAXIDMA_DMA_TO_DEVICE);
    if (Status != XST_SUCCESS) xil_printf("tile: DMA_B submit failed\r\n");
    b = global_timer_read(); t_arm += b - a;

    a = b;
    while (XAxiDma_Busy(&AxiDma_A, XAXIDMA_DMA_TO_DEVICE) || XAxiDma_Busy(&AxiDma_B, XAXIDMA_DMA_TO_DEVICE)){}
    b = global_timer_read(); t_poll += b - a;

    a = b;
    Status = XAxiDma_SimpleTransfer(&AxiDma_R1, (UINTPTR)rx_buf_one, 128, XAXIDMA_DEVICE_TO_DMA);
    if (Status != XST_SUCCESS) xil_printf("tile: DMA_R1 submit failed\r\n");
    Status = XAxiDma_SimpleTransfer(&AxiDma_R2, (UINTPTR)rx_buf_two, 128, XAXIDMA_DEVICE_TO_DMA);
    if (Status != XST_SUCCESS) xil_printf("tile: DMA_R2 submit failed\r\n");
    b = global_timer_read(); t_arm += b - a;

    a = b;
    while (XAxiDma_Busy(&AxiDma_R1, XAXIDMA_DEVICE_TO_DMA) || XAxiDma_Busy(&AxiDma_R2, XAXIDMA_DEVICE_TO_DMA)){}
    b = global_timer_read(); t_poll += b - a;

    a = b;
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf_one, 128);
    Xil_DCacheInvalidateRange((UINTPTR)rx_buf_two, 128);
    b = global_timer_read(); t_cache += b - a;
}

static u64 t_extract = 0, t_accum = 0, t_repack, t_flush;

void matmul_tiled(u8* A, u8* B, u32* C) {
    int t = 8;
    int tiles_per_row = N / t;
    memset(C, 0, N*N*sizeof(u32));

    u64 rt0 = global_timer_read();
    repack_tiled(A, A_tiled);
    repack_tiled(B, B_tiled);
    u64 rt1 = global_timer_read();
    t_repack += rt1-rt0;

    for (int i = 0; i < tiles_per_row; i++) {
        for (int j = 0; j < tiles_per_row; j++) {
            memset(tile_acc, 0, sizeof(tile_acc));
            for (int k = 0; k < tiles_per_row; k++) {
                u64 a = global_timer_read();
                memcpy(tx_buf_a, get_tile(A_tiled, i, k), 64);
                memcpy(tx_buf_b, get_tile(B_tiled, k, j), 64);
                u64 b = global_timer_read();
                t_extract += b - a;

                run_one_tile();

                a = global_timer_read();
                accumulate_tile_local();
                u64 c = global_timer_read();
                t_accum += c - a;
            }
                        u64 a = global_timer_read();
            flush_tile_to_C(C, i*8, j*8);
            u64 b = global_timer_read();
            t_flush += b - a;  // new bucket
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


    global_timer_start();

    u64 t0 = global_timer_read();
    matmul_tiled(A_full, B_full, C_full);
    u64 t1 = global_timer_read();

    u64 ticks = t1 - t0;
    // Global Timer runs at CPU clock / 2
    u32 tick_hz = XPAR_CPU_CORE_CLOCK_FREQ_HZ / 2;
    u32 elapsed_us = (u32)((ticks * 1000000ULL) / tick_hz);

    xil_printf("ticks=%u  elapsed=%u us\r\n", (u32)ticks, elapsed_us);
    if (elapsed_us > 0) {
        u32 num_tiles = (N/8) * (N/8) * (N/8);
        u32 total_bytes = num_tiles * 256;
        xil_printf("bytes=%u  bandwidth=%u KB/s\r\n",total_bytes, (u32)((u64)total_bytes * 1000000ULL / elapsed_us / 1000));
    }

u32 us_cache   = (u32)((t_cache   * 1000000ULL) / tick_hz);
    u32 us_arm     = (u32)((t_arm     * 1000000ULL) / tick_hz);
    u32 us_poll    = (u32)((t_poll    * 1000000ULL) / tick_hz);
    u32 us_extract = (u32)((t_extract * 1000000ULL) / tick_hz);
    u32 us_accum   = (u32)((t_accum   * 1000000ULL) / tick_hz);
    u32 us_repack  = (u32)((t_repack  * 1000000ULL) / tick_hz);
    u32 us_flush  = (u32)((t_flush  * 1000000ULL) / tick_hz);

    xil_printf("repack=%u us  extract=%u us  accum=%u us\r\n", us_repack, us_extract, us_accum);
    xil_printf("cache=%u us  arm=%u us  poll=%u us flush=%u us  (grand total=%u us)\r\n",
               us_cache, us_arm, us_poll, us_flush,
               us_cache + us_arm + us_poll + us_extract + us_accum + us_repack + us_flush);

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