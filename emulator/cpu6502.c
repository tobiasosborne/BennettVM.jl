/* cpu6502.c — a real MOS 6502 fetch-decode-execute core, for BennettVM (E1).
 *
 * Extends the proven E0 MVP (docs/design/emulator-mvp/mos6502.c) from an
 * 8-opcode if/elseif chain to a full `switch(opcode)` decode. The E1 de-risk
 * question: does a C `switch` over SPARSE 6502 opcodes survive Bennett.jl
 * extraction (stay a plain LLVM `switch`, NOT a dense `@switch.table` lookup
 * GEP that the ingester rejects)?
 *
 * Same walls avoided as E0:
 *   - RAM is a calloc'd `uint8_t *` (single-index GEP the ptr_cells ingester
 *     handles); a C stack array `uint8_t mem[N]` emits a rejected 2-index GEP.
 *   - Opcodes are the real, SPARSE 6502 encodings (0xA9, 0xE8, 0x4C, ...) so
 *     the decode cannot be dense-tabulated into a jump table.
 *
 * ORACLE NOTE (Rule 4): the golden master is the NATIVE clang binary running
 * this exact C (see cpu6502_main.c). native == VM validates the VM path and
 * reversibility. A handful of KNOWN-ANSWER programs (whose correct 6502 result
 * is hand-derived) additionally guard 6502 *semantics* — see test_cpu6502.jl.
 */
#include <stdint.h>
#include <stdlib.h>

/* ---- 6502 status flag bit masks (in the P register) ---- */
#define FLAG_C 0x01 /* carry            */
#define FLAG_Z 0x02 /* zero             */
#define FLAG_I 0x04 /* interrupt disable*/
#define FLAG_D 0x08 /* decimal          */
#define FLAG_B 0x10 /* break            */
#define FLAG_U 0x20 /* unused (always 1)*/
#define FLAG_V 0x40 /* overflow         */
#define FLAG_N 0x80 /* negative         */

/* Set/clear a single flag bit from a boolean condition. */
#define SET_FLAG(mask, cond) (P = (P & ~(int64_t)(mask)) | ((cond) ? (int64_t)(mask) : 0))
/* N and Z from an 8-bit value. */
#define SET_NZ(v)                                                              \
    do {                                                                       \
        int64_t _t = (v) & 0xFF;                                               \
        P = (P & ~(int64_t)(FLAG_N | FLAG_Z)) | (_t == 0 ? FLAG_Z : 0) |       \
            (_t & FLAG_N);                                                      \
    } while (0)

/* Addressing-mode effective addresses. Use ONLY inside the decode loop (they
 * read the loop-locals o1/o2/abs16/mem and the registers X/Y). All wrap to the
 * correct 6502 width. Zero-page indexed and the indirect-pointer fetches wrap
 * within the zero page ((ptr+1)&0xFF), matching real hardware. */
#define EA_ZP   ((o1) & 0xFF)
#define EA_ZPX  (((o1) + X) & 0xFF)
#define EA_ZPY  (((o1) + Y) & 0xFF)
#define EA_ABS  (abs16)
#define EA_ABSX (((abs16) + X) & 0xFFFF)
#define EA_ABSY (((abs16) + Y) & 0xFFFF)
#define EA_INDX ((mem[((o1) + X) & 0xFF] | (mem[((o1) + X + 1) & 0xFF] << 8)) & 0xFFFF)
#define EA_INDY (((mem[(o1) & 0xFF] | (mem[((o1) + 1) & 0xFF] << 8)) + Y) & 0xFFFF)

/* ALU ops on an 8-bit operand m (A is the implicit accumulator). */
#define DO_ADC(m)                                                              \
    do {                                                                       \
        int64_t _m = (m) & 0xFF, _c = P & FLAG_C, _s = A + _m + _c;            \
        SET_FLAG(FLAG_C, _s > 0xFF);                                           \
        SET_FLAG(FLAG_V, ((~(A ^ _m)) & (A ^ _s) & 0x80) != 0);               \
        A = _s & 0xFF; SET_NZ(A);                                             \
    } while (0)
#define DO_SBC(m) DO_ADC(((m) & 0xFF) ^ 0xFF)
#define DO_AND(m) do { A = (A & (m)) & 0xFF; SET_NZ(A); } while (0)
#define DO_ORA(m) do { A = (A | (m)) & 0xFF; SET_NZ(A); } while (0)
#define DO_EOR(m) do { A = (A ^ (m)) & 0xFF; SET_NZ(A); } while (0)
#define DO_CMP(reg, m)                                                         \
    do {                                                                       \
        int64_t _m = (m) & 0xFF;                                               \
        SET_FLAG(FLAG_C, ((reg) & 0xFF) >= _m);                                \
        SET_NZ(((reg) & 0xFF) - _m);                                           \
    } while (0)
#define DO_BIT(m)                                                             \
    do {                                                                       \
        int64_t _m = (m) & 0xFF;                                               \
        P = (P & ~(int64_t)FLAG_Z) | (((A & _m) & 0xFF) == 0 ? FLAG_Z : 0);    \
        P = (P & ~(int64_t)FLAG_N) | (_m & 0x80);                              \
        P = (P & ~(int64_t)FLAG_V) | (_m & 0x40);                              \
    } while (0)

/* Read-modify-write shifts/rotates on an lvalue v (accumulator or a temp). */
#define ASL_V(v) do { int64_t _n = ((v) >> 7) & 1; (v) = ((v) << 1) & 0xFF; SET_FLAG(FLAG_C, _n); SET_NZ(v); } while (0)
#define LSR_V(v) do { int64_t _n = (v) & 1;        (v) = ((v) >> 1) & 0xFF; SET_FLAG(FLAG_C, _n); SET_NZ(v); } while (0)
#define ROL_V(v) do { int64_t _c = (P & FLAG_C) ? 1 : 0, _n = ((v) >> 7) & 1; (v) = (((v) << 1) | _c) & 0xFF; SET_FLAG(FLAG_C, _n); SET_NZ(v); } while (0)
#define ROR_V(v) do { int64_t _c = (P & FLAG_C) ? 0x80 : 0, _n = (v) & 1;     (v) = (((v) >> 1) | _c) & 0xFF; SET_FLAG(FLAG_C, _n); SET_NZ(v); } while (0)
#define INC_M(ea) do { int64_t _e = (ea), _v = (mem[_e] + 1) & 0xFF; mem[_e] = (uint8_t)_v; SET_NZ(_v); } while (0)
#define DEC_M(ea) do { int64_t _e = (ea), _v = (mem[_e] - 1) & 0xFF; mem[_e] = (uint8_t)_v; SET_NZ(_v); } while (0)

/* Hardware stack: page $0100 + SP, pre-decrement on push. */
#define PUSH(v) do { mem[0x0100 + (SP & 0xFF)] = (uint8_t)(v); SP = (SP - 1) & 0xFF; } while (0)
#define PULL()  (SP = (SP + 1) & 0xFF, (int64_t)mem[0x0100 + (SP & 0xFF)])

/* Conditional branch: signed rel-8 lives in o1. */
#define BRANCH(cond) do { pc += 2; if (cond) { int64_t _r = o1; if (_r >= 128) _r -= 256; pc = (pc + _r) & 0xFFFF; } } while (0)

/* The shared fetch-decode-execute core.
 *
 *   mem     : 64 KB calloc'd RAM+ROM (ROM pre-loaded by the caller).
 *   pc      : initial program counter.
 *   budget  : max guest instructions to retire (halts fail-safe if exceeded).
 *   mode    : selects the returned observable (so tests can assert either a
 *             whole-state checksum OR a single register for a known answer):
 *               0 -> 64-bit state checksum (regs + the $0000-$01FF window)
 *               1 -> final A   2 -> final X   3 -> final Y
 *               4 -> final P   5 -> final SP
 *
 * Returns the selected observable as int64_t.
 */
