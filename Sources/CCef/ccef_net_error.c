// CefSwift — names of Chromium's network errors (see ccef_net_error.h).

#include "ccef_net_error.h"

const char* ccef_net_error_name(int code) {
  switch (code) {
#define NET_ERROR(label, value) \
  case value:                   \
    return #label;
#include "include/base/internal/cef_net_error_list.h"
#undef NET_ERROR
    default:
      return 0;
  }
}
