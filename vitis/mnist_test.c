#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xparameters_ps.h"
#include <stdlib.h>
#include "weights_data.h"
#include "testdata.h"

// ---- Global Timer ----
#define GLOBAL_TMR_BASE   0xF8F00200
#define GTIMER_COUNTER_LO (GLOBAL_TMR_BASE + 0x00)
#define GTIMER_COUNTER_HI (GLOBAL_TMR_BASE + 0x04)
#define GTIMER_CONTROL    (GLOBAL_TMR_BASE + 0x08)

static void global_timer_start(void) {
    Xil_Out32(GTIMER_CONTROL, 0x0);
    Xil_Out32(GTIMER_COUNTER_LO, 0x0);
    Xil_Out32(GTIMER_COUNTER_HI, 0x0);
    Xil_Out32(GTIMER_CONTROL, 0x1);
}

static u64 global_timer_read(void) {
    u32 lo, hi, hi2;
    do {
        hi  = Xil_In32(GTIMER_COUNTER_HI);
        lo  = Xil_In32(GTIMER_COUNTER_LO);
        hi2 = Xil_In32(GTIMER_COUNTER_HI);
    } while (hi != hi2);
    return (((u64)hi) << 32) | lo;
}

static u32 ticks_to_us(u64 ticks) {
    u32 tick_hz = XPAR_CPU_CORE_CLOCK_FREQ_HZ / 2;
    return (u32)(((u64)ticks * 1000000ULL) / tick_hz);
}

// ---- newip AXI-Lite ----
#define NEWIP_BASE         0x43C00000
#define REG_RUN            (NEWIP_BASE + 0x00)
#define REG_PROGRAM_DONE   (NEWIP_BASE + 0x04)
#define REG_DBG_RADDR      (NEWIP_BASE + 0x08)
#define REG_DBG_RDATA_LO   (NEWIP_BASE + 0x0C)
#define REG_DBG_RDATA_HI   (NEWIP_BASE + 0x10)
#define REG_INSTR_WDATA_LO (NEWIP_BASE + 0x14)
#define REG_INSTR_WDATA_HI (NEWIP_BASE + 0x18)
#define REG_INSTR_WADDR    (NEWIP_BASE + 0x1C)
#define REG_INSTR_RADDR    (NEWIP_BASE + 0x20)
#define REG_INSTR_RDATA_LO (NEWIP_BASE + 0x24)
#define REG_INSTR_RDATA_HI (NEWIP_BASE + 0x28)
#define REG_DBG_CMD_STATUS (NEWIP_BASE + 0x38)
#define REG_STORE_STATUS   (NEWIP_BASE + 0x3C)

#define N          64
#define TILES      8
#define CHUNK_W    512
#define CHUNK_B    4096
#define K1_CHUNKS  13
#define STAGE_BASE 0x11000000
#define ADDR_OUT   0x10500000

// ---- instruction encoding ----
static void write_instr(u32 addr, u32 lo, u32 hi) {
    Xil_Out32(REG_INSTR_WDATA_LO, lo);
    Xil_Out32(REG_INSTR_WDATA_HI, hi);
    Xil_Out32(REG_INSTR_WADDR, addr);
}

static void encode_load(u32 opcode, u32 ddr, u32 bram, u32 length,
                        u32 *lo, u32 *hi) {
    u64 w = ((u64)opcode << 60)
          | (((u64)ddr & 0xFFFFFFFFULL) << 28)
          | (((u64)bram & 0x3FFF) << 14)
          | (((u64)length & 0x1F) << 9);
    *lo = (u32)(w & 0xFFFFFFFF);
    *hi = (u32)(w >> 32);
}

static void encode_matmul(u32 a, u32 b, u32 c, u32 tiles, u32 acc,
                          u32 *lo, u32 *hi) {
    u64 w = ((u64)0x2 << 60)
          | (((u64)a & 0x3FFF) << 46)
          | (((u64)b & 0x3FFF) << 32)
          | (((u64)c & 0x3FFF) << 18)
          | (((u64)tiles & 0x1F) << 13)
          | (((u64)acc & 0x1) << 12);
    *lo = (u32)(w & 0xFFFFFFFF);
    *hi = (u32)(w >> 32);
}

static void encode_store(u32 ddr, u32 bram, u32 length, u32 *lo, u32 *hi) {
    u64 w = ((u64)0x3 << 60)
          | (((u64)ddr & 0xFFFFFFFFULL) << 28)
          | (((u64)bram & 0x3FFF) << 14)
          | (((u64)length & 0x1F) << 9);
    *lo = (u32)(w & 0xFFFFFFFF);
    *hi = (u32)(w >> 32);
}