int64_t cpu6502_core(uint8_t *mem, int64_t pc, int64_t budget, int64_t mode) {
    int64_t A = 0, X = 0, Y = 0;
    int64_t SP = 0xFF;          /* stack pointer (page 1: $0100+SP) */
    int64_t P = FLAG_U | FLAG_I; /* power-on-ish: U set, I set      */
    int64_t running = 1;

    while (running == 1 && budget > 0) {
        int64_t op = mem[pc & 0xFFFF];
        /* Operand bytes read eagerly (harmless for shorter opcodes). */
        int64_t o1 = mem[(pc + 1) & 0xFFFF];
        int64_t o2 = mem[(pc + 2) & 0xFFFF];
        int64_t abs16 = (o1 | (o2 << 8)) & 0xFFFF;

        switch (op) {
        /* ===================== LDA (8 modes) ===================== */
        case 0xA9: A = o1;             SET_NZ(A); pc += 2; break; /* # */
        case 0xA5: A = mem[EA_ZP];     SET_NZ(A); pc += 2; break; /* zp */
        case 0xB5: A = mem[EA_ZPX];    SET_NZ(A); pc += 2; break; /* zp,X */
        case 0xAD: A = mem[EA_ABS];    SET_NZ(A); pc += 3; break; /* abs */
        case 0xBD: A = mem[EA_ABSX];   SET_NZ(A); pc += 3; break; /* abs,X */
        case 0xB9: A = mem[EA_ABSY];   SET_NZ(A); pc += 3; break; /* abs,Y */
        case 0xA1: A = mem[EA_INDX];   SET_NZ(A); pc += 2; break; /* (ind,X) */
        case 0xB1: A = mem[EA_INDY];   SET_NZ(A); pc += 2; break; /* (ind),Y */
        /* ===================== LDX (5 modes) ===================== */
        case 0xA2: X = o1;             SET_NZ(X); pc += 2; break; /* # */
        case 0xA6: X = mem[EA_ZP];     SET_NZ(X); pc += 2; break; /* zp */
        case 0xB6: X = mem[EA_ZPY];    SET_NZ(X); pc += 2; break; /* zp,Y */
        case 0xAE: X = mem[EA_ABS];    SET_NZ(X); pc += 3; break; /* abs */
        case 0xBE: X = mem[EA_ABSY];   SET_NZ(X); pc += 3; break; /* abs,Y */
        /* ===================== LDY (5 modes) ===================== */
        case 0xA0: Y = o1;             SET_NZ(Y); pc += 2; break; /* # */
        case 0xA4: Y = mem[EA_ZP];     SET_NZ(Y); pc += 2; break; /* zp */
        case 0xB4: Y = mem[EA_ZPX];    SET_NZ(Y); pc += 2; break; /* zp,X */
        case 0xAC: Y = mem[EA_ABS];    SET_NZ(Y); pc += 3; break; /* abs */
        case 0xBC: Y = mem[EA_ABSX];   SET_NZ(Y); pc += 3; break; /* abs,X */
        /* ===================== STA (7 modes) ===================== */
        case 0x85: mem[EA_ZP]   = (uint8_t)A; pc += 2; break; /* zp */
        case 0x95: mem[EA_ZPX]  = (uint8_t)A; pc += 2; break; /* zp,X */
        case 0x8D: mem[EA_ABS]  = (uint8_t)A; pc += 3; break; /* abs */
        case 0x9D: mem[EA_ABSX] = (uint8_t)A; pc += 3; break; /* abs,X */
        case 0x99: mem[EA_ABSY] = (uint8_t)A; pc += 3; break; /* abs,Y */
        case 0x81: mem[EA_INDX] = (uint8_t)A; pc += 2; break; /* (ind,X) */
        case 0x91: mem[EA_INDY] = (uint8_t)A; pc += 2; break; /* (ind),Y */
        /* ===================== STX / STY ===================== */
        case 0x86: mem[EA_ZP]  = (uint8_t)X; pc += 2; break; /* STX zp */
        case 0x96: mem[EA_ZPY] = (uint8_t)X; pc += 2; break; /* STX zp,Y */
        case 0x8E: mem[EA_ABS] = (uint8_t)X; pc += 3; break; /* STX abs */
        case 0x84: mem[EA_ZP]  = (uint8_t)Y; pc += 2; break; /* STY zp */
        case 0x94: mem[EA_ZPX] = (uint8_t)Y; pc += 2; break; /* STY zp,X */
        case 0x8C: mem[EA_ABS] = (uint8_t)Y; pc += 3; break; /* STY abs */

        /* ===================== ADC (8 modes) ===================== */
        case 0x69: DO_ADC(o1);            pc += 2; break;
        case 0x65: DO_ADC(mem[EA_ZP]);    pc += 2; break;
        case 0x75: DO_ADC(mem[EA_ZPX]);   pc += 2; break;
        case 0x6D: DO_ADC(mem[EA_ABS]);   pc += 3; break;
        case 0x7D: DO_ADC(mem[EA_ABSX]);  pc += 3; break;
        case 0x79: DO_ADC(mem[EA_ABSY]);  pc += 3; break;
        case 0x61: DO_ADC(mem[EA_INDX]);  pc += 2; break;
        case 0x71: DO_ADC(mem[EA_INDY]);  pc += 2; break;
        /* ===================== SBC (8 modes) ===================== */
        case 0xE9: DO_SBC(o1);            pc += 2; break;
        case 0xE5: DO_SBC(mem[EA_ZP]);    pc += 2; break;
        case 0xF5: DO_SBC(mem[EA_ZPX]);   pc += 2; break;
        case 0xED: DO_SBC(mem[EA_ABS]);   pc += 3; break;
        case 0xFD: DO_SBC(mem[EA_ABSX]);  pc += 3; break;
        case 0xF9: DO_SBC(mem[EA_ABSY]);  pc += 3; break;
        case 0xE1: DO_SBC(mem[EA_INDX]);  pc += 2; break;
        case 0xF1: DO_SBC(mem[EA_INDY]);  pc += 2; break;
        /* ===================== AND (8 modes) ===================== */
        case 0x29: DO_AND(o1);            pc += 2; break;
        case 0x25: DO_AND(mem[EA_ZP]);    pc += 2; break;
        case 0x35: DO_AND(mem[EA_ZPX]);   pc += 2; break;
        case 0x2D: DO_AND(mem[EA_ABS]);   pc += 3; break;
        case 0x3D: DO_AND(mem[EA_ABSX]);  pc += 3; break;
        case 0x39: DO_AND(mem[EA_ABSY]);  pc += 3; break;
        case 0x21: DO_AND(mem[EA_INDX]);  pc += 2; break;
        case 0x31: DO_AND(mem[EA_INDY]);  pc += 2; break;
        /* ===================== ORA (8 modes) ===================== */
        case 0x09: DO_ORA(o1);            pc += 2; break;
        case 0x05: DO_ORA(mem[EA_ZP]);    pc += 2; break;
        case 0x15: DO_ORA(mem[EA_ZPX]);   pc += 2; break;
        case 0x0D: DO_ORA(mem[EA_ABS]);   pc += 3; break;
        case 0x1D: DO_ORA(mem[EA_ABSX]);  pc += 3; break;
        case 0x19: DO_ORA(mem[EA_ABSY]);  pc += 3; break;
        case 0x01: DO_ORA(mem[EA_INDX]);  pc += 2; break;
        case 0x11: DO_ORA(mem[EA_INDY]);  pc += 2; break;
        /* ===================== EOR (8 modes) ===================== */
        case 0x49: DO_EOR(o1);            pc += 2; break;
        case 0x45: DO_EOR(mem[EA_ZP]);    pc += 2; break;
        case 0x55: DO_EOR(mem[EA_ZPX]);   pc += 2; break;
        case 0x4D: DO_EOR(mem[EA_ABS]);   pc += 3; break;
        case 0x5D: DO_EOR(mem[EA_ABSX]);  pc += 3; break;
        case 0x59: DO_EOR(mem[EA_ABSY]);  pc += 3; break;
        case 0x41: DO_EOR(mem[EA_INDX]);  pc += 2; break;
        case 0x51: DO_EOR(mem[EA_INDY]);  pc += 2; break;
        /* ===================== CMP (8 modes) ===================== */
        case 0xC9: DO_CMP(A, o1);           pc += 2; break;
        case 0xC5: DO_CMP(A, mem[EA_ZP]);   pc += 2; break;
        case 0xD5: DO_CMP(A, mem[EA_ZPX]);  pc += 2; break;
        case 0xCD: DO_CMP(A, mem[EA_ABS]);  pc += 3; break;
        case 0xDD: DO_CMP(A, mem[EA_ABSX]); pc += 3; break;
        case 0xD9: DO_CMP(A, mem[EA_ABSY]); pc += 3; break;
        case 0xC1: DO_CMP(A, mem[EA_INDX]); pc += 2; break;
        case 0xD1: DO_CMP(A, mem[EA_INDY]); pc += 2; break;
        /* ===================== CPX / CPY ===================== */
        case 0xE0: DO_CMP(X, o1);           pc += 2; break;
        case 0xE4: DO_CMP(X, mem[EA_ZP]);   pc += 2; break;
        case 0xEC: DO_CMP(X, mem[EA_ABS]);  pc += 3; break;
        case 0xC0: DO_CMP(Y, o1);           pc += 2; break;
        case 0xC4: DO_CMP(Y, mem[EA_ZP]);   pc += 2; break;
        case 0xCC: DO_CMP(Y, mem[EA_ABS]);  pc += 3; break;
        /* ===================== BIT ===================== */
        case 0x24: DO_BIT(mem[EA_ZP]);  pc += 2; break;
        case 0x2C: DO_BIT(mem[EA_ABS]); pc += 3; break;

        /* ===================== ASL (A + 4 memory modes) ===================== */
        case 0x0A: ASL_V(A); pc += 1; break;
        case 0x06: { int64_t e = EA_ZP;   int64_t v = mem[e]; ASL_V(v); mem[e] = (uint8_t)v; pc += 2; break; }
        case 0x16: { int64_t e = EA_ZPX;  int64_t v = mem[e]; ASL_V(v); mem[e] = (uint8_t)v; pc += 2; break; }
        case 0x0E: { int64_t e = EA_ABS;  int64_t v = mem[e]; ASL_V(v); mem[e] = (uint8_t)v; pc += 3; break; }
        case 0x1E: { int64_t e = EA_ABSX; int64_t v = mem[e]; ASL_V(v); mem[e] = (uint8_t)v; pc += 3; break; }
        /* ===================== LSR ===================== */
        case 0x4A: LSR_V(A); pc += 1; break;
        case 0x46: { int64_t e = EA_ZP;   int64_t v = mem[e]; LSR_V(v); mem[e] = (uint8_t)v; pc += 2; break; }
        case 0x56: { int64_t e = EA_ZPX;  int64_t v = mem[e]; LSR_V(v); mem[e] = (uint8_t)v; pc += 2; break; }
        case 0x4E: { int64_t e = EA_ABS;  int64_t v = mem[e]; LSR_V(v); mem[e] = (uint8_t)v; pc += 3; break; }
        case 0x5E: { int64_t e = EA_ABSX; int64_t v = mem[e]; LSR_V(v); mem[e] = (uint8_t)v; pc += 3; break; }
        /* ===================== ROL ===================== */
        case 0x2A: ROL_V(A); pc += 1; break;
        case 0x26: { int64_t e = EA_ZP;   int64_t v = mem[e]; ROL_V(v); mem[e] = (uint8_t)v; pc += 2; break; }
        case 0x36: { int64_t e = EA_ZPX;  int64_t v = mem[e]; ROL_V(v); mem[e] = (uint8_t)v; pc += 2; break; }
        case 0x2E: { int64_t e = EA_ABS;  int64_t v = mem[e]; ROL_V(v); mem[e] = (uint8_t)v; pc += 3; break; }
        case 0x3E: { int64_t e = EA_ABSX; int64_t v = mem[e]; ROL_V(v); mem[e] = (uint8_t)v; pc += 3; break; }
        /* ===================== ROR ===================== */
        case 0x6A: ROR_V(A); pc += 1; break;
        case 0x66: { int64_t e = EA_ZP;   int64_t v = mem[e]; ROR_V(v); mem[e] = (uint8_t)v; pc += 2; break; }
        case 0x76: { int64_t e = EA_ZPX;  int64_t v = mem[e]; ROR_V(v); mem[e] = (uint8_t)v; pc += 2; break; }
        case 0x6E: { int64_t e = EA_ABS;  int64_t v = mem[e]; ROR_V(v); mem[e] = (uint8_t)v; pc += 3; break; }
        case 0x7E: { int64_t e = EA_ABSX; int64_t v = mem[e]; ROR_V(v); mem[e] = (uint8_t)v; pc += 3; break; }

        /* ===================== INC / DEC memory ===================== */
        case 0xE6: INC_M(EA_ZP);   pc += 2; break;
        case 0xF6: INC_M(EA_ZPX);  pc += 2; break;
        case 0xEE: INC_M(EA_ABS);  pc += 3; break;
        case 0xFE: INC_M(EA_ABSX); pc += 3; break;
        case 0xC6: DEC_M(EA_ZP);   pc += 2; break;
        case 0xD6: DEC_M(EA_ZPX);  pc += 2; break;
        case 0xCE: DEC_M(EA_ABS);  pc += 3; break;
        case 0xDE: DEC_M(EA_ABSX); pc += 3; break;
        /* ===================== register INC/DEC ===================== */
        case 0xE8: X = (X + 1) & 0xFF; SET_NZ(X); pc += 1; break; /* INX */
        case 0xCA: X = (X - 1) & 0xFF; SET_NZ(X); pc += 1; break; /* DEX */
        case 0xC8: Y = (Y + 1) & 0xFF; SET_NZ(Y); pc += 1; break; /* INY */
        case 0x88: Y = (Y - 1) & 0xFF; SET_NZ(Y); pc += 1; break; /* DEY */

        /* ===================== register transfers ===================== */
        case 0xAA: X = A;  SET_NZ(X); pc += 1; break; /* TAX */
        case 0x8A: A = X;  SET_NZ(A); pc += 1; break; /* TXA */
        case 0xA8: Y = A;  SET_NZ(Y); pc += 1; break; /* TAY */
        case 0x98: A = Y;  SET_NZ(A); pc += 1; break; /* TYA */
        case 0xBA: X = SP; SET_NZ(X); pc += 1; break; /* TSX */
        case 0x9A: SP = X;            pc += 1; break; /* TXS (no flags) */

        /* ===================== stack ===================== */
        case 0x48: PUSH(A);                       pc += 1; break; /* PHA */
        case 0x68: A = PULL(); SET_NZ(A);         pc += 1; break; /* PLA */
        case 0x08: PUSH(P | FLAG_B | FLAG_U);     pc += 1; break; /* PHP */
        case 0x28: P = (PULL() & ~(int64_t)FLAG_B) | FLAG_U; pc += 1; break; /* PLP */

        /* ===================== jumps / calls ===================== */
        case 0x4C: pc = abs16; break;                              /* JMP abs */
        case 0x6C: { /* JMP (indirect) — with the real page-boundary bug */
            int64_t lo = mem[abs16];
            int64_t hia = (abs16 & 0xFF00) | ((abs16 + 1) & 0xFF);
            int64_t hi = mem[hia];
            pc = (lo | (hi << 8)) & 0xFFFF; break;
        }
        case 0x20: { /* JSR abs — push (return-1) hi then lo */
            int64_t ret = (pc + 2) & 0xFFFF;
            PUSH((ret >> 8) & 0xFF); PUSH(ret & 0xFF);
            pc = abs16; break;
        }
        case 0x60: { /* RTS — pull lo,hi; pc = addr+1 */
            int64_t lo = PULL(); int64_t hi = PULL();
            pc = ((lo | (hi << 8)) + 1) & 0xFFFF; break;
        }
        case 0x40: { /* RTI — pull P, then pull PC (no +1) */
            P = (PULL() & ~(int64_t)FLAG_B) | FLAG_U;
            int64_t lo = PULL(); int64_t hi = PULL();
            pc = (lo | (hi << 8)) & 0xFFFF; break;
        }

        /* ===================== branches ===================== */
        case 0x10: BRANCH(!(P & FLAG_N)); break; /* BPL */
        case 0x30: BRANCH(  P & FLAG_N ); break; /* BMI */
        case 0x50: BRANCH(!(P & FLAG_V)); break; /* BVC */
        case 0x70: BRANCH(  P & FLAG_V ); break; /* BVS */
        case 0x90: BRANCH(!(P & FLAG_C)); break; /* BCC */
        case 0xB0: BRANCH(  P & FLAG_C ); break; /* BCS */
        case 0xD0: BRANCH(!(P & FLAG_Z)); break; /* BNE */
        case 0xF0: BRANCH(  P & FLAG_Z ); break; /* BEQ */

        /* ===================== flag ops ===================== */
        case 0x18: P &= ~(int64_t)FLAG_C; pc += 1; break; /* CLC */
        case 0x38: P |=  FLAG_C;          pc += 1; break; /* SEC */
        case 0x58: P &= ~(int64_t)FLAG_I; pc += 1; break; /* CLI */
        case 0x78: P |=  FLAG_I;          pc += 1; break; /* SEI */
        case 0xB8: P &= ~(int64_t)FLAG_V; pc += 1; break; /* CLV */
        case 0xD8: P &= ~(int64_t)FLAG_D; pc += 1; break; /* CLD */
        case 0xF8: P |=  FLAG_D;          pc += 1; break; /* SED */

        /* ===================== misc / halt ===================== */
        case 0xEA: pc += 1; break;                        /* NOP */
        case 0x00: running = 0; pc += 1; break;           /* BRK -> halt */
        default:   running = 0; pc += 1; break;           /* unknown -> halt */
        }
        budget -= 1;
    }

    /* ---- observable selection ---- */
    if (mode == 1) return A & 0xFF;
    if (mode == 2) return X & 0xFF;
    if (mode == 3) return Y & 0xFF;
    if (mode == 4) return P & 0xFF;
    if (mode == 5) return SP & 0xFF;

    /* mode 0: xorshift64 state checksum over regs + the whole zero page and
     * stack page ($0000-$01FF, 512 cells). xorshift (xor/shl/lshr only) is
     * order-sensitive, so a single-register or single-cell error avalanches —
     * satisfies Rule 4 (any error shows up). The wide window means a store to
     * ANY zero-page/stack cell (incl. RMW, PHA/JSR pushes) is observable. */
    uint64_t h = 0x9E3779B97F4A7C15ULL;
    /* fold in each field, scrambling between folds */
#define MIX(x)                                                                 \
    do {                                                                       \
        h ^= (uint64_t)(int64_t)(x);                                           \
        h ^= h << 13;                                                          \
        h ^= h >> 7;                                                           \
        h ^= h << 17;                                                          \
    } while (0)
    MIX(A); MIX(X); MIX(Y); MIX(SP); MIX(P); MIX(pc);
    for (int64_t i = 0; i < 512; i++) MIX(mem[i & 0xFFFF]);
#undef MIX
    return (int64_t)h;
}

