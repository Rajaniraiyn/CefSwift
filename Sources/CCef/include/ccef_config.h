// CefSwift — CCef configuration.
//
// This header MUST be included before any vendored CEF header. It pins the
// CEF API version so that the C API surface stays ABI-stable across CEF
// binary updates (see https://chromiumembedded.github.io/cef/api_versioning).

#ifndef CCEF_CONFIG_H_
#define CCEF_CONFIG_H_

// Pinned API version. Newest stable version listed in the vendored
// include/cef_api_versions.h (CEF_API_VERSION_LAST == 14800 for CEF 148).
#ifndef CEF_API_VERSION
#define CEF_API_VERSION 14800
#endif

// Expected platform API hash for CEF_API_VERSION on macOS, captured verbatim
// from CEF_API_HASH_14800 (OS_MAC branch) in include/cef_api_versions.h.
// Compared at runtime against cef_api_hash(CEF_API_VERSION, 0) right after
// the framework is loaded.
#define CCEF_EXPECTED_API_HASH_PLATFORM "c4a25b0e7f0beb51b9f5db9fb75904d11dd856a1"

// Stringified API version, convenient for diagnostics.
#define CCEF_API_VERSION_VALUE 14800

#endif  // CCEF_CONFIG_H_
