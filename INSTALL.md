# Install JMS

The APK path, SHA-256, version and signing identity are recorded in `docs/JMS_STATUS.md`. Installation is unverified until performed on an authorized device.

For an ARM64 Android device, verify the APK hash and install the provided **test-signed release-mode** APK with `adb install -r <APK>`. Do not uninstall either JMS or the original client to resolve a signature conflict. A different signing key cannot update an installed package; retain the same authorized key for future JMS builds.

JMS uses `com.jim608.jms` and the `jms` deep-link scheme. Original app data remains in its own sandbox. Configure a test Jellyfin account after launch. JMS does not embed a server, credentials or an upstream updater.

Other platform resources are maintained, but platform validation is reported individually in `docs/JMS_STATUS.md`. No remote JMS store or download service is configured.
