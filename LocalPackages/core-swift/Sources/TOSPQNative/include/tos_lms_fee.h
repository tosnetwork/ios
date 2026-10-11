#ifndef TOS_LMS_FEE_H
#define TOS_LMS_FEE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int tos_wallet_lms_fee_verify(uint32_t leaf,const unsigned char *digest,size_t digest_size,const unsigned char *signature,size_t signature_size,const unsigned char *key,size_t key_size);
/* Seed-to-enrollment binding only. This does not sign or establish journal continuity. */
int tos_wallet_lms_fee_bind_seed(const unsigned char *seed,size_t seed_size,uint32_t leaf,
    const unsigned char *path,size_t path_size,const unsigned char *key,size_t key_size);
/* Internal reserved-leaf primitive. Wallet code calls it only through the durable state callback. */
int tos_wallet_lms_fee_sign_reserved(const unsigned char *seed,size_t seed_size,uint32_t leaf,
    const unsigned char *digest,size_t digest_size,const unsigned char *path,size_t path_size,
    const unsigned char *key,size_t key_size,unsigned char *output,size_t output_size);
#ifdef __cplusplus
}
#endif
#endif
