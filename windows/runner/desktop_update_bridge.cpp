#include "desktop_update_bridge.h"

#include <windows.h>
#include <shellapi.h>
#include <softpub.h>
#include <wintrust.h>
#include <flutter/standard_method_codec.h>
#include <cstring>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

std::wstring Wide(const std::string& value) {
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (count <= 0) return {};
  std::wstring result(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), count);
  return result;
}

std::wstring StringArg(const Map& args, const char* name) {
  const auto found = args.find(Value(name));
  if (found == args.end()) return {};
  const auto text = std::get_if<std::string>(&found->second);
  return text ? Wide(*text) : L"";
}

int64_t CodeArg(const Map& args) {
  const auto found = args.find(Value("versionCode"));
  if (found == args.end()) return 0;
  if (const auto value = std::get_if<int32_t>(&found->second)) return *value;
  if (const auto value = std::get_if<int64_t>(&found->second)) return *value;
  return 0;
}

bool VerifyInstaller(const Map& args) {
  const auto path = StringArg(args, "path");
  const auto expectedVersion = StringArg(args, "versionName");
  const auto code = CodeArg(args);
  if (path.empty() || expectedVersion.empty() || code <= FLUTTER_VERSION_BUILD || code > 65535) return false;
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) return false;
  DWORD ignored = 0;
  const DWORD size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
  if (!size || size > 1024 * 1024) return false;
  std::vector<BYTE> data(size);
  if (!GetFileVersionInfoW(path.c_str(), 0, size, data.data())) return false;
  VS_FIXEDFILEINFO* fixed = nullptr;
  UINT length = 0;
  if (!VerQueryValueW(data.data(), L"\\", reinterpret_cast<void**>(&fixed), &length) ||
      length < sizeof(VS_FIXEDFILEINFO) || fixed->dwSignature != 0xfeef04bd ||
      LOWORD(fixed->dwFileVersionLS) != code) return false;
  struct Translation { WORD language; WORD codepage; };
  Translation* translations = nullptr;
  if (!VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
      reinterpret_cast<void**>(&translations), &length) || length < sizeof(Translation)) return false;
  const auto translation = translations[0];
  auto property = [&](const wchar_t* key) -> std::wstring {
    wchar_t query[128];
    swprintf_s(query, L"\\StringFileInfo\\%04x%04x\\%s", translation.language, translation.codepage, key);
    wchar_t* text = nullptr;
    UINT count = 0;
    if (!VerQueryValueW(data.data(), query, reinterpret_cast<void**>(&text), &count) || count == 0) return {};
    std::wstring value(text, count - 1);
    const auto last = value.find_last_not_of(L" ");
    return last == std::wstring::npos ? L"" : value.substr(0, last + 1);
  };
  if (property(L"ProductName") != L"JMS" || property(L"ProductVersion") != expectedVersion) return false;
  WINTRUST_FILE_INFO file{};
  file.cbStruct = sizeof(file);
  file.pcwszFilePath = path.c_str();
  WINTRUST_DATA trust{};
  trust.cbStruct = sizeof(trust);
  trust.dwUIChoice = WTD_UI_NONE;
  trust.dwUnionChoice = WTD_CHOICE_FILE;
  trust.pFile = &file;
  trust.dwStateAction = WTD_STATEACTION_VERIFY;
  trust.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
  GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  const LONG status = WinVerifyTrust(nullptr, &action, &trust);
  trust.dwStateAction = WTD_STATEACTION_CLOSE;
  WinVerifyTrust(nullptr, &action, &trust);
  return status == TRUST_E_NOSIGNATURE;
}
}

#ifndef JMS_UPDATE_TEST
DesktopUpdateBridge::DesktopUpdateBridge(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "com.jim608.jms/desktop_updates", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "device") {
      using VersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
      const auto address = GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
      VersionFunction versionFunction = nullptr;
      static_assert(sizeof(versionFunction) == sizeof(address));
      std::memcpy(&versionFunction, &address, sizeof(address));
      OSVERSIONINFOW version{};
      version.dwOSVersionInfoSize = sizeof(version);
      if (!versionFunction || versionFunction(&version) != 0) {
        result->Error("device");
        return;
      }
      result->Success(Value(Map{
          {Value("versionCode"), Value(static_cast<int32_t>(FLUTTER_VERSION_BUILD))},
          {Value("windowsBuild"), Value(static_cast<int32_t>(version.dwBuildNumber))}}));
      return;
    }
    const auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (!args || !VerifyInstaller(*args)) {
      result->Error("metadata");
      return;
    }
    if (call.method_name() == "validate") {
      result->Success(Value(true));
    } else if (call.method_name() == "install") {
      const auto path = StringArg(*args, "path");
      SHELLEXECUTEINFOW info{};
      info.cbSize = sizeof(info);
      info.lpVerb = L"open";
      info.lpFile = path.c_str();
      info.nShow = SW_SHOWNORMAL;
      if (!ShellExecuteExW(&info)) {
        result->Success(Value(GetLastError() == ERROR_CANCELLED ? "installCancelled" : "installBlocked"));
      } else {
        result->Success(Value("installPending"));
      }
    } else {
      result->NotImplemented();
    }
  });
}
#endif
