// CefSwift — runtime loader implementation (see ccef_loader.h).

#include "CCef.h"

#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

static void* g_handle = NULL;
static char g_error[1024];

const char* ccef_loader_error(void) {
  return g_error;
}

int ccef_is_framework_loaded(void) {
  return g_handle != NULL;
}

int ccef_pinned_api_version(void) {
  return CEF_API_VERSION;
}

const char* ccef_pinned_api_hash(void) {
  return CEF_API_HASH_PLATFORM;
}

int ccef_load_framework(const char* framework_binary_path) {
  if (g_handle) {
    return 1;
  }
  g_error[0] = '\0';
  void* handle =
      dlopen(framework_binary_path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!handle) {
    const char* err = dlerror();
    snprintf(g_error, sizeof(g_error), "dlopen failed for '%s': %s",
             framework_binary_path, err ? err : "unknown error");
    return 0;
  }
  g_handle = handle;
  return 1;
}

int ccef_has_symbol(const char* symbol_name) {
  return g_handle && dlsym(g_handle, symbol_name) != NULL;
}

// Binds `name` on first use. Calling a CEF function before the framework is
// loaded, or one the loaded binary does not export, is a programmer error
// and aborts with a message naming the function.
static void* ccef_bind(_Atomic(void*)* slot, const char* name) {
  void* fn = atomic_load_explicit(slot, memory_order_acquire);
  if (fn) {
    return fn;
  }
  if (!g_handle) {
    fprintf(stderr,
            "CefSwift fatal: %s() called before the CEF framework was loaded. "
            "Call CefRuntime.shared.initialize() first.\n",
            name);
    abort();
  }
  fn = dlsym(g_handle, name);
  if (!fn) {
    fprintf(stderr,
            "CefSwift fatal: the loaded CEF framework does not export %s(). "
            "The bundled framework does not match the vendored headers.\n",
            name);
    abort();
  }
  atomic_store_explicit(slot, fn, memory_order_release);
  return fn;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpedantic"

#define CCEF_SYM(ret, name, params, args)                       \
  ret name params {                                             \
    static _Atomic(void*) slot;                                 \
    return ((ret(*) params)ccef_bind(&slot, #name)) args;       \
  }
#include "ccef_symbols.h"
#undef CCEF_SYM

#pragma clang diagnostic pop
