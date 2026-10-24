#include "test_profile.h"

#include <windows.h>

#include <array>
#include <cwctype>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <utility>

#ifndef JMS_TEST_PROFILE_BUILD
#define JMS_TEST_PROFILE_BUILD 0
#endif

namespace {

constexpr char kMarkerContents[] = "JMS isolated test profile v1\n";
constexpr wchar_t kMarkerName[] = L".jms-test-profile-v1";
constexpr std::array<const wchar_t*, 7> kDirectories = {
    L"config", L"support", L"documents", L"cache", L"temp", L"downloads",
    L"seerr-sessions"};

TestProfileConfiguration configuration{JMS_TEST_PROFILE_BUILD != 0,
                                       std::nullopt};

[[noreturn]] void InvalidProfile() {
  throw std::runtime_error("invalid isolated test profile");
}

DWORD Attributes(const std::filesystem::path& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    const auto error = GetLastError();
    if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) {
      InvalidProfile();
    }
  }
  return attributes;
}

void RejectReparseAncestors(const std::filesystem::path& path) {
  auto current = path.root_path();
  for (const auto& component : path.relative_path()) {
    current /= component;
    const auto attributes = Attributes(current);
    if (attributes == INVALID_FILE_ATTRIBUTES) continue;
    if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
      InvalidProfile();
    }
  }
}

std::filesystem::path NormalizeRoot(
    const std::string& argument,
    TestProfileDriveTypeGetter drive_type_getter) {
  if (argument.empty() || argument.find('\0') != std::string::npos) {
    InvalidProfile();
  }
  auto root = std::filesystem::u8path(argument);
  const auto text = root.wstring();
  // Reject UNC/device paths and drive-relative roots; no network lookup occurs.
  if (!root.is_absolute() || root.root_name().wstring().size() != 2 ||
      text.size() < 3 || text[1] != L':' ||
      ((text[0] < L'A' || text[0] > L'Z') &&
       (text[0] < L'a' || text[0] > L'z'))) {
    InvalidProfile();
  }
  for (const auto& component : root.relative_path()) {
    const auto name = component.wstring();
    if (name.empty()) continue;
    if (name == L"." || name == L".." || name.back() == L' ' ||
        name.back() == L'.' || name.find_first_of(L"<>:\"|?*") !=
                                    std::wstring::npos) {
      InvalidProfile();
    }
    auto stem = name.substr(0, name.find(L'.'));
    for (auto& letter : stem) letter = static_cast<wchar_t>(towupper(letter));
    if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" ||
        stem == L"NUL" ||
        (stem.size() == 4 &&
         (stem.substr(0, 3) == L"COM" || stem.substr(0, 3) == L"LPT") &&
         stem[3] >= L'1' && stem[3] <= L'9')) {
      InvalidProfile();
    }
  }
  root = root.lexically_normal();
  while (root != root.root_path() && root.filename().empty()) {
    root = root.parent_path();
  }
  if (root == root.root_path()) InvalidProfile();
  root.make_preferred();
  // A drive letter may refer to a mapped network location. Reject it before
  // inspecting even the first path component or creating any test files.
  const auto drive_type = drive_type_getter != nullptr
      ? drive_type_getter(root.root_path())
      : GetDriveTypeW(root.root_path().c_str());
  if (drive_type != DRIVE_FIXED && drive_type != DRIVE_REMOVABLE &&
      drive_type != DRIVE_RAMDISK) {
    InvalidProfile();
  }
  RejectReparseAncestors(root);
  return root;
}

bool ValidMarker(const std::filesystem::path& root) {
  const auto marker = root / kMarkerName;
  const auto attributes = Attributes(marker);
  if (attributes == INVALID_FILE_ATTRIBUTES) return false;
  if ((attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) !=
      0 || std::filesystem::hard_link_count(marker) > 1 ||
      std::filesystem::file_size(marker) != sizeof(kMarkerContents) - 1) {
    InvalidProfile();
  }
  std::ifstream stream(marker, std::ios::binary);
  if (!stream) InvalidProfile();
  const std::string contents(std::istreambuf_iterator<char>{stream}, {});
  return contents == kMarkerContents;
}

void CreateMarker(const std::filesystem::path& root) {
  const auto marker = root / kMarkerName;
  const auto file = CreateFileW(marker.c_str(), GENERIC_WRITE, 0, nullptr,
                                CREATE_NEW, FILE_ATTRIBUTE_NORMAL |
                                                FILE_FLAG_OPEN_REPARSE_POINT,
                                nullptr);
  if (file == INVALID_HANDLE_VALUE) InvalidProfile();
  DWORD written = 0;
  const bool success = WriteFile(file, kMarkerContents,
                                 static_cast<DWORD>(sizeof(kMarkerContents) - 1),
                                 &written, nullptr) != FALSE &&
                       written == sizeof(kMarkerContents) - 1;
  CloseHandle(file);
  if (!success) InvalidProfile();
}

