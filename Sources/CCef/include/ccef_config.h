// CefSwift — CCef configuration.
//
// Included before any vendored CEF header. Pins the CEF API version so the C
// API stays ABI-stable across CEF binary updates
// (https://chromiumembedded.github.io/cef/api_versioning). Bump the pin to
// adopt newer APIs, then run Scripts/generate-bindings.py.

#ifndef CCEF_CONFIG_H_
#define CCEF_CONFIG_H_

#ifndef CEF_API_VERSION
#define CEF_API_VERSION 15600
#endif

#endif  // CCEF_CONFIG_H_
