// CefSwift — names of Chromium's network errors.

#ifndef CCEF_NET_ERROR_H_
#define CCEF_NET_ERROR_H_

#ifdef __cplusplus
extern "C" {
#endif

/// The name of a `cef_errorcode_t` value without its `ERR_` prefix, such as
/// "NAME_NOT_RESOLVED" for -105, from cef_net_error_list.h; NULL for a
/// value the list does not have. Needs no framework.
const char* ccef_net_error_name(int code);

#ifdef __cplusplus
}
#endif

#endif  // CCEF_NET_ERROR_H_
