// CefSwift helper-process executable.
//
// `swift package cef bundle` compiles this file against the bundled CEF
// framework and copies it into each helper app. It links two libraries,
// in this order:
//
// 1. libcefswift_helper_startup.dylib (helper_startup.c), which seals the
//    sandbox before the framework's code runs.
// 2. The CEF framework itself. A library linked at launch, unlike one
//    loaded with dlopen(), has its pointers fixed up by the kernel as its
//    pages are read in, so those pages stay clean memory that every helper
//    shares instead of about 12 MB of private memory in each.
//
// It then runs the subprocess Chromium asked for and exits with its code.

#include <stdio.h>
#include <string.h>

#include "ccef_config.h"
#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"

// Custom URL schemes must be registered in every process. The browser
// process passes its list as --cefswift-schemes=name:options,name:options
// (CefCustomScheme.childProcessSwitchName).
static const char kSchemesSwitch[] = "--cefswift-schemes=";

enum { kMaxSchemes = 64, kMaxSchemeName = 128 };
static char g_scheme_names[kMaxSchemes][kMaxSchemeName];
static int g_scheme_options[kMaxSchemes];
static int g_scheme_count;

// Reads "name:options,…" and skips malformed entries, as
// CefCustomScheme's parser in the browser process would.
static void parse_schemes(const char* list) {
  while (*list && g_scheme_count < kMaxSchemes) {
    const char* end = strchr(list, ',');
    size_t length = end ? (size_t)(end - list) : strlen(list);
    const char* colon = memchr(list, ':', length);
    if (colon && colon > list && (size_t)(colon - list) < kMaxSchemeName && colon + 1 < list + length) {
      int options = 0;
      int valid = 1;
      for (const char* digit = colon + 1; digit < list + length; ++digit) {
        if (*digit < '0' || *digit > '9') {
          valid = 0;
          break;
        }
        options = options * 10 + (*digit - '0');
      }
      if (valid) {
        memcpy(g_scheme_names[g_scheme_count], list, (size_t)(colon - list));
        g_scheme_names[g_scheme_count][colon - list] = '\0';
        g_scheme_options[g_scheme_count] = options;
        ++g_scheme_count;
      }
    }
    if (!end) {
      break;
    }
    list = end + 1;
  }
}

static void CEF_CALLBACK register_custom_schemes(struct _cef_app_t* self, struct _cef_scheme_registrar_t* registrar) {
  (void)self;
  for (int i = 0; i < g_scheme_count; ++i) {
    cef_string_t name = {0};
    cef_string_utf8_to_utf16(g_scheme_names[i], strlen(g_scheme_names[i]), &name);
    registrar->add_custom_scheme(registrar, &name, g_scheme_options[i]);
    cef_string_utf16_clear(&name);
  }
}

// The app object lives for the whole process, so reference counting is a
// formality.
static void CEF_CALLBACK add_ref(cef_base_ref_counted_t* self) { (void)self; }
static int CEF_CALLBACK release(cef_base_ref_counted_t* self) { (void)self; return 0; }
static int CEF_CALLBACK has_one_ref(cef_base_ref_counted_t* self) { (void)self; return 1; }
static int CEF_CALLBACK has_at_least_one_ref(cef_base_ref_counted_t* self) { (void)self; return 1; }

int main(int argc, char** argv) {
  // The first call into CEF in every process: it selects the API version.
  const char* hash = cef_api_hash(CEF_API_VERSION, 0);
  if (!hash || strcmp(hash, CEF_API_HASH_PLATFORM) != 0) {
    fprintf(stderr, "CefSwift helper: the CEF framework's API hash %s does not match the expected %s\n",
            hash ? hash : "(none)", CEF_API_HASH_PLATFORM);
    return 125;
  }

  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], kSchemesSwitch, sizeof(kSchemesSwitch) - 1) == 0) {
      parse_schemes(argv[i] + sizeof(kSchemesSwitch) - 1);
    }
  }

  static cef_app_t app;
  cef_app_t* app_pointer = NULL;
  if (g_scheme_count > 0) {
    app.base.size = sizeof(cef_app_t);
    app.base.add_ref = add_ref;
    app.base.release = release;
    app.base.has_one_ref = has_one_ref;
    app.base.has_at_least_one_ref = has_at_least_one_ref;
    app.on_register_custom_schemes = register_custom_schemes;
    app_pointer = &app;
  }

  cef_main_args_t main_args = {.argc = argc, .argv = argv};
  return cef_execute_process(&main_args, app_pointer, NULL);
}
