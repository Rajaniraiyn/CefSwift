// CefSwift — X-macro table of every cef_* global resolved from the framework.
//
// Adding a symbol is a one-liner here. Define CCEF_SYM / CCEF_SYM_VOID before
// including this file:
//
//   CCEF_SYM(return_type, name, (param decls), (param names))   -> returns
//   CCEF_SYM_VOID(name, (param decls), (param names))           -> void
//
// Every symbol listed here is dlsym'd at ccef_load_framework() time; a missing
// symbol fails the load with the symbol name in ccef_loader_error().

// --- API hash / version ----------------------------------------------------
CCEF_SYM(const char*, cef_api_hash, (int version, int entry), (version, entry))
CCEF_SYM(int, cef_api_version, (void), ())
CCEF_SYM(int, cef_version_info, (int entry), (entry))

// --- Process / lifecycle ---------------------------------------------------
CCEF_SYM(int, cef_execute_process,
         (const cef_main_args_t* args, cef_app_t* application,
          void* windows_sandbox_info),
         (args, application, windows_sandbox_info))
CCEF_SYM(int, cef_initialize,
         (const cef_main_args_t* args, const struct _cef_settings_t* settings,
          cef_app_t* application, void* windows_sandbox_info),
         (args, settings, application, windows_sandbox_info))
CCEF_SYM(int, cef_get_exit_code, (void), ())
CCEF_SYM_VOID(cef_shutdown, (void), ())

// --- Message loop ------------------------------------------------------------
CCEF_SYM_VOID(cef_do_message_loop_work, (void), ())
CCEF_SYM_VOID(cef_run_message_loop, (void), ())
CCEF_SYM_VOID(cef_quit_message_loop, (void), ())

// --- Browser creation --------------------------------------------------------
CCEF_SYM(int, cef_browser_host_create_browser,
         (const cef_window_info_t* windowInfo, struct _cef_client_t* client,
          const cef_string_t* url, const struct _cef_browser_settings_t* settings,
          struct _cef_dictionary_value_t* extra_info,
          struct _cef_request_context_t* request_context),
         (windowInfo, client, url, settings, extra_info, request_context))
CCEF_SYM(cef_browser_t*, cef_browser_host_create_browser_sync,
         (const cef_window_info_t* windowInfo, struct _cef_client_t* client,
          const cef_string_t* url, const struct _cef_browser_settings_t* settings,
          struct _cef_dictionary_value_t* extra_info,
          struct _cef_request_context_t* request_context),
         (windowInfo, client, url, settings, extra_info, request_context))
CCEF_SYM(cef_browser_t*, cef_browser_host_get_browser_by_identifier,
         (int browser_id), (browser_id))

// --- Strings -----------------------------------------------------------------
CCEF_SYM(int, cef_string_utf8_to_utf16,
         (const char* src, size_t src_len, cef_string_utf16_t* output),
         (src, src_len, output))
CCEF_SYM(int, cef_string_utf16_to_utf8,
         (const char16_t* src, size_t src_len, cef_string_utf8_t* output),
         (src, src_len, output))
CCEF_SYM(int, cef_string_utf16_set,
         (const char16_t* src, size_t src_len, cef_string_utf16_t* output,
          int copy),
         (src, src_len, output, copy))
CCEF_SYM_VOID(cef_string_utf16_clear, (cef_string_utf16_t* str), (str))
CCEF_SYM_VOID(cef_string_utf8_clear, (cef_string_utf8_t* str), (str))
CCEF_SYM(cef_string_userfree_utf16_t, cef_string_userfree_utf16_alloc, (void), ())
CCEF_SYM_VOID(cef_string_userfree_utf16_free,
              (cef_string_userfree_utf16_t str), (str))

// --- String lists ------------------------------------------------------------
CCEF_SYM(cef_string_list_t, cef_string_list_alloc, (void), ())
CCEF_SYM(size_t, cef_string_list_size, (cef_string_list_t list), (list))
CCEF_SYM(int, cef_string_list_value,
         (cef_string_list_t list, size_t index, cef_string_t* value),
         (list, index, value))
CCEF_SYM_VOID(cef_string_list_append,
              (cef_string_list_t list, const cef_string_t* value), (list, value))
CCEF_SYM_VOID(cef_string_list_free, (cef_string_list_t list), (list))

// --- String multimaps ----------------------------------------------------------
CCEF_SYM(cef_string_multimap_t, cef_string_multimap_alloc, (void), ())
CCEF_SYM(size_t, cef_string_multimap_size, (cef_string_multimap_t map), (map))
CCEF_SYM(int, cef_string_multimap_key,
         (cef_string_multimap_t map, size_t index, cef_string_t* key),
         (map, index, key))
CCEF_SYM(int, cef_string_multimap_value,
         (cef_string_multimap_t map, size_t index, cef_string_t* value),
         (map, index, value))
CCEF_SYM(int, cef_string_multimap_append,
         (cef_string_multimap_t map, const cef_string_t* key,
          const cef_string_t* value),
         (map, key, value))
CCEF_SYM_VOID(cef_string_multimap_free, (cef_string_multimap_t map), (map))

// --- Custom schemes ------------------------------------------------------------
CCEF_SYM(int, cef_register_scheme_handler_factory,
         (const cef_string_t* scheme_name, const cef_string_t* domain_name,
          struct _cef_scheme_handler_factory_t* factory),
         (scheme_name, domain_name, factory))
CCEF_SYM(int, cef_clear_scheme_handler_factories, (void), ())

// --- Request context / command line ------------------------------------------
CCEF_SYM(cef_request_context_t*, cef_request_context_get_global_context,
         (void), ())
CCEF_SYM(cef_command_line_t*, cef_command_line_create, (void), ())
CCEF_SYM(cef_command_line_t*, cef_command_line_get_global, (void), ())

// --- Tasks ---------------------------------------------------------------------
CCEF_SYM(int, cef_currently_on, (cef_thread_id_t threadId), (threadId))
CCEF_SYM(int, cef_post_task,
         (cef_thread_id_t threadId, cef_task_t* task), (threadId, task))
CCEF_SYM(int, cef_post_delayed_task,
         (cef_thread_id_t threadId, cef_task_t* task, int64_t delay_ms),
         (threadId, task, delay_ms))

// --- Values ----------------------------------------------------------------------
CCEF_SYM(cef_value_t*, cef_value_create, (void), ())
CCEF_SYM(cef_binary_value_t*, cef_binary_value_create,
         (const void* data, size_t data_size), (data, data_size))
CCEF_SYM(cef_dictionary_value_t*, cef_dictionary_value_create, (void), ())
CCEF_SYM(cef_list_value_t*, cef_list_value_create, (void), ())

// --- Cookies ------------------------------------------------------------------------
CCEF_SYM(cef_cookie_manager_t*, cef_cookie_manager_get_global_manager,
         (struct _cef_completion_callback_t* callback), (callback))
