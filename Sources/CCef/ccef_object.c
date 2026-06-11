// CefSwift — generic refcounted CEF object allocator (see ccef_object.h).

#include "ccef_object.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct ccef_object_header_t {
  _Atomic(int32_t) ref_count;
  void* swift_object;
  ccef_object_on_zero_t on_zero;
  // The cef struct follows, 16-byte aligned.
} ccef_object_header_t;

// Keep the cef struct max_align_t-aligned regardless of header size.
#define CCEF_HEADER_SIZE \
  ((sizeof(ccef_object_header_t) + 15u) & ~(size_t)15u)

static ccef_object_header_t* ccef_header(void* cef_self) {
  return (ccef_object_header_t*)((char*)cef_self - CCEF_HEADER_SIZE);
}

static void CEF_CALLBACK ccef_base_add_ref(cef_base_ref_counted_t* self) {
  atomic_fetch_add_explicit(&ccef_header(self)->ref_count, 1,
                            memory_order_relaxed);
}

static int CEF_CALLBACK ccef_base_release(cef_base_ref_counted_t* self) {
  ccef_object_header_t* header = ccef_header(self);
  int32_t previous = atomic_fetch_sub_explicit(&header->ref_count, 1,
                                               memory_order_acq_rel);
  if (previous == 1) {
    if (header->on_zero) {
      header->on_zero(header->swift_object);
    }
    free(header);
    return 1;
  }
  return 0;
}

static int CEF_CALLBACK ccef_base_has_one_ref(cef_base_ref_counted_t* self) {
  return atomic_load_explicit(&ccef_header(self)->ref_count,
                              memory_order_acquire) == 1;
}

static int CEF_CALLBACK
ccef_base_has_at_least_one_ref(cef_base_ref_counted_t* self) {
  return atomic_load_explicit(&ccef_header(self)->ref_count,
                              memory_order_acquire) >= 1;
}

void* ccef_object_alloc(size_t struct_size, void* swift_object,
                        ccef_object_on_zero_t on_zero) {
  ccef_object_header_t* header = calloc(1, CCEF_HEADER_SIZE + struct_size);
  if (!header) {
    return NULL;
  }
  atomic_store_explicit(&header->ref_count, 1, memory_order_relaxed);
  header->swift_object = swift_object;
  header->on_zero = on_zero;

  cef_base_ref_counted_t* base =
      (cef_base_ref_counted_t*)((char*)header + CCEF_HEADER_SIZE);
  base->size = struct_size;
  base->add_ref = ccef_base_add_ref;
  base->release = ccef_base_release;
  base->has_one_ref = ccef_base_has_one_ref;
  base->has_at_least_one_ref = ccef_base_has_at_least_one_ref;
  return base;
}

void* ccef_object_get_swift(void* cef_self) {
  return ccef_header(cef_self)->swift_object;
}

void ccef_object_add_ref(void* cef_self) {
  ccef_base_add_ref((cef_base_ref_counted_t*)cef_self);
}

int ccef_object_release(void* cef_self) {
  return ccef_base_release((cef_base_ref_counted_t*)cef_self);
}

int ccef_object_ref_count(void* cef_self) {
  return atomic_load_explicit(&ccef_header(cef_self)->ref_count,
                              memory_order_acquire);
}
