// CefSwift — framework-independent cef_string_t helpers (see ccef_string.h).

#include "ccef_string.h"

#include <stdlib.h>
#include <string.h>

static void ccef_string_dtor(char16_t* str) {
  free(str);
}

int ccef_string_set_utf16(const char16_t* src, size_t length,
                          cef_string_utf16_t* out) {
  ccef_string_clear(out);
  if (length == 0) {
    return 1;
  }
  char16_t* copy = malloc((length + 1) * sizeof(char16_t));
  if (!copy) {
    return 0;
  }
  memcpy(copy, src, length * sizeof(char16_t));
  copy[length] = 0;
  out->str = copy;
  out->length = length;
  out->dtor = ccef_string_dtor;
  return 1;
}

void ccef_string_clear(cef_string_utf16_t* out) {
  if (out->dtor && out->str) {
    out->dtor(out->str);
  }
  out->str = NULL;
  out->length = 0;
  out->dtor = NULL;
}
