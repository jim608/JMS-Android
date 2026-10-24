# Windows isolated test profiles

The local Windows test package uses a dedicated data root selected at process
startup. The normal build keeps its existing storage paths and defaults.

## Build and launch contract

Both build layers must opt in:

- CMake runner cache: `JMS_TEST_PROFILE_BUILD=ON` (default `OFF`).
- Dart compilation: `--dart-define=JMS_TEST_PROFILE_BUILD=true`.

The test executable requires `--profile-dir <absolute-local-directory>` (the
`--profile-dir=<directory>` form is also accepted). Use a new empty directory for
each synthetic test profile. Secondary windows inherit the same root through
the native configuration channel.

An ordinary build rejects profile arguments. A test build without a root, an
invalid root, or a native/Dart build mismatch fails before opening application
stores. Native validation runs before creating the Flutter engine. Dart repeats
the configuration handshake as its first bootstrap operation, before crash
logs, preferences, sync cleanup, or application directory lookups.

## Namespace

| Data | Directory under the selected root |
| --- | --- |
| Legacy and async preferences | `config/shared_preferences.json` |
| Application support, databases, downloader records | `support/` |
| Application documents and test sync output | `documents/` |
| Application cache and crash logs | `cache/` |
| Temporary files | `temp/` |
| Download directory | `downloads/` |
| Native Seerr session files | `seerr-sessions/` |

Native startup creates `.jms-test-profile-v1` and the seven directories. Reusing a
directory requires the exact marker. Network shares, mapped network drives,
drive roots, relative paths and unsafe path aliases are rejected. Existing
namespace links are validated before store access.

`TEMP` and `TMP` are changed only for the test process. Main-isolate path-provider
lookups use the selected namespace. Desktop download workers receive an immutable
directory snapshot before resolving tasks, callbacks, resume records or local
stores. Stored resume paths and task paths cannot select another profile.

Test builds disable notifications, update actions, Discord presence, diagnostic
reporting and system media registration. Saved opt-in values cannot enable those
external effects. This policy does not modify settings in an ordinary build.

## Verification boundary

Automated checks create empty, synthetic profile directories and fake values.
They cover cold preference reads/writes, clearing one profile without changing
another, worker-isolate namespaces, startup refusal cases and disabled external
effects. Native policy tests also use synthetic filesystem aliases.

These checks do not open an existing user profile, account database, credentials
or sessions. They do not establish real-account or interactive Windows app
acceptance. A complete test-package build and fixture checks remain separate
from the source-level and unit-test results.
