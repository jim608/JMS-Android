/// Explicit Windows isolation, enabled by a validated native profile root.
abstract final class JmsTestProfilePolicy {
  static const buildEnabled = bool.fromEnvironment('JMS_TEST_PROFILE_BUILD');
  static bool _runtimeIsolation = false;
  static bool get enabled => buildEnabled || _runtimeIsolation;

  static void enableRuntimeIsolation() => _runtimeIsolation = true;

  // Tests restore this alongside their fake platform stores.
  static void resetRuntimeIsolationForTesting() => _runtimeIsolation = false;
  static const profileArgument = '--profile-dir';
  static const markerName = '.jms-test-profile-v1';
  static const markerContents = 'JMS isolated test profile v1\n';
}
