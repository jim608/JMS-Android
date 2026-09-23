#include "seerr_session_bridge.h"

#include <shlobj.h>
#include <wincrypt.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

#include <flutter/standard_method_codec.h>

namespace {

std::filesystem::path StorageDirectory() {
  PWSTR raw_path = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT,
                                 nullptr, &raw_path))) {
    throw std::runtime_error("storage unavailable");
  }
  const std::filesystem::path directory =
      std::filesystem::path(raw_path) / L"JMS" / L"seerr-sessions";
  CoTaskMemFree(raw_path);
  return directory;
}

bool ValidScope(const std::string& scope) {
  return scope.size() == 64 &&
         std::all_of(scope.begin(), scope.end(), [](char letter) {
           return (letter >= '0' && letter <= '9') ||
                  (letter >= 'a' && letter <= 'f');
         });
}

std::string Protect(const std::string& value, const std::string& scope,
                    bool encrypt) {
  DATA_BLOB input{static_cast<DWORD>(value.size()),
                  reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))};
  DATA_BLOB entropy{static_cast<DWORD>(scope.size()),
                    reinterpret_cast<BYTE*>(const_cast<char*>(scope.data()))};
  DATA_BLOB output{};
  const bool success = encrypt
                           ? CryptProtectData(&input, L"JMS Jellyseerr session",
                                              &entropy, nullptr, nullptr,
                                              CRYPTPROTECT_UI_FORBIDDEN, &output)
                           : CryptUnprotectData(&input, nullptr, &entropy,
                                                nullptr, nullptr,
                                                CRYPTPROTECT_UI_FORBIDDEN, &output);
  if (!success) throw std::runtime_error("storage unavailable");
  const std::string result(reinterpret_cast<char*>(output.pbData),
                           output.cbData);
  LocalFree(output.pbData);
  return result;
}

void HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  try {
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) throw std::runtime_error("invalid arguments");
    const auto scope_entry = arguments->find(flutter::EncodableValue("key"));
    if (scope_entry == arguments->end()) throw std::runtime_error("missing scope");
    const auto* scope = std::get_if<std::string>(&scope_entry->second);
    if (scope == nullptr || !ValidScope(*scope)) throw std::runtime_error("invalid scope");
    const auto directory = StorageDirectory();
    const auto file = directory / std::filesystem::path(scope->begin(), scope->end());

    if (call.method_name() == "read") {
      if (!std::filesystem::exists(file)) {
        result->Success(flutter::EncodableValue());
        return;
      }
      if (std::filesystem::file_size(file) > 32768) throw std::runtime_error("invalid record");
      std::ifstream stream(file, std::ios::binary);
      if (!stream) throw std::runtime_error("storage unavailable");
      const std::string ciphertext(std::istreambuf_iterator<char>{stream}, {});
      result->Success(flutter::EncodableValue(Protect(ciphertext, *scope, false)));
      return;
    }
    if (call.method_name() == "write") {
      const auto value_entry = arguments->find(flutter::EncodableValue("value"));
      const auto* value = value_entry == arguments->end()
                              ? nullptr
                              : std::get_if<std::string>(&value_entry->second);
      if (value == nullptr || value->empty()) {
        std::filesystem::remove(file);
      } else {
        if (value->size() > 8192) throw std::runtime_error("record too large");
        std::filesystem::create_directories(directory);
        auto temporary = file;
        temporary += L".tmp";
        const std::string ciphertext = Protect(*value, *scope, true);
        {
          std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
          if (!stream) throw std::runtime_error("storage unavailable");
          stream.write(ciphertext.data(), ciphertext.size());
          if (!stream) throw std::runtime_error("storage unavailable");
        }
        if (!MoveFileExW(temporary.c_str(), file.c_str(),
                         MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
          std::filesystem::remove(temporary);
          throw std::runtime_error("storage unavailable");
        }
      }
      result->Success(flutter::EncodableValue());
      return;
    }
    result->NotImplemented();
  } catch (...) {
    result->Error("secure_storage_unavailable", "Seerr session storage unavailable");
  }
}

}

SeerrSessionBridge::SeerrSessionBridge(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.jim608.jms/seerr-session",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(HandleCall);
}
