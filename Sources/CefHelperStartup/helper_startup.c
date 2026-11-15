// CefSwift helper startup library.
//
// Seals Chromium's macOS sandbox in a helper process before any code of the
// CEF framework runs. The helper executable links this library ahead of the
// framework, and dyld runs a library's initializers before those of the
// libraries listed after it, so this initializer runs first. It is
// CefSwift's counterpart of Chromium's libaperitif.dylib, built on CEF's
// libcef_sandbox.dylib (see docs/sandbox.md).
//
// This is the one part of the helper that is not Swift: it must run before
// the framework's static initializers, which run before any Swift code of
// the executable, and it must not pull in the Swift runtime. SwiftPM builds
// it as the dynamic library product `cefswift_helper_startup`; `swift
// package cef bundle` copies it into Contents/Frameworks.

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "cefswift_helper_startup.h"

// libcef_sandbox.dylib, relative to a helper executable at
// <App>.app/Contents/Frameworks/<Helper>.app/Contents/MacOS/<Helper>.
static const char kSandboxLibrary[] =
    "@executable_path/../../../Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib";

// Lives as long as the process: a sealed sandbox cannot be unsealed.
static void* g_sandbox_context;

int cefswift_helper_is_sandboxed(void) { return g_sandbox_context != NULL; }

__attribute__((constructor)) static void cefswift_seal_sandbox(int argc, char** argv) {
  // Chromium passes --no-sandbox to helpers when the app runs unsandboxed.
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--no-sandbox") == 0) {
      return;
    }
  }
  // From include/cef_sandbox_mac.h.
  void* library = dlopen(kSandboxLibrary, RTLD_NOW | RTLD_LOCAL);
  void* (*initialize)(int, char**) =
      library ? (void* (*)(int, char**))dlsym(library, "cef_sandbox_initialize") : NULL;
  g_sandbox_context = initialize ? initialize(argc, argv) : NULL;
  if (!g_sandbox_context) {
    // Never run a helper unsandboxed that was asked to be sandboxed.
    fprintf(stderr, "CefSwift helper: sandbox initialization failed (%s)\n", library ? "seal" : dlerror());
    _exit(125);
  }
}
