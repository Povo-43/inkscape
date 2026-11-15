#ifndef _STDINT_H
#define _STDINT_H

/* 
 * Android NDK compat header - only define types missing from NDK sysroot
 * NDK's <cstdint> provides most types with using_if_exists,
 * so we only add what's truly missing or non-standard
 */

#ifndef INT8_MIN
#define INT8_MIN (-128)
#endif
#ifndef INT16_MIN
#define INT16_MIN (-32768)
#endif
#ifndef INT32_MIN
#define INT32_MIN (-2147483648)
#endif
#ifndef INT64_MIN
#define INT64_MIN (-9223372036854775807LL - 1)
#endif
#ifndef INT8_MAX
#define INT8_MAX 127
#endif
#ifndef INT16_MAX
#define INT16_MAX 32767
#endif
#ifndef INT32_MAX
#define INT32_MAX 2147483647
#endif
#ifndef INT64_MAX
#define INT64_MAX 9223372036854775807LL
#endif
#ifndef UINT8_MAX
#define UINT8_MAX 255
#endif
#ifndef UINT16_MAX
#define UINT16_MAX 65535
#endif
#ifndef UINT32_MAX
#define UINT32_MAX 4294967295U
#endif
#ifndef UINT64_MAX
#define UINT64_MAX 18446744073709551615ULL
#endif

/* intptr_t / uintptr_t - may be missing from some NDK versions */
#ifndef INTPTR_MIN
#define INTPTR_MIN INT64_MIN
#endif
#ifndef INTPTR_MAX
#define INTPTR_MAX INT64_MAX
#endif
#ifndef UINTPTR_MAX
#define UINTPTR_MAX UINT64_MAX
#endif

#ifndef INTMAX_MIN
#define INTMAX_MIN INT64_MIN
#endif
#ifndef INTMAX_MAX
#define INTMAX_MAX INT64_MAX
#endif
#ifndef UINTMAX_MAX
#define UINTMAX_MAX UINT64_MAX
#endif
#ifndef PTRDIFF_MIN
#define PTRDIFF_MIN INTPTR_MIN
#endif
#ifndef PTRDIFF_MAX
#define PTRDIFF_MAX INTPTR_MAX
#endif
#ifndef SIZE_MAX
#define SIZE_MAX UINT64_MAX
#endif

/* C macros for literals */
#ifndef INT8_C
#define INT8_C(c) c
#endif
#ifndef INT16_C
#define INT16_C(c) c
#endif
#ifndef INT32_C
#define INT32_C(c) c
#endif
#ifndef INT64_C
#define INT64_C(c) c ## LL
#endif
#ifndef UINT8_C
#define UINT8_C(c) c
#endif
#ifndef UINT16_C
#define UINT16_C(c) c ## U
#endif
#ifndef UINT32_C
#define UINT32_C(c) c ## U
#endif
#ifndef UINT64_C
#define UINT64_C(c) c ## ULL
#endif
#ifndef INTMAX_C
#define INTMAX_C(c) c ## LL
#endif
#ifndef UINTMAX_C
#define UINTMAX_C(c) c ## ULL
#endif

/* Non-standard types used by some codebases */
#ifndef __uint32_t_defined
#define __uint32_t_defined
typedef unsigned int __uint32_t;
#endif
#ifndef __uint64_t_defined
#define __uint64_t_defined
typedef unsigned long long __uint64_t;
#endif
#ifndef __uint16_t_defined
#define __uint16_t_defined
typedef unsigned short __uint16_t;
#endif
#ifndef __uint8_t_defined
#define __uint8_t_defined
typedef unsigned char __uint8_t;
#endif
#ifndef __int32_t_defined
#define __int32_t_defined
typedef int __int32_t;
#endif
#ifndef __int64_t_defined
#define __int64_t_defined
typedef long long __int64_t;
#endif
#ifndef __int16_t_defined
#define __int16_t_defined
typedef short __int16_t;
#endif
#ifndef __int8_t_defined
#define __int8_t_defined
typedef signed char __int8_t;
#endif

/* stdint types are provided by NDK's <cstdint> - don't redefine them */
/* If you see errors about types not defined, include <cstdint> or <stdint.h> first */

/* atomic_ref_compat.h is included separately via -include flag */
/* Do not include it here to avoid circular dependency with NDK's <atomic> */

#endif