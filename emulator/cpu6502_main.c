/* cpu6502_main.c — native golden-master driver.
 *
 * Compiled WITH cpu6502.c into a native binary. Given a test-entry name and a
 * seed on argv, calls that entry and prints its int64 return as a signed
 * decimal (%lld). The Julia harness shells out to this binary to obtain the
 * golden value, then compares bit-for-bit against the BennettVM run of the
 * SAME entry (Rule 4). This file is NOT part of the .ll module (no printf/argv
 * in the extracted IR).
 *
 * The dispatch below is generated to match the entries defined in cpu6502.c;
 * add a line here whenever a new test_* entry is added there.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* One row per entry defined in cpu6502.c (kept in sync as entries are added). */
#define ENTRY_LIST(X)                                                          \
    X(cpu6502_run)                                                             \
    X(test_loadstore)                                                          \
    X(test_adc)                                                                \
    X(test_sbc)                                                                \
    X(test_logic)                                                              \
    X(test_cmp_branch)                                                         \
    X(test_transfers)                                                          \
    X(test_incdec)                                                             \
    X(test_jmp)                                                                \
    X(test_adc_known)                                                          \
    X(test_sub_known)                                                          \
    X(test_countdown)                                                          \
    X(test_addr_modes)                                                         \
    X(test_memrmw)                                                             \
    X(test_shifts)                                                             \
    X(test_stack)                                                              \
    X(test_jsr_rts)                                                            \
    X(test_cpxy_bit)                                                           \
    X(test_flags)                                                              \
    X(test_indirect)                                                           \
    X(test_branches2)                                                          \
    X(test_asl_known)                                                          \
    X(test_lsr_known)                                                          \
    X(test_jsr_known)

/* forward declarations */
#define DECL(name) int64_t name(int64_t seed);
ENTRY_LIST(DECL)
#undef DECL

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <entry> <seed>\n", argv[0]);
        return 2;
    }
    const char *name = argv[1];
    int64_t seed = (int64_t)strtoll(argv[2], NULL, 0);

#define DISPATCH(nm)                                                           \
    if (!strcmp(name, #nm)) { printf("%lld\n", (long long)nm(seed)); return 0; }
    ENTRY_LIST(DISPATCH)
#undef DISPATCH

    fprintf(stderr, "unknown entry: %s\n", name);
    return 3;
}
