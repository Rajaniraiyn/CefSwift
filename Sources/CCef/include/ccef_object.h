// CefSwift — generic refcounted CEF object allocator.
//
// CEF capi handler structs (cef_client_t, cef_app_t, ...) embed a
// cef_base_ref_counted_t as their first member. CefSwift allocates such
// structs through ccef_object_alloc(), which places a hidden header (atomic
// refcount + opaque Swift object pointer) immediately BEFORE the cef struct
// and wires generic add_ref/release/has_one_ref callbacks. When the refcount
// drops to zero the `on_zero` callback fires (Swift releases its retained
// reference) and the memory is freed.

#ifndef CCEF_OBJECT_H_
#define CCEF_OBJECT_H_

#include <stddef.h>

#include "include/capi/cef_base_capi.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ccef_object_on_zero_t)(void* swift_object);

/// Allocates `struct_size` bytes of zeroed memory for a CEF struct whose
/// first member is cef_base_ref_counted_t. The struct's `base.size` is set to
/// `struct_size` and base callbacks are installed. Initial refcount is 1 and
/// is owned by the caller; passing the struct into CEF transfers that
/// reference (capi rules).
///
/// `swift_object` is an opaque pointer (an Unmanaged retained Swift object);
/// `on_zero` is invoked exactly once, when the refcount reaches zero, before
/// the memory is freed. Both may be NULL.
void* ccef_object_alloc(size_t struct_size, void* swift_object,
                        ccef_object_on_zero_t on_zero);

/// Returns the `swift_object` associated with a struct allocated by
/// ccef_object_alloc(). `cef_self` is the pointer CEF passes as `self`.
void* ccef_object_get_swift(void* cef_self);

/// Manual refcount manipulation (rarely needed; the base callbacks installed
/// by ccef_object_alloc are what CEF uses).
void ccef_object_add_ref(void* cef_self);
int ccef_object_release(void* cef_self);

/// Current refcount, for tests/diagnostics only.
int ccef_object_ref_count(void* cef_self);

#ifdef __cplusplus
}
#endif

#endif  // CCEF_OBJECT_H_
