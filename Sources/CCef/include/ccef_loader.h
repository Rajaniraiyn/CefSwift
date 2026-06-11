// CefSwift — runtime loader for the Chromium Embedded Framework dylib.
//
// CefSwift never links against the CEF framework. Instead the framework
// binary is dlopen'd at runtime and every cef_* global used by CefSwift is
// resolved with dlsym into a pointer table (see ccef_symbols.h). Real-named
// trampoline functions are defined in ccef_loader.c so Swift code calls the
// C API naturally (cef_initialize(...), etc.).

#ifndef CCEF_LOADER_H_
#define CCEF_LOADER_H_

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the CEF framework binary at `framework_binary_path` (the path to the
/// dylib inside the .framework, e.g.
/// ".../Chromium Embedded Framework.framework/Chromium Embedded Framework")
/// using dlopen(RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) and resolves every
/// required cef_* symbol.
///
/// Returns 1 on success, 0 on failure. On failure ccef_loader_error()
/// describes the problem (including the missing symbol name, if any) and the
/// framework is left unloaded.
int ccef_load_framework(const char* framework_binary_path);

/// Unloads the framework (dlclose) and clears the symbol table. Call only
/// after cef_shutdown() in the browser process. Safe to call when not loaded.
void ccef_unload_framework(void);

/// Returns 1 if the framework is currently loaded.
int ccef_is_framework_loaded(void);

/// Last loader error message (empty string when no error occurred).
const char* ccef_loader_error(void);

#ifdef __cplusplus
}
#endif

#endif  // CCEF_LOADER_H_
