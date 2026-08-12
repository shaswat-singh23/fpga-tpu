// Full pipeline trial: LOAD_A -> LOAD_B -> MATMUL -> STORE_C -> HALT,
// run as ONE continuous hardware execution (single run trigger).
// N=64 (tiles=8), all-1s input, expected output: every C[i][j] = 64.
//
// NOTE: intentionally NOT itemized/multi-triggered -- gemm_sequencer has an
// open, unresolved issue where a THIRD consecutive MATMUL trigger in one
// session can hang (see repo notes). A single continuous run only ever
// triggers MATMUL once, which is proven reliable.

#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xparameters_ps.h"

// XTime_GetTime/xtime_l.h is unreliable on this platform -- read the ARM
// Global Timer directly instead.
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

// TODO: confirm from xparameters.h (XPAR_NEWIP_0_BASEADDR)
#define NEWIP_BASE   0x43C00000

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
#define REG_DBG_CMD_STATUS (NEWIP_BASE + 0x38)  // load path: {err,done,state[1:0]}
#define REG_STORE_STATUS   (NEWIP_BASE + 0x3C)  // store path: {adapter_done,err,done,state[1:0]}

#define N       64
#define TILES   8

#define ADDR_A  0x10000000
#define ADDR_B  0x10100000
#define ADDR_C  0x10200000

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

static void encode_load(u32 opcode, u32 ddr_addr, u32 bram_addr, u32 length,
                         u32 *lo, u32 *hi) {
    u64 w = ((u64)opcode << 61) | ((u64)ddr_addr << 29) |
            ((u64)(bram_addr & 0x3FFF) << 15) | ((u64)(length & 0x1F) << 10);
    *lo = (u32)(w & 0xFFFFFFFF);
    *hi = (u32)(w >> 32);
}

static void encode_matmul(u32 a_addr, u32 b_addr, u32 c_addr,
                           u32 tiles, u32 acc, u32 *lo, u32 *hi) {
    u64 w = ((u64)0x2 << 61) | ((u64)(a_addr & 0x3FFF) << 47) |
            ((u64)(b_addr & 0x3FFF) << 33) | ((u64)(c_addr & 0x3FFF) << 19) |
            ((u64)(tiles & 0x1F) << 14) | ((u64)(acc & 0x1) << 13);
    *lo = (u32)(w & 0xFFFFFFFF);
    *hi = (u32)(w >> 32);
}

static void encode_store(u32 ddr_addr, u32 bram_addr, u32 length,
                          u32 *lo, u32 *hi) {
    u64 w = ((u64)0x3 << 61) | ((u64)ddr_addr << 29) |
            ((u64)(bram_addr & 0x3FFF) << 15) | ((u64)(length & 0x1F) << 10);
    *lo = (u32)(w & 0xFFFFFFFF);
    *hi = (u32)(w >> 32);
}