/* ================= test-program entry functions =================
 * Each: calloc 64 KB, load a hand-assembled ROM (constant-index stores),
 * inject `seed` where the program reads it, run the core, free, return the
 * selected observable. `seed` is the C parameter NAME the harness keys on.
 */

/* Demo / STEP-1 de-risk entry: a data-dependent loop (acc += 5, n times, n at
 * $20) driven by the guest's OWN backward BNE branch, with an X down-counter.
 * This is the entry that first proved the `switch` decode survives extraction.
 * Returns a full state checksum (mode 0). The exact ROM is loaded below. */
int64_t cpu6502_run(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    /* Guest program: acc(=$22) += 5, n times (n at $20); counter DOWN in X.
     * acc is initialised BEFORE LDX $20 so the Z flag the BEQ tests reflects
     * (n == 0), not the LDA #$00. */
    /*  $00 A9 00     LDA #$00       ; acc = 0                                */
    /*  $02 85 22     STA $22                                                 */
    /*  $04 A6 20     LDX $20        ; X = n  (sets Z iff n==0)               */
    /*  $06 F0 0A     BEQ end ($12)  ; if n==0 skip loop                      */
    /*  $08 A5 22     LDA $22  <-loop($08)                                    */
    /*  $0A 18        CLC                                                     */
    /*  $0B 69 05     ADC #$05                                                */
    /*  $0D 85 22     STA $22                                                 */
    /*  $0F CA        DEX                                                     */
    /*  $10 D0 F6     BNE loop (rel = -10 -> back to $08)                     */
    /*  $12 A5 22     LDA $22  end($12)                                       */
    /*  $14 00        BRK                                                     */
    mem[0x00] = 0xA9; mem[0x01] = 0x00;
    mem[0x02] = 0x85; mem[0x03] = 0x22;
    mem[0x04] = 0xA6; mem[0x05] = 0x20;
    mem[0x06] = 0xF0; mem[0x07] = 0x0A; /* BEQ +10 -> $12 (from $08)          */
    mem[0x08] = 0xA5; mem[0x09] = 0x22;
    mem[0x0A] = 0x18;
    mem[0x0B] = 0x69; mem[0x0C] = 0x05;
    mem[0x0D] = 0x85; mem[0x0E] = 0x22;
    mem[0x0F] = 0xCA;
    mem[0x10] = 0xD0; mem[0x11] = 0xF6; /* BNE -10 -> $08 (from $12)          */
    mem[0x12] = 0xA5; mem[0x13] = 0x22;
    mem[0x14] = 0x00;                   /* BRK                                */

    mem[0x20] = (uint8_t)(seed & 0xFF); /* inject n                          */

    int64_t r = cpu6502_core(mem, 0, 4000, 0);
    free(mem);
    return r;
}

