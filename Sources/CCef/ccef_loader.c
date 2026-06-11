// CefSwift — runtime loader implementation.
//
// Pattern mirrors CEF's official libcef_dll/wrapper/libcef_dll_dylib.cc:
// dlopen the framework binary, dlsym every cef_* global into a pointer table,
// and expose real-named trampolines. Because CefSwift never links the
// framework, our trampoline definitions satisfy the linker for the CEF_EXPORT
// prototypes declared in the vendored headers.

#include "CCef.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Pointer table
// ---------------------------------------------------------------------------

static struct {
#define CCEF_SYM(ret, name, params, args) ret(*name) params;
#define CCEF_SYM_VOID(name, params, args) void (*name) params;
#include "ccef_symbols.h"
#undef CCEF_SYM
#undef CCEF_SYM_VOID
} g_ptrs;

static void* g_handle = NULL;
static char g_error[1024];

static void ccef_set_error(const char* fmt, const char* a, const char* b) {
  snprintf(g_error, sizeof(g_error), fmt, a, b ? b : "");
}

const char* ccef_loader_error(void) {
  return g_error;
}

int ccef_is_framework_loaded(void) {
  return g_handle != NULL;
}

int ccef_load_framework(const char* framework_binary_path) {
  if (g_handle) {
    ccef_set_error("CEF framework is already loaded%s%s", "", NULL);
    return 0;
  }
  g_error[0] = '\0';

  void* handle =
      dlopen(framework_binary_path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!handle) {
    const char* err = dlerror();
    ccef_set_error("dlopen failed for '%s': %s", framework_binary_path,
                   err ? err : "unknown error");
    return 0;
  }

#define CCEF_RESOLVE(name)                                                  \
  do {                                                                      \
    *(void**)(&g_ptrs.name) = dlsym(handle, #name);                         \
    if (!g_ptrs.name) {                                                     \
      ccef_set_error("missing CEF symbol '%s' in '%s'", #name,              \
                     framework_binary_path);                                \
      memset(&g_ptrs, 0, sizeof(g_ptrs));                                   \
      dlclose(handle);                                                      \
      return 0;                                                             \
    }                                                                       \
  } while (0)

#define CCEF_SYM(ret, name, params, args) CCEF_RESOLVE(name);
#define CCEF_SYM_VOID(name, params, args) CCEF_RESOLVE(name);
#include "ccef_symbols.h"
#undef CCEF_SYM
#undef CCEF_SYM_VOID
#undef CCEF_RESOLVE

  g_handle = handle;
  return 1;
}

void ccef_unload_framework(void) {
  if (!g_handle) {
    return;
  }
  dlclose(g_handle);
  g_handle = NULL;
  memset(&g_ptrs, 0, sizeof(g_ptrs));
}

// ---------------------------------------------------------------------------
// Real-named trampolines
// ---------------------------------------------------------------------------
// The vendored headers declare these CEF_EXPORT; since the framework is never
// linked, these definitions are the only ones the linker sees. Calling any of
// them before ccef_load_framework() succeeds is a programmer error and traps
// deterministically.

#define CCEF_REQUIRE(name)                                                   \
  do {                                                                       \
    if (!g_ptrs.name) {                                                      \
      fprintf(stderr,                                                        \
              "CefSwift fatal: %s() called before the CEF framework was "    \
              "loaded. Call CefRuntime.initialize() (or "                    \
              "ccef_load_framework) first.\n",                               \
              #name);                                                        \
      __builtin_trap();                                                      \
    }                                                                        \
  } while (0)

#define CCEF_SYM(ret, name, params, args) \
  ret name params {                       \
    CCEF_REQUIRE(name);                   \
    return g_ptrs.name args;              \
  }
#define CCEF_SYM_VOID(name, params, args) \
  void name params {                      \
    CCEF_REQUIRE(name);                   \
    g_ptrs.name args;                     \
  }
#include "ccef_symbols.h"
#undef CCEF_SYM
#undef CCEF_SYM_VOID
#undef CCEF_REQUIRE
