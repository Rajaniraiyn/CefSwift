// CefSwift — request filter matching in C (see ccef_request_match.h).

#include "ccef_request_match.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
  char16_t* units;
  size_t length;
} ccef_units_t;

struct ccef_request_match_t {
  uint64_t resource_types;
  ccef_units_t* hosts;
  size_t host_count;
  ccef_units_t* patterns;
  size_t pattern_count;
};

// UTF-8 to UTF-16, without the framework. Invalid sequences become U+FFFD,
// which no address CEF reports contains, so they never match.
static ccef_units_t ccef_units_from_utf8(const char* text, int lowercase) {
  size_t length = strlen(text);
  ccef_units_t result = {calloc(length + 1, sizeof(char16_t)), 0};
  if (!result.units) return result;
  const unsigned char* s = (const unsigned char*)text;
  size_t i = 0;
  while (i < length) {
    uint32_t c = s[i];
    size_t extra = 0;
    if (c < 0x80) {
      extra = 0;
    } else if ((c & 0xE0) == 0xC0) {
      c &= 0x1F;
      extra = 1;
    } else if ((c & 0xF0) == 0xE0) {
      c &= 0x0F;
      extra = 2;
    } else if ((c & 0xF8) == 0xF0) {
      c &= 0x07;
      extra = 3;
    } else {
      c = 0xFFFD;
    }
    if (extra > 0 && i + extra >= length) {
      c = 0xFFFD;
      extra = length - i - 1;
    }
    for (size_t k = 1; k <= extra && c != 0xFFFD; k++) {
      unsigned char next = s[i + k];
      if ((next & 0xC0) != 0x80) {
        c = 0xFFFD;
        break;
      }
      c = (c << 6) | (next & 0x3F);
    }
    i += extra + 1;
    if (lowercase && c >= 'A' && c <= 'Z') c += 'a' - 'A';
    if (c >= 0x10000 && c != 0xFFFD) {
      // A pair takes two units; the buffer has one unit per byte, and a
      // four-byte sequence yields two.
      c -= 0x10000;
      result.units[result.length++] = (char16_t)(0xD800 + (c >> 10));
      result.units[result.length++] = (char16_t)(0xDC00 + (c & 0x3FF));
    } else {
      result.units[result.length++] = (char16_t)c;
    }
  }
  return result;
}

ccef_request_match_t* ccef_request_match_create(uint64_t resource_types,
                                                const char* const* hosts,
                                                size_t host_count,
                                                const char* const* patterns,
                                                size_t pattern_count) {
  ccef_request_match_t* match = calloc(1, sizeof(ccef_request_match_t));
  if (!match) return NULL;
  match->resource_types = resource_types;
  if (host_count > 0) {
    match->hosts = calloc(host_count, sizeof(ccef_units_t));
    for (size_t i = 0; match->hosts && i < host_count; i++) {
      match->hosts[match->host_count++] = ccef_units_from_utf8(hosts[i], 1);
    }
  }
  if (pattern_count > 0) {
    match->patterns = calloc(pattern_count, sizeof(ccef_units_t));
    for (size_t i = 0; match->patterns && i < pattern_count; i++) {
      match->patterns[match->pattern_count++] = ccef_units_from_utf8(patterns[i], 0);
    }
  }
  return match;
}

void ccef_request_match_destroy(ccef_request_match_t* match) {
  if (!match) return;
  for (size_t i = 0; i < match->host_count; i++) free(match->hosts[i].units);
  for (size_t i = 0; i < match->pattern_count; i++) free(match->patterns[i].units);
  free(match->hosts);
  free(match->patterns);
  free(match);
}

int ccef_request_match_host_range(const char16_t* url,
                                  size_t length,
                                  size_t* start,
                                  size_t* end) {
  size_t i = 0;
  // The scheme ends at the first ':'; an address without "://" has no host.
  while (i < length && url[i] != ':') {
    if (url[i] == '/' || url[i] == '?' || url[i] == '#') return 0;
    i++;
  }
  if (i + 2 >= length || url[i + 1] != '/' || url[i + 2] != '/') return 0;
  size_t authority = i + 3;
  size_t authority_end = authority;
  while (authority_end < length && url[authority_end] != '/' && url[authority_end] != '?' &&
         url[authority_end] != '#') {
    authority_end++;
  }
  size_t host = authority;
  for (size_t k = authority; k < authority_end; k++) {
    if (url[k] == '@') host = k + 1;
  }
  size_t host_end = host;
  if (host_end < authority_end && url[host] == '[') {
    while (host_end < authority_end && url[host_end] != ']') host_end++;
    if (host_end < authority_end) host_end++;
  } else {
    while (host_end < authority_end && url[host_end] != ':') host_end++;
  }
  *start = host;
  *end = host_end;
  return 1;
}

static char16_t ccef_lower(char16_t c) {
  return (c >= 'A' && c <= 'Z') ? (char16_t)(c + ('a' - 'A')) : c;
}

// Whether the host url[start, end) is `rule` or a subdomain of it.
static int ccef_host_matches(const char16_t* url, size_t start, size_t end, const ccef_units_t* rule) {
  size_t length = end - start;
  if (rule->length == 0 || length < rule->length) return 0;
  size_t offset = start + length - rule->length;
  for (size_t i = 0; i < rule->length; i++) {
    if (ccef_lower(url[offset + i]) != rule->units[i]) return 0;
  }
  return length == rule->length || url[offset - 1] == '.';
}

// `*` matches any run of units, everything else itself. Iterative, with one
// backtracking point: O(text × pattern) at worst, no recursion.
static int ccef_pattern_matches(const char16_t* text, size_t length, const ccef_units_t* pattern) {
  size_t t = 0, p = 0;
  size_t star = (size_t)-1, resume = 0;
  while (t < length) {
    if (p < pattern->length && pattern->units[p] == '*') {
      star = p++;
      resume = t;
    } else if (p < pattern->length && pattern->units[p] == text[t]) {
      p++;
      t++;
    } else if (star != (size_t)-1) {
      p = star + 1;
      t = ++resume;
    } else {
      return 0;
    }
  }
  while (p < pattern->length && pattern->units[p] == '*') p++;
  return p == pattern->length;
}

int ccef_request_match_excludes_type(const ccef_request_match_t* match, int resource_type) {
  if (!match || match->resource_types == 0) return 0;
  if (resource_type < 0 || resource_type >= 64) return 1;
  return (match->resource_types & ((uint64_t)1 << resource_type)) == 0;
}

int ccef_request_match_test(const ccef_request_match_t* match,
                            const cef_string_utf16_t* url,
                            int resource_type) {
  if (!match) return 1;
  if (ccef_request_match_excludes_type(match, resource_type)) return 0;
  if (match->host_count == 0 && match->pattern_count == 0) return 1;
  if (!url || !url->str) return 0;
  size_t start = 0, end = 0;
  if (match->host_count > 0 && ccef_request_match_host_range(url->str, url->length, &start, &end)) {
    for (size_t i = 0; i < match->host_count; i++) {
      if (ccef_host_matches(url->str, start, end, &match->hosts[i])) return 1;
    }
  }
  for (size_t i = 0; i < match->pattern_count; i++) {
    if (ccef_pattern_matches(url->str, url->length, &match->patterns[i])) return 1;
  }
  return 0;
}
