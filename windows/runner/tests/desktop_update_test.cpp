#define JMS_UPDATE_TEST
#include "../desktop_update_bridge.cpp"
#include <iostream>

int main(int argc, char** argv) {
  if (argc != 4) return 2;
  Map args{{Value("path"), Value(argv[1])},
      {Value("versionName"), Value(argv[2])},
      {Value("versionCode"), Value(static_cast<int32_t>(std::stoi(argv[3])))}};
  if (!VerifyInstaller(args)) return 3;
  args[Value("versionCode")] = Value(static_cast<int32_t>(std::stoi(argv[3]) + 1));
  if (VerifyInstaller(args)) return 4;
  args[Value("versionCode")] = Value(static_cast<int32_t>(std::stoi(argv[3])));
  args[Value("versionName")] = Value("wrong-version");
  if (VerifyInstaller(args)) return 5;
  args[Value("path")] = Value("missing.exe");
  if (VerifyInstaller(args)) return 6;
  std::cout << "Native installer metadata and unsigned-policy checks: 4 passed\n";
  return 0;
}
