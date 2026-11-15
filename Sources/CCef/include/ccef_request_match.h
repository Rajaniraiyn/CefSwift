// CefSwift — the declarative part of a request filter, tested in C.
//
// Chromium asks about every request on its IO thread. A filter that names
// the hosts, address patterns and resource types it cares about is tested
// here, on the request's UTF-16 address as CEF hands it over, so a request
// it does not care about costs no Swift value and never reaches the
// filter's closure.

#ifndef CCEF_REQUEST_MATCH_H_
#define CCEF_REQUEST_MATCH_H_

#include <stddef.h>
#include <stdint.h>

#include "include/internal/cef_string_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Compiled hosts, patterns and resource types. Immutable once created, so
/// any thread may test against it.
typedef struct ccef_request_match_t ccef_request_match_t;

/// Creates a matcher. `resource_types` is a mask of `1 << cef_resource_type_t`
/// values, 0 for every type. `hosts` are ASCII host names, each matching
/// itself and its subdomains, compared without case. `patterns` are UTF-8
/// addresses where `*` stands for any run of characters, compared exactly.
/// With neither hosts nor patterns every address matches.
ccef_request_match_t* ccef_request_match_create(uint64_t resource_types,
                                                const char* const* hosts,
                                                size_t host_count,
                                                const char* const* patterns,
                                                size_t pattern_count);

void ccef_request_match_destroy(ccef_request_match_t* match);

/// Whether a request of `resource_type` for `url` passes: 1 or 0.
int ccef_request_match_test(const ccef_request_match_t* match,
                            const cef_string_utf16_t* url,
                            int resource_type);

/// Whether `resource_type` alone already fails the matcher, before the
/// address is read: 1 or 0.
int ccef_request_match_excludes_type(const ccef_request_match_t* match,
                                     int resource_type);

/// The host of `url` (after `scheme://` and any user information, up to
/// the port, path, query or fragment) as a range of UTF-16 units; 0 when
/// the address has no `://`. For tests.
int ccef_request_match_host_range(const char16_t* url,
                                  size_t length,
                                  size_t* start,
                                  size_t* end);

#ifdef __cplusplus
}
#endif

#endif  // CCEF_REQUEST_MATCH_H_
