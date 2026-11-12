// CefSwift helper startup library.
//
// Seals Chromium's macOS sandbox in a helper process before any code of the
// CEF framework runs. The helper executable (helper_main.c) links this
// library ahead of the framework, and dyld runs a library's initializers
// before those of libraries listed after it, so this initializer runs
// first. It is CefSwift's counterpart of Chromium's libaperitif.dylib,
// built on CEF's libcef_sandbox.dylib (see docs/sandbox.md).
//
// `swift package cef bundle` compiles this file into
// Contents/Frameworks/libcefswift_helper_startup.dylib.

#include <stdio.h>
#include <string.h>
#include <unistd.h>

// From libcef_sandbox.dylib (include/cef_sandbox_mac.h).
extern void* cef_sandbox_initialize(int argc, char** argv);

// Lives as long as the process: a sealed sandbox cannot be unsealed.
static void* g_sandbox_context;

__attribute__((constructor)) static void cefswift_seal_sandbox(int argc, char** argv) {
  // Chromium passes --no-sandbox to helpers when the app runs unsandboxed.
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--no-sandbox") == 0) {
      return;
    }
  }
  g_sandbox_context = cef_sandbox_initialize(argc, argv);
  if (!g_sandbox_context) {
    // Never run a helper unsandboxed that was asked to be sandboxed.
    fputs("CefSwift helper: sandbox initialization failed\n", stderr);
    _exit(125);
  }
}
