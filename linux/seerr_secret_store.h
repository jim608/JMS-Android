#pragma once
#include <libsecret/secret.h>
gchar* jms_secret_read(const gchar* key, GCancellable* cancel, GError** error);
gboolean jms_secret_write(const gchar* key, const gchar* value, GCancellable* cancel, GError** error);
