#include <mpv/client.h>
#include <mpv/render.h>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <set>
#include <thread>
#include <utility>
#include <unistd.h>

static bool synthetic_tracks(mpv_handle* player) {
  mpv_node list{};
  if (mpv_get_property(player, "track-list", MPV_FORMAT_NODE, &list) < 0) return false;
  bool video = false, audio = false, subtitle = false;
  if (list.format == MPV_FORMAT_NODE_ARRAY) {
    for (int t = 0; t < list.u.list->num; t++) {
      const auto& track = list.u.list->values[t];
      if (track.format != MPV_FORMAT_NODE_MAP) continue;
      for (int k = 0; k < track.u.list->num; k++) {
        const auto& value = track.u.list->values[k];
        if (std::strcmp(track.u.list->keys[k], "type") || value.format != MPV_FORMAT_STRING) continue;
        video |= !std::strcmp(value.u.string, "video");
        audio |= !std::strcmp(value.u.string, "audio");
        subtitle |= !std::strcmp(value.u.string, "sub");
      }
    }
  }
  mpv_free_node_contents(&list);
  return video && audio && subtitle;
}

// Exercise generated media in the installed libmpv. Software video and a PCM
// file prove actual decoding without claiming physical GPU/audio validation.
int main(int argc, char** argv) {
  if (argc != 2) return 2;
  char pcm_path[] = "/tmp/jms-flatpak-audio.XXXXXX";
  const int pcm_fd = mkstemp(pcm_path);
  if (pcm_fd < 0) return 3;
  close(pcm_fd);
  mpv_handle* player = mpv_create();
  if (!player) { unlink(pcm_path); return 4; }
  bool options = true;
  for (const auto& option : {
      std::make_pair("vo", "libmpv"), std::make_pair("ao", "pcm"),
      std::make_pair("hwdec", "no"), std::make_pair("terminal", "no"),
      std::make_pair("vid", "1"), std::make_pair("aid", "1"), std::make_pair("sid", "1"),
      std::make_pair("ao-pcm-waveheader", "yes"),
      std::make_pair("ao-pcm-file", static_cast<const char*>(pcm_path))}) {
    const int status = mpv_set_option_string(player, option.first, option.second);
    if (status < 0) std::cerr << "mpv option " << option.first << ": " << mpv_error_string(status) << '\n';
    options &= status >= 0;
  }
  if (!options || mpv_initialize(player) < 0) {
    mpv_terminate_destroy(player); unlink(pcm_path); return 5;
  }
  mpv_render_context* renderer = nullptr;
  char api[] = MPV_RENDER_API_TYPE_SW;
  mpv_render_param create[] = {{MPV_RENDER_PARAM_API_TYPE, api}, {MPV_RENDER_PARAM_INVALID, nullptr}};
  if (mpv_render_context_create(&renderer, player, create) < 0) {
    mpv_terminate_destroy(player); unlink(pcm_path); return 6;
  }
  std::atomic<bool> stop{false}, pending{true}, render_failed{false};
  std::atomic<unsigned> rendered{0}, distinct{0};
  mpv_render_context_set_update_callback(renderer, [](void* flag) {
    static_cast<std::atomic<bool>*>(flag)->store(true);
  }, &pending);
  std::thread render_thread([&] {
    alignas(64) std::array<unsigned char, 320 * 180 * 4> pixels{};
    std::set<uint64_t> signatures;
    int dimensions[] = {320, 180};
    size_t stride = 320 * 4;
    int wait = 0;
    char format[] = "rgb0";
    mpv_render_param surface[] = {
        {MPV_RENDER_PARAM_SW_SIZE, dimensions}, {MPV_RENDER_PARAM_SW_FORMAT, format},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride}, {MPV_RENDER_PARAM_SW_POINTER, pixels.data()},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &wait}, {MPV_RENDER_PARAM_INVALID, nullptr}};
    while (!stop.load()) {
      if (pending.exchange(false) && (mpv_render_context_update(renderer) & MPV_RENDER_UPDATE_FRAME)) {
        if (mpv_render_context_render(renderer, surface) < 0) { render_failed.store(true); break; }
        uint64_t signature = 1469598103934665603ULL;
        bool colored = false;
        for (size_t pixel = 0; pixel < pixels.size(); pixel += 4) {
          for (size_t channel = 0; channel < 3; channel++) {
            colored |= pixels[pixel + channel] != 0;
            signature = (signature ^ pixels[pixel + channel]) * 1099511628211ULL;
          }
        }
        if (colored) { rendered++; signatures.insert(signature); distinct.store(signatures.size()); }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  });
  const char* command[] = {"loadfile", argv[1], nullptr};
  bool loaded = false, tracks = false, subtitle = false, eof = false;
  int result = mpv_command(player, command) < 0 ? 7 : 8;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
  while (result == 8 && std::chrono::steady_clock::now() < deadline) {
    mpv_event* event = mpv_wait_event(player, .05);
    if (event->event_id == MPV_EVENT_FILE_LOADED) {
      loaded = true;
      tracks = synthetic_tracks(player);
    }
    if (loaded) {
      char* text = mpv_get_property_string(player, "sub-text");
      subtitle |= text && std::strstr(text, "JMS synthetic subtitle");
      mpv_free(text);
    }
    if (event->event_id == MPV_EVENT_END_FILE) {
      const auto* end = static_cast<mpv_event_end_file*>(event->data);
      eof = end->reason == MPV_END_FILE_REASON_EOF && end->error == 0;
      break;
    }
  }
  stop.store(true);
  render_thread.join();
  mpv_render_context_set_update_callback(renderer, nullptr, nullptr);
  mpv_render_context_free(renderer);
  mpv_terminate_destroy(player);
  std::ifstream pcm(pcm_path, std::ios::binary);
  char wave[12]{};
  pcm.read(wave, sizeof(wave));
  const bool wav = pcm.gcount() == 12 && !std::memcmp(wave, "RIFF", 4) && !std::memcmp(wave + 8, "WAVE", 4);
  size_t audio_bytes = 0, nonzero_audio_bytes = 0;
  char sample;
  while (pcm.get(sample)) {
    if (audio_bytes >= 128 && sample != 0) nonzero_audio_bytes++;
    audio_bytes++;
  }
  pcm.close();
  unlink(pcm_path);
  const bool passed = loaded && tracks && subtitle && eof && !render_failed.load() &&
      rendered.load() >= 2 && distinct.load() >= 2 && wav && audio_bytes >= 48000 && nonzero_audio_bytes >= 1024;
  std::cout << "{\"fileLoaded\":" << (loaded ? "true" : "false")
            << ",\"requiredTracks\":" << (tracks ? "true" : "false")
            << ",\"eof\":" << (eof ? "true" : "false")
            << ",\"renderedVideoFrames\":" << rendered.load()
            << ",\"distinctVideoFrames\":" << distinct.load()
            << ",\"decodedPcmFileBytes\":" << audio_bytes + sizeof(wave)
            << ",\"nonzeroPcmBytes\":" << nonzero_audio_bytes
            << ",\"assTextDecoded\":" << (subtitle ? "true" : "false")
            << ",\"renderError\":" << (render_failed.load() ? "true" : "false")
            << ",\"hardwareGpuAudio\":false,\"passed\":" << (passed ? "true" : "false") << "}\n";
  return passed ? 0 : result;
}
