# JMS — Jim608 Media Server

JMS is a cross-platform Jellyfin client derived from the upstream v0.11.1 release. It retains media browsing, account switching, streaming, audio and subtitle selection, downloads, offline playback and the existing platform interfaces.

This working version integrates JMS branding, ASS/SSA delivery and CJK font fixes, and ambient-background resource improvements. Android is the primary acceptance platform. Build and test results, limitations and exact APK details are recorded in [JMS_STATUS](docs/JMS_STATUS.md). A successful build does not establish installation or real-device performance.

## Build and install

Use Flutter **3.35.7**, Dart **3.9.2**, JDK **21**, the committed dependency lock and Android API **37** (`platforms;android-37.0`). See [DEVELOPEMENT.md](DEVELOPEMENT.md) and [INSTALL.md](INSTALL.md).

The independent Android application ID is `com.jim608.jms`. It can coexist with the original application. It does not automatically inherit another application's login or sandbox data. The current release-mode APK uses a test signing key and is not an official production update.

No JMS update, store, donation or issue endpoint has been configured. Automatic updates are disabled. Server addresses remain configurable. Do not enter production credentials into fixture runs.

## Open source and licensing

Based on [Fladder by DonutWare and contributors](https://github.com/DonutWare/Fladder), commit `a30343a30754114ca66fcae921a0949003761344`. Original author attribution and [GPLv3 license](LICENSE) are preserved. Noto Sans CJK is distributed with its SIL OFL license. See [source materials](docs/JMS_SOURCES.md) before redistribution. Upstream source links are attribution, not JMS update or support channels.
