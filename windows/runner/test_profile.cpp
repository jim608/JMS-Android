#include "test_profile.h"

#include <shlobj.h>
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

bool SameComponent(const std::filesystem::path& left,
                   const std::filesystem::path& right) {
  const auto a = left.wstring();
  const auto b = right.wstring();
  return CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()), b.c_str(),
                              static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}

bool IsWithinOrSame(const std::filesystem::path& path,
                    const std::filesystem::path& ancestor) {
  auto part = path.begin();
  for (auto base = ancestor.begin(); base != ancestor.end(); ++base, ++part) {
    if (part == path.end() || !SameComponent(*part, *base)) return false;
  }
  return true;
}

std::filesystem::path KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR raw = nullptr;
  // DONT_VERIFY only obtains the configured path string; it does not open the
  // user's directory or create a missing Known Folder.
  if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DONT_VERIFY, nullptr, &raw)) ||
      raw == nullptr) {
    InvalidProfile();
  }
  const std::wstring text(raw);
  CoTaskMemFree(raw);
  return std::filesystem::path(text);
}

std::filesystem::path ExecutableDirectory() {
  std::wstring text(32768, L'\0');
  const auto length = GetModuleFileNameW(nullptr, text.data(),
                                          static_cast<DWORD>(text.size()));
  if (length == 0 || length >= text.size()) InvalidProfile();
  text.resize(length);
  return std::filesystem::path(text).parent_path();
}

TestProfileProtectedPaths DefaultProtectedPaths() {
  const auto roaming = KnownFolder(FOLDERID_RoamingAppData);
  const auto local = KnownFolder(FOLDERID_LocalAppData);
  const auto documents = KnownFolder(FOLDERID_Documents);
  return {{roaming, local, documents},
          {roaming / L"Jim608" / L"JMS", local / L"Jim608" / L"JMS",
           local / L"JMS" / L"seerr-sessions", ExecutableDirectory()}};
}

std::filesystem::path VolumeIdentityPath(const std::filesystem::path& path) {
  // A second drive letter may name the same physical volume. Replace the
  // drive letter with its volume GUID before comparing path components.
  if (path.root_name().wstring().size() != 2) return path;
  std::array<wchar_t, 32768> volume{};
  if (!GetVolumeNameForVolumeMountPointW(path.root_path().c_str(),
                                        volume.data(),
                                        static_cast<DWORD>(volume.size()))) {
    InvalidProfile();
  }
  return (std::filesystem::path(volume.data()) / path.relative_path())
      .lexically_normal();
}

void RejectDriveAlias(const std::filesystem::path& root) {
  // SUBST and DOS device paths can make a seemingly separate drive point into
  // an existing profile subtree. A real local drive maps to a device volume.
  std::array<wchar_t, 32768> target{};
  const auto name = root.root_name().wstring();
  if (QueryDosDeviceW(name.c_str(), target.data(),
                      static_cast<DWORD>(target.size())) == 0 ||
      std::wstring(target.data()).rfind(L"\\Device\\", 0) != 0) {
    InvalidProfile();
  }
}

void RejectProtectedOverlap(
    const std::filesystem::path& root,
    TestProfileProtectedPathsGetter protected_paths_getter,
    TestProfilePathIdentityGetter path_identity_getter) {
  const auto paths = protected_paths_getter != nullptr
                         ? protected_paths_getter()
                         : DefaultProtectedPaths();
  // Synthetic test paths do not query any actual user folder or drive. Native
  // startup additionally compares physical volume identities.
  const bool physical = protected_paths_getter == nullptr;
  if (physical) RejectDriveAlias(root);
  auto identity = [&](const std::filesystem::path& value) {
    if (path_identity_getter != nullptr) return path_identity_getter(value);
    return physical ? VolumeIdentityPath(value) : value;
  };
  const auto selected = identity(root);
  auto comparable = [&](const std::filesystem::path& value) {
    if (!value.is_absolute()) InvalidProfile();
    const auto normalized = value.lexically_normal();
    return identity(normalized);
  };
  for (const auto& base : paths.known_folder_roots) {
    // Documents/task-child is allowed; Documents itself and its ancestors
    // would include user data and are rejected.
    if (IsWithinOrSame(comparable(base), selected)) InvalidProfile();
  }
  for (const auto& storage : paths.storage_paths) {
    const auto guarded = comparable(storage);
    if (IsWithinOrSame(selected, guarded) ||
        IsWithinOrSame(guarded, selected)) {
      InvalidProfile();
    }
  }
}

std::filesystem::path NormalizeRoot(
    const std::string& argument,
    TestProfileDriveTypeGetter drive_type_getter,
    TestProfileProtectedPathsGetter protected_paths_getter,
    TestProfilePathIdentityGetter path_identity_getter) {
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
    if (name == L"." || name == L".." || name.find(L'~') != std::wstring::npos ||
        name.back() == L' ' ||
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
  RejectProtectedOverlap(root, protected_paths_getter, path_identity_getter);
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
    TestProfileDriveTypeGetter drive_type_getter,
    TestProfileProtectedPathsGetter protected_paths_getter,
    TestProfilePathIdentityGetter path_identity_getter) {
  std::optional<std::string> root_argument;
  for (size_t index = 0; index < arguments.size(); ++index) {
    const auto& argument = arguments[index];
    if (argument != "--profile-dir" && argument.rfind("--profile-dir=", 0) != 0) {
      continue;
    }
    if (root_argument.has_value()) InvalidProfile();
    if (argument == "--profile-dir") {
      if (++index == arguments.size()) InvalidProfile();
      root_argument = arguments[index];
    } else {
      root_argument = argument.substr(14);
    }
  }
  if (!root_argument.has_value()) {
    if (test_build) InvalidProfile();
    return TestProfileConfiguration{false, std::nullopt};
  }

  auto root = NormalizeRoot(*root_argument, drive_type_getter,
                            protected_paths_getter, path_identity_getter);
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
  return TestProfileConfiguration{test_build, std::move(root)};
}

void InitializeTestProfile(
    const std::vector<std::string>& arguments,
    TestProfileProtectedPathsGetter protected_paths_getter) {
  configuration = PrepareTestProfile(JMS_TEST_PROFILE_BUILD != 0, arguments,
                                     true, nullptr, protected_paths_getter);
}

const TestProfileConfiguration& GetTestProfileConfiguration() {
  if (configuration.root.has_value()) {
    ValidatePreparedRoot(*configuration.root, true);
  } else if (configuration.test_build) {
    InvalidProfile();
  }
  return configuration;
}

std::optional<std::filesystem::path> GetIsolatedTestProfileRoot() {
  if (!configuration.root.has_value()) {
    if (configuration.test_build) InvalidProfile();
    return std::nullopt;
  }
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
