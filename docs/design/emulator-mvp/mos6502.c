/* mos6502.c — a genuine tiny MOS 6502 fetch-decode-execute core.
 *
 * ROM + RAM share one byte array `mem[64]`; the ROM is written in, then
 * FETCHED at a runtime program counter. 8 real, SPARSE 6502 opcodes so the
 * decode stays a comparison chain (no dense lookup-table GEP). A data-dependent
 * loop is driven by the guest program's OWN backward relative branch (BNE).
 *
 * Guest program (hand-assembled) computes acc += 5, n times  →  returns 5*n:
 *   $00 A9 00  LDA #$00 ; $02 85 22  STA $22 (acc=0)
 *   $04 A9 00  LDA #$00 ; $06 85 21  STA $21 (i=0)
 *   $08 A5 22  LDA $22 <-loop ; $0A 69 05  ADC #$05 ; $0C 85 22  STA $22
 *   $0E E6 21  INC $21 ; $10 A5 21  LDA $21 ; $12 C5 20  CMP $20 (Z=(i==n))
 *   $14 D0 F2  BNE loop (rel=-14) ; $16 A5 22  LDA $22 ; $18 00  BRK
 * RAM: $20=n (input), $21=i, $22=acc  (all above the 25-byte ROM).
 */
#include <stdint.h>
#include <stdlib.h>

int64_t mos6502(int64_t n) {
    /* Heap-backed RAM (calloc → single-index pointer GEPs, the shape the
     * ptr_cells ingester handles; a `uint8_t mem[64]` stack array instead emits
     * an unsupported two-index `[64 x i8], 0, %idx` GEP). calloc zero-fills. */
    uint8_t *mem = (uint8_t *)calloc(64, 1);

    /* --- load ROM (6502 $addr -> mem[$addr]) --- */
    mem[0]=0xA9; mem[1]=0x00; mem[2]=0x85; mem[3]=0x22; mem[4]=0xA9;
    mem[5]=0x00; mem[6]=0x85; mem[7]=0x21; mem[8]=0xA5; mem[9]=0x22;
    mem[10]=0x69; mem[11]=0x05; mem[12]=0x85; mem[13]=0x22; mem[14]=0xE6;
    mem[15]=0x21; mem[16]=0xA5; mem[17]=0x21; mem[18]=0xC5; mem[19]=0x20;
    mem[20]=0xD0; mem[21]=0xF2; mem[22]=0xA5; mem[23]=0x22; mem[24]=0x00;

    /* --- inject input at zero-page $20 --- */
    mem[0x20] = (uint8_t)(n & 0xFF);

    /* --- CPU state --- */
    int64_t A = 0, pc = 0, Z = 0, running = 1, budget = 0;
    while (running == 1 && budget < 4000) {
        int64_t op = mem[pc];
        if (op == 0xA9) {                          /* LDA #imm */
            A = mem[pc + 1] & 0xFF; pc += 2;
        } else if (op == 0x85) {                   /* STA zp */
            int64_t a = mem[pc + 1]; mem[a] = (uint8_t)A; pc += 2;
        } else if (op == 0xA5) {                   /* LDA zp */
            int64_t a = mem[pc + 1]; A = mem[a] & 0xFF; pc += 2;
        } else if (op == 0x69) {                   /* ADC #imm (carry ignored) */
            A = (A + mem[pc + 1]) & 0xFF; pc += 2;
        } else if (op == 0xE6) {                   /* INC zp */
            int64_t a = mem[pc + 1];
            mem[a] = (uint8_t)((mem[a] + 1) & 0xFF); pc += 2;
        } else if (op == 0xC5) {                   /* CMP zp -> Z */
            int64_t a = mem[pc + 1];
            Z = (A == (mem[a] & 0xFF)) ? 1 : 0; pc += 2;
        } else if (op == 0xD0) {                   /* BNE rel (signed 8-bit) */
            int64_t rel = mem[pc + 1]; pc += 2;
            if (rel >= 128) rel -= 256;
            if (Z == 0) pc += rel;
        } else {                                   /* 0x00 BRK / unknown */
            running = 0; pc += 1;
        }
        budget++;
    }
    free(mem);
    return A;
}
