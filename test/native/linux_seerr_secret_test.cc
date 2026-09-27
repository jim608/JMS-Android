#include "seerr_secret_store.h"
#include <cstring>

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  const gchar* key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const gchar* other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  g_autoptr(GError) error = nullptr;
  if (!std::strcmp(argv[1], "write"))
    return jms_secret_write(key, "fixture-session-only", nullptr, &error) && !error ? 0 : 1;
  if (!std::strcmp(argv[1], "clear"))
    return jms_secret_write(key, nullptr, nullptr, &error) && !error ? 0 : 1;
  if (!std::strcmp(argv[1], "invalid")) {
    gchar* value = jms_secret_read("invalid", nullptr, &error);
    if (value) secret_password_free(value);
    return error && error->code == G_IO_ERROR_INVALID_ARGUMENT ? 0 : 1;
  }
  gchar* value = jms_secret_read(!std::strcmp(argv[1], "isolated") ? other : key, nullptr, &error);
  const bool valid = !std::strcmp(argv[1], "unavailable") ? error != nullptr :
      !error && (!std::strcmp(argv[1], "read") ? value && !std::strcmp(value, "fixture-session-only") : value == nullptr);
  if (value) secret_password_free(value);
  return valid ? 0 : 1;
}
