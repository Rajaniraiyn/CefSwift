// CefSwift — runtime loader for the Chromium Embedded Framework.
//
// CefSwift never links against CEF. The framework binary is dlopen'd at
// runtime and every cef_* global declared by the vendored headers is defined
// here as a trampoline that binds itself with dlsym on first call (the list
// is generated; see ccef_symbols.h). Swift calls the C API by its real names.

#ifndef CCEF_LOADER_H_
#define CCEF_LOADER_H_

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the CEF framework binary at `framework_binary_path` (the Mach-O
/// inside the .framework). Returns 1 on success, 0 on failure — see
/// ccef_loader_error(). The framework stays loaded for the process lifetime.
int ccef_load_framework(const char* framework_binary_path);

/// Returns 1 if the framework is loaded.
int ccef_is_framework_loaded(void);

/// Returns 1 if the loaded framework exports `symbol_name`.
int ccef_has_symbol(const char* symbol_name);

/// Last loader error message (empty string when none).
const char* ccef_loader_error(void);

/// The CEF API version this module was compiled against (CEF_API_VERSION).
int ccef_pinned_api_version(void);

/// The platform API hash the vendored headers define for that version.
const char* ccef_pinned_api_hash(void);

#ifdef __cplusplus
}
#endif

#endif  // CCEF_LOADER_H_
