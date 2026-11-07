// SPDX-License-Identifier: GPL-2.0-or-later
//
// Polyfill for std::atomic_ref, which is not provided by the libc++ shipped
// with the Android NDK (verified absent in NDK r27 and r28). The std::atomic_ref
// template is required by src/util/statics.h (singleton thread-safety, added in
// commit 7f5306db). Without it, the Android arm64 build fails to compile.
//
// This header is force-included only for Android builds via the CMake cache
// variable INKSCAPE_ANDROID_INCLUDE (see packaging/android/README.md). It does
// not affect any other platform. It implements the subset of std::atomic_ref
// actually used by Inkscape (store/load with a memory order) on top of the
// Clang/GCC __atomic_* compiler builtins, which are always available.
//
// Upstream context: the GTK4-on-Android CI job (.gitlab-ci.yml:inkscape:android)
// is `when: manual, allow_failure: true`, so this breakage went unnoticed after
// 7f5306db landed. A proper upstream fix would land either here (force-include
// polyfill) or as an `#ifdef __ANDROID__` fallback in src/util/statics.h.

#ifndef INKSCAPE_ANDROID_ATOMIC_REF_POLYFILL_H
#define INKSCAPE_ANDROID_ATOMIC_REF_POLYFILL_H

#include <atomic>
#include <type_traits>

namespace std {

template <typename T>
class atomic_ref {
    T *_ptr;

    static int _mo(memory_order mo) noexcept {
        return static_cast<int>(static_cast<underlying_type<memory_order>::type>(mo));
    }

public:
    static constexpr bool is_always_lock_free = __atomic_always_lock_free(sizeof(T), nullptr);

    explicit atomic_ref(T &obj) noexcept : _ptr(&obj) {}
    atomic_ref(const atomic_ref &) noexcept = default;
    atomic_ref &operator=(const atomic_ref &) = delete;

    T operator=(T val) const noexcept { store(val); return val; }

    void store(T val, memory_order mo = memory_order::seq_cst) const noexcept {
        __atomic_store_n(_ptr, val, _mo(mo));
    }

    T load(memory_order mo = memory_order::seq_cst) const noexcept {
        return __atomic_load_n(_ptr, _mo(mo));
    }

    T exchange(T val, memory_order mo = memory_order::seq_cst) const noexcept {
        return __atomic_exchange_n(_ptr, val, _mo(mo));
    }

    bool compare_exchange_strong(T &expected, T desired,
                                 memory_order success = memory_order::seq_cst,
                                 memory_order failure = memory_order::seq_cst) const noexcept {
        return __atomic_compare_exchange_n(_ptr, &expected, desired, false, _mo(success), _mo(failure));
    }

    bool compare_exchange_weak(T &expected, T desired,
                               memory_order success = memory_order::seq_cst,
                               memory_order failure = memory_order::seq_cst) const noexcept {
        return __atomic_compare_exchange_n(_ptr, &expected, desired, true, _mo(success), _mo(failure));
    }

    bool is_lock_free() const noexcept { return __atomic_is_lock_free(sizeof(T), _ptr); }
};

} // namespace std

#endif // INKSCAPE_ANDROID_ATOMIC_REF_POLYFILL_H
