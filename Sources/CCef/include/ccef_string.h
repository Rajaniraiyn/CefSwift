// CefSwift — framework-independent cef_string_t helpers.
//
// These helpers copy UTF-16 data into a cef_string_t with a malloc/free dtor,
// so strings can be created and destroyed without the CEF framework loaded
// (unlike cef_string_utf16_set, which is a libcef export). CEF-allocated
// strings must still be freed with cef_string_userfree_utf16_free.

#ifndef CCEF_STRING_H_
#define CCEF_STRING_H_

#include <stddef.h>

#include "include/internal/cef_string_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Copies `length` UTF-16 code units from `src` into `out`, freeing any
/// previous value. The copy is owned by `out` (dtor = free). Returns 1 on
/// success, 0 on allocation failure (out is cleared).
int ccef_string_set_utf16(const char16_t* src, size_t length,
                          cef_string_utf16_t* out);

/// Frees the value held by `out` (if any) and zeroes the struct. Only valid
/// for strings whose dtor was installed by this allocator or is NULL/CEF-set;
/// it simply invokes the stored dtor.
void ccef_string_clear(cef_string_utf16_t* out);

#ifdef __cplusplus
}
#endif

#endif  // CCEF_STRING_H_