/* ---------------------------------------------------------------------------
 * STEP-2 opcode-group programs. Convention: the seed is injected at zero-page
 * $40 (clear of every ROM, which all end well below $40); results land in
 * $20..$2F, inside the mode-0 checksum window ($0000-$01FF). Programs use ONLY
 * the Step-1 opcode set. Each is small (< 1 page) and CONTIGUOUS (a gap would
 * read as 0x00 == BRK and halt early).
 * ------------------------------------------------------------------------- */

/* LDA #/zp/abs, LDX #/zp, LDY #, STA zp/abs. */
int64_t test_loadstore(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA9; mem[0x01] = 0xAB;       /* LDA #$AB                     */
    mem[0x02] = 0x85; mem[0x03] = 0x20;       /* STA $20                      */
    mem[0x04] = 0xA5; mem[0x05] = 0x40;       /* LDA $40  (seed)              */
    mem[0x06] = 0x85; mem[0x07] = 0x21;       /* STA $21                      */
    mem[0x08] = 0x8D; mem[0x09] = 0x00; mem[0x0A] = 0x03; /* STA $0300        */
    mem[0x0B] = 0xAD; mem[0x0C] = 0x00; mem[0x0D] = 0x03; /* LDA $0300        */
    mem[0x0E] = 0x85; mem[0x0F] = 0x22;       /* STA $22                      */
    mem[0x10] = 0xA6; mem[0x11] = 0x40;       /* LDX $40                      */
    mem[0x12] = 0xA0; mem[0x13] = 0x3C;       /* LDY #$3C                     */
    mem[0x14] = 0x8A;                          /* TXA                          */
    mem[0x15] = 0x85; mem[0x16] = 0x23;       /* STA $23                      */
    mem[0x17] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 2000, 0);
    free(mem);
    return r;
}

/* ADC #/zp, CLC/SEC (carry + overflow flag paths). */
int64_t test_adc(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x40;       /* LDA $40                      */
    mem[0x02] = 0x18;                          /* CLC                          */
    mem[0x03] = 0x69; mem[0x04] = 0x7F;       /* ADC #$7F                     */
    mem[0x05] = 0x85; mem[0x06] = 0x20;       /* STA $20                      */
    mem[0x07] = 0x38;                          /* SEC                          */
    mem[0x08] = 0x69; mem[0x09] = 0x01;       /* ADC #$01 (+carry)            */
    mem[0x0A] = 0x85; mem[0x0B] = 0x21;       /* STA $21                      */
    mem[0x0C] = 0xA9; mem[0x0D] = 0x05;       /* LDA #$05                     */
    mem[0x0E] = 0x85; mem[0x0F] = 0x31;       /* STA $31 (=5)                 */
    mem[0x10] = 0xA5; mem[0x11] = 0x40;       /* LDA $40                      */
    mem[0x12] = 0x18;                          /* CLC                          */
    mem[0x13] = 0x65; mem[0x14] = 0x31;       /* ADC $31 (zp)                 */
    mem[0x15] = 0x85; mem[0x16] = 0x22;       /* STA $22                      */
    mem[0x17] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 2000, 0);
    free(mem);
    return r;
}

