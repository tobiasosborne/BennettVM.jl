/* main_golden.c — golden-master harness for hashtable.c. NOT part of the
 * fixture module (it does I/O via printf, which is forbidden inside the
 * closed-world fixture). It links against hashtable.c, runs the two drivers
 * for a fixed set of n, and prints one line per (driver, n) as:
 *
 *     basic <n> <checksum>
 *     grow  <n> <checksum>
 *
 * The native output of this program (compiled at -O2 and at -O0+sanitizers,
 * which must agree) is recorded in GOLDEN.txt and is the oracle CW-C3 checks
 * the BennettVM round-trip against.
 *
 * Ref: docs/adr/0017-closed-world-execution.md §Sequencing CW-C
 *   ("golden master against native execution").
 */

#include <stdint.h>
#include <stdio.h>

/* Declared here (no shared header — the fixture is a single TU by design). */
int64_t ht_demo_basic(int64_t n);
int64_t ht_demo_grow(int64_t n);

int main(void) {
    static const int64_t ns[] = {0, 1, 7, 64, 1000};
    const int count = (int)(sizeof(ns) / sizeof(ns[0]));
    for (int i = 0; i < count; i++) {
        printf("basic %lld %lld\n", (long long)ns[i],
               (long long)ht_demo_basic(ns[i]));
    }
    for (int i = 0; i < count; i++) {
        printf("grow %lld %lld\n", (long long)ns[i],
               (long long)ht_demo_grow(ns[i]));
    }
    return 0;
}
