/* Public CI fixture: one sandbox process, one D-Bus connection, one Update.
 * Build against gio-2.0 in the existing Linux CI toolchain. No signing keys.
 */
#include <gio/gio.h>
#include <string.h>

#define PORTAL "org.freedesktop.portal.Flatpak"
#define ROOT "/org/freedesktop/portal/Flatpak"
#define MONITOR PORTAL ".UpdateMonitor"

typedef struct {
  GMainLoop *loop;
  GDBusConnection *bus;
  gchar *owner, *path;
  const gchar *baseline, *target;
  gboolean deny, requested, finished;
  gint result;
} Probe;

static gboolean checksum(const gchar *s) {
  return s && strlen(s) == 64 && strspn(s, "0123456789abcdef") == 64;
}

static void finish(Probe *p, gint result, const gchar *code) {
  if (p->finished) return;
  p->finished = TRUE;
  p->result = result;
  g_print("{\"event\":\"result\",\"code\":\"%s\",\"updateDispatched\":%s,\"success\":%s}\n",
          code, p->requested ? "true" : "false", result == 0 ? "true" : "false");
  g_main_loop_quit(p->loop);
}

static gboolean denied_name(const gchar *s) {
  return g_strcmp0(s, "org.freedesktop.DBus.Error.AccessDenied") == 0 ||
         g_strcmp0(s, "org.freedesktop.portal.Error.NotAllowed") == 0 ||
         g_strcmp0(s, "org.freedesktop.portal.Error.Cancelled") == 0;
}

static GVariant *call(Probe *p, const gchar *dest, const gchar *path,
                      const gchar *iface, const gchar *method,
                      GVariant *args, const gchar *type, GError **error) {
  return g_dbus_connection_call_sync(p->bus, dest, path, iface, method, args,
      G_VARIANT_TYPE(type), G_DBUS_CALL_FLAGS_NONE, 15000, NULL, error);
}

static GVariant *empty_options(void) {
  return g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0);
}

static void request(Probe *p) {
  GError *error = NULL;
  p->requested = TRUE; /* Never dispatch a second Update, including on timeout. */
  GVariant *reply = call(p, p->owner, p->path, MONITOR, "Update",
      g_variant_new("(s@a{sv})", "", empty_options()), "()", &error);
  if (reply) {
    g_variant_unref(reply);
    g_print("{\"event\":\"request\",\"acknowledged\":true}\n");
    return;
  }
  gchar *remote = error ? g_dbus_error_get_remote_error(error) : NULL;
  if (denied_name(remote)) {
    finish(p, p->deny ? 0 : 1, p->deny ? "expected-method-denial" : "method-denied");
  } else {
    /* A missing reply does not prove the installation never started.
     * Continue listening for a real terminal Progress until the deadline. */
    g_print("{\"event\":\"request\",\"acknowledged\":false,\"outcomeUncertain\":true}\n");
  }
  g_free(remote);
  g_clear_error(&error); /* Never print a raw D-Bus error message. */
}

static void signal_cb(GDBusConnection *bus, const gchar *sender,
                      const gchar *path, const gchar *iface,
                      const gchar *name, GVariant *parameters, gpointer data) {
  (void)bus;
  Probe *p = data;
  if (p->finished || g_strcmp0(sender, p->owner) ||
      g_strcmp0(path, p->path) || g_strcmp0(iface, MONITOR)) return;
  if (strcmp(name, "UpdateAvailable") && strcmp(name, "Progress")) return;
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(a{sv})"))) {
    finish(p, 1, "invalid-signal-signature"); return;
  }
  GVariant *dict = NULL;
  g_variant_get(parameters, "(@a{sv})", &dict);
  if (!strcmp(name, "UpdateAvailable") && !p->requested) {
    const gchar *running = NULL, *local = NULL, *remote = NULL;
    gboolean valid = g_variant_lookup(dict, "running-commit", "&s", &running) &&
        g_variant_lookup(dict, "local-commit", "&s", &local) &&
        g_variant_lookup(dict, "remote-commit", "&s", &remote) &&
        checksum(running) && checksum(local) && checksum(remote) &&
        !strcmp(running, p->baseline) && !strcmp(local, p->baseline) &&
        !strcmp(remote, p->target);
    if (!valid) finish(p, 1, "unexpected-update-identity");
    else {
      g_print("{\"event\":\"update-available\",\"running\":\"%s\",\"local\":\"%s\",\"remote\":\"%s\"}\n",
              running, local, remote);
      request(p);
    }
  } else if (!strcmp(name, "Progress") && p->requested) {
    guint32 status = 0, percent = 0;
    GVariant *v = g_variant_lookup_value(dict, "status", NULL);
    GVariant *progress = g_variant_lookup_value(dict, "progress", NULL);
    gboolean valid = (!v || g_variant_is_of_type(v, G_VARIANT_TYPE_UINT32)) &&
        (!progress || g_variant_is_of_type(progress, G_VARIANT_TYPE_UINT32));
    if (valid && v) status = g_variant_get_uint32(v);
    if (valid && progress) percent = g_variant_get_uint32(progress);
    if (!valid || status > 3 || percent > 100) {
      finish(p, 1, "invalid-progress");
    } else {
      g_print("{\"event\":\"progress\",\"status\":%u,\"percent\":%u,\"hasPercent\":%s}\n",
              status, percent, progress ? "true" : "false");
      if (status == 2) finish(p, p->deny ? 1 : 0, p->deny ? "unexpected-install" : "terminal-done");
      else if (status == 1) finish(p, 1, "unexpected-empty-update");
      else if (status == 3) {
        const gchar *error_name = NULL;
        g_variant_lookup(dict, "error", "&s", &error_name);
        gboolean expected = p->deny && denied_name(error_name);
        finish(p, expected ? 0 : 1, expected ? "expected-progress-denial" : "terminal-failed");
      }
      /* status 0, including progress 100, is never terminal. */
    }
    if (v) g_variant_unref(v);
    if (progress) g_variant_unref(progress);
  }
  g_variant_unref(dict);
}

