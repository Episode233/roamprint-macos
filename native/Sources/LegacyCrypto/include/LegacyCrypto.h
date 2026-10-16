#ifndef ROAMPRINT_LEGACY_CRYPTO_H
#define ROAMPRINT_LEGACY_CRYPTO_H
#include <stddef.h>
#include <stdint.h>

/* Compatibility only: these primitives match the enterprise V5 protocol. */
int rp_twofish128_ecb(const uint8_t key[16], const uint8_t *input,
                     uint8_t *output, size_t length, int decrypt);
void rp_md5(const uint8_t *input, size_t length, uint8_t output[16]);
#endif
