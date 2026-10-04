#include "include/tos_pq.h"
#include "vendor/mldsa/mldsa_native.h"
#include "vendor/falcon/falcon.h"
#include "falcon512-native.h"
#include <string.h>
#define M(sym) tos_mobile_mldsa44_##sym
static const uint8_t context[] = "TOS-AUTH-ML-DSA-44-v1";
static const uint8_t falcon_tag[] = "TOS-AUTH-FALCON512-PADDED-v1";
void tos_pq_clear(void *p, size_t n) { volatile uint8_t *v=p; while(n--) *v++=0; }
size_t tos_pq_public_key_size(int a) { return a==1?1312:a==2?897:0; }
size_t tos_pq_signature_size(int a) { return a==1?2420:a==2?666:0; }
static int message_valid(int a,const uint8_t *m,size_t n) {
 if (!m) return 0;
 if(a==1) return n==32;
 /* Falcon signs exactly tag || zero || root.wc:int32 || root.hash || D. */
 return a==2 && n==sizeof(falcon_tag)-1+1+4+32+32 &&
   memcmp(m,falcon_tag,sizeof(falcon_tag)-1)==0 && m[sizeof(falcon_tag)-1]==0;
}
static int keygen(int a,const uint8_t *seed,uint8_t *sk,uint8_t *pk) {
 if(a==1) return M(keypair_internal)(pk,sk,seed);
 shake256_context rng;
 union { uint64_t align; uint8_t bytes[FALCON_TMPSIZE_KEYGEN(9)]; } tmp;
 /* Versioned, algorithm-separated deterministic restore from the 32-byte seed. */
 shake256_init(&rng);
 shake256_inject(&rng,"TOS-MOBILE-FALCON512-SEED-v1",sizeof("TOS-MOBILE-FALCON512-SEED-v1")-1);
 shake256_inject(&rng,seed,32); shake256_flip(&rng);
 int rc=falcon_keygen_make(&rng,9,sk,1281,pk,897,tmp.bytes,sizeof(tmp.bytes));
 tos_pq_clear(&rng,sizeof(rng)); tos_pq_clear(&tmp,sizeof(tmp));
 return rc || !tos_falcon512_public_key_valid(pk,897)?-1:0;
}
int tos_pq_public_key(int a,const uint8_t *seed,size_t ns,uint8_t *pk,size_t np) {
 uint8_t sk[2560]; int rc=-1;
 if(!seed || ns!=32 || !pk || !np || np!=tos_pq_public_key_size(a)) return -1;
 rc=keygen(a,seed,sk,pk); tos_pq_clear(sk,sizeof(sk));
 if(rc) tos_pq_clear(pk,np);
 return rc? -1:0;
}
int tos_pq_verify(int a,const uint8_t *pk,size_t np,const uint8_t *m,size_t nm,
 const uint8_t *sig,size_t ns) {
 if(!pk || !sig || !np || np!=tos_pq_public_key_size(a) ||
    ns!=tos_pq_signature_size(a) || !message_valid(a,m,nm)) return 0;
 if(a==1) return M(verify)(sig,m,nm,context,sizeof(context)-1,pk)==0;
 return tos_falcon512_padded_verify(m,nm,sig,ns,pk,np)==1;
}
int tos_pq_sign(int a,const uint8_t *seed,size_t nseed,const uint8_t *entropy,size_t ne,
 const uint8_t *m,size_t nm,uint8_t *sig,size_t ns) {
 uint8_t sk[2560],pk[1312]; int rc=-1;
 if(!seed || nseed!=32 || !entropy || ne!=48 || !sig || !ns ||
   ns!=tos_pq_signature_size(a) || !message_valid(a,m,nm)) return -1;
 if(keygen(a,seed,sk,pk)) goto done;
 if(a==1) {
   uint8_t prefix[sizeof(context)+1]; prefix[0]=0; prefix[1]=sizeof(context)-1;
   memcpy(prefix+2,context,sizeof(context)-1);
   rc=M(signature_internal)(sig,m,nm,prefix,sizeof(prefix),entropy,sk,0);
 } else {
   shake256_context rng;
   union { uint64_t align; uint8_t bytes[FALCON_TMPSIZE_SIGNDYN(9)]; } tmp;
   size_t n=ns; shake256_init_prng_from_seed(&rng,entropy,ne);
   rc=falcon_sign_dyn(&rng,sig,&n,FALCON_SIG_PADDED,sk,1281,m,nm,tmp.bytes,sizeof(tmp.bytes));
   tos_pq_clear(&rng,sizeof(rng));tos_pq_clear(&tmp,sizeof(tmp));
   if(n!=ns) rc=-1;
 }
 if(rc || !tos_pq_verify(a,pk,tos_pq_public_key_size(a),m,nm,sig,ns)) rc=-1;
 done: tos_pq_clear(sk,sizeof(sk)); tos_pq_clear(pk,sizeof(pk));
 if(rc) tos_pq_clear(sig,ns);
 return rc? -1:0;
}
