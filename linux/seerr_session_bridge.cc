#include "seerr_session_bridge.h"
#include "seerr_secret_store.h"
#include <cstring>

struct SessionOperation {
  FlMethodCall* call;
  gchar* key;
  gchar* value;
  bool read;
  guint timeout;
};

static void free_operation(gpointer data) {
  auto* op = static_cast<SessionOperation*>(data);
  g_object_unref(op->call);
  g_free(op->key);
  if (op->value) secret_password_free(op->value);
  delete op;
}

static gboolean cancel_operation(gpointer data) {
  g_cancellable_cancel(G_CANCELLABLE(data));
  return G_SOURCE_CONTINUE;
}

static void worker(GTask* task, gpointer, gpointer data, GCancellable* cancel) {
  auto* op = static_cast<SessionOperation*>(data);
  GError* error = nullptr;
  gchar* value = nullptr;
  if (op->read) value = jms_secret_read(op->key, cancel, &error);
  else if (!jms_secret_write(op->key, op->value, cancel, &error) && !error)
    g_set_error_literal(&error, G_IO_ERROR, G_IO_ERROR_FAILED, "Session storage unavailable");
  if (error) {
    if (value) secret_password_free(value);
    g_task_return_error(task, error);
  } else g_task_return_pointer(task, value, reinterpret_cast<GDestroyNotify>(secret_password_free));
}

static void completed(GObject*, GAsyncResult* result, gpointer) {
  GTask* task = G_TASK(result);
  auto* op = static_cast<SessionOperation*>(g_task_get_task_data(task));
  g_source_remove(op->timeout);
  g_autoptr(GError) error = nullptr;
  gchar* value = static_cast<gchar*>(g_task_propagate_pointer(task, &error));
  if (error) fl_method_call_respond_error(op->call, "secure_storage",
      "Desktop Secret Service unavailable or locked", nullptr, nullptr);
  else {
    g_autoptr(FlValue) response = value ? fl_value_new_string(value) : fl_value_new_null();
    fl_method_call_respond_success(op->call, response, nullptr);
  }
  if (value) secret_password_free(value);
}

static void method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  if (std::strcmp(method, "read") && std::strcmp(method, "write")) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  FlValue* key = fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, "key") : nullptr;
  FlValue* value = fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, "value") : nullptr;
  if (!key || fl_value_get_type(key) != FL_VALUE_TYPE_STRING ||
      (value && fl_value_get_type(value) != FL_VALUE_TYPE_NULL && fl_value_get_type(value) != FL_VALUE_TYPE_STRING)) {
    fl_method_call_respond_error(call, "invalid_arguments", "Invalid session arguments", nullptr, nullptr);
    return;
  }
  auto* op = new SessionOperation{FL_METHOD_CALL(g_object_ref(call)), g_strdup(fl_value_get_string(key)),
      value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? g_strdup(fl_value_get_string(value)) : nullptr,
      !std::strcmp(method, "read"), 0};
  g_autoptr(GCancellable) cancel = g_cancellable_new();
  op->timeout = g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, 15,
      cancel_operation, g_object_ref(cancel), g_object_unref);
  g_autoptr(GTask) task = g_task_new(nullptr, cancel, completed, nullptr);
  g_task_set_task_data(task, op, free_operation);
  g_task_run_in_thread(task, worker);
}

void jms_register_seerr_session(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(messenger,
      "com.jim608.jms/seerr-session", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call, nullptr, nullptr);
}
