// CefSwift — macOS sandbox loader for helper processes.
//
// Since CEF M138 the macOS sandbox ships as a standalone dylib inside the
// framework bundle (`Libraries/libcef_sandbox.dylib`). Helper processes must
// initialize it BEFORE the main CEF framework is loaded, so this loader is
// deliberately independent of ccef_loader.{h,c} / the main symbol table: it
// performs its own dlopen/dlsym of just `cef_sandbox_initialize` /
// `cef_sandbox_destroy` (see include/cef_sandbox_mac.h and CEF's
// libcef_dll/wrapper/cef_scoped_sandbox_context_mac.mm for the reference
// implementation this mirrors).

#ifndef CCEF_SANDBOX_H_
#define CCEF_SANDBOX_H_

#ifdef __cplusplus
extern "C" {
#endif

/// Initializes the Chromium macOS sandbox for the current (helper) process.
/// Resolves `libcef_sandbox.dylib` relative to the executable
/// (`<exe>/../../../Chromium Embedded Framework.framework/Libraries/...`,
/// helpers live in `Contents/Frameworks/` of the main app), dlopens it, and
/// calls `cef_sandbox_initialize(argc, argv)`. The resulting context (and
/// the dylib) stay alive for the rest of the process — sealing the sandbox
/// is one-way. Returns 1 on success, 0 on failure (see
/// ccef_sandbox_error()). Must be called before ccef_load_framework().
int ccef_sandbox_initialize(int argc, char** argv);

/// Destroys the sandbox context created by ccef_sandbox_initialize().
/// Only meaningful immediately before process termination; helper processes
/// normally never call this (the OS reclaims everything at exit).
void ccef_sandbox_destroy(void);

/// Whether ccef_sandbox_initialize() succeeded in this process.
int ccef_sandbox_is_initialized(void);

/// Last sandbox loader error message (empty string when none).
const char* ccef_sandbox_error(void);

#ifdef __cplusplus
}
#endif

#endif  // CCEF_SANDBOX_H_
