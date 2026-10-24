// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "include/media_kit_video/video_output_manager.h"

struct _VideoOutputManager {
  GObject parent_instance;
  GHashTable* video_outputs;
  FlTextureRegistrar* texture_registrar;
  FlView* view;
};

G_DEFINE_TYPE(VideoOutputManager, video_output_manager, G_TYPE_OBJECT)

static void video_output_manager_init(VideoOutputManager* self) {
  self->video_outputs = g_hash_table_new_full(g_direct_hash, g_direct_equal,
                                              nullptr, g_object_unref);
}

static void video_output_manager_dispose(GObject* object) {
  VideoOutputManager* self = VIDEO_OUTPUT_MANAGER(object);
  g_hash_table_unref(self->video_outputs);
  G_OBJECT_CLASS(video_output_manager_parent_class)->dispose(object);
}

static void video_output_manager_class_init(VideoOutputManagerClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = video_output_manager_dispose;
}

VideoOutputManager* video_output_manager_new(
    FlTextureRegistrar* texture_registrar,
    FlView* view) {
  VideoOutputManager* video_output_manager = VIDEO_OUTPUT_MANAGER(
      g_object_new(video_output_manager_get_type(), nullptr));
  video_output_manager->texture_registrar = texture_registrar;
  video_output_manager->view = view;
  return video_output_manager;
}

void video_output_manager_create(VideoOutputManager* self,
                                 gint64 handle,
                                 VideoOutputConfiguration configuration,
                                 TextureUpdateCallback texture_update_callback,
                                 gpointer texture_update_callback_context) {
  if (!g_hash_table_contains(self->video_outputs, GINT_TO_POINTER(handle))) {
    g_autoptr(VideoOutput) video_output = video_output_new(
        self->texture_registrar, self->view, handle, configuration);
    video_output_set_texture_update_callback(
        video_output, texture_update_callback, texture_update_callback_context);
    g_hash_table_insert(self->video_outputs, GINT_TO_POINTER(handle),
                        g_object_ref(video_output));
  }
}

void video_output_manager_set_size(VideoOutputManager* self,
                                   gint64 handle,
                                   gint64 width,
                                   gint64 height) {
  if (g_hash_table_contains(self->video_outputs, GINT_TO_POINTER(handle))) {
    VideoOutput* video_output = VIDEO_OUTPUT(
        g_hash_table_lookup(self->video_outputs, GINT_TO_POINTER(handle)));
    video_output_set_size(video_output, width, height);
  }
}

void video_output_manager_dispose(VideoOutputManager* self, gint64 handle) {
  if (g_hash_table_contains(self->video_outputs, GINT_TO_POINTER(handle))) {
    g_hash_table_remove(self->video_outputs, GINT_TO_POINTER(handle));
  }
}

FlValue* video_output_manager_get_render_capabilities(VideoOutputManager* self,
                                                     gint64 handle) {
  const gchar* api = "unknown";
  if (g_hash_table_contains(self->video_outputs, GINT_TO_POINTER(handle))) {
    VideoOutput* video_output = VIDEO_OUTPUT(
        g_hash_table_lookup(self->video_outputs, GINT_TO_POINTER(handle)));
    api = video_output_get_render_api(video_output);
  }
  const gboolean software = g_strcmp0(api, "sw") == 0;
  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "version", fl_value_new_int(1));
  g_autofree gchar* handle_text = g_strdup_printf("%" G_GINT64_FORMAT, handle);
  fl_value_set_string_take(result, "handle", fl_value_new_string(handle_text));
  fl_value_set_string_take(result, "apiType", fl_value_new_string(api));
  // The SW callback renders rgb0 into Flutter's 8-bit pixel-buffer texture.
  // GL output remains renderer-managed; this query makes no HDR display claim.
  fl_value_set_string_take(result, "pixelFormat",
                           fl_value_new_string(software ? "rgb0" : "unknown"));
  fl_value_set_string_take(result, "outputTransfer",
                           fl_value_new_string(software ? "sdr" : "unknown"));
  return result;
}