static void encode_activate(u32 c, u32 bias, u32 bias_en, u32 length,
                            u32 mode, u32 *lo, u32 *hi) {
    u64 w = ((u64)0x4 << 60)
          | (((u64)c & 0x3FFF) << 46)
          | (((u64)bias & 0x3FFF) << 32)
          | (((u64)bias_en & 0x1) << 31)
          | (((u64)length & 0x1F) << 13)
          | (((u64)mode & 0x7) << 10);
    *lo = (u32)(w & 0xFFFFFFFF);
    *hi = (u32)(w >> 32);
}

static void encode_quantize(u32 c, u32 b, u32 scale, u32 length, u32 shift,
                            u32 *lo, u32 *hi) {
    u64 w = ((u64)0x5 << 60)
          | (((u64)c & 0x3FFF) << 46)
          | (((u64)b & 0x3FFF) << 32)
          | (((u64)scale & 0x3FFF) << 18)
          | (((u64)length & 0x1F) << 13)
          | (((u64)shift & 0x1F) << 8);
    *lo = (u32)(w & 0xFFFFFFFF);
    *hi = (u32)(w >> 32);
}

static u32 g_slot       = 0;
static u32 g_prog_start = 0;

static void prog_begin(void) { g_prog_start = g_slot; }
static void prog_emit(u32 lo, u32 hi) { write_instr(g_slot++, lo, hi); }

static int wait_done(u32 timeout_polls) {
    for (u32 i = 0; i < timeout_polls; i++)
        if (Xil_In32(REG_PROGRAM_DONE)) return 1;
    return 0;
}

static void wait_done_clear(u32 timeout_polls) {
    for (u32 i = 0; i < timeout_polls; i++)
        if (!Xil_In32(REG_PROGRAM_DONE)) return;
}

static int prog_run(const char *label, u32 *elapsed_us_out) {
    write_instr(g_slot, 0, (u32)(0x6 << 28));

    Xil_Out32(REG_RUN, 0);
    wait_done_clear(1000000);
    Xil_Out32(REG_INSTR_RADDR, g_prog_start);

    global_timer_start();
    u64 t0 = global_timer_read();
    Xil_Out32(REG_RUN, 1);

    int ok = wait_done(20000000);
    u64 t1 = global_timer_read();
    Xil_Out32(REG_RUN, 0);

    if (!ok) {
        xil_printf("FAIL [%s]: program_done never asserted\r\n", label);
        return 0;
    }
    if (elapsed_us_out) *elapsed_us_out = ticks_to_us(t1 - t0);
    return 1;
}

// ---- DDR packing ----
static void pack_A(s8 *dst, const s8 M[N][N]) {
    for (int it = 0; it < TILES; it++)
        for (int jt = 0; jt < TILES; jt++)
            for (int r = 0; r < 8; r++)
                for (int c = 0; c < 8; c++)
                    dst[(it*TILES+jt)*64 + r*8 + c] = M[it*8+r][jt*8+c];
}

static void pack_B(s8 *dst, const s8 M[N][N]) {
    for (int jt = 0; jt < TILES; jt++)
        for (int kt = 0; kt < TILES; kt++)
            for (int col = 0; col < 8; col++)
                for (int p = 0; p < 8; p++)
                    dst[(jt*TILES+kt)*64 + col*8 + p] = M[kt*8+p][jt*8+col];
}

static void unpack_C(s32 C[N][N], const s32 *ddr) {
    int total_words = N * N / 8;
    for (int w = 0; w < total_words; w++) {
        int tile_idx = w / 8;
        int col_in_tile = w % 8;
        int jt = tile_idx / TILES;
        int it = tile_idx % TILES;
        for (int L = 0; L < 8; L++)
            C[it*8 + L][jt*8 + col_in_tile] = ddr[w*8 + L];
    }
}

static void extract_A_chunk(s8 dst[64][64], const s8 *flat, int cols_total, int chunk) {
    for (int r = 0; r < 64; r++)
        for (int c = 0; c < 64; c++)
            dst[r][c] = flat[r * cols_total + chunk * 64 + c];
}

static void extract_B_chunk(s8 dst[64][64], const s8 *flat, int chunk) {
    for (int r = 0; r < 64; r++)
        for (int c = 0; c < 64; c++)
            dst[r][c] = flat[(chunk * 64 + r) * 64 + c];
}

