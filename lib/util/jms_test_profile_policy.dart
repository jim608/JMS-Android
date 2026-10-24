/// Opt-in build boundary for local, isolated Windows test packages.
abstract final class JmsTestProfilePolicy {
  static const enabled = bool.fromEnvironment('JMS_TEST_PROFILE_BUILD');
  static const profileArgument = '--profile-dir';
  static const markerName = '.jms-test-profile-v1';
  static const markerContents = 'JMS isolated test profile v1\n';
}
