#ifndef RUNNER_TEST_PROFILE_H_
#define RUNNER_TEST_PROFILE_H_

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

struct TestProfileConfiguration {
  bool test_build;
  std::optional<std::filesystem::path> root;
};

using TestProfileDriveTypeGetter =
    unsigned int (*)(const std::filesystem::path& drive_root);

// Pure argument policy plus setup of only the explicitly selected test root.
// Existing roots must carry the fixed test marker, or be completely empty.
TestProfileConfiguration PrepareTestProfile(
    bool test_build, const std::vector<std::string>& arguments,
    bool configure_process_temp = true,
    TestProfileDriveTypeGetter drive_type_getter = nullptr);

// Called by WinMain before the engine or any plugins are created.
void InitializeTestProfile(const std::vector<std::string>& arguments);
const TestProfileConfiguration& GetTestProfileConfiguration();

// Revalidates the dedicated namespace and never falls back to production.
// A normal build returns nullopt without reading any profile or storage.
std::optional<std::filesystem::path> GetIsolatedTestProfileRoot();
void ValidateIsolatedTestProfileFile(const std::filesystem::path& file);

#endif