// ---- software baseline: identical int8xint8->int32 arithmetic, no accelerator ----
static void sw_layer_matmul(const s8 *W, int out_dim, int in_dim,
                             const s8 *X, int batch,
                             const s8 *bias, int apply_relu,
                             s32 *out) {
    for (int b = 0; b < batch; b++) {
        for (int o = 0; o < out_dim; o++) {
            s32 sum = 0;
            for (int k = 0; k < in_dim; k++)
                sum += (s32)W[o * in_dim + k] * (s32)X[k * batch + b];
            sum += (s32)bias[o];
            out[o * batch + b] = apply_relu ? (sum < 0 ? 0 : sum) : sum;
        }
    }
}

static void sw_quantize_layer(const s32 *in, int dim, int batch,
                               const u8 *M, int shift, s8 *out) {
    for (int b = 0; b < batch; b++) {
        for (int i = 0; i < dim; i++) {
            s64 product = (s64)in[i * batch + b] * (s64)M[i];
            s64 shifted = product >> shift;
            if (shifted > 127) shifted = 127;
            if (shifted < -128) shifted = -128;
            out[i * batch + b] = (s8)shifted;
        }
    }
}

static int argmax_count_correct_hw(s32 C[N][N]) {
    int correct = 0;
    for (int img = 0; img < 64; img++) {
        int best = 0;
        s32 best_val = C[0][img];
        for (int cls = 1; cls < 10; cls++)
            if (C[cls][img] > best_val) { best_val = C[cls][img]; best = cls; }
        if (best == Y_LABELS[img]) correct++;
    }
    return correct;
}

static int argmax_count_correct_sw(const s32 *L3_out) {
    int correct = 0;
    for (int img = 0; img < 64; img++) {
        int best = 0;
        s32 best_val = L3_out[0 * 64 + img];
        for (int cls = 1; cls < 10; cls++) {
            s32 v = L3_out[cls * 64 + img];
            if (v > best_val) { best_val = v; best = cls; }
        }
        if (best == Y_LABELS[img]) correct++;
    }
    return correct;
}

