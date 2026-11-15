// CefSwift — framework-independent cef_string_t helpers (see ccef_string.h).

#include "ccef_string.h"

void ccef_string_clear(cef_string_utf16_t* out) {
  if (out->dtor && out->str) {
    out->dtor(out->str);
  }
  out->str = NULL;
  out->length = 0;
  out->dtor = NULL;
}
