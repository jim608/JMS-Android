#ifndef RUNNER_SEERR_SESSION_BRIDGE_H_
#define RUNNER_SEERR_SESSION_BRIDGE_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

class SeerrSessionBridge {
 public:
  explicit SeerrSessionBridge(flutter::BinaryMessenger* messenger);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
