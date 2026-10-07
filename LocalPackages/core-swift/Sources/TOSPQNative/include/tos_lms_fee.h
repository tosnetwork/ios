#ifndef TOS_LMS_FEE_H
#define TOS_LMS_FEE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int tos_wallet_lms_fee_verify(uint32_t leaf,const unsigned char *digest,size_t digest_size,const unsigned char *signature,size_t signature_size,const unsigned char *key,size_t key_size);
#ifdef __cplusplus
}
#endif
#endif