/* SBC #, SEC/CLC (borrow paths). */
int64_t test_sbc(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x40;       /* LDA $40                      */
    mem[0x02] = 0x38;                          /* SEC                          */
    mem[0x03] = 0xE9; mem[0x04] = 0x10;       /* SBC #$10                     */
    mem[0x05] = 0x85; mem[0x06] = 0x20;       /* STA $20                      */
    mem[0x07] = 0x18;                          /* CLC (force a borrow)         */
    mem[0x08] = 0xE9; mem[0x09] = 0x01;       /* SBC #$01                     */
    mem[0x0A] = 0x85; mem[0x0B] = 0x21;       /* STA $21                      */
    mem[0x0C] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 2000, 0);
    free(mem);
    return r;
}

/* AND #/ORA #/EOR #. */
int64_t test_logic(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x40;       /* LDA $40                      */
    mem[0x02] = 0x29; mem[0x03] = 0x0F;       /* AND #$0F                     */
    mem[0x04] = 0x85; mem[0x05] = 0x20;       /* STA $20                      */
    mem[0x06] = 0xA5; mem[0x07] = 0x40;       /* LDA $40                      */
    mem[0x08] = 0x09; mem[0x09] = 0xF0;       /* ORA #$F0                     */
    mem[0x0A] = 0x85; mem[0x0B] = 0x21;       /* STA $21                      */
    mem[0x0C] = 0xA5; mem[0x0D] = 0x40;       /* LDA $40                      */
    mem[0x0E] = 0x49; mem[0x0F] = 0xFF;       /* EOR #$FF                     */
    mem[0x10] = 0x85; mem[0x11] = 0x22;       /* STA $22                      */
    mem[0x12] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 2000, 0);
    free(mem);
    return r;
}

/* CMP # + BEQ/BNE/BCC/BCS (all four branch conditions, both taken/not). */
int64_t test_cmp_branch(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x40;       /* LDA $40                      */
    mem[0x02] = 0xC9; mem[0x03] = 0x20;       /* CMP #$20                     */
    mem[0x04] = 0x90; mem[0x05] = 0x04;       /* BCC $0A (seed<0x20)          */
    mem[0x06] = 0xA9; mem[0x07] = 0xAA;       /* LDA #$AA                     */
    mem[0x08] = 0xD0; mem[0x09] = 0x02;       /* BNE $0C                      */
    mem[0x0A] = 0xA9; mem[0x0B] = 0x55;       /* LDA #$55  (lt)               */
    mem[0x0C] = 0x85; mem[0x0D] = 0x20;       /* STA $20  (done)              */
    mem[0x0E] = 0xA5; mem[0x0F] = 0x40;       /* LDA $40                      */
    mem[0x10] = 0xC9; mem[0x11] = 0x10;       /* CMP #$10                     */
    mem[0x12] = 0xF0; mem[0x13] = 0x04;       /* BEQ $18                      */
    mem[0x14] = 0xA9; mem[0x15] = 0x01;       /* LDA #$01                     */
    mem[0x16] = 0xD0; mem[0x17] = 0x02;       /* BNE $1A                      */
    mem[0x18] = 0xA9; mem[0x19] = 0x99;       /* LDA #$99  (eq)               */
    mem[0x1A] = 0x85; mem[0x1B] = 0x21;       /* STA $21                      */
    mem[0x1C] = 0xB0; mem[0x1D] = 0x02;       /* BCS $20 (carry from CMP)     */
    mem[0x1E] = 0xA9; mem[0x1F] = 0x7E;       /* LDA #$7E                     */
    mem[0x20] = 0x85; mem[0x21] = 0x22;       /* STA $22                      */
    mem[0x22] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 2000, 0);
    free(mem);
    return r;
}

/* TAX/TXA/TAY/TYA. */
int64_t test_transfers(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x40;       /* LDA $40                      */
    mem[0x02] = 0xAA;                          /* TAX                          */
    mem[0x03] = 0xE8;                          /* INX                          */
    mem[0x04] = 0x8A;                          /* TXA                          */
    mem[0x05] = 0xA8;                          /* TAY                          */
    mem[0x06] = 0xC8;                          /* INY                          */
    mem[0x07] = 0x98;                          /* TYA                          */
    mem[0x08] = 0x85; mem[0x09] = 0x20;       /* STA $20                      */
    mem[0x0A] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 2000, 0);
    free(mem);
    return r;
}

/* INX/DEX/INY/DEY (incl. wrap). */
int64_t test_incdec(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA6; mem[0x01] = 0x40;       /* LDX $40                      */
    mem[0x02] = 0xA0; mem[0x03] = 0x00;       /* LDY #$00                     */
    mem[0x04] = 0xE8;                          /* INX                          */
    mem[0x05] = 0xCA;                          /* DEX                          */
    mem[0x06] = 0xCA;                          /* DEX                          */
    mem[0x07] = 0xC8;                          /* INY                          */
    mem[0x08] = 0x88;                          /* DEY                          */
    mem[0x09] = 0x88;                          /* DEY (wrap 0 -> 0xFF)         */
    mem[0x0A] = 0x8A;                          /* TXA                          */
    mem[0x0B] = 0x85; mem[0x0C] = 0x20;       /* STA $20                      */
    mem[0x0D] = 0x98;                          /* TYA                          */
    mem[0x0E] = 0x85; mem[0x0F] = 0x21;       /* STA $21                      */
    mem[0x10] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 2000, 0);
    free(mem);
    return r;
}

/* JMP abs (must skip the bytes between the jump and its target). */
int64_t test_jmp(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA9; mem[0x01] = 0x11;       /* LDA #$11                     */
    mem[0x02] = 0x4C; mem[0x03] = 0x08; mem[0x04] = 0x00; /* JMP $0008        */
    mem[0x05] = 0xA9; mem[0x06] = 0xFF;       /* LDA #$FF (skipped)           */
    mem[0x07] = 0x00;                          /* BRK (skipped)                */
    mem[0x08] = 0x85; mem[0x09] = 0x20;       /* STA $20  (target; A=0x11)    */
    mem[0x0A] = 0xA5; mem[0x0B] = 0x40;       /* LDA $40                      */
    mem[0x0C] = 0x85; mem[0x0D] = 0x21;       /* STA $21                      */
    mem[0x0E] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 2000, 0);
    free(mem);
    return r;
}

/* ------------------- KNOWN-ANSWER (6502-semantics) programs -------------------
 * These return a single register (mode 1 = A) whose correct 6502 value is a
 * closed formula of `seed`, so the harness asserts native==VM AND ==formula —
 * catching a semantic opcode bug that native==VM alone cannot (both run this C).
 */

/* A = (seed + 5) & 0xFF. */
int64_t test_adc_known(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x40;       /* LDA $40                      */
    mem[0x02] = 0x18;                          /* CLC                          */
    mem[0x03] = 0x69; mem[0x04] = 0x05;       /* ADC #$05                     */
    mem[0x05] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 100, 1); /* mode 1 -> return A           */
    free(mem);
    return r;
}

/* A = (seed - 0x10) & 0xFF  (SEC then SBC #$10). */
int64_t test_sub_known(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x40;       /* LDA $40                      */
    mem[0x02] = 0x38;                          /* SEC                          */
    mem[0x03] = 0xE9; mem[0x04] = 0x10;       /* SBC #$10                     */
    mem[0x05] = 0x00;                          /* BRK                          */
    mem[0x40] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 100, 1);
    free(mem);
    return r;
}

/* A = (5 * seed) & 0xFF  — the data-dependent loop, returned as A (mode 1). */
int64_t test_countdown(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA9; mem[0x01] = 0x00;       /* LDA #$00                     */
    mem[0x02] = 0x85; mem[0x03] = 0x22;       /* STA $22 (acc=0)              */
    mem[0x04] = 0xA6; mem[0x05] = 0x20;       /* LDX $20 (X=n)                */
    mem[0x06] = 0xF0; mem[0x07] = 0x0A;       /* BEQ $12                      */
    mem[0x08] = 0xA5; mem[0x09] = 0x22;       /* LDA $22  <-loop              */
    mem[0x0A] = 0x18;                          /* CLC                          */
    mem[0x0B] = 0x69; mem[0x0C] = 0x05;       /* ADC #$05                     */
    mem[0x0D] = 0x85; mem[0x0E] = 0x22;       /* STA $22                      */
    mem[0x0F] = 0xCA;                          /* DEX                          */
    mem[0x10] = 0xD0; mem[0x11] = 0xF6;       /* BNE $08                      */
    mem[0x12] = 0xA5; mem[0x13] = 0x22;       /* LDA $22                      */
    mem[0x14] = 0x00;                          /* BRK                          */
    mem[0x20] = (uint8_t)(seed & 0xFF);        /* n at $20                     */
    int64_t r = cpu6502_core(mem, 0, 4000, 1);
    free(mem);
    return r;
}

