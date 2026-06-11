// CefSwift — macOS sandbox loader implementation (see ccef_sandbox.h).
//
// Mirrors CEF's libcef_dll/wrapper/cef_scoped_sandbox_context_mac.mm: resolve
// libcef_sandbox.dylib relative to the helper executable, dlopen it with its
// own handle (NOT the main ccef_loader symbol table), and call
// cef_sandbox_initialize(argc, argv) before any Chromium code runs.

#include "ccef_sandbox.h"

#include <dlfcn.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Relative path from the helper executable to the sandbox dylib (helpers
// live in <App>.app/Contents/Frameworks/<Helper>.app/Contents/MacOS/).
static const char kSandboxLibraryRelativePath[] =
    "../../../Chromium Embedded Framework.framework/"
    "Libraries/libcef_sandbox.dylib";

typedef void* (*ccef_sandbox_initialize_t)(int argc, char** argv);
typedef void (*ccef_sandbox_destroy_t)(void* sandbox_context);

static void* g_sandbox_library = NULL;
static void* g_sandbox_context = NULL;
static char g_sandbox_error[1024];

const char* ccef_sandbox_error(void) {
  return g_sandbox_error;
}

int ccef_sandbox_is_initialized(void) {
  return g_sandbox_context != NULL;
}

int ccef_sandbox_initialize(int argc, char** argv) {
  if (g_sandbox_context) {
    return 1;  // already sealed; idempotent
  }
  g_sandbox_error[0] = '\0';

  // Resolve the executable path (two-call _NSGetExecutablePath pattern).
  uint32_t exec_path_size = 0;
  if (_NSGetExecutablePath(NULL, &exec_path_size) != -1) {
    snprintf(g_sandbox_error, sizeof(g_sandbox_error),
             "_NSGetExecutablePath sizing call failed");
    return 0;
  }
  char* exec_path = malloc(exec_path_size);
  if (!exec_path || _NSGetExecutablePath(exec_path, &exec_path_size) != 0) {
    snprintf(g_sandbox_error, sizeof(g_sandbox_error),
             "_NSGetExecutablePath failed");
    free(exec_path);
    return 0;
  }

  // dirname() may modify its argument and/or return static storage; copy out.
  char library_path[4096];
  const char* exec_dir = dirname(exec_path);
  int written = snprintf(library_path, sizeof(library_path), "%s/%s",
                         exec_dir ? exec_dir : ".",
                         kSandboxLibraryRelativePath);
  free(exec_path);
  if (written < 0 || (size_t)written >= sizeof(library_path)) {
    snprintf(g_sandbox_error, sizeof(g_sandbox_error),
             "sandbox library path too long");
    return 0;
  }

  void* handle = dlopen(library_path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!handle) {
    const char* err = dlerror();
    snprintf(g_sandbox_error, sizeof(g_sandbox_error),
             "dlopen failed for '%s': %s", library_path,
             err ? err : "unknown error");
    return 0;
  }

  ccef_sandbox_initialize_t initialize_fn;
  *(void**)(&initialize_fn) = dlsym(handle, "cef_sandbox_initialize");
  if (!initialize_fn) {
    snprintf(g_sandbox_error, sizeof(g_sandbox_error),
             "missing symbol 'cef_sandbox_initialize' in '%s'", library_path);
    dlclose(handle);
    return 0;
  }

  void* context = initialize_fn(argc, argv);
  if (!context) {
    snprintf(g_sandbox_error, sizeof(g_sandbox_error),
             "cef_sandbox_initialize returned NULL");
    dlclose(handle);
    return 0;
  }

  // Keep both alive for the process lifetime: the sandbox cannot be unsealed.
  g_sandbox_library = handle;
  g_sandbox_context = context;
  return 1;
}

void ccef_sandbox_destroy(void) {
  if (!g_sandbox_context) {
    return;
  }
  ccef_sandbox_destroy_t destroy_fn;
  *(void**)(&destroy_fn) = dlsym(g_sandbox_library, "cef_sandbox_destroy");
  if (destroy_fn) {
    destroy_fn(g_sandbox_context);
  }
  g_sandbox_context = NULL;
  // Leave the dylib loaded; unloading sandbox code at exit is pointless risk.
}