void ValidateMetadataLeaves(const std::filesystem::path& root) {
  // This is called only for an explicitly selected, marker-validated test root.
  // Do not follow reparse entries or open file contents during this scan.
  for (const auto& entry : std::filesystem::recursive_directory_iterator(root)) {
    const auto attributes = Attributes(entry.path());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      InvalidProfile();
    }
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
        std::filesystem::hard_link_count(entry.path()) > 1) {
      InvalidProfile();
    }
  }
}

void ValidatePreparedRoot(const std::filesystem::path& root, bool scan_leaves) {
  RejectReparseAncestors(root);
  if (Attributes(root) == INVALID_FILE_ATTRIBUTES || !ValidMarker(root)) {
    InvalidProfile();
  }
  for (const auto* directory : kDirectories) {
    const auto path = root / directory;
    RejectReparseAncestors(path);
    if (Attributes(path) == INVALID_FILE_ATTRIBUTES) InvalidProfile();
  }
  if (scan_leaves) ValidateMetadataLeaves(root);
}

}

TestProfileConfiguration PrepareTestProfile(
    bool test_build, const std::vector<std::string>& arguments,
    bool configure_process_temp,
    TestProfileDriveTypeGetter drive_type_getter) {
  std::optional<std::string> root_argument;
  for (size_t index = 0; index < arguments.size(); ++index) {
    const auto& argument = arguments[index];
    if (argument != "--profile-dir" && argument.rfind("--profile-dir=", 0) != 0) {
      continue;
    }
    if (!test_build || root_argument.has_value()) InvalidProfile();
    if (argument == "--profile-dir") {
      if (++index == arguments.size()) InvalidProfile();
      root_argument = arguments[index];
    } else {
      root_argument = argument.substr(14);
    }
  }
  if (!test_build) return TestProfileConfiguration{false, std::nullopt};
  if (!root_argument.has_value()) InvalidProfile();

  auto root = NormalizeRoot(*root_argument, drive_type_getter);
  const bool exists = Attributes(root) != INVALID_FILE_ATTRIBUTES;
  const bool marked = exists && ValidMarker(root);
  if (exists && !marked &&
      std::filesystem::directory_iterator(root) !=
          std::filesystem::directory_iterator()) {
    InvalidProfile();
  }
  if (marked) ValidateMetadataLeaves(root);
  for (const auto* directory : kDirectories) {
    RejectReparseAncestors(root / directory);
  }
  std::filesystem::create_directories(root);
  if (!ValidMarker(root)) CreateMarker(root);
  for (const auto* directory : kDirectories) {
    std::filesystem::create_directories(root / directory);
  }
  ValidatePreparedRoot(root, true);
  if (configure_process_temp &&
      (!SetEnvironmentVariableW(L"TEMP", (root / L"temp").c_str()) ||
       !SetEnvironmentVariableW(L"TMP", (root / L"temp").c_str()))) {
    InvalidProfile();
  }
  return TestProfileConfiguration{true, std::move(root)};
}

void InitializeTestProfile(const std::vector<std::string>& arguments) {
  configuration = PrepareTestProfile(JMS_TEST_PROFILE_BUILD != 0, arguments);
}

const TestProfileConfiguration& GetTestProfileConfiguration() {
  if (configuration.test_build) {
    if (!configuration.root.has_value()) InvalidProfile();
    ValidatePreparedRoot(*configuration.root, true);
  }
  return configuration;
}

std::optional<std::filesystem::path> GetIsolatedTestProfileRoot() {
  if (!configuration.test_build) return std::nullopt;
  if (!configuration.root.has_value()) InvalidProfile();
  ValidatePreparedRoot(*configuration.root, false);
  return configuration.root;
}

void ValidateIsolatedTestProfileFile(const std::filesystem::path& file) {
  const auto root = GetIsolatedTestProfileRoot();
  if (!root.has_value()) return;
  const auto relative = file.lexically_normal().lexically_relative(*root);
  if (relative.empty() || relative.is_absolute()) InvalidProfile();
  for (const auto& component : relative) {
    if (component == L".." || component == L".") InvalidProfile();
  }
  RejectReparseAncestors(file.parent_path());
  const auto attributes = Attributes(file);
  if (attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
    InvalidProfile();
  }
  if (attributes != INVALID_FILE_ATTRIBUTES &&
      std::filesystem::hard_link_count(file) > 1) {
    InvalidProfile();
  }
}
