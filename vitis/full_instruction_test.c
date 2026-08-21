// Bitstream validation trial after the batch=64 BRAM resize, 9-bit
// instruction addressing, and 50MHz clock change.
//
// TEST 1: regression -- the exact two-layer pipeline that passed before
//         (LOAD -> MATMUL -> ACTIVATE -> STORE -> QUANTIZE -> MATMUL ->
//          ACTIVATE -> STORE). Confirms nothing broke.
// TEST 2: accumulate smoke test -- FIRST TIME ON HARDWARE. mm_accumulate
//         was hardcoded 1'b0 until today; sim-verified only.
// TEST 3: multi-K-tile chain -- 3 MATMULs at different A/B offsets
//         accumulating into one C tile. The real layer-1 pattern, small.
// TEST 4: high-address BRAM -- exercises the top of the enlarged
//         A_buf (7168 words) / B_buf (6656 words).
// TEST 5: instruction slots past 128 -- pads pc beyond the old limit,
//         then runs a verifiable program entirely above slot 128.
//         Plus a direct write/readback at slots 300 and 511.

#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xparameters_ps.h"
#include <stdlib.h>

// ---- Global Timer (xtime_l.h is unreliable on this platform) ----
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

// ---- test parameters ----
#define N          64
#define TILES      8
#define SHIFT_VAL  4
#define CHUNK_W    512     // 64-bit words per 64x64 int8 chunk (4096B / 8)
#define CHUNK_B    4096    // bytes per 64x64 int8 chunk

// A_buf depth 7168 words -> last chunk starts at 6656
// B_buf depth 6656 words -> last chunk starts at 6144
#define A_HIGH_ADDR 6656
#define B_HIGH_ADDR 6144

#define ADDR_A       0x10000000
#define ADDR_B       0x10100000
#define ADDR_BIAS    0x10200000
#define ADDR_SCALE   0x10300000
#define ADDR_C1      0x10400000
#define ADDR_C2      0x10500000
#define ADDR_A_CHAIN 0x10600000   // 3 chunks contiguous
#define ADDR_B_CHAIN 0x10700000
#define ADDR_C3      0x10800000   // accumulate test
#define ADDR_C4      0x10900000   // chain test
#define ADDR_C5      0x10A00000   // high-address test
#define ADDR_C6      0x10B00000   // past-slot-128 test

// ---- instruction encoding (unchanged) ----
static void write_instr(u32 addr, u32 lo, u32 hi) {
    Xil_Out32(REG_INSTR_WDATA_LO, lo);
    Xil_Out32(REG_INSTR_WDATA_HI, hi);
    Xil_Out32(REG_INSTR_WADDR, addr);
}

static void read_instr(u32 addr, u32 *lo, u32 *hi) {
    Xil_Out32(REG_INSTR_RADDR, addr);
    *lo = Xil_In32(REG_INSTR_RDATA_LO);
    *hi = Xil_In32(REG_INSTR_RDATA_HI);
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

// ---- program builder ----
// pc persists across `run` triggers and only advances on real instruction
// retirement (HALT does not advance it). So each program is written
// starting at the slot where the previous program's HALT sits, and
// INSTR_RADDR is set to that same slot before triggering.
static u32 g_slot       = 0;   // next slot to write
static u32 g_prog_start = 0;   // slot the current program begins at

static void prog_begin(void) {
    g_prog_start = g_slot;
}

static void prog_emit(u32 lo, u32 hi) {
    write_instr(g_slot++, lo, hi);
}

static int wait_done(u32 timeout_polls) {
    for (u32 i = 0; i < timeout_polls; i++) {
        if (Xil_In32(REG_PROGRAM_DONE)) return 1;
    }
    return 0;
}

static void wait_done_clear(u32 timeout_polls) {
    for (u32 i = 0; i < timeout_polls; i++) {
        if (!Xil_In32(REG_PROGRAM_DONE)) return;
    }
}

// Places HALT at g_slot WITHOUT advancing it -- pc comes to rest there,
// which is exactly where the next program starts writing.
static int prog_run(const char *label, u32 *elapsed_us_out) {
    write_instr(g_slot, 0, (u32)(0x6 << 28));   // HALT

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
        xil_printf("FAIL [%s]: program_done never asserted (prog_start=%u, slot=%u)\r\n",
                   label, g_prog_start, g_slot);
        u32 cs = Xil_In32(REG_DBG_CMD_STATUS);
        xil_printf("  load status: 0x%02x (state=%d done=%d err=%d)\r\n",
                   cs, cs & 0x3, (cs >> 2) & 0x1, (cs >> 3) & 0x1);
        u32 ss = Xil_In32(REG_STORE_STATUS);
        xil_printf("  store status: 0x%02x (state=%d cmd_done=%d cmd_err=%d adapter_done=%d)\r\n",
                   ss, ss & 0x3, (ss >> 2) & 0x1, (ss >> 3) & 0x1, (ss >> 4) & 0x1);
        return 0;
    }

    if (elapsed_us_out) {
        u32 tick_hz = XPAR_CPU_CORE_CLOCK_FREQ_HZ / 2;
        *elapsed_us_out = (u32)(((u64)(t1 - t0) * 1000000ULL) / tick_hz);
    }
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

// ---- golden models ----
static void matmul_gold(const s8 A[N][N], const s8 B[N][N], s32 C[N][N]) {
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            s32 sum = 0;
            for (int k = 0; k < N; k++)
                sum += (s32)A[i][k] * (s32)B[k][j];
            C[i][j] = sum;
        }
}

