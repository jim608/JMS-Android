#include "test_profile.h"

#include <windows.h>

#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

int passed = 0;
unsigned int mock_drive_type = DRIVE_UNKNOWN;
int drive_queries = 0;

unsigned int MockDriveType(const std::filesystem::path& drive_root) {
  if (drive_root.has_relative_path()) {
    throw std::runtime_error("drive policy received a non-root path");
  }
  ++drive_queries;
  return mock_drive_type;
}

void Check(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
  ++passed;
}

void Rejects(const std::function<void()>& action, const char* message) {
  bool rejected = false;
  try {
    action();
  } catch (...) {
    rejected = true;
  }
  Check(rejected, message);
}

void WriteFixture(const std::filesystem::path& file, const std::string& value) {
  std::ofstream output(file, std::ios::binary);
  output << value;
  if (!output) throw std::runtime_error("synthetic fixture write failed");
}

std::string ReadFixture(const std::filesystem::path& file) {
  std::ifstream input(file, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>{input}, {});
}

}

int main(int argc, char** argv) {
  try {
    if (argc != 2) return 2;
    const auto fixtures = std::filesystem::u8path(argv[1]);
    const auto first = fixtures / L"profile-a";
    const auto second = fixtures / L"profile-b";
    const auto ordinary = PrepareTestProfile(false, {"--handheld"}, false);
    Check(!ordinary.test_build && !ordinary.root.has_value(),
          "normal startup unexpectedly uses a test root");
    Rejects([&] { PrepareTestProfile(true, {}, false); },
            "test build accepted a missing root");
    Rejects([&] { PrepareTestProfile(false, {"--profile-dir", first.u8string()}, false); },
            "production build accepted a test root");
    for (const auto& invalid : {"relative", "C:", "C:/", "C:relative",
                                "//invalid-server/fixture", "\\\\?\\C:\\fixture",
                                "C:/fixture/../escape", "C:/fixture/profile.",
                                "C:/fixture/CON", "C:/fixture/profile:stream"}) {
      Rejects([&] { PrepareTestProfile(true, {"--profile-dir", invalid}, false); },
              "invalid path was accepted");
    }
    Rejects([&] { PrepareTestProfile(true, {"--profile-dir"}, false); },
            "missing argument value was accepted");
    Rejects([&] { PrepareTestProfile(true, {"--profile-dir="}, false); },
            "empty argument value was accepted");
    Rejects([&] { PrepareTestProfile(true,
              {"--profile-dir", first.u8string(), "--profile-dir=" + second.u8string()}, false); },
            "duplicate roots were accepted");

    for (const auto type : {DRIVE_REMOTE, DRIVE_UNKNOWN, DRIVE_NO_ROOT_DIR,
                             DRIVE_CDROM}) {
      mock_drive_type = type;
      drive_queries = 0;
      const auto candidate = fixtures / ("rejected-mock-drive-" + std::to_string(type));
      Rejects([&] { PrepareTestProfile(true,
                  {"--profile-dir", candidate.u8string()}, false, MockDriveType); },
              "remote or unavailable mock drive was accepted");
      Check(drive_queries == 1 && !std::filesystem::exists(candidate),
            "rejected mock drive touched a profile directory");
    }
    for (const auto type : {DRIVE_FIXED, DRIVE_REMOVABLE, DRIVE_RAMDISK}) {
      mock_drive_type = type;
      drive_queries = 0;
      const auto candidate = fixtures / ("accepted-mock-drive-" + std::to_string(type));
      const auto accepted = PrepareTestProfile(true,
          {"--profile-dir", candidate.u8string()}, false, MockDriveType);
      Check(drive_queries == 1 && accepted.root == candidate,
            "valid local mock drive was rejected");
    }

    const auto a = PrepareTestProfile(true, {"--profile-dir", first.u8string()}, false);
    const auto b = PrepareTestProfile(true, {"--profile-dir=" + second.u8string()}, false);
    Check(a.root == first && b.root == second, "profile root changed unexpectedly");
    for (const auto* name : {L"config", L"support", L"documents", L"cache",
                              L"temp", L"downloads", L"seerr-sessions"}) {
      Check(std::filesystem::is_directory(first / name) &&
                std::filesystem::is_directory(second / name),
            "required namespace directory missing");
      WriteFixture(first / name / L"fake-value.txt", "synthetic-a");
      Check(!std::filesystem::exists(second / name / L"fake-value.txt"),
            "fixture crossed a profile boundary");
      WriteFixture(second / name / L"fake-value.txt", "synthetic-b");
      Check(ReadFixture(first / name / L"fake-value.txt") == "synthetic-a",
            "another profile overwrote a synthetic fixture");
    }
    const auto reopened = PrepareTestProfile(true, {"--profile-dir", first.u8string()}, false);
    Check(reopened.root == first, "marked profile could not be reopened");
    Check(ReadFixture(first / L"config" / L"fake-value.txt") == "synthetic-a",
          "reopening a test root changed its synthetic settings");

    const auto nonempty = fixtures / L"unmarked-nonempty";
    std::filesystem::create_directory(nonempty);
    WriteFixture(nonempty / L"unrelated.txt", "synthetic-do-not-touch");
    Rejects([&] { PrepareTestProfile(true, {"--profile-dir", nonempty.u8string()}, false); },
            "an unmarked nonempty directory was accepted");
    Check(ReadFixture(nonempty / L"unrelated.txt") == "synthetic-do-not-touch",
          "rejected directory was changed");
    const auto invalid_marker = fixtures / L"invalid-marker";
    std::filesystem::create_directory(invalid_marker);
    WriteFixture(invalid_marker / L".jms-test-profile-v1", "synthetic-invalid-marker");
    Rejects([&] { PrepareTestProfile(true, {"--profile-dir", invalid_marker.u8string()}, false); },
            "invalid marker was accepted");
    Rejects([&] { PrepareTestProfile(true,
              {"--profile-dir", (fixtures / L"junction-root").u8string()}, false); },
            "a root junction was accepted");
    Rejects([&] { PrepareTestProfile(true,
              {"--profile-dir", (fixtures / L"bad-child").u8string()}, false); },
            "a cache junction was accepted");

    InitializeTestProfile({"--profile-dir", first.u8string()});
    Check(GetTestProfileConfiguration().test_build &&
              GetIsolatedTestProfileRoot() == first,
          "the native Seerr namespace does not use the configured test root");
    ValidateIsolatedTestProfileFile(first / L"seerr-sessions" / L"fake-value.txt");
    Rejects([&] { ValidateIsolatedTestProfileFile(second / L"seerr-sessions" / L"fake-value.txt"); },
            "a leaf outside the selected test profile was accepted");
    Rejects([&] { ValidateIsolatedTestProfileFile(fixtures / L"junction-root" / L"fake-value.txt"); },
            "an escaped junction leaf was accepted");
    wchar_t temp[32768];
    const auto length = GetEnvironmentVariableW(L"TEMP", temp, 32768);
    Check(length != 0 && length < 32768 &&
              std::filesystem::path(temp) == first / L"temp",
          "process TEMP did not use the isolated namespace");
    const auto tmp_length = GetEnvironmentVariableW(L"TMP", temp, 32768);
    Check(tmp_length != 0 && tmp_length < 32768 &&
              std::filesystem::path(temp) == first / L"temp",
          "process TMP did not use the isolated namespace");

    // Every hardlink target below is a newly created fake file in profile B.
    const auto fake_target = second / L"config" / L"fake-value.txt";
    for (const auto* relative : {L"config/shared_preferences.json",
                                 L"cache/fake-cache.db",
                                 L"support/fake-database.sqlite"}) {
      const auto candidate = fixtures / ("hardlink-case-" + std::to_string(passed));
      PrepareTestProfile(true, {"--profile-dir", candidate.u8string()}, false);
      Check(CreateHardLinkW((candidate / relative).c_str(), fake_target.c_str(),
                             nullptr) != FALSE,
            "could not create a synthetic hardlink fixture");
      Rejects([&] { PrepareTestProfile(true,
                  {"--profile-dir", candidate.u8string()}, false); },
              "startup accepted a hardlinked synthetic settings/cache/database leaf");
    }
    const auto marker_root = fixtures / L"hardlinked-marker";
    PrepareTestProfile(true, {"--profile-dir", marker_root.u8string()}, false);
    Check(CreateHardLinkW((fixtures / L"marker-alias.txt").c_str(),
                           (marker_root / L".jms-test-profile-v1").c_str(),
                           nullptr) != FALSE,
          "could not create a synthetic marker alias");
    Rejects([&] { PrepareTestProfile(true,
                {"--profile-dir", marker_root.u8string()}, false); },
            "startup accepted a hardlinked marker");

    const auto record = first / L"seerr-sessions" / std::wstring(64, L'a');
    Check(CreateHardLinkW(record.c_str(), fake_target.c_str(), nullptr) != FALSE,
          "could not create a synthetic Seerr record alias");
    Rejects([&] { ValidateIsolatedTestProfileFile(record); },
            "a hardlinked Seerr record was accepted");
    auto temporary_record = record;
    temporary_record += L".tmp";
    Check(CreateHardLinkW(temporary_record.c_str(), fake_target.c_str(),
                           nullptr) != FALSE,
          "could not create a synthetic Seerr temporary record alias");
    Rejects([&] { ValidateIsolatedTestProfileFile(temporary_record); },
            "a hardlinked Seerr temporary record was accepted");
    Rejects([&] { GetTestProfileConfiguration(); },
            "configuration returned a namespace containing hardlinked leaves");

    std::cout << "PASS " << passed << " native synthetic assertions\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << "\n";
    return 1;
  }
}
