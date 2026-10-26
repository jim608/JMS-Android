# Explicit isolated Windows profile

The normal Windows installer retains the stable JMS installation identity. A normal
launch without a profile argument uses the existing Windows user profile.

For a diagnostic startup, the same binary accepts `--profile-dir` followed by an
absolute local directory. This is an explicit diagnostic mode, not an installation
or migration. Use a new empty directory, separate from the application bundle and
any existing JMS storage. The native runner validates it before starting Flutter.
Unsafe paths, overlapping normal JMS or application directories, linked paths,
and unmarked nonempty directories are rejected without falling back to the normal
profile. A valid existing isolated directory must carry the fixed profile marker.

The selected root contains:

| Directory | Data |
| --- | --- |
| `config` | Legacy and async preferences, accounts and settings |
| `support` | Databases, image-cache index and downloader state |
| `documents` | Isolated sync/download document storage |
| `cache` | Application cache and crash records |
| `temp` | Process temporary files and cached image files |
| `downloads` | Download-directory requests |
| `seerr-sessions` | Reserved isolated namespace; native persistence is disabled |

Each secondary Flutter engine obtains the same validated root from the native
process before requesting preferences or paths. The mode also disables automatic
updates, diagnostics transport, notifications, Discord presence and Windows media
controls. Native Seerr persistence fails closed before filesystem or Windows DPAPI
access, and the native updater rejects direct channel calls. A new-process menu
action is disabled so it cannot escape into the normal
profile. It never changes Windows Known Folder configuration, accounts, registry
permissions or security settings. Operating-system DLLs, fonts, GPU services and
the bundled read-only application files are still used normally.

`JMS_TEST_PROFILE_BUILD` remains a separate build-time requirement for older TEST
packages: those packages must always receive a profile root. The formal binary
does not require one for ordinary startup. An explicit profile root is required
when validating a formal binary without touching the current user's JMS data.