static gboolean deadline(gpointer data) {
  Probe *p = data;
  finish(p, 4, p->requested ? "deadline-update-outcome-uncertain" : "deadline-no-update-signal");
  return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
  if (argc != 5 || (strcmp(argv[1], "update") && strcmp(argv[1], "deny")) ||
      !checksum(argv[2]) || !checksum(argv[3]) || !strcmp(argv[2], argv[3]) ||
      !*argv[4] || strspn(argv[4], "0123456789") != strlen(argv[4])) return 2;
  guint64 seconds = g_ascii_strtoull(argv[4], NULL, 10);
  if (seconds < 30 || seconds > 900) return 2;
  Probe p = {0};
  p.baseline = argv[2]; p.target = argv[3]; p.deny = !strcmp(argv[1], "deny"); p.result = 1;
  p.loop = g_main_loop_new(NULL, FALSE);
  GError *error = NULL;
  p.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
  GVariant *reply = NULL;
  guint subscription = 0, timer = 0;
  gchar *rule = NULL;
  if (!p.bus) goto failed;
  /* Activate through a standard property call, then pin and recheck the owner. */
  reply = call(&p, PORTAL, ROOT, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", PORTAL, "version"), "(v)", &error);
  if (!reply) goto failed;
  g_variant_unref(reply); reply = NULL;
  reply = call(&p, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
      "GetNameOwner", g_variant_new("(s)", PORTAL), "(s)", &error);
  if (!reply) goto failed;
  const gchar *owner = NULL;
  g_variant_get(reply, "(&s)", &owner);
  if (!g_dbus_is_unique_name(owner)) goto failed;
  p.owner = g_strdup(owner);
  g_variant_unref(reply); reply = NULL;
  reply = call(&p, p.owner, ROOT, "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", PORTAL, "version"), "(v)", &error);
  if (!reply) goto failed;
  GVariant *boxed = g_variant_get_child_value(reply, 0);
  GVariant *version = g_variant_get_variant(boxed);
  gboolean supported = g_variant_is_of_type(version, G_VARIANT_TYPE_UINT32) &&
      g_variant_get_uint32(version) >= 2;
  g_variant_unref(version); g_variant_unref(boxed);
  g_variant_unref(reply); reply = NULL;
  if (!supported) goto failed;
  subscription = g_dbus_connection_signal_subscribe(p.bus, p.owner, MONITOR, NULL, NULL, NULL,
      G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, signal_cb, &p, NULL);
  rule = g_strdup_printf("type='signal',sender='%s',interface='%s'", p.owner, MONITOR);
  reply = call(&p, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
      "AddMatch", g_variant_new("(s)", rule), "()", &error);
  if (!reply) goto failed;
  g_variant_unref(reply); reply = NULL;
  reply = call(&p, p.owner, ROOT, PORTAL, "CreateUpdateMonitor",
      g_variant_new("(@a{sv})", empty_options()), "(o)", &error);
  if (!reply) goto failed;
  const gchar *path = NULL;
  g_variant_get(reply, "(&o)", &path);
  const gchar *unique = g_dbus_connection_get_unique_name(p.bus);
  gchar *encoded = g_strdup(unique + 1);
  for (gchar *c = encoded; *c; c++) if (*c == '.') *c = '_';
  gchar *prefix = g_strdup_printf(ROOT "/update_monitor/%s/", encoded);
  gboolean own = strlen(path) <= 512 && g_str_has_prefix(path, prefix) &&
      *(path + strlen(prefix)) && !strchr(path + strlen(prefix), '/');
  g_free(encoded); g_free(prefix);
  if (!own) goto failed;
  p.path = g_strdup(path);
  g_variant_unref(reply); reply = NULL;
  timer = g_timeout_add_seconds((guint)seconds, deadline, &p);
  g_main_loop_run(p.loop);
  goto cleanup;
failed:
  finish(&p, 1, "portal-setup-failed");
cleanup:
  if (reply) g_variant_unref(reply);
  g_clear_error(&error);
  if (timer && g_main_context_find_source_by_id(NULL, timer)) g_source_remove(timer);
  if (p.path) {
    /* Close cancels this monitor; it is not proof of rollback after a timeout. */
    GVariant *closed = g_dbus_connection_call_sync(p.bus, p.owner, p.path, MONITOR, "Close", NULL,
        G_VARIANT_TYPE("()"), G_DBUS_CALL_FLAGS_NONE, 3000, NULL, NULL);
    if (closed) g_variant_unref(closed);
  }
  if (subscription) g_dbus_connection_signal_unsubscribe(p.bus, subscription);
  if (rule && p.bus) {
    GVariant *removed = g_dbus_connection_call_sync(p.bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "RemoveMatch", g_variant_new("(s)", rule), G_VARIANT_TYPE("()"),
        G_DBUS_CALL_FLAGS_NONE, 3000, NULL, NULL);
    if (removed) g_variant_unref(removed);
  }
  if (p.bus) g_object_unref(p.bus);
  g_free(rule); g_free(p.owner); g_free(p.path); g_main_loop_unref(p.loop);
  return p.result;
}
