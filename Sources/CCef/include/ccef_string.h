// CefSwift — framework-independent cef_string_t helpers.
//
// Clears a cef_string_t without the CEF framework loaded (unlike
// cef_string_utf16_clear, which is a libcef export), so strings CefSwift
// fills (CefStringUtil.set) can be freed anywhere. CEF-allocated userfree
// strings must still be freed with cef_string_userfree_utf16_free.

#ifndef CCEF_STRING_H_
#define CCEF_STRING_H_

#include <stddef.h>

#include "include/internal/cef_string_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Frees the value held by `out` (if any) by invoking its stored dtor, and
/// zeroes the struct.
void ccef_string_clear(cef_string_utf16_t* out);

#ifdef __cplusplus
}
#endif

#endif  // CCEF_STRING_H_
