#ifndef _STDINT_H
#define _STDINT_H
typedef signed char int8_t;
typedef unsigned char uint8_t;
typedef signed short int16_t;
typedef unsigned short uint16_t;
typedef signed int int32_t;
typedef unsigned int uint32_t;
typedef signed long long int64_t;
typedef unsigned long long uint64_t;
typedef signed long intptr_t;
typedef unsigned long uintptr_t;
typedef signed long long intmax_t;
typedef unsigned long long uintmax_t;
#define INT8_MIN (-128)
#define INT16_MIN (-32768)
#define INT32_MIN (-2147483648)
#define INT64_MIN (-9223372036854775807LL - 1)
#define INT8_MAX 127
#define INT16_MAX 32767
#define INT32_MAX 2147483647
#define INT64_MAX 9223372036854775807LL
#define UINT8_MAX 255
#define UINT16_MAX 65535
#define UINT32_MAX 4294967295U
#define UINT64_MAX 18446744073709551615ULL
#define INTPTR_MIN INT64_MIN
#define INTPTR_MAX INT64_MAX
#define UINTPTR_MAX UINT64_MAX
#define INTMAX_MIN INT64_MIN
#define INTMAX_MAX INT64_MAX
#define UINTMAX_MAX UINT64_MAX
#define PTRDIFF_MIN INTPTR_MIN
#define PTRDIFF_MAX INTPTR_MAX
#define SIZE_MAX UINT64_MAX
#define INT8_C(c) c
#define INT16_C(c) c
#define INT32_C(c) c
#define INT64_C(c) c ## LL
#define UINT8_C(c) c
#define UINT16_C(c) c ## U
#define UINT32_C(c) c ## U
#define UINT64_C(c) c ## ULL
#define INTMAX_C(c) c ## LL
#define UINTMAX_C(c) c ## ULL
typedef unsigned int __uint32_t;
typedef unsigned long long __uint64_t;
typedef unsigned short __uint16_t;
typedef unsigned char __uint8_t;
typedef int __int32_t;
typedef long long __int64_t;
typedef short __int16_t;
typedef signed char __int8_t;
#ifdef __cplusplus
#include <atomic_ref_compat.h>
#endif
#endif
