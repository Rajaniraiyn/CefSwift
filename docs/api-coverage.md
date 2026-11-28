# API coverage

What of CEF's C API (the vendored `cef_*_capi.h` headers in
`Sources/CCef/include/include/capi`) and of the Chromium-private services
CefChromium binds CefSwift exposes as public API. It is a map for
contributors deciding what to add next, and for embedders checking whether
something exists before they reach for `page.devTools` or a command-line
switch.

The audit was made on 2026-11-28 against CEF 158.0.6 (Chromium
158.0.8127.89) with the C API pinned at `CEF_API_VERSION` 15600
(`Sources/CCef/include/ccef_config.h`). A struct member or exported
function counts as used when a Swift source of `CefKit`, `CefChromium`,
`CefPasskeys`, `CefRenderer`, `CefBase` or `CefSwiftUI` names it; the
public name next to it was checked by hand.

| Status | Meaning |
|---|---|
| **Exposed** | Public API covers what CEF offers. |
| **Partial** | Public API covers some of it; the row says what is left. |
| **Not exposed** | Left out on purpose; the row says why. |
| **Missing** | Nothing reaches it yet. |

Not every unused member is a gap. CefKit uses CEF's reference counting,
values, strings, task posting, threads, streams and images internally,
without public types of their own, and Swift and Foundation replace CEF's
URL, Base64, JSON, MIME, XML, ZIP and file utilities. Those rows are at the
end ([Utilities CefSwift uses internally](#utilities-cefswift-uses-internally)).

## API added after the pin

CEF 158 adds members at API version 15800 that the 15600 pin does not
compile in. Using them means moving the pin
([automation](automation.md#moving-cef_api_version)); until then they are
**Missing**.

| CEF API | What it does | Who would use it |
|---|---|---|
| `cef_browser_host_t.send_keyboard_event`, `send_mouse_event`, `send_gesture_event`, `send_wheel_event` | Portable input snapshots injected into web content, for windowed pages as well as offscreen ones, from any thread | Automation and agents that drive a windowed page without the DevTools Protocol's `Input` domain |
| `cef_client_t.get_input_handler`, `cef_input_handler_t` (`on_pre_keyboard_event`, `on_keyboard_event`, `on_pre_mouse_event`, `on_pre_gesture_event`) | Sees and can swallow input before web content gets it | Gesture and shortcut handling for windowed pages |
| `cef_keyboard_input_event_from_mac_event_ex` and the other `cef_input_event_utils_capi.h` functions | Converts an `NSEvent` into CEF's portable keyboard event | The offscreen view's key translation (`CefKeyCodes.swift` does this by hand today) |
| `cef_window_delegate_t` and `cef_textfield_delegate_t.on_keyboard_event` (15800 variants) | Portable keyboard events for CEF Views | Only CEF Views controls, which CefSwift does not expose |

`cef_browser_host_t.set_ax_viewport_collapse` is `CEF_EXPERIMENTAL` and is
left out with every experimental member.

## Browser host

`cef_browser_t` and `cef_browser_host_t`: 15 of 21 and 55 of 73 members
used.

| CEF API | CefSwift | Status |
|---|---|---|
| Navigation: `load_url`, `go_back`, `go_forward`, `reload`, `reload_ignore_cache`, `stop_load`, `get_navigation_entries`, `get_visible_navigation_entry` | `CefPage.load(_:)`, `goBack()`, `goForward()`, `reload(ignoringCache:)`, `stopLoading()`, `backForwardList`, `canGoBack`, `isLoading` (from the load handler) | Exposed |
| `can_go_back`, `can_go_forward`, `is_loading`, `has_document` | The same state, tracked from `cef_load_handler_t` and observable | Not exposed: the handler's events are the source of truth, so the polling getters are not called |
| Lifetime: `close_browser`, `try_close_browser`, `is_ready_to_be_closed` | `CefPage.close(force:)`, `confirmLeavingPage`, `CefBeforeUnloadListeners` | Exposed (`is_ready_to_be_closed` is Views-only bookkeeping CefKit does not need) |
| Find: `find`, `stop_finding` | `find(_:backwards:caseSensitive:)`, `findResult`, `stopFinding(clearingSelection:)`, `CefFindSession` | Exposed |
| Zoom: `set_zoom_level`, `get_zoom_level`, `get_default_zoom_level`, `can_zoom`, `zoom` | `zoomLevel` (observable), `defaultZoomLevel`, `canZoom(_:)`, `zoom(_:)` | Exposed |
| Per-host zoom levels (Chromium's `HostZoomMap`, the `partition.per_host_zoom_levels` preference) | Setting `zoomLevel` sets the level of the page's site | Partial: no list of the sites with a saved level, and no way to set or forget one without a page on that site |
| Audio: `set_audio_muted`, `is_audio_muted` | `isAudioMuted` (observable) | Exposed |
| `print` | `CefPage.print()`: Chromium's print preview or the system dialog | Exposed |
| `print_to_pdf`, `cef_pdf_print_settings_t` | `pdf(configuration:)`, `printToPDF(at:configuration:)`, `PDFConfiguration` (paper, orientation, margins, scale, ranges, header and footer templates, tagged PDF, outline) | Exposed |
| `cef_print_handler_t`, `cef_print_settings_t` | — | Not exposed: Linux only, per its header; macOS printing goes through Chromium's own preview and the system dialog |
| `download_image` | `favicon` | Partial: used for favicons only; any image can be fetched with `CefProfile.data(from:)` |
| `start_download` | `CefProfile`'s download API, `CefDownload` | Exposed |
| `show_dev_tools`, `close_dev_tools`, `has_dev_tools` | `showDevTools(inspecting:)` | Exposed; docked DevTools is not possible ([Known limits](guide.md#known-limits)) |
| `send_dev_tools_message`, `add_dev_tools_message_observer` | `CefDevTools.send`, `events(_:bufferingPolicy:)` | Exposed |
| `execute_dev_tools_method` | `send_dev_tools_message` builds the same message | Not exposed: one path is enough |
| `set_auto_resize_enabled`, `cef_display_handler_t.on_auto_resize` | — | Missing: sizing a view to its content (popovers, inline widgets) |
| `run_file_dialog` | — | Not exposed: an app shows `NSOpenPanel` itself |
| `replace_misspelling`, `add_word_to_dictionary` | `replaceMisspelling(with:)`, `learnSpelling(_:)` | Exposed |
| `exit_fullscreen`, `cef_display_handler_t.on_fullscreen_mode_change` | `exitFullscreen()`, `isFullscreen` | Exposed |
| `is_fullscreen` | `isFullscreen` | Not exposed: the handler's event is the source |
| `execute_chrome_command`, `can_execute_chrome_command`, `cef_command_handler_t` | `execute(_:disposition:)`, `CefChromeCommand`, `page(_:handleChromeCommand:disposition:)` | Exposed |
| `set_accessibility_state` | `setAccessibilityEnabled(_:)` | Exposed |
| `notify_screen_info_changed`, `was_resized`, `was_hidden`, `invalidate`, `set_windowless_frame_rate`, `send_external_begin_frame`, `send_*_event`, `ime_*`, `drag_*` | The offscreen host views and `CefPage`'s offscreen input methods | Exposed |
| `is_render_process_unresponsive`, `cef_request_handler_t.on_render_process_unresponsive` | `pageIsUnresponsive(_:)`, `UnresponsivePagePolicy` | Exposed through the event |
| `get_opener_identifier`, `get_opener_window_handle` | `page(_:didOpen:)`, CefKit's own opener tracking | Not exposed: CefKit tracks openers itself, including ones CEF does not report |
| `get_runtime_style`, `cef_browser_view_t.get_runtime_style` | The host decides the style (`CefWebView` Alloy, `CefWindow` Chrome) | Not exposed: the app chose it |
| `get_frame_by_name`, `get_frame_names` | `frames`, `frame(withID:)` | Partial: by identifier, not by name; filter `frames` by `name` |

## Frames

`cef_frame_t`: 22 of 26 members used. `cef_frame_handler_t`: all used.

| CEF API | CefSwift | Status |
|---|---|---|
| `get_identifier`, `get_name`, `get_url`, `is_main`, `get_parent`, `cef_frame_handler_t` | `CefFrame`, `CefPage.frames` (observable) | Exposed |
| `execute_java_script`, renderer evaluation | `executeJavaScript(_:in:)`, `evaluateJavaScript(_:in:timeout:)` | Exposed |
| `get_source`, `get_text` | `source(of:)`, `text(of:)` | Exposed |
| `load_request`, `load_url` | `CefPage.load(_:)` with a `URLRequest` (main frame, same origin) | Partial: only the main frame, and only within its origin (a CEF limit) |
| `undo`, `redo`, `cut`, `copy`, `paste`, `paste_and_match_style`, `del`, `select_all` | `CefPage+Editing`'s editing commands | Exposed |
| `view_source` | `CefChromeCommand.viewSource` in Chrome-style pages | Partial: no direct call for Alloy pages |
| `visit_dom`, `cef_domdocument_t`, `cef_domnode_t` | — | Not exposed: renderer-only and slower than evaluating JavaScript; CefSwift's renderer side is the bridge and evaluation |
| `create_urlrequest` | `CefProfile.data(for:)`, `bytes(for:)`, `download(for:to:)` | Not exposed per frame: the profile's requests cover it |
| `is_focused` | `CefPage+Focus` tracks focus | Not exposed |

## Requests and network

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_request_handler_t.get_resource_request_handler`, `cef_resource_request_handler_t.on_before_resource_load`, `cef_cookie_access_filter_t` | `CefRequestFilter` (profile and page), `CefResourceRequest`, `CefResourceRequestAction` | Exposed |
| `cef_resource_request_handler_t.on_resource_response`, `on_resource_redirect`, `on_resource_load_complete`, `get_resource_response_filter`, `cef_response_filter_t` | — | Missing: response inspection and rewriting ([Known limits](guide.md#known-limits)) |
| `cef_resource_request_handler_t.get_resource_handler` | Scheme handlers | Partial: custom content per scheme, not per request |
| `cef_scheme_registrar_t`, `cef_scheme_handler_factory_t`, `cef_resource_handler_t` | `CefCustomScheme`, `CefSchemeHandler`, `registerSchemeHandler(scheme:domain:handler:)` (runtime and profile), range requests, streamed and file bodies | Exposed |
| `cef_clear_scheme_handler_factories`, `cef_request_context_t.clear_scheme_handler_factories` | `removeSchemeHandler(scheme:domain:)` | Exposed one at a time |
| `cef_urlrequest_t`, `cef_urlrequest_client_t` | `CefProfile.data(for:)`, `bytes(for:)`, `download(for:to:)`, `RequestConfiguration` (credentials, progress, redirects, stream limits) | Exposed |
| `cef_request_handler_t.get_auth_credentials`, `cef_auth_callback_t` | `page(_:credentialFor:)`, `AuthenticationPromptPolicy` | Exposed |
| `cef_request_handler_t.on_certificate_error` | `page(_:shouldProceedDespite:)`, `CefCertificateError`, the built-in interstitial | Exposed |
| `cef_request_handler_t.on_select_client_certificate` | `page(_:selectClientCertificateFor:)`, `ClientCertificatePolicy`, `CefClientCertificatePresenter` | Exposed |
| `cef_sslstatus_t`, `cef_sslinfo_t`, `cef_x509_certificate_t` | `connectionSecurity`, `CefCertificate` (`secCertificate`, chain, fingerprints) | Exposed (`get_pemencoded` is not used; `derRepresentation` is the source) |
| `cef_request_handler_t.on_open_urlfrom_tab`, `on_before_browse`, `cef_life_span_handler_t.on_before_popup` | `decidePolicyFor`, `decideWindowOpenFor`, `CefWindowOpenDecision` | Exposed |
| `cef_life_span_handler_t.on_before_popup_aborted`, `on_before_dev_tools_popup` | — | Not exposed: CefKit's popup bookkeeping does not need them |
| `cef_request_context_t.clear_http_cache`, `clear_certificate_exceptions`, `clear_http_auth_credentials`, `close_all_connections`, `resolve_host` | `clearHTTPCache()`, `clearCertificateExceptions()`, `clearHTTPAuthenticationCredentials()`, `closeAllConnections()`, `resolveHost(_:)` | Exposed |
| `cef_add_cross_origin_whitelist_entry`, `cef_remove_cross_origin_whitelist_entry`, `cef_clear_cross_origin_whitelist` | — | Missing: lets a custom scheme's pages read another origin without CORS headers |
| `cef_request_handler_t.on_document_available_in_main_frame`, `on_render_view_ready` | `CefPage`'s load events | Not exposed |
| `cef_server_t`, `cef_server_handler_t` | — | Not exposed: an HTTP and WebSocket server is an app's choice (Network.framework, SwiftNIO) |

## Cookies and storage

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_cookie_manager_t` (`visit_all_cookies`, `visit_url_cookies`, `set_cookie`, `delete_cookies`, `flush_store`) | `CefProfile.cookies(for:)`, `enumerateCookies`, `setCookie(_:for:)`, `deleteCookies(for:named:)`, `flushCookies()` | Exposed |
| `cef_cookie_manager_get_global_manager` | Each profile's context's manager | Not exposed: the global manager is the default profile's |
| Site data other than cookies (local storage, IndexedDB, cache storage, service workers) for one origin | — | Missing: CEF has no call; Chromium's DevTools `Storage.clearDataForOrigin` does it in an open page |
| All browsing data | `CefChromeCommand.clearBrowsingData` (Chrome's dialog) | Partial: no programmatic call |
| `CefPage.Configuration` storage switches | `CefPage.Configuration.content` (`localStorage` and the rest) | Exposed |

## Media and permissions

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_permission_handler_t.on_request_media_access_permission`, `on_show_permission_prompt`, `on_dismiss_permission_prompt` | `decidePermissionFor`, `CefPermissionRequest` (camera, microphone, screen capture, system audio and the rest), `CefPermissionDecision`, the built-in sheet | Exposed |
| `cef_request_context_t.set_content_setting`, `get_content_setting` | `profile.siteSettings` (`CefSiteSettings`: per-origin settings, defaults, exceptions, changes) | Exposed |
| `cef_request_context_t.get_website_setting`, `set_website_setting` | — | Missing: website settings that are not content settings (dictionaries, such as a site's chosen devices) |
| Choosing which camera or microphone a page gets | — | Missing: CEF passes no device list to `on_request_media_access_permission`; Chromium picks the default device, and a page can pick with `getUserMedia` constraints |
| `getDisplayMedia` picker | Chrome-style pages show Chromium's picker; `screenCapture` permission | Partial: no hook to supply the app's own picker or a preselected source |
| `cef_display_handler_t.on_media_access_change` | `mediaCapture` (observable) | Exposed |
| `cef_media_router_t`, `cef_media_sink_t`, `cef_media_route_t`, `cef_media_observer_t` | `CefMediaRouter`, `Sink`, `Route`, `cast(_:to:)` | Partial: `send_route_message`, `get_device_info` and the sink icon type are not exposed |
| `cef_audio_handler_t` | — | Missing: capture of a page's decoded audio |
| Picture in Picture: `cef_browser_view_delegate_t.allow_picture_in_picture_without_user_activation`, `use_frameless_window_for_picture_in_picture`, `allow_move_for_picture_in_picture` | `CefContextMenuCommand.pictureInPicture`, media flags in `CefContextMenuTarget` | Partial: no `CefWindow` option for the Picture in Picture window, and no call to enter or leave it |
| `cef_component_updater_t` | Widevine through `Services.ProtectedMedia` | Exposed for its one use |

## Printing and PDF

See [Browser host](#browser-host): `print()`, `pdf(configuration:)` and
`printToPDF(at:configuration:)` are exposed, and `cef_print_handler_t` is
Linux only.

## Downloads

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_download_handler_t` (`can_download`, `on_before_download`, `on_download_updated`) | `CefProfileDelegate.decideDestinationFor`, `DownloadPolicy`, `CefDownloadDecision`, `CefDownloadPresenter` | Exposed |
| `cef_download_item_t`, `cef_download_item_callback_t` | `CefDownload` (observable; state, progress, rate, `pause()`, `resume()`, `cancel()`), `profile.downloads` | Exposed (`get_percent_complete` and `get_content_disposition` are not used) |

## Preferences

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_preference_manager_t` (`has_preference`, `get_preference`, `get_all_preferences`, `can_set_preference`, `set_preference`, `add_preference_observer`) | `profile.preferences` and `CefRuntime.shared.preferences` (`CefPreferences`): typed keys, raw names, observation, reset | Exposed |
| Typed keys | `savesPasswords`, `fillsAddresses`, `checksSpelling`, `spellingLanguages`, `acceptLanguages`, `thirdPartyCookies`, font sizes, `homePage` and more | Exposed; any other preference is a `Key` the app declares |
| `cef_browser_process_handler_t.on_register_custom_preferences`, `cef_preference_registrar_t` | — | Missing: preferences of the app's own, kept with Chromium's |
| `cef_preference_manager_get_chrome_variations_as_switches`, `_as_strings` | — | Not exposed: diagnostic only |
| `cef_request_context_t.set_chrome_color_scheme` | `CefProfile.setColorScheme(_:accentColor:)` | Partial: the getters are not exposed |
| Spellcheck | `checksSpelling`, `spellingLanguages`, `replaceMisspelling(with:)`, `learnSpelling(_:)`, the context menu's spelling items | Exposed; on macOS Chromium uses the system spell checker, so there are no dictionaries to download |

## Extensions

CEF 158's C API has no extension API: CefSwift reaches Chromium's own
extension system.

| Service | CefSwift | Status |
|---|---|---|
| Installing with the app | `CefRuntime.Configuration.extensions` (`webStore`, `package`, `unpacked`) | Exposed |
| Chromium's `chrome.developerPrivate` and `chrome.management` on `chrome://extensions` | CefChromium's `CefExtensions`: list, enable, uninstall, site access, incognito, pinning, reload, updates, developer mode, load unpacked, pack | Exposed |
| Toolbar actions and popups | Chromium's own toolbar in Chrome-style windows, `chromiumSurfacePolicy` | Exposed |

## Views

CEF Views is how CefSwift makes Chrome-style windows. Its controls are
not exposed: an app builds its interface in AppKit or SwiftUI.

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_window_t`, `cef_window_delegate_t`, `cef_browser_view_t`, `cef_browser_view_delegate_t` | `CefWindow` (toolbar, frame, frameless, title, tabbing, accessories, insets, corner radius, page overlay), `CefWindow.window` for the `NSWindow` | Exposed; the window's AppKit object covers minimize, zoom, full screen and the rest |
| `cef_window_t.show_as_browser_modal_dialog`, `add_overlay_view`, `set_accelerator`, `show_menu` | `pageOverlay`, `NSMenu` | Not exposed: AppKit does it |
| `cef_overlay_controller_t` | `pageOverlay` | Partial: used internally for the overlay |
| `cef_panel_t`, `cef_label_button_t`, `cef_menu_button_t`, `cef_textfield_t`, `cef_scroll_view_t`, `cef_box_layout_t`, `cef_fill_layout_t` | — | Not exposed: Views controls draw in Chromium's style, not AppKit's |
| `cef_display_t`, `cef_display_get_*` | `NSScreen` | Not exposed |
| `cef_browser_view_delegate_t` Picture in Picture members | — | Missing (see [Media and permissions](#media-and-permissions)) |

## DevTools and the DevTools Protocol

| CEF API | CefSwift | Status |
|---|---|---|
| `send_dev_tools_message`, `cef_dev_tools_message_observer_t` | `page.devTools`: `send(_:_:)`, `send(_:_:as:)` (`Decodable` result), `events(_:bufferingPolicy:)`, domain leases shared with CefKit's own features | Exposed |
| Typed protocol commands (input, screenshots, DOM and accessibility snapshots) | `send(_:_:as:)` decodes a result; parameters are `CefJSON` | Partial: no typed commands, and a typed result is decoded from a `CefJSON` tree rather than from the reply's bytes |
| Screenshots | `CefPage.snapshot()` (PNG; offscreen frames without the protocol), CefChromium's `CefTab.capturePreview(scale:)` | Exposed |
| `remote_debugging_port` | `CefRuntime.Configuration.remoteDebuggingPort` | Exposed |
| `cef_begin_tracing`, `cef_end_tracing`, `cef_end_tracing_callback_t` | — | Missing: a Chromium trace (`chrome://tracing` and Perfetto format) without DevTools |

## Accessibility

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_accessibility_handler_t` | `CefOffscreenPageView`'s accessibility elements, `CefAccessibilityTree`, `CefAccessibilityNode`, `requestAccessibilityTree()`, `performAccessibilityAction(_:on:)` | Exposed |
| `set_accessibility_state` | `setAccessibilityEnabled(_:)` | Exposed |
| Windowed and Chrome-style pages | Chromium's own `NSAccessibility` objects | Exposed by Chromium |
| `cef_render_handler_t.on_virtual_keyboard_requested`, `get_touch_handle_size`, `on_touch_handle_state_changed` | — | Not exposed: touch selection handles and virtual keyboards do not apply on the Mac |

## Process messages and V8

CefSwift's renderer side (`CefRenderer`, run by the helper) is not
extensible by apps: what an app's code would do in the renderer, it does
through bridges, user scripts and evaluation, so the helper stays a
generic executable that `cef bundle` builds.

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_process_message_t`, `cef_shared_process_message_builder_t`, `cef_shared_memory_region_t` | `CefBridge` (typed `handle` methods, `emit`), payloads in shared memory from 64 KB | Exposed through the bridge |
| `cef_render_process_handler_t.on_context_created`, `on_context_released`, `on_browser_created`, `on_process_message_received` | Bridges, `CefUserScript`, evaluation | Exposed through those |
| `on_web_kit_initialized`, `on_uncaught_exception`, `on_focused_node_changed` | — | Not exposed: no app code runs in the renderer; `didLog` reports uncaught errors as console messages |
| `cef_v8_context_t`, `cef_v8_value_t`, `cef_v8_handler_t`, `cef_v8_accessor_t`, `cef_v8_interceptor_t` | `CefRenderer`'s bridge functions and `V8Wire` | Not exposed: internal |
| `cef_register_extension` (V8 extensions) | — | Not exposed: user scripts and bridges cover it |
| Worker and service-worker contexts | — | Missing: CEF reports only frames' contexts, so bridges and user scripts do not reach workers |

## Application and runtime

| CEF API | CefSwift | Status |
|---|---|---|
| `cef_initialize`, `cef_shutdown`, `cef_do_message_loop_work`, `on_schedule_message_pump_work` | `CefRuntime.initialize(configuration:)`, `CefMessagePump`, quitting | Exposed |
| `cef_run_message_loop`, `cef_quit_message_loop`, `cef_set_nestable_tasks_allowed` | — | Not exposed: the app's run loop drives Chromium |
| `cef_settings_t` | `CefRuntime.Configuration` | Exposed |
| `cef_app_t.on_before_command_line_processing`, `cef_command_line_t` | `extraCommandLineSwitches`, `onBeforeCommandLineProcessing`, `CefCommandLine` | Exposed |
| `cef_resource_bundle_handler_t.get_localized_string` | `stringOverrides` | Exposed (`get_data_resource` is not) |
| `cef_task_manager_t` | `CefTaskManager` | Exposed |
| `cef_set_crash_key_value`, `cef_crash_reporting_enabled` | — | Missing: crash keys for apps that configure Chromium's crash reporter |
| `cef_browser_host_get_browser_by_identifier` | `CefRuntime`'s registry | Not exposed |
| `cef_launch_process` | `Process` | Not exposed |

## Chromium-private services (CefChromium)

CefChromium reaches Chromium's own WebUI services from hidden service
hosts ([architecture](architecture.md#internal-page-services)).

| Service | CefSwift | Status |
|---|---|---|
| `chrome.bookmarks` on `chrome://bookmarks`, the `Bookmarks` file | `CefBookmarks` | Exposed |
| `history.mojom.PageHandler` on `chrome://history` | `CefHistory.search`, `remove`, `favicon` | Exposed |
| `most_visited.mojom` on `chrome://new-tab-page-third-party` | `CefHistory.topSites()` | Exposed |
| `mojom.OmniboxInternalsPageHandler` on `chrome://omnibox-internals` | `CefAutocomplete` | Exposed (experimental) |
| `tab_strip_internals.mojom`, `chrome.tabs`, `chrome.windows` | `CefTabs`, `CefTab`, `CefTabGroup`, `CefChromeWindow`, sessions | Exposed |
| `discards.mojom` on `chrome://discards` | `CefPage.discard()`, Memory Saver | Exposed |
| `chrome.developerPrivate`, `chrome.management` | `CefExtensions` | Exposed |
| Chromium's AppKit bubbles and surfaces | `CefChromiumSurface`, `chromiumSurfacePolicy` | Exposed |
| Browsing-data removal (`chrome://settings`' clear-browsing-data handler) | — | Missing |
| Saved zoom levels (`chrome://settings`' zoom-levels handler) | — | Missing |
| Password manager | Chromium's own interface in Chrome-style windows | Not exposed: no service host binds it, and passwords belong to Chromium's UI |

## Utilities CefSwift uses internally

| CEF API | Why it has no public API |
|---|---|
| `cef_value_t`, `cef_dictionary_value_t`, `cef_list_value_t`, `cef_binary_value_t` | Process messages and preferences; `CefJSON` is the public value |
| `cef_task_t`, `cef_task_runner_t`, `cef_post_task`, `cef_thread_t`, `cef_waitable_event_t` | `CefIOActor`, `CefFileActor` and `CefThreadExecutor` |
| `cef_stream_reader_t`, `cef_stream_writer_t`, `cef_read_handler_t`, `cef_write_handler_t` | Scheme handler and upload bodies; `Data`, files and `AsyncSequence` are public |
| `cef_image_t` | Favicons and drag images; `NSImage` is public |
| `cef_menu_model_t`, `cef_menu_model_delegate_t`, `cef_run_context_menu_callback_t` | `CefContextMenu` (14 of 56 menu-model members: enough to read and rebuild the menu) |
| `cef_drag_data_t`, `cef_drag_handler_t` | Offscreen drag and drop, draggable regions |
| `cef_parse_url`, `cef_create_url`, `cef_resolve_url`, `cef_uriencode`, `cef_uridecode`, `cef_base64_*`, `cef_parse_json*`, `cef_get_mime_type`, `cef_get_extensions_for_mime_type` | Foundation |
| `cef_xml_reader_t`, `cef_zip_reader_t`, `cef_file_util_capi.h`, `cef_path_util_capi.h`, `cef_is_rtl` | Foundation |
