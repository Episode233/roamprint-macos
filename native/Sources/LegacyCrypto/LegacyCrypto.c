#include "include/LegacyCrypto.h"
#include "vendor/twofish.h"
#include "vendor/md5.h"
#include <pthread.h>

static pthread_once_t twofish_once = PTHREAD_ONCE_INIT;

static void initialise_twofish(void) { Twofish_initialise(); }

static void clear_memory(void *memory, size_t length) {
    volatile uint8_t *bytes = memory;
    while (length--) *bytes++ = 0;
}

int rp_twofish128_ecb(const uint8_t key[16], const uint8_t *input,
                     uint8_t *output, size_t length, int decrypt) {
    if (!key || !input || !output || length == 0 || length % 16 != 0)
        return 0;
    if (pthread_once(&twofish_once, initialise_twofish) != 0) return 0;
    Twofish_key expanded;
    uint8_t key_copy[16];
    for (size_t i = 0; i < 16; ++i) key_copy[i] = key[i];
    Twofish_prepare_key(key_copy, 16, &expanded);
    for (size_t offset = 0; offset < length; offset += 16) {
        if (decrypt) Twofish_decrypt(&expanded, (uint8_t *)input + offset, output + offset);
        else Twofish_encrypt(&expanded, (uint8_t *)input + offset, output + offset);
    }
    clear_memory(key_copy, sizeof key_copy);
    clear_memory(&expanded, sizeof expanded);
    return 1;
}

void rp_md5(const uint8_t *input, size_t length, uint8_t output[16]) {
    MD5_CTX context;
    md5_init(&context);
    if (length) md5_update(&context, input, length);
    md5_final(&context, output);
    clear_memory(&context, sizeof context);
}
