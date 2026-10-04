#ifndef TOS_MOBILE_PQ_H
#define TOS_MOBILE_PQ_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Fixed profiles; all entropy comes from the caller's checked OS CSPRNG.
   Seed is 32 bytes. Expanded secrets never leave the native call. */
#define TOS_PQ_MLDSA44 1
#define TOS_PQ_FALCON512 2
size_t tos_pq_public_key_size(int algorithm);
size_t tos_pq_signature_size(int algorithm);
void tos_pq_clear(void *data, size_t size);
int tos_pq_public_key(int algorithm, const uint8_t *seed, size_t seed_size,
                      uint8_t *public_key, size_t public_key_size);
int tos_pq_sign(int algorithm, const uint8_t *seed, size_t seed_size,
                const uint8_t *entropy, size_t entropy_size,
                const uint8_t *message, size_t message_size,
                uint8_t *signature, size_t signature_size);
int tos_pq_verify(int algorithm, const uint8_t *public_key, size_t public_key_size,
                  const uint8_t *message, size_t message_size,
                  const uint8_t *signature, size_t signature_size);
#ifdef __cplusplus
}
#endif
#endif
