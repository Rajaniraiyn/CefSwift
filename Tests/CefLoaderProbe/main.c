// CefSwift — loads the CEF framework in a process of its own, for LoaderTests.
//
// The framework's static initializers make PartitionAlloc the process's
// default malloc zone by unregistering the system zone and registering it
// again. A pointer the system zone allocated, freed by another thread
// between the two, is owned by no registered zone, and Chromium's free
// traps (EXC_BREAKPOINT). A test process runs hundreds of tests on other
// threads while one loads the framework, so the loader tests load it here.
//
//   CefLoaderProbe check <framework binary>
//       Loads the framework and checks the loader against it. Exits 0, or
//       prints what failed and exits 1.
//   CefLoaderProbe free-during-load <framework binary>
//       Frees a system-zone pointer while the system zone is unregistered,
//       as another thread can: Chromium traps.

#include "CCef.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Allocated by the system zone before the load; freed inside the window.
static void* g_system_block = NULL;

static void probe_malloc_zone_unregister(malloc_zone_t* zone) {
  malloc_zone_unregister(zone);
  if (g_system_block) {
    void* block = g_system_block;
    g_system_block = NULL;
    free(block);
  }
}

// Points the framework's imports of malloc_zone_unregister at the probe's,
// once dyld has bound the framework and before its initializers run.
// dyld honours no interposing from a main executable, so the bound
// pointers are rewritten in place.
static void probe_redirect_unregister(const struct mach_header* header, intptr_t slide) {
  Dl_info info;
  if (!dladdr(header, &info) || !strstr(info.dli_fname, "Chromium Embedded Framework")) {
    return;
  }
  const uintptr_t target = (uintptr_t)&malloc_zone_unregister;
  const struct load_command* command =
      (const struct load_command*)((const char*)header + sizeof(struct mach_header_64));
  for (uint32_t index = 0; index < header->ncmds; index++) {
    if (command->cmd == LC_SEGMENT_64) {
      const struct segment_command_64* segment = (const struct segment_command_64*)command;
      if (strncmp(segment->segname, "__DATA", 6) == 0 || strncmp(segment->segname, "__AUTH", 6) == 0) {
        uintptr_t* words = (uintptr_t*)(segment->vmaddr + slide);
        size_t count = segment->vmsize / sizeof(uintptr_t);
        for (size_t word = 0; word < count; word++) {
          if (words[word] != target) continue;
          uintptr_t page = (uintptr_t)&words[word] & ~(uintptr_t)(getpagesize() - 1);
          mprotect((void*)page, getpagesize(), PROT_READ | PROT_WRITE);
          words[word] = (uintptr_t)&probe_malloc_zone_unregister;
        }
      }
    }
    command = (const struct load_command*)((const char*)command + command->cmdsize);
  }
}

static int failures = 0;

static void expect(int condition, const char* what) {
  if (!condition) {
    fprintf(stderr, "CefLoaderProbe: %s\n", what);
    failures += 1;
  }
}

static int check(const char* binary) {
  if (!ccef_load_framework(binary)) {
    fprintf(stderr, "CefLoaderProbe: %s\n", ccef_loader_error());
    return 1;
  }
  expect(ccef_is_framework_loaded() == 1, "the framework is not reported loaded");
  expect(ccef_has_symbol("cef_initialize") == 1, "cef_initialize is not exported");
  expect(ccef_has_symbol("cef_no_such_function") == 0, "a missing function is reported");

  // cef_api_hash must be the first CEF call in the process.
  const char* hash = cef_api_hash(ccef_pinned_api_version(), 0);
  expect(hash != NULL, "cef_api_hash returned NULL");
  if (hash && strcmp(hash, ccef_pinned_api_hash()) != 0) {
    fprintf(stderr, "CefLoaderProbe: API hash %s, the headers pin %s\n", hash, ccef_pinned_api_hash());
    failures += 1;
  }
  expect(cef_api_version() == ccef_pinned_api_version(), "the framework runs another API version");

  // A string conversion implemented by the framework.
  cef_string_utf16_t utf16 = {0};
  expect(cef_string_utf8_to_utf16("loader-test", 11, &utf16) == 1, "UTF-8 to UTF-16 failed");
  const char* expected = "loader-test";
  int same = utf16.length == strlen(expected);
  for (size_t index = 0; same && index < utf16.length; index++) {
    same = utf16.str[index] == (char16_t)expected[index];
  }
  expect(same, "the converted string differs");
  cef_string_utf16_clear(&utf16);
  return failures ? 1 : 0;
}

int main(int argc, char** argv) {
  if (argc == 3 && strcmp(argv[1], "check") == 0) {
    return check(argv[2]);
  }
  if (argc == 3 && strcmp(argv[1], "free-during-load") == 0) {
    // The trap is expected: the signal ends the probe without a crash report.
    task_set_exception_ports(mach_task_self(), EXC_MASK_BREAKPOINT, MACH_PORT_NULL, EXCEPTION_DEFAULT, 0);
    g_system_block = malloc(64);
    _dyld_register_func_for_add_image(probe_redirect_unregister);
    if (!ccef_load_framework(argv[2])) {
      fprintf(stderr, "CefLoaderProbe: %s\n", ccef_loader_error());
      return 1;
    }
    fprintf(stderr, g_system_block ? "CefLoaderProbe: the framework did not unregister a zone\n"
                                   : "CefLoaderProbe: the free inside the window did not trap\n");
    return 2;
  }
  fprintf(stderr, "usage: CefLoaderProbe check|free-during-load <framework binary>\n");
  return 64;
}