static void matmul_gold_acc(const s8 A[N][N], const s8 B[N][N], s32 C[N][N]) {
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            s32 sum = C[i][j];
            for (int k = 0; k < N; k++)
                sum += (s32)A[i][k] * (s32)B[k][j];
            C[i][j] = sum;
        }
}

static void activate_gold(s32 C[N][N], const s8 bias[N]) {
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            s32 v = C[i][j] + (s32)bias[i];
            C[i][j] = (v < 0) ? 0 : v;
        }
}

static void quantize_gold(const s32 C[N][N], s8 Bout[N][N],
                          const u8 M[N], int shift) {
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            s64 prod = (s64)C[i][j] * (s64)M[i];
            s64 shifted = prod >> shift;
            s8 out;
            if (shifted > 127)       out = 127;
            else if (shifted < -128) out = -128;
            else                     out = (s8)shifted;
            Bout[i][j] = out;
        }
}

static int compare_C(const char *label, const s32 got[N][N], const s32 exp[N][N]) {
    int err = 0;
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
            if (got[i][j] != exp[i][j]) {
                if (err < 33)
                    xil_printf("  %s MISMATCH [%d][%d]: got %d exp %d\r\n",
                               label, i, j, (int)got[i][j], (int)exp[i][j]);
                err++;
            }
    xil_printf("%-34s %s (%d / %d mismatches)\r\n",
               label, err == 0 ? "PASS" : "FAIL", err, N*N);
    return err;
}

// ---- shared test data ----
static s8  A_matrix[N][N];
static s8  B_matrix[N][N];
static s8  bias_vec[N];
static u8  scale_vec[N];
static s8  A_chain[3][N][N];
static s8  B_chain[3][N][N];

static s32 C_gold[N][N];
static s32 C_gold2[N][N];
static s32 C_got[N][N];
static s8  B2_gold[N][N];

