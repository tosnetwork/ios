cmake_minimum_required(VERSION 3.16)
project(tos_mobile_pq LANGUAGES C)
set(F vendor/falcon)
add_library(tospq STATIC tos_v5r2.c vendor/slhdsa/slh_dsa.c vendor/slhdsa/slh_sha2.c
 vendor/slhdsa/sha2_256.c vendor/slhdsa/sha2_512.c tos_pq.c falcon512-native.c vendor/mldsa/mldsa_native.c
 ${F}/falcon.c ${F}/codec.c ${F}/common.c ${F}/shake.c ${F}/vrfy.c
 ${F}/keygen.c ${F}/sign.c ${F}/fft.c ${F}/fpr.c ${F}/rng.c)
set_target_properties(tospq PROPERTIES C_STANDARD 99 POSITION_INDEPENDENT_CODE YES)
target_include_directories(tospq PRIVATE . vendor/mldsa vendor/falcon vendor/slhdsa PUBLIC include)
target_compile_definitions(tospq PRIVATE MLD_CONFIG_FILE="mldsa-config.h"
 FALCON_FPEMU=1 FALCON_FPNATIVE=0 FALCON_AVX2=0 FALCON_FMA=0
 FALCON_PREFIX=tos_mobile_falcon_inner FALCON_RAND_GETENTROPY=0
 FALCON_RAND_URANDOM=0 FALCON_RAND_WIN32=0)
