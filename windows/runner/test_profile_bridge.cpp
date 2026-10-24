#include "test_profile_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "test_profile.h"

namespace {

class TestProfileBridge : public flutter::Plugin {
 public:
  explicit TestProfileBridge(flutter::BinaryMessenger* messenger) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "nl.jknaapen.fladder/test_profile",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([](
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
      if (call.method_name() != "configuration") {
        result->NotImplemented();
        return;
      }
      try {
        const auto& configuration = GetTestProfileConfiguration();
        flutter::EncodableMap values;
        values[flutter::EncodableValue("testBuild")] =
            flutter::EncodableValue(configuration.test_build);
        values[flutter::EncodableValue("root")] = configuration.root.has_value()
            ? flutter::EncodableValue(configuration.root->u8string())
            : flutter::EncodableValue();
        result->Success(flutter::EncodableValue(values));
      } catch (...) {
        result->Error("test_profile_unavailable",
                      "Isolated test profile unavailable");
      }
    });
  }

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}

void RegisterTestProfileBridge(flutter::FlutterEngine* engine) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(
          engine->GetRegistrarForPlugin("JmsTestProfileBridge"));
  registrar->AddPlugin(
      std::make_unique<TestProfileBridge>(registrar->messenger()));
}