/* ===========================================================================
 * STEP-3 opcode-group programs (mode-0 checksum over the widened $0000-$01FF
 * window). Memory map: ROM $00-$5F, seed at $60, scratch/pointers $70-$7F,
 * result cells $80-$8F, far demo pages $0300-$06FF (copied back into $80..$8F
 * so their effects land in the checksum window). ROMs stay CONTIGUOUS through
 * their reachable control flow (unreached gaps are 0x00 == BRK, only safe when
 * a JMP/JSR routes around them).
 * ======================================================================= */

/* Indexed + indirect addressing: zp,X / abs,X / abs,Y / zp,Y / (ind,X)/(ind),Y. */
int64_t test_addr_modes(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA2; mem[0x01] = 0x03;               /* LDX #$03            */
    mem[0x02] = 0xA0; mem[0x03] = 0x02;               /* LDY #$02            */
    mem[0x04] = 0xA5; mem[0x05] = 0x60;               /* LDA $60 (seed)      */
    mem[0x06] = 0x95; mem[0x07] = 0x80;               /* STA $80,X -> $83    */
    mem[0x08] = 0x9D; mem[0x09] = 0x00; mem[0x0A] = 0x03; /* STA $0300,X     */
    mem[0x0B] = 0x99; mem[0x0C] = 0x00; mem[0x0D] = 0x04; /* STA $0400,Y     */
    mem[0x0E] = 0xB5; mem[0x0F] = 0x80;               /* LDA $80,X -> $83    */
    mem[0x10] = 0x85; mem[0x11] = 0x88;               /* STA $88             */
    mem[0x12] = 0xBD; mem[0x13] = 0x00; mem[0x14] = 0x03; /* LDA $0300,X     */
    mem[0x15] = 0x85; mem[0x16] = 0x89;               /* STA $89             */
    mem[0x17] = 0xB9; mem[0x18] = 0x00; mem[0x19] = 0x04; /* LDA $0400,Y     */
    mem[0x1A] = 0x85; mem[0x1B] = 0x8A;               /* STA $8A             */
    mem[0x1C] = 0xA9; mem[0x1D] = 0x00;               /* LDA #$00            */
    mem[0x1E] = 0x85; mem[0x1F] = 0x70;               /* STA $70 (ptr lo)    */
    mem[0x20] = 0xA9; mem[0x21] = 0x05;               /* LDA #$05            */
    mem[0x22] = 0x85; mem[0x23] = 0x71;               /* STA $71 -> $0500    */
    mem[0x24] = 0xA5; mem[0x25] = 0x60;               /* LDA $60             */
    mem[0x26] = 0x91; mem[0x27] = 0x70;               /* STA ($70),Y ->$0502 */
    mem[0x28] = 0xB1; mem[0x29] = 0x70;               /* LDA ($70),Y         */
    mem[0x2A] = 0x85; mem[0x2B] = 0x8B;               /* STA $8B             */
    mem[0x2C] = 0xA9; mem[0x2D] = 0x00;               /* LDA #$00            */
    mem[0x2E] = 0x85; mem[0x2F] = 0x73;               /* STA $73             */
    mem[0x30] = 0xA9; mem[0x31] = 0x06;               /* LDA #$06            */
    mem[0x32] = 0x85; mem[0x33] = 0x74;               /* STA $74 -> $0600    */
    mem[0x34] = 0xA5; mem[0x35] = 0x60;               /* LDA $60             */
    mem[0x36] = 0x81; mem[0x37] = 0x70;               /* STA ($70,X)->$0600  */
    mem[0x38] = 0xA1; mem[0x39] = 0x70;               /* LDA ($70,X)         */
    mem[0x3A] = 0x85; mem[0x3B] = 0x8C;               /* STA $8C             */
    mem[0x3C] = 0xA6; mem[0x3D] = 0x60;               /* LDX $60 (X=seed)    */
    mem[0x3E] = 0x96; mem[0x3F] = 0x80;               /* STX $80,Y -> $82    */
    mem[0x40] = 0xB6; mem[0x41] = 0x80;               /* LDX $80,Y -> $82    */
    mem[0x42] = 0x8A;                                  /* TXA                 */
    mem[0x43] = 0x85; mem[0x44] = 0x8D;               /* STA $8D             */
    mem[0x45] = 0x00;                                  /* BRK                 */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* INC/DEC memory (zp, zp,X, abs, abs,X) + STX/STY (zp, abs, indexed). */
int64_t test_memrmw(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60;               /* LDA $60             */
    mem[0x02] = 0x85; mem[0x03] = 0x80;               /* STA $80             */
    mem[0x04] = 0xE6; mem[0x05] = 0x80;               /* INC $80             */
    mem[0x06] = 0xC6; mem[0x07] = 0x80;               /* DEC $80             */
    mem[0x08] = 0xE6; mem[0x09] = 0x80;               /* INC $80             */
    mem[0x0A] = 0xA2; mem[0x0B] = 0x02;               /* LDX #$02            */
    mem[0x0C] = 0xF6; mem[0x0D] = 0x7E;               /* INC $7E,X -> $80    */
    mem[0x0E] = 0xD6; mem[0x0F] = 0x7E;               /* DEC $7E,X -> $80    */
    mem[0x10] = 0xA5; mem[0x11] = 0x60;               /* LDA $60             */
    mem[0x12] = 0x8D; mem[0x13] = 0x00; mem[0x14] = 0x03; /* STA $0300       */
    mem[0x15] = 0xEE; mem[0x16] = 0x00; mem[0x17] = 0x03; /* INC $0300       */
    mem[0x18] = 0xCE; mem[0x19] = 0x00; mem[0x1A] = 0x03; /* DEC $0300       */
    mem[0x1B] = 0xFE; mem[0x1C] = 0x00; mem[0x1D] = 0x03; /* INC $0300,X     */
    mem[0x1E] = 0xDE; mem[0x1F] = 0x00; mem[0x20] = 0x03; /* DEC $0300,X     */
    mem[0x21] = 0xA6; mem[0x22] = 0x60;               /* LDX $60            */
    mem[0x23] = 0x86; mem[0x24] = 0x82;               /* STX $82            */
    mem[0x25] = 0x8E; mem[0x26] = 0x01; mem[0x27] = 0x03; /* STX $0301      */
    mem[0x28] = 0xA4; mem[0x29] = 0x60;               /* LDY $60            */
    mem[0x2A] = 0x84; mem[0x2B] = 0x83;               /* STY $83            */
    mem[0x2C] = 0x8C; mem[0x2D] = 0x02; mem[0x2E] = 0x03; /* STY $0302      */
    mem[0x2F] = 0xAD; mem[0x30] = 0x00; mem[0x31] = 0x03; /* LDA $0300      */
    mem[0x32] = 0x85; mem[0x33] = 0x84;               /* STA $84            */
    mem[0x34] = 0xAD; mem[0x35] = 0x01; mem[0x36] = 0x03; /* LDA $0301      */
    mem[0x37] = 0x85; mem[0x38] = 0x85;               /* STA $85            */
    mem[0x39] = 0xAD; mem[0x3A] = 0x02; mem[0x3B] = 0x03; /* LDA $0302      */
    mem[0x3C] = 0x85; mem[0x3D] = 0x86;               /* STA $86            */
    mem[0x3E] = 0x00;                                  /* BRK                */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* ASL/LSR/ROL/ROR on the accumulator and on memory (zp + abs + abs,X). */
int64_t test_shifts(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60; mem[0x02] = 0x0A; mem[0x03] = 0x85; mem[0x04] = 0x80; /* LDA;ASL A;STA $80 */
    mem[0x05] = 0xA5; mem[0x06] = 0x60; mem[0x07] = 0x4A; mem[0x08] = 0x85; mem[0x09] = 0x81; /* LDA;LSR A;STA $81 */
    mem[0x0A] = 0xA5; mem[0x0B] = 0x60; mem[0x0C] = 0x38; mem[0x0D] = 0x2A; mem[0x0E] = 0x85; mem[0x0F] = 0x82; /* LDA;SEC;ROL A;STA $82 */
    mem[0x10] = 0xA5; mem[0x11] = 0x60; mem[0x12] = 0x38; mem[0x13] = 0x6A; mem[0x14] = 0x85; mem[0x15] = 0x83; /* LDA;SEC;ROR A;STA $83 */
    mem[0x16] = 0xA5; mem[0x17] = 0x60; mem[0x18] = 0x85; mem[0x19] = 0x84; mem[0x1A] = 0x06; mem[0x1B] = 0x84; /* STA $84;ASL $84 */
    mem[0x1C] = 0xA5; mem[0x1D] = 0x60; mem[0x1E] = 0x85; mem[0x1F] = 0x85; mem[0x20] = 0x46; mem[0x21] = 0x85; /* STA $85;LSR $85 */
    mem[0x22] = 0xA5; mem[0x23] = 0x60; mem[0x24] = 0x85; mem[0x25] = 0x86; mem[0x26] = 0x18; mem[0x27] = 0x26; mem[0x28] = 0x86; /* STA $86;CLC;ROL $86 */
    mem[0x29] = 0xA5; mem[0x2A] = 0x60; mem[0x2B] = 0x85; mem[0x2C] = 0x87; mem[0x2D] = 0x66; mem[0x2E] = 0x87; /* STA $87;ROR $87 */
    mem[0x2F] = 0xA5; mem[0x30] = 0x60; mem[0x31] = 0x8D; mem[0x32] = 0x00; mem[0x33] = 0x03; /* STA $0300 */
    mem[0x34] = 0x0E; mem[0x35] = 0x00; mem[0x36] = 0x03;                                     /* ASL $0300 */
    mem[0x37] = 0xA2; mem[0x38] = 0x01; mem[0x39] = 0x1E; mem[0x3A] = 0x00; mem[0x3B] = 0x03; /* LDX #1;ASL $0300,X */
    mem[0x3C] = 0xAD; mem[0x3D] = 0x00; mem[0x3E] = 0x03; mem[0x3F] = 0x85; mem[0x40] = 0x88; /* LDA $0300;STA $88 */
    mem[0x41] = 0x00;                                                                          /* BRK */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* PHA/PLA/PHP/PLP + TSX/TXS (stack lives in the $0100 page, in-window). */
int64_t test_stack(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60;               /* LDA $60             */
    mem[0x02] = 0x48;                                  /* PHA (seed)          */
    mem[0x03] = 0xA9; mem[0x04] = 0xAA;               /* LDA #$AA            */
    mem[0x05] = 0x48;                                  /* PHA (0xAA)          */
    mem[0x06] = 0x68;                                  /* PLA -> A=0xAA       */
    mem[0x07] = 0x85; mem[0x08] = 0x80;               /* STA $80             */
    mem[0x09] = 0x68;                                  /* PLA -> A=seed       */
    mem[0x0A] = 0x85; mem[0x0B] = 0x81;               /* STA $81             */
    mem[0x0C] = 0x38;                                  /* SEC                 */
    mem[0x0D] = 0x08;                                  /* PHP                 */
    mem[0x0E] = 0x18;                                  /* CLC                 */
    mem[0x0F] = 0x28;                                  /* PLP (restore C=1)   */
    mem[0x10] = 0xA9; mem[0x11] = 0x00;               /* LDA #$00            */
    mem[0x12] = 0xB0; mem[0x13] = 0x02;               /* BCS $16             */
    mem[0x14] = 0xA9; mem[0x15] = 0xEE;               /* LDA #$EE            */
    mem[0x16] = 0x85; mem[0x17] = 0x82;               /* STA $82             */
    mem[0x18] = 0xBA;                                  /* TSX                 */
    mem[0x19] = 0x86; mem[0x1A] = 0x83;               /* STX $83             */
    mem[0x1B] = 0xA2; mem[0x1C] = 0xF0;               /* LDX #$F0            */
    mem[0x1D] = 0x9A;                                  /* TXS                 */
    mem[0x1E] = 0xBA;                                  /* TSX                 */
    mem[0x1F] = 0x86; mem[0x20] = 0x84;               /* STX $84             */
    mem[0x21] = 0x00;                                  /* BRK                 */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* JSR/RTS subroutine calls (return addresses on the hardware stack). */
int64_t test_jsr_rts(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60;               /* LDA $60             */
    mem[0x02] = 0x20; mem[0x03] = 0x20; mem[0x04] = 0x00; /* JSR $0020        */
    mem[0x05] = 0x85; mem[0x06] = 0x80;               /* STA $80 (seed+5)    */
    mem[0x07] = 0x20; mem[0x08] = 0x20; mem[0x09] = 0x00; /* JSR $0020        */
    mem[0x0A] = 0x85; mem[0x0B] = 0x81;               /* STA $81 (seed+10)   */
    mem[0x0C] = 0x20; mem[0x0D] = 0x30; mem[0x0E] = 0x00; /* JSR $0030 (INX)  */
    mem[0x0F] = 0x86; mem[0x10] = 0x82;               /* STX $82             */
    mem[0x11] = 0x4C; mem[0x12] = 0x40; mem[0x13] = 0x00; /* JMP $0040        */
    mem[0x20] = 0x18; mem[0x21] = 0x69; mem[0x22] = 0x05; mem[0x23] = 0x60;   /* sub: CLC;ADC #5;RTS */
    mem[0x30] = 0xE8; mem[0x31] = 0x60;               /* sub2: INX;RTS       */
    mem[0x40] = 0xA9; mem[0x41] = 0x5A; mem[0x42] = 0x85; mem[0x43] = 0x83; mem[0x44] = 0x00; /* LDA #$5A;STA $83;BRK */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* CPX/CPY (all modes) + BIT (zp + abs); flags captured via PHP/PLA. */
int64_t test_cpxy_bit(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA6; mem[0x01] = 0x60;               /* LDX $60             */
    mem[0x02] = 0xE0; mem[0x03] = 0x20;               /* CPX #$20            */
    mem[0x04] = 0xA9; mem[0x05] = 0x00;               /* LDA #$00            */
    mem[0x06] = 0x90; mem[0x07] = 0x02;               /* BCC $0A             */
    mem[0x08] = 0xA9; mem[0x09] = 0x01;               /* LDA #$01            */
    mem[0x0A] = 0x85; mem[0x0B] = 0x80;               /* STA $80             */
    mem[0x0C] = 0xA9; mem[0x0D] = 0x30;               /* LDA #$30            */
    mem[0x0E] = 0x85; mem[0x0F] = 0x70;               /* STA $70 (=0x30)     */
    mem[0x10] = 0xE4; mem[0x11] = 0x70;               /* CPX $70 (zp)        */
    mem[0x12] = 0xA9; mem[0x13] = 0x00;               /* LDA #$00            */
    mem[0x14] = 0xF0; mem[0x15] = 0x02;               /* BEQ $18             */
    mem[0x16] = 0xA9; mem[0x17] = 0x02;               /* LDA #$02            */
    mem[0x18] = 0x85; mem[0x19] = 0x81;               /* STA $81             */
    mem[0x1A] = 0xEC; mem[0x1B] = 0x70; mem[0x1C] = 0x00; /* CPX $0070 (abs) */
    mem[0x1D] = 0x08; mem[0x1E] = 0x68; mem[0x1F] = 0x85; mem[0x20] = 0x82;   /* PHP;PLA;STA $82 */
    mem[0x21] = 0xA4; mem[0x22] = 0x60;               /* LDY $60             */
    mem[0x23] = 0xC0; mem[0x24] = 0x10;               /* CPY #$10            */
    mem[0x25] = 0xA9; mem[0x26] = 0x00;               /* LDA #$00            */
    mem[0x27] = 0xB0; mem[0x28] = 0x02;               /* BCS $2B             */
    mem[0x29] = 0xA9; mem[0x2A] = 0x03;               /* LDA #$03            */
    mem[0x2B] = 0x85; mem[0x2C] = 0x83;               /* STA $83             */
    mem[0x2D] = 0xC4; mem[0x2E] = 0x60;               /* CPY $60 (zp)        */
    mem[0x2F] = 0x08; mem[0x30] = 0x68; mem[0x31] = 0x85; mem[0x32] = 0x84;   /* PHP;PLA;STA $84 */
    mem[0x33] = 0xA9; mem[0x34] = 0xC0;               /* LDA #$C0            */
    mem[0x35] = 0x85; mem[0x36] = 0x71;               /* STA $71 (=0xC0)     */
    mem[0x37] = 0xA5; mem[0x38] = 0x60;               /* LDA $60             */
    mem[0x39] = 0x24; mem[0x3A] = 0x71;               /* BIT $71 (zp)        */
    mem[0x3B] = 0x08; mem[0x3C] = 0x68; mem[0x3D] = 0x85; mem[0x3E] = 0x85;   /* PHP;PLA;STA $85 */
    mem[0x3F] = 0x2C; mem[0x40] = 0x71; mem[0x41] = 0x00; /* BIT $0071 (abs) */
    mem[0x42] = 0x08; mem[0x43] = 0x68; mem[0x44] = 0x85; mem[0x45] = 0x86;   /* PHP;PLA;STA $86 */
    mem[0x46] = 0x00;                                  /* BRK                 */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* Flag ops SEC/CLC/SEI/CLI/SED/CLD/CLV — observed by pushing P (PHP/PLA). */
int64_t test_flags(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60;               /* LDA $60             */
    mem[0x02] = 0x38;                                  /* SEC                 */
    mem[0x03] = 0xF8;                                  /* SED                 */
    mem[0x04] = 0x78;                                  /* SEI                 */
    mem[0x05] = 0xA9; mem[0x06] = 0x40;               /* LDA #$40            */
    mem[0x07] = 0x85; mem[0x08] = 0x70;               /* STA $70             */
    mem[0x09] = 0x24; mem[0x0A] = 0x70;               /* BIT $70 (V<-1)      */
    mem[0x0B] = 0x08; mem[0x0C] = 0x68; mem[0x0D] = 0x85; mem[0x0E] = 0x80;   /* PHP;PLA;STA $80 */
    mem[0x0F] = 0x18;                                  /* CLC                 */
    mem[0x10] = 0xD8;                                  /* CLD                 */
    mem[0x11] = 0x58;                                  /* CLI                 */
    mem[0x12] = 0xB8;                                  /* CLV                 */
    mem[0x13] = 0x08; mem[0x14] = 0x68; mem[0x15] = 0x85; mem[0x16] = 0x81;   /* PHP;PLA;STA $81 */
    mem[0x17] = 0x00;                                  /* BRK                 */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* JMP (indirect): a vector at $0300 -> $0040; must land at $40, not fall through. */
int64_t test_indirect(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA9; mem[0x01] = 0x40;               /* LDA #$40            */
    mem[0x02] = 0x8D; mem[0x03] = 0x00; mem[0x04] = 0x03; /* STA $0300 (lo)   */
    mem[0x05] = 0xA9; mem[0x06] = 0x00;               /* LDA #$00            */
    mem[0x07] = 0x8D; mem[0x08] = 0x01; mem[0x09] = 0x03; /* STA $0301 (hi)   */
    mem[0x0A] = 0xA5; mem[0x0B] = 0x60;               /* LDA $60 (seed)      */
    mem[0x0C] = 0x6C; mem[0x0D] = 0x00; mem[0x0E] = 0x03; /* JMP ($0300)      */
    mem[0x0F] = 0xA9; mem[0x10] = 0xFF;               /* LDA #$FF (skipped)  */
    mem[0x11] = 0x85; mem[0x12] = 0x80;               /* STA $80  (skipped)  */
    mem[0x13] = 0x00;                                  /* BRK      (skipped)  */
    mem[0x40] = 0x85; mem[0x41] = 0x81;               /* target: STA $81     */
    mem[0x42] = 0xA9; mem[0x43] = 0x5A;               /* LDA #$5A            */
    mem[0x44] = 0x85; mem[0x45] = 0x82;               /* STA $82             */
    mem[0x46] = 0x00;                                  /* BRK                 */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* Branches BPL/BMI/BVC/BVS (sign + overflow condition paths). */
int64_t test_branches2(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60;               /* LDA $60 (sets N)    */
    mem[0x02] = 0xA2; mem[0x03] = 0x00;               /* LDX #$00            */
    mem[0x04] = 0x10; mem[0x05] = 0x02;               /* BPL $08             */
    mem[0x06] = 0xA2; mem[0x07] = 0x01;               /* LDX #$01 (negative) */
    mem[0x08] = 0x86; mem[0x09] = 0x80;               /* STX $80             */
    mem[0x0A] = 0xA5; mem[0x0B] = 0x60;               /* LDA $60             */
    mem[0x0C] = 0xA0; mem[0x0D] = 0x00;               /* LDY #$00            */
    mem[0x0E] = 0x30; mem[0x0F] = 0x02;               /* BMI $12             */
    mem[0x10] = 0xA0; mem[0x11] = 0x02;               /* LDY #$02 (positive) */
    mem[0x12] = 0x84; mem[0x13] = 0x81;               /* STY $81             */
    mem[0x14] = 0xA5; mem[0x15] = 0x60;               /* LDA $60             */
    mem[0x16] = 0x18;                                  /* CLC                 */
    mem[0x17] = 0x69; mem[0x18] = 0x60;               /* ADC #$60 (may V)    */
    mem[0x19] = 0xA9; mem[0x1A] = 0x00;               /* LDA #$00            */
    mem[0x1B] = 0x50; mem[0x1C] = 0x02;               /* BVC $1F             */
    mem[0x1D] = 0xA9; mem[0x1E] = 0x01;               /* LDA #$01 (V set)    */
    mem[0x1F] = 0x85; mem[0x20] = 0x82;               /* STA $82             */
    mem[0x21] = 0xA5; mem[0x22] = 0x60;               /* LDA $60             */
    mem[0x23] = 0x18;                                  /* CLC                 */
    mem[0x24] = 0x69; mem[0x25] = 0x60;               /* ADC #$60            */
    mem[0x26] = 0xA9; mem[0x27] = 0x00;               /* LDA #$00            */
    mem[0x28] = 0x70; mem[0x29] = 0x02;               /* BVS $2C             */
    mem[0x2A] = 0xA9; mem[0x2B] = 0x02;               /* LDA #$02 (V clear)  */
    mem[0x2C] = 0x85; mem[0x2D] = 0x83;               /* STA $83             */
    mem[0x2E] = 0x00;                                  /* BRK                 */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 3000, 0);
    free(mem);
    return r;
}

/* --------- STEP-3 known-answer (semantics) programs (mode 1 = return A) ------ */

/* A = (seed << 1) & 0xFF  (ASL A). */
int64_t test_asl_known(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60;               /* LDA $60             */
    mem[0x02] = 0x0A;                                  /* ASL A               */
    mem[0x03] = 0x00;                                  /* BRK                 */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 100, 1);
    free(mem);
    return r;
}

/* A = (seed & 0xFF) >> 1  (LSR A, logical). */
int64_t test_lsr_known(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60;               /* LDA $60             */
    mem[0x02] = 0x4A;                                  /* LSR A               */
    mem[0x03] = 0x00;                                  /* BRK                 */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 100, 1);
    free(mem);
    return r;
}

/* A = (seed + 10) & 0xFF via two JSRs to a "+5" subroutine (JSR/RTS semantics). */
int64_t test_jsr_known(int64_t seed) {
    uint8_t *mem = (uint8_t *)calloc(65536, 1);
    mem[0x00] = 0xA5; mem[0x01] = 0x60;               /* LDA $60             */
    mem[0x02] = 0x20; mem[0x03] = 0x10; mem[0x04] = 0x00; /* JSR $0010        */
    mem[0x05] = 0x20; mem[0x06] = 0x10; mem[0x07] = 0x00; /* JSR $0010        */
    mem[0x08] = 0x00;                                  /* BRK                 */
    mem[0x10] = 0x18; mem[0x11] = 0x69; mem[0x12] = 0x05; mem[0x13] = 0x60;   /* CLC;ADC #5;RTS */
    mem[0x60] = (uint8_t)(seed & 0xFF);
    int64_t r = cpu6502_core(mem, 0, 200, 1);
    free(mem);
    return r;
}
