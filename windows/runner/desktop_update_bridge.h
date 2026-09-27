#ifndef JMS_DESKTOP_UPDATE_BRIDGE_H_
#define JMS_DESKTOP_UPDATE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>

class DesktopUpdateBridge {
 public:
  explicit DesktopUpdateBridge(flutter::BinaryMessenger* messenger);
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