int main(void) {
    xil_printf("\r\n=== BITSTREAM VALIDATION (N=%d, 50MHz, resized BRAM) ===\r\n", N);

    int total_err = 0;
    u32 us;
    u32 lo, hi;

    srand(0xDEADBEEF);
    for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) {
            A_matrix[i][j] = (s8)((rand() & 0x3F) - 32);
            B_matrix[i][j] = (s8)((rand() & 0x3F) - 32);
        }
    for (int i = 0; i < N; i++) {
        bias_vec[i]  = (s8)((rand() % 101) - 50);
        scale_vec[i] = (u8)((rand() % 3) + 1);
    }
    // chain operands kept small so 3 accumulated products stay well
    // inside int32 and any overflow would be a real bug, not saturation
    for (int k = 0; k < 3; k++)
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) {
                A_chain[k][i][j] = (s8)((rand() & 0x1F) - 16);
                B_chain[k][i][j] = (s8)((rand() & 0x1F) - 16);
            }

    volatile s8  *ddr_A     = (volatile s8  *)ADDR_A;
    volatile s8  *ddr_B     = (volatile s8  *)ADDR_B;
    volatile s8  *ddr_bias  = (volatile s8  *)ADDR_BIAS;
    volatile u8  *ddr_scale = (volatile u8  *)ADDR_SCALE;

    pack_A((s8 *)ddr_A, A_matrix);
    pack_B((s8 *)ddr_B, B_matrix);
    for (int i = 0; i < N; i++) { ddr_bias[i] = bias_vec[i]; ddr_scale[i] = scale_vec[i]; }
    for (int k = 0; k < 3; k++) {
        pack_A((s8 *)(ADDR_A_CHAIN + k*CHUNK_B), A_chain[k]);
        pack_B((s8 *)(ADDR_B_CHAIN + k*CHUNK_B), B_chain[k]);
    }
    for (int i = 0; i < N*N; i++) {
        ((volatile s32 *)ADDR_C1)[i] = 0;  ((volatile s32 *)ADDR_C2)[i] = 0;
        ((volatile s32 *)ADDR_C3)[i] = 0;  ((volatile s32 *)ADDR_C4)[i] = 0;
        ((volatile s32 *)ADDR_C5)[i] = 0;  ((volatile s32 *)ADDR_C6)[i] = 0;
    }

    Xil_DCacheFlushRange((UINTPTR)ADDR_A,       N*N);
    Xil_DCacheFlushRange((UINTPTR)ADDR_B,       N*N);
    Xil_DCacheFlushRange((UINTPTR)ADDR_BIAS,    N);
    Xil_DCacheFlushRange((UINTPTR)ADDR_SCALE,   N);
    Xil_DCacheFlushRange((UINTPTR)ADDR_A_CHAIN, 3*CHUNK_B);
    Xil_DCacheFlushRange((UINTPTR)ADDR_B_CHAIN, 3*CHUNK_B);
    Xil_DCacheFlushRange((UINTPTR)ADDR_C1, N*N*sizeof(s32));
    Xil_DCacheFlushRange((UINTPTR)ADDR_C2, N*N*sizeof(s32));
    Xil_DCacheFlushRange((UINTPTR)ADDR_C3, N*N*sizeof(s32));
    Xil_DCacheFlushRange((UINTPTR)ADDR_C4, N*N*sizeof(s32));
    Xil_DCacheFlushRange((UINTPTR)ADDR_C5, N*N*sizeof(s32));
    Xil_DCacheFlushRange((UINTPTR)ADDR_C6, N*N*sizeof(s32));

    // ================= TEST 1: regression, two-layer pipeline =================
    xil_printf("\r\n--- TEST 1: two-layer regression ---\r\n");
    prog_begin();
    encode_load(0x0, ADDR_A,     0, TILES, &lo, &hi); prog_emit(lo, hi);
    encode_load(0x1, ADDR_B,     0, TILES, &lo, &hi); prog_emit(lo, hi);
    encode_load(0x7, ADDR_BIAS,  0, 1,     &lo, &hi); prog_emit(lo, hi);
    encode_load(0x8, ADDR_SCALE, 0, 1,     &lo, &hi); prog_emit(lo, hi);
    encode_matmul(0, 0, 63, TILES, 0, &lo, &hi);        prog_emit(lo, hi);
    encode_activate(63, 0, 1, TILES, 0, &lo, &hi);      prog_emit(lo, hi);
    encode_store(ADDR_C1, 63, TILES, &lo, &hi);         prog_emit(lo, hi);
    encode_quantize(63, 0, 0, TILES, SHIFT_VAL, &lo, &hi); prog_emit(lo, hi);
    encode_matmul(0, 0, 63, TILES, 0, &lo, &hi);        prog_emit(lo, hi);
    encode_activate(63, 0, 1, TILES, 0, &lo, &hi);      prog_emit(lo, hi);
    encode_store(ADDR_C2, 63, TILES, &lo, &hi);         prog_emit(lo, hi);

    if (prog_run("test1", &us)) {
        xil_printf("execution time: %u us\r\n", us);
        Xil_DCacheInvalidateRange((UINTPTR)ADDR_C1, N*N*sizeof(s32));
        Xil_DCacheInvalidateRange((UINTPTR)ADDR_C2, N*N*sizeof(s32));
u32 dbg_lo, dbg_hi;
    for (int bruh = 0; bruh<3; bruh++){
        Xil_Out32(REG_DBG_RADDR, bruh);
        dbg_lo = Xil_In32(REG_DBG_RDATA_LO);
        dbg_hi = Xil_In32(REG_DBG_RDATA_HI);
        xil_printf("A_buf[%d] via debug port: lo=%08x hi=%08x\r\n",bruh, dbg_lo, dbg_hi);
    }
        matmul_gold(A_matrix, B_matrix, C_gold);
        activate_gold(C_gold, bias_vec);
        unpack_C(C_got, (const s32 *)ADDR_C1);
        total_err += compare_C("T1 layer1 (MATMUL+ACT)", C_got, C_gold);

        quantize_gold(C_gold, B2_gold, scale_vec, SHIFT_VAL);
        matmul_gold(A_matrix, B2_gold, C_gold2);
        activate_gold(C_gold2, bias_vec);
        unpack_C(C_got, (const s32 *)ADDR_C2);
        total_err += compare_C("T1 layer2 (QUANT+MATMUL)", C_got, C_gold2);
    } else total_err++;

    // ================= TEST 2: accumulate smoke test =================
    // FIRST hardware exercise of mm_accumulate. Same A/B twice into the
    // same C offset -> expect exactly 2x. B_buf must be reloaded because
    // TEST 1's QUANTIZE overwrote it.
    xil_printf("\r\n--- TEST 2: accumulate (2x same product) ---\r\n");
    prog_begin();
    encode_load(0x0, ADDR_A, 0, TILES, &lo, &hi);  prog_emit(lo, hi);
    encode_load(0x1, ADDR_B, 0, TILES, &lo, &hi);  prog_emit(lo, hi);
    encode_matmul(0, 0, 63, TILES, 0, &lo, &hi);    prog_emit(lo, hi);  // acc=0
    encode_matmul(0, 0, 63, TILES, 1, &lo, &hi);    prog_emit(lo, hi);  // acc=1
    encode_store(ADDR_C3, 63, TILES, &lo, &hi);     prog_emit(lo, hi);

    if (prog_run("test2", &us)) {
        xil_printf("execution time: %u us\r\n", us);
        Xil_DCacheInvalidateRange((UINTPTR)ADDR_C3, N*N*sizeof(s32));
        matmul_gold(A_matrix, B_matrix, C_gold);
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) C_gold[i][j] *= 2;
        unpack_C(C_got, (const s32 *)ADDR_C3);
        total_err += compare_C("T2 accumulate", C_got, C_gold);
    } else total_err++;

    // ================= TEST 3: multi-K-tile chain =================
    // 3 chunks at distinct A/B offsets accumulating into one C tile --
    // the layer-1 pattern in miniature.
    xil_printf("\r\n--- TEST 3: 3-chunk K-tile chain ---\r\n");
    prog_begin();
    for (int k = 0; k < 3; k++) {
        encode_load(0x0, ADDR_A_CHAIN + k*CHUNK_B, k*CHUNK_W, TILES, &lo, &hi);
        prog_emit(lo, hi);
        encode_load(0x1, ADDR_B_CHAIN + k*CHUNK_B, k*CHUNK_W, TILES, &lo, &hi);
        prog_emit(lo, hi);
    }
    for (int k = 0; k < 3; k++) {
        encode_matmul(k*CHUNK_W, k*CHUNK_W, 63, TILES, (k == 0) ? 0 : 1, &lo, &hi);
        prog_emit(lo, hi);
    }
    encode_store(ADDR_C4, 63, TILES, &lo, &hi); prog_emit(lo, hi);

    if (prog_run("test3", &us)) {
        xil_printf("execution time: %u us\r\n", us);
        Xil_DCacheInvalidateRange((UINTPTR)ADDR_C4, N*N*sizeof(s32));
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) C_gold[i][j] = 0;
        for (int k = 0; k < 3; k++)
            matmul_gold_acc(A_chain[k], B_chain[k], C_gold);
        unpack_C(C_got, (const s32 *)ADDR_C4);
        total_err += compare_C("T3 K-tile chain", C_got, C_gold);
    } else total_err++;

    // ================= TEST 4: high-address BRAM =================
    // Top of the enlarged A_buf (7168 words) and B_buf (6656 words).
    xil_printf("\r\n--- TEST 4: high BRAM addresses (A=%d, B=%d) ---\r\n",
               A_HIGH_ADDR, B_HIGH_ADDR);
    prog_begin();
    encode_load(0x0, ADDR_A, A_HIGH_ADDR, TILES, &lo, &hi); prog_emit(lo, hi);
    encode_load(0x1, ADDR_B, B_HIGH_ADDR, TILES, &lo, &hi); prog_emit(lo, hi);
    encode_matmul(A_HIGH_ADDR, B_HIGH_ADDR, 63, TILES, 0, &lo, &hi); prog_emit(lo, hi);
    encode_store(ADDR_C5, 63, TILES, &lo, &hi); prog_emit(lo, hi);

    if (prog_run("test4", &us)) {
        xil_printf("execution time: %u us\r\n", us);
        Xil_DCacheInvalidateRange((UINTPTR)ADDR_C5, N*N*sizeof(s32));
        matmul_gold(A_matrix, B_matrix, C_gold);
        unpack_C(C_got, (const s32 *)ADDR_C5);
        total_err += compare_C("T4 high BRAM address", C_got, C_gold);
    } else total_err++;

    // ================= TEST 5: instruction slots past 128 =================
    // Direct write/readback well above the old 128-slot limit first --
    // isolates "the 9-bit address path works" from "execution works".
    xil_printf("\r\n--- TEST 5: instruction slots > 128 ---\r\n");
    {
        u32 rlo, rhi;
        int slot_err = 0;
        const u32 probe_slots[2] = {300, 511};
        for (int p = 0; p < 2; p++) {
            write_instr(probe_slots[p], 0xA5A50000u | probe_slots[p], 0x5A5A0000u | probe_slots[p]);
        }
        for (int p = 0; p < 2; p++) {
            read_instr(probe_slots[p], &rlo, &rhi);
            u32 elo = 0xA5A50000u | probe_slots[p];
            u32 ehi = 0x5A5A0000u | probe_slots[p];
            if (rlo != elo || rhi != ehi) {
                xil_printf("  slot %u readback MISMATCH: got hi=%08x lo=%08x exp hi=%08x lo=%08x\r\n",
                           probe_slots[p], rhi, rlo, ehi, elo);
                slot_err++;
            }
        }
        xil_printf("%-34s %s\r\n", "T5a slot 300/511 readback",
                   slot_err == 0 ? "PASS" : "FAIL");
        total_err += slot_err;
    }

    // Pad pc past 128 with idempotent ACTIVATEs (ReLU, no bias), then run a
    // real verifiable program whose instructions all live above slot 128.
    xil_printf("padding pc from slot %u to 140...\r\n", g_slot);
    prog_begin();
    while (g_slot < 140) {
        encode_activate(0, 0, 0, TILES, 0, &lo, &hi);
        prog_emit(lo, hi);
    }
    encode_load(0x0, ADDR_A, 0, TILES, &lo, &hi);  prog_emit(lo, hi);
    encode_load(0x1, ADDR_B, 0, TILES, &lo, &hi);  prog_emit(lo, hi);
    encode_matmul(0, 0, 63, TILES, 0, &lo, &hi);    prog_emit(lo, hi);
    encode_store(ADDR_C6, 63, TILES, &lo, &hi);     prog_emit(lo, hi);
    xil_printf("real instructions occupy slots 140..%u\r\n", g_slot - 1);

    if (prog_run("test5", &us)) {
        xil_printf("execution time: %u us\r\n", us);
        Xil_DCacheInvalidateRange((UINTPTR)ADDR_C6, N*N*sizeof(s32));
        matmul_gold(A_matrix, B_matrix, C_gold);
        unpack_C(C_got, (const s32 *)ADDR_C6);
        total_err += compare_C("T5b execute above slot 128", C_got, C_gold);
    } else total_err++;

    xil_printf("\r\n========================================\r\n");
    if (total_err == 0) xil_printf("ALL TESTS PASS -- bitstream validated\r\n");
    else                xil_printf("%d FAILURES -- see above\r\n", total_err);
    return (total_err > 0) ? 1 : 0;
}