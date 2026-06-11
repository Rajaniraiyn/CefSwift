// CefSwift — CCef umbrella header.
//
// Exposes the CEF C API (capi) plus the CefSwift runtime loader to Swift.
// Only C-safe headers are included here; the C++ headers in include/*.h,
// include/base and include/wrapper are vendored for reference but never
// imported into the module.

#ifndef CCEF_H_
#define CCEF_H_

// Pin the API version before any CEF header.
#include "ccef_config.h"

// Version / API hash.
#include "include/cef_api_hash.h"
#include "include/cef_api_versions.h"
#include "include/cef_version.h"
#include "include/cef_version_info.h"

// Internal C types.
#include "include/internal/cef_export.h"
#include "include/internal/cef_string_types.h"
#include "include/internal/cef_string.h"
#include "include/internal/cef_string_list.h"
#include "include/internal/cef_string_map.h"
#include "include/internal/cef_string_multimap.h"
#include "include/internal/cef_time.h"
#include "include/internal/cef_types.h"
#include "include/internal/cef_types_geometry.h"
#include "include/internal/cef_types_color.h"
#include "include/internal/cef_types_runtime.h"
#include "include/internal/cef_types_mac.h"
#include "include/internal/cef_logging_internal.h"
#include "include/internal/cef_thread_internal.h"

// C API.
#include "include/capi/cef_base_capi.h"
#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_browser_process_handler_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_command_line_capi.h"
#include "include/capi/cef_context_menu_handler_capi.h"
#include "include/capi/cef_cookie_capi.h"
#include "include/capi/cef_dialog_handler_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_download_handler_capi.h"
#include "include/capi/cef_drag_handler_capi.h"
#include "include/capi/cef_find_handler_capi.h"
#include "include/capi/cef_focus_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_frame_handler_capi.h"
#include "include/capi/cef_jsdialog_handler_capi.h"
#include "include/capi/cef_keyboard_handler_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_navigation_entry_capi.h"
#include "include/capi/cef_permission_handler_capi.h"
#include "include/capi/cef_preference_capi.h"
#include "include/capi/cef_print_handler_capi.h"
#include "include/capi/cef_process_message_capi.h"
#include "include/capi/cef_registration_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/capi/cef_request_capi.h"
#include "include/capi/cef_request_context_capi.h"
#include "include/capi/cef_request_context_handler_capi.h"
#include "include/capi/cef_request_handler_capi.h"
#include "include/capi/cef_v8_capi.h"
#include "include/capi/cef_resource_handler_capi.h"
#include "include/capi/cef_resource_request_handler_capi.h"
#include "include/capi/cef_response_capi.h"
#include "include/capi/cef_scheme_capi.h"
#include "include/capi/cef_string_visitor_capi.h"
#include "include/capi/cef_task_capi.h"
#include "include/capi/cef_values_capi.h"

// Views framework (chrome-style windows: cef_browser_view + cef_window).
#include "include/capi/views/cef_view_capi.h"
#include "include/capi/views/cef_view_delegate_capi.h"
#include "include/capi/views/cef_panel_capi.h"
#include "include/capi/views/cef_panel_delegate_capi.h"
#include "include/capi/views/cef_browser_view_capi.h"
#include "include/capi/views/cef_browser_view_delegate_capi.h"
#include "include/capi/views/cef_window_capi.h"
#include "include/capi/views/cef_window_delegate_capi.h"

// CefSwift runtime loader + helpers.
#include "ccef_loader.h"
#include "ccef_object.h"
#include "ccef_sandbox.h"
#include "ccef_string.h"

#endif  // CCEF_H_