int main() {
    int i, j;
    volatile s8  *bufA = (volatile s8  *)ADDR_A;
    volatile s8  *bufB = (volatile s8  *)ADDR_B;
    volatile s32 *bufC = (volatile s32 *)ADDR_C;
    u32 instr_lo, instr_hi;

    xil_printf("\r\n--- matmul trial: N=%d, tiles=%d ---\r\n", N, TILES);

    // ---- 1. fill A and B with all 1s, clear C ----
    for (i = 0; i < N * N; i++) { bufA[i] = 1; bufB[i] = 1; }
    for (i = 0; i < N * N; i++) { bufC[i] = 0; }
    Xil_DCacheFlushRange((UINTPTR)bufA, N * N * sizeof(s8));
    Xil_DCacheFlushRange((UINTPTR)bufB, N * N * sizeof(s8));
    Xil_DCacheFlushRange((UINTPTR)bufC, N * N * sizeof(s32));
    xil_printf("DDR buffers filled (A=1s, B=1s, C=0)\r\n");

    // ---- 2. write the program (starts at pc=0, fresh board state) ----
    encode_load(0x0, ADDR_A, 0, TILES, &instr_lo, &instr_hi);
    write_instr(0, instr_lo, instr_hi);

    encode_load(0x1, ADDR_B, 0, TILES, &instr_lo, &instr_hi);
    write_instr(1, instr_lo, instr_hi);

    encode_matmul(0, 0, 0, TILES, 0, &instr_lo, &instr_hi);
    write_instr(2, instr_lo, instr_hi);

    encode_store(ADDR_C, 0, TILES, &instr_lo, &instr_hi);
    write_instr(3, instr_lo, instr_hi);

    write_instr(4, 0, (u32)(0x6 << 29));   // HALT
    xil_printf("program written: LOAD_A, LOAD_B, MATMUL, STORE_C, HALT\r\n");

    // ---- 3. verify instructions landed ----
    for (i = 0; i < 5; i++) {
        u32 lo, hi;
        read_instr(i, &lo, &hi);
        xil_printf("  instr[%d] readback: hi=%08x lo=%08x\r\n", i, hi, lo);
    }

    // ---- 4. clean trigger (single run, pc starts at 0 on fresh board) ----
    Xil_Out32(REG_RUN, 0);
    Xil_Out32(REG_INSTR_RADDR, 0);
    global_timer_start();
    u64 t_start = global_timer_read();

    Xil_Out32(REG_RUN, 1);

    int poll_count;
    u32 done_flag = 0;
    for (poll_count = 0; poll_count < 20000000; poll_count++) {
        done_flag = Xil_In32(REG_PROGRAM_DONE);
        if (done_flag) break;
    }

    u64 t_end = global_timer_read();
    u64 elapsed = t_end - t_start;
    Xil_Out32(REG_RUN, 0);

    if (!done_flag) {
        xil_printf("FAIL: program_done never asserted (timed out after %d polls)\r\n", poll_count);

        u32 stuck_lo, stuck_hi;
        read_instr(5, &stuck_lo, &stuck_hi);   // slot 5 is unused -> reveals instr_mem[pc]
        xil_printf("stuck-pc probe: hi=%08x lo=%08x (compare vs instr[0..4] above)\r\n",
                   stuck_hi, stuck_lo);

        u32 cmd_status = Xil_In32(REG_DBG_CMD_STATUS);
        xil_printf("load status: 0x%02x (state=%d done=%d err=%d)\r\n",
                   cmd_status, cmd_status & 0x3, (cmd_status >> 2) & 0x1, (cmd_status >> 3) & 0x1);

        u32 store_status = Xil_In32(REG_STORE_STATUS);
        xil_printf("store status: 0x%02x (state=%d cmd_done=%d cmd_err=%d adapter_done=%d)\r\n",
                   store_status, store_status & 0x3, (store_status >> 2) & 0x1,
                   (store_status >> 3) & 0x1, (store_status >> 4) & 0x1);

        return 1;
    }
    xil_printf("program_done asserted after %d poll iterations\r\n", poll_count);

    // ---- 5. report timing ----
    u32 tick_hz = XPAR_CPU_CORE_CLOCK_FREQ_HZ / 2;
    u32 elapsed_us = (u32)(((u64)elapsed * 1000000ULL) / tick_hz);
    xil_printf("hardware execution time: %u ticks, %u us\r\n", (u32)elapsed, elapsed_us);

    // ---- 6. verify C against golden (every element = N) ----
    Xil_DCacheInvalidateRange((UINTPTR)bufC, N * N * sizeof(s32));

    int mismatches = 0;
    for (i = 0; i < N; i++) {
        for (j = 0; j < N; j++) {
            s32 got = bufC[i * N + j];
            s32 exp = N;
            if (got != exp) {
                if (mismatches < 10) {
                    xil_printf("MISMATCH C[%d][%d]: got %d expected %d\r\n", i, j, got, exp);
                }
                mismatches++;
            }
        }
    }

    if (mismatches == 0) {
        xil_printf("PASS: all %d elements match (each = %d)\r\n", N * N, N);
    } else {
        xil_printf("FAIL: %d mismatches out of %d\r\n", mismatches, N * N);
    }

    xil_printf("--- trial done ---\r\n");
    return mismatches;
}