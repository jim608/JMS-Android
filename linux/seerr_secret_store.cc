#include "seerr_secret_store.h"
#include <cstring>

static const SecretSchema* schema() {
  static SecretSchema value = {};
  static gsize initialized = 0;
  if (g_once_init_enter(&initialized)) {
    value.name = "com.jim608.jms.seerr-session";
    value.flags = SECRET_SCHEMA_NONE;
    value.attributes[0] = {"scope", SECRET_SCHEMA_ATTRIBUTE_STRING};
    g_once_init_leave(&initialized, 1);
  }
  return &value;
}

static gboolean valid_key(const gchar* key, GError** error) {
  if (key && std::strlen(key) == 64 &&
      g_regex_match_simple("^[a-f0-9]{64}$", key, G_REGEX_DEFAULT, G_REGEX_MATCH_DEFAULT)) return TRUE;
  g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "Invalid session scope");
  return FALSE;
}

gchar* jms_secret_read(const gchar* key, GCancellable* cancel, GError** error) {
  if (!valid_key(key, error)) return nullptr;
  return secret_password_lookup_sync(schema(), cancel, error, "scope", key, nullptr);
}

gboolean jms_secret_write(const gchar* key, const gchar* value, GCancellable* cancel, GError** error) {
  if (!valid_key(key, error)) return FALSE;
  if (!value) {
    secret_password_clear_sync(schema(), cancel, error, "scope", key, nullptr);
    return !error || !*error;
  }
  if (std::strlen(value) > 65536 || !g_utf8_validate(value, -1, nullptr)) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "Invalid session record");
    return FALSE;
  }
  // Desktop-managed persistent collection; never use a plaintext fallback.
  return secret_password_store_sync(schema(), SECRET_COLLECTION_DEFAULT,
      "JMS Seerr session", value, cancel, error, "scope", key, nullptr);
}