int main() {
    static s8 chunk_buf[64][64];
    u32 lo, hi;
    u32 hw_us, sw_us;

    // ================= PHASE 1: HARDWARE =================

    for (int k = 0; k < K1_CHUNKS; k++) {
        extract_A_chunk(chunk_buf, W1_DATA, 832, k);
        pack_A((s8 *)(STAGE_BASE + k * CHUNK_B), chunk_buf);
        Xil_DCacheFlushRange((UINTPTR)(STAGE_BASE + k * CHUNK_B), CHUNK_B);
    }
    pack_A((s8 *)(STAGE_BASE + 13 * CHUNK_B), (const s8 (*)[64])W2_DATA);
    pack_A((s8 *)(STAGE_BASE + 14 * CHUNK_B), (const s8 (*)[64])W3_DATA);
    Xil_DCacheFlushRange((UINTPTR)(STAGE_BASE + 13 * CHUNK_B), 2 * CHUNK_B);

    u32 b_stage_base = STAGE_BASE + 15 * CHUNK_B;
    for (int k = 0; k < K1_CHUNKS; k++) {
        extract_B_chunk(chunk_buf, X_INPUT, k);
        pack_B((s8 *)(b_stage_base + k * CHUNK_B), chunk_buf);
    }
    Xil_DCacheFlushRange((UINTPTR)b_stage_base, K1_CHUNKS * CHUNK_B);

    u32 misc_stage = b_stage_base + K1_CHUNKS * CHUNK_B;
    u32 ADDR_B1 = misc_stage + 0*64;
    u32 ADDR_B2 = misc_stage + 1*64;
    u32 ADDR_B3 = misc_stage + 2*64;
    u32 ADDR_M1 = misc_stage + 3*64;
    u32 ADDR_M2 = misc_stage + 4*64;
    for (int i = 0; i < 64; i++) {
        ((volatile s8 *)ADDR_B1)[i] = B1_DATA[i];
        ((volatile s8 *)ADDR_B2)[i] = B2_DATA[i];
        ((volatile s8 *)ADDR_B3)[i] = B3_DATA[i];
        ((volatile u8 *)ADDR_M1)[i] = L1_M_DATA[i];
        ((volatile u8 *)ADDR_M2)[i] = L2_M_DATA[i];
    }
    Xil_DCacheFlushRange((UINTPTR)misc_stage, 5 * 64);

    for (int i = 0; i < N*N; i++) ((volatile s32 *)ADDR_OUT)[i] = 0;
    Xil_DCacheFlushRange((UINTPTR)ADDR_OUT, N*N*sizeof(s32));

    prog_begin();
    for (int k = 0; k < K1_CHUNKS; k++) {
        encode_load(0x0, STAGE_BASE + k*CHUNK_B, k*CHUNK_W, TILES, &lo, &hi);
        prog_emit(lo, hi);
    }
    encode_load(0x0, STAGE_BASE + 13*CHUNK_B, 13*CHUNK_W, TILES, &lo, &hi); prog_emit(lo, hi);
    encode_load(0x0, STAGE_BASE + 14*CHUNK_B, 14*CHUNK_W, TILES, &lo, &hi); prog_emit(lo, hi);
    for (int k = 0; k < K1_CHUNKS; k++) {
        encode_load(0x1, b_stage_base + k*CHUNK_B, k*CHUNK_W, TILES, &lo, &hi);
        prog_emit(lo, hi);
    }
    encode_load(0x7, ADDR_B1, 0, 1, &lo, &hi); prog_emit(lo, hi);
    encode_load(0x7, ADDR_B2, 8, 1, &lo, &hi); prog_emit(lo, hi);
    encode_load(0x7, ADDR_B3, 16, 1, &lo, &hi); prog_emit(lo, hi);
    encode_load(0x8, ADDR_M1, 0, 1, &lo, &hi); prog_emit(lo, hi);
    encode_load(0x8, ADDR_M2, 8, 1, &lo, &hi); prog_emit(lo, hi);

    for (int k = 0; k < K1_CHUNKS; k++) {
        encode_matmul(k*CHUNK_W, k*CHUNK_W, 63, TILES, (k==0)?0:1, &lo, &hi);
        prog_emit(lo, hi);
    }
    encode_activate(63, 0, 1, TILES, 0, &lo, &hi); prog_emit(lo, hi);
    encode_quantize(63, 0, 0, TILES, L1_SHIFT, &lo, &hi); prog_emit(lo, hi);

    encode_matmul(13*CHUNK_W, 0, 63, TILES, 0, &lo, &hi); prog_emit(lo, hi);
    encode_activate(63, 8, 1, TILES, 0, &lo, &hi); prog_emit(lo, hi);
    encode_quantize(63, 0, 8, TILES, L2_SHIFT, &lo, &hi); prog_emit(lo, hi);

    encode_matmul(14*CHUNK_W, 0, 63, TILES, 0, &lo, &hi); prog_emit(lo, hi);
    encode_activate(63, 16, 1, TILES, 1, &lo, &hi); prog_emit(lo, hi);   // mode=1, no ReLU

    encode_store(ADDR_OUT, 63, TILES, &lo, &hi); prog_emit(lo, hi);

    if (!prog_run("mnist_inference", &hw_us)) return 1;

    Xil_DCacheInvalidateRange((UINTPTR)ADDR_OUT, N*N*sizeof(s32));
    static s32 C_got[N][N];
    unpack_C(C_got, (const s32 *)ADDR_OUT);
    int hw_correct = argmax_count_correct_hw(C_got);

    // ================= PHASE 2: SOFTWARE BASELINE =================

    static s32 L1_out[64 * 64];
    static s8  L1_q[64 * 64];
    static s32 L2_out[64 * 64];
    static s8  L2_q[64 * 64];
    static s32 L3_out[64 * 64];

    global_timer_start();
    u64 sw_t0 = global_timer_read();

    sw_layer_matmul(W1_DATA, 64, 832, X_INPUT, 64, B1_DATA, 1, L1_out);
    sw_quantize_layer(L1_out, 64, 64, L1_M_DATA, L1_SHIFT, L1_q);

    sw_layer_matmul(W2_DATA, 64, 64, L1_q, 64, B2_DATA, 1, L2_out);
    sw_quantize_layer(L2_out, 64, 64, L2_M_DATA, L2_SHIFT, L2_q);

    sw_layer_matmul(W3_DATA, 64, 64, L2_q, 64, B3_DATA, 0, L3_out);

    u64 sw_t1 = global_timer_read();
    sw_us = ticks_to_us(sw_t1 - sw_t0);
    int sw_correct = argmax_count_correct_sw(L3_out);

    // ================= RESULTS =================

    xil_printf("\r\n=== hardware ===\r\n");
    xil_printf("execution time: %u us\r\n", hw_us);
    xil_printf("accuracy: %d / 64 correct\r\n", hw_correct);

    xil_printf("\r\n=== software baseline (same ARM core, plain C loop) ===\r\n");
    xil_printf("execution time: %u us\r\n", sw_us);
    xil_printf("accuracy: %d / 64 correct\r\n", sw_correct);

    xil_printf("\r\n=== speedup: %u.%02ux ===\r\n",
               sw_us / hw_us, (u32)(((u64)(sw_us % hw_us) * 100) / hw_us));

    return 0;
}