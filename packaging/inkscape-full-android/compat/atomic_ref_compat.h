#ifndef ATOMIC_REF_COMPAT_H
#define ATOMIC_REF_COMPAT_H
#include <atomic>
#if defined(__ANDROID__) && __cplusplus >= 202002L && !defined(__cpp_lib_atomic_ref)
#include <type_traits>
namespace std {
template <typename T>
class atomic_ref {
    T& ref_;
public:
    explicit atomic_ref(T& obj) : ref_(obj) {}
    atomic_ref(const atomic_ref&) = default;
    atomic_ref& operator=(const atomic_ref&) = delete;
    static constexpr bool is_always_lock_free = true;
    bool is_lock_free() const noexcept { return true; }
    void store(T desired, memory_order = memory_order_seq_cst) noexcept { __atomic_store_n(&ref_, desired, __ATOMIC_SEQ_CST); }
    T load(memory_order = memory_order_seq_cst) const noexcept { return __atomic_load_n(&ref_, __ATOMIC_SEQ_CST); }
    operator T() const noexcept { return load(); }
    T exchange(T desired, memory_order = memory_order_seq_cst) noexcept { return __atomic_exchange_n(&ref_, desired, __ATOMIC_SEQ_CST); }
    bool compare_exchange_weak(T& expected, T desired, memory_order = memory_order_seq_cst, memory_order = memory_order_seq_cst) noexcept { return __atomic_compare_exchange_n(&ref_, &expected, desired, true, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); }
    bool compare_exchange_strong(T& expected, T desired, memory_order = memory_order_seq_cst, memory_order = memory_order_seq_cst) noexcept { return __atomic_compare_exchange_n(&ref_, &expected, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); }
};
}
#define __cpp_lib_atomic_ref 201711L
#endif
#endif
