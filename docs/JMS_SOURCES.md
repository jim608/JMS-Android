# JMS 對應原始碼與授權材料

## M13：依產物分類並解除，而非沿用整體 BLOCKED

目標為 Android ARM64 `.9 (2009)`；使用者已授權只在 Android 排除 MDK，保留 MPV/Native。候選 APK 的實際 ELF/ABI/來源核對由 `scripts/verify_jms_android_native.py` 保存到 `artifacts/checks/m13/candidate-native/native-review.json`：10 個非 App ELF、MDK 三庫與 FvpPlugin 均不存在、19 個 ASS wrapper 必需符號均解析。這是靜態 PASS，不是手機渲染驗收。其他平台保留 fvp/MDK 原能力，**不因此獲得發布合規或平台驗收 PASS**。

分類：**A** 分發許可／相容性；**B** 相應來源、修改／建置腳本、必要版權／授權聲明；**C** 額外重現性／精確工具鏈改善（不是每種授權都要求相同的 source 證明）；**D** 僅擁有者能陳述的歷史。ISC/BSD/Apache 的完整 notices 仍須保存，但不得將「沒有單一 commit 字串」直接當作 GPL source 缺失。正式版本來源包可用版本、內容、checksum 與 build recipe 對應，無須編造 commit。這是材料與產物範圍核對，不是法律意見。

| 原項目／分類 | 新證據、實際處置與解除條件 |
| --- | --- |
| MDK 0.38.0／A | 作者在 [Issue #5 回覆](https://github.com/wang-bin/mdk-sdk/issues/5#issuecomment-623045316) 明示 GPL 不相容，並非免費使用即可解決。Android 不再註冊/編譯 fvp；候選中 `libmdk.so`、`libfvp_plugin.so`、SDK `libffmpeg.so` 必須全部不存在，DEX 不含 FvpPlugin。以實際排除解除本次 Android 的該項，不替作者新增例外。 |
| SDK libass／B、C | `.8` 的獨立 libass 是 MDK 0.17.5，`libasskt.so` 又依賴同名檔，Gradle pickFirst 掩蓋衝突。排除 MDK 後採原已鎖定 ass-kt 0.3.0 AAR 的 libass 0.17.4；wrapper hash 不變。來源為 libass-cmake 精確 gitlinks 的 libass、HarfBuzz、FriBidi、FreeType、libunibreak、Fontconfig、Expat，皆已取回。符號 ABI 檢查不可代替手機字幕畫面。舊 SDK 精確 patch 不再是新 APK 的要求；核心 ISC source 本身不錯當 copyleft，內嵌 FriBidi 的 LGPL 材料仍提供。 |
| SDK avbuild／B、C | 已從 `.8 libffmpeg.so` 取得完整 configure 字串，修正前輪取證不完整（`artifacts/checks/m13/extracted-configurations.log`）。舊 MDK SDK 原生 FFmpeg 不再進入候選，新 APK 不要求不存在元件的建置材料；既有 pinned FFmpeg base/avbuild 候選保留作歷史證據，不拿 master 冒充它。 |
| `libmpv.so`／B | 實際 full flavor，非 encoders-gpl；原 ELF/hash 不變。已補 FFmpeg 6.0、libass 0.17.1、HarfBuzz 7.2.0、FriBidi 1.0.12、FreeType 2.13.0、MbedTLS 3.4.0、dav1d 1.2.0、libxml2 2.10.3 的 recipe 指定來源，保留原 build repo、全部 patches/scripts、MPV 與 helper 精確源碼。dav1d/libxml2 為官方正式 release archive，以版本／內容／SHA 對應。沒有下載僅 GPL encoder flavor 才使用的 x264/vorbis/vpx，亦不要求該不存在組態。 |
| `libasskt.so`／B | 原 AAR 中的 JNI wrapper bytes 與 `.8` 相同。ass-android、ass-cmake 的精確 source/Gradle/CMake、7 個實際啟用的遞迴來源均封存；Fontconfig/Expat 在 CMake 明確啟用，沒有以「Android 應該不用」略過。 |
| `libffmpegJNI.so`／B | Jellyfin Media3 1.8.0+1、FFmpeg **6.0.2** 的相應原始碼、JNI 與 build script 保留 M10 精確材料，不能和 MPV 的 **6.0** 混用；打包後 hash 另核對。 |
| `libflutter.so`／B、C | 官方 engine `035316565ad77281a75305515e4682e6c4c6f7ca` 的 sky_engine.zip 已下載；其中 1,646,500-byte 綜合 LICENSE 與本機逐 byte 相同，含 Skia/BoringSSL/FreeType/HarfBuzz，不再只放 framework BSD。工具鏈/engine revision 已鎖；沒有把要求 bit-identical 重建整個 Flutter engine 當作同等的新增授權阻塞。 |
| AndroidX graphics-path 1.0.1／B、C | 已取得官方 same-version sources.jar；另由 [官方 1.0.1 發布紀錄](https://developer.android.com/jetpack/androidx/releases/graphics#graphics-path-1.0.1) 的 commit `8a05a22af450d589ef911d772a001a49dcb05b71` 取回 13 個 native/build 檔案（含 math/Skia 衍生 header），保存各檔 URL/SHA 及版權，不冒用 latest main。 |
| AndroidX datastore 1.1.7／B、C | 同版 Google Maven sources.jar 與 Apache copyright/license 聲明補齐；ABI/ELF 來源仍依已對應的 Gradle AAR。未將 permissive library 的 exact native rebuild 誤列 copyleft 義務。 |
| `libc++_shared.so`／B、C | 候選實際換成同一 ass-kt 0.3.0 AAR 的 runtime，SHA `ad74bf43…197869`；不是沿用 `.8` MDK runtime。ass-android 的兩個 Gradle source 指定 NDK **28.1.13356709**，ELF clang 19.0.0／r530567d／LLVM commit `97a699bf4812a18fb657c2779f5296a4ab2694d2` 相符。該精確 revision 的 libcxx/libcxxabi/libunwind 三份授權原文已補取；APK 既有 notices 含全部版權與條款，libunwind 只在非條款的元件說明名稱與 libc++abi 不同，完整原文另附 Release。逐條覆蓋檢查拒絕任何條款缺失，不冒稱三份檔案逐 byte 相同。 |
| SQLite 3.50.4／C | 官方 amalgamation 3500400 已補取，保留 public-domain 標示及 Dart wrapper BSD；不是 GPL 對應來源硬性缺件。 |
| 金鑰／D | 使用者回答本人建立保管，並補充「我控制 沒有人知道」。本機有限 Git/8 份來源包無 key，ACL 限本人/System/Administrators；無已知洩漏，保留同一私鑰。不是要求使用者提供不存在的「從未洩漏證明」。不公開金鑰、不換簽章。 |

### 分發材料與重建入口

- `config/jms_native_materials.json` + `scripts/collect_jms_native_materials.py`：有界、HTTPS、checksum 綁定下載；既有檔案 hash 不符就拒絕，不靜默改變版本。`scripts/collect_jms_androidx_native.py` 只取官方已發布 commit 的 component，不下載整個 AndroidX。
- `scripts/assemble_jms_native_notices.py` 從這些 source 原文、官方 engine 綜合 LICENSE、NDK NOTICE 與 AndroidX headers 生成 `assets/licenses/JMS_NATIVE_NOTICES.txt`；來源清單／SHA 在 `docs/native-notices/android-manifest.json`。App 開源授權頁會載入，APK 內逐 byte 核對，不只附外部網址。
- 同一 Release 的 `JMS-native-materials.zip` 包含適用 M10 精確根 source/build/patches、M13 全部所需依賴來源／manifest，另以 JMS source ZIP 提供本次實際 app、fvp fork、lock、Gradle、測試及建置命令。舊 MDK SDK binary 不附在公開材料。
- Native 重建：解開 ass-android `2e7f6a6116b4`，將其 libass-cmake 子模組填為 `d3f00a43ca66`，其 `src/` 各資料夾按 `ass-cmake-tree.json` gitlinks 放入對應七份完整來源；依該 repo 的 Gradle/CMake 與 CI 選用 NDK/ABI（本次實際包沿用原 0.3.0 AAR，沒有冒稱本機已重建 native）。
- MPV 重建：解開 build repo `23d81c8a50c6`，按 `buildscripts/include/depinfo.sh`/`download-deps.sh` 將同版來源放入 deps，保留其 patches、full flavor、NDK 25.2.9519653／SDK 33.0.2 設定；不可用本機 NDK 27 假称同組態重建。Jellyfin FFmpeg 6.0.2 另沿用其封存腳本／NDK 26.1.10909125。
- 下方 M10/M12 是舊 `.6/.8` 真實稽核歷史；新候選以當次 artifact-bound review 的 A/B/C/D 清單為準，不擅自把舊檔案本身改成合規。Android 安裝／實機 ASS／硬體解碼等驗收仍另列，不以 source notices PASS 代替。

本工作樹基於 DonutWare/Fladder `v0.11.1`，commit `a30343a30754114ca66fcae921a0949003761344`。上游 GPLv3 LICENSE 保持原文；修改清單與證據見 JMS_STATUS.md 及交付的 Git 差異。JMS 不代表上游官方產品。

- Flutter 3.35.7 / Dart 3.9.2；工具鏈 commit `adc901062556672b4138e18a4dc62a4be8f4b3c2`。
- pubspec.lock 未升級；media-kit fork 所有套件使用 `cb56b5a6149f1e51086eba473c7e48041c54ab12`，來源 `https://github.com/DonutWare/media-kit`。
- Android MPV 預建函式庫來源：`https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.8`；依賴原有套件建置腳本下載並驗證。
- Media3 / ass-media 版本維持上游設定。ass-media 0.3.0 來源 `https://github.com/peerless2012/libass-android`，其 Maven sources.jar 已供本輪程式核對。尚未宣稱 TV 或 libass 原生套件的完整相應原始碼核對完成。
- Noto Sans CJK TC Regular：`https://github.com/notofonts/noto-cjk/blob/Sans2.004/Sans/OTF/TraditionalChinese/NotoSansCJKtc-Regular.otf`，16435884 bytes，SHA-256 `dce08bd4fd91aa8aa76ed8fea4b694c2dfb8550f67871e326843212ddbeb88b4`。
- 字型 OFL：`assets/subtitle_fonts/OFL.txt`，來源 `https://github.com/notofonts/noto-cjk/blob/a99a4354c68964f6bfac488d01010b1fb6d9178a/Sans/LICENSE`；APK 中附帶，App 授權頁註冊 GPL 與 OFL。
- JMS 字標為本次自製 SVG；衍生 PNG、ICO、平台圖示由 scripts/generate_jms_artwork.py 與鎖定 icons_launcher 生成。
- ASS/SSA/SRT fixture 為本次自製，未使用使用者影片或字幕。測試片源由 FFmpeg testsrc2 / sine 生成。
- Python 本機驗證工具：fonttools 4.59.1、Pillow 11.3.0，位於專案 `.jms-tools/python`，不是 App 執行依賴。

交付的原始碼封存不包含私鑰、帳密、全域快取或 `.jms-tools`。`.fvmrc`、pubspec.lock、Android Gradle 配置、字型授權、測試素材與重建腳本應一併提供。

M12 的舊 MDK 組合與 SDK 精確来源仍未獲追溯或例外，沒有改寫其歷史結論；M13 新 Android 產物排除該 SDK，並補齊實際保留元件的材料與 notices。當前 gate 僅適用 `docs/release-evidence/native-review.json` 綁定的逐檔雜湊，不是授予其他 binary 或平台一概通過，也不是法律認證。不得僅以來源 ZIP 存在就略過稽核。

## M12：進一步查證，不再以套件名稱作結論

- `.8` APK 的 13 個非 libapp ELF 與前輪一致，已逐檔 SHA 綁定 `docs/release-evidence/native-review.json`；source/版本/組態/原生 bytes 不變時可沿用相同稽核，不每版重新掃整庫。這份 review 的 status=BLOCKED、missing 清單非空，不能當成已核准來源。
- **libass API 版本已查明**：SDK 的 ARM64 `ass_library_version` 反組譯載入 `0x01705000`，對照 [libass 0.17.5 ass.h](https://github.com/libass/libass/blob/4a05d8127f525943ebf45fdc6497c9e665947f0d/libass/ass.h) 的版本常數。取得該 commit source ZIP 與 ISC 原文。這解除了「版本完全未知」，但同 API 常數可包含不同 patches；**仍缺這一 SDK 的實際 revision/patch、靜態 FreeType/HarfBuzz/FriBidi 等有實際使用者的版本/notice/source/build manifest**，不能把 upstream tag 自動視為精確 binary source。
- **MDK 組合問題仍有具體依據**：官方 [README 授權段](https://github.com/wang-bin/mdk-sdk/blob/c3ca899c53d2369b7149aba8410576482d42e973/README.md#license) 表示 Flutter 可免費用；作者在 [issue #300](https://github.com/wang-bin/mdk-sdk/issues/300) 說明保留閉源。取得的 [0.38.0 podspec](https://github.com/wang-bin/mdk-sdk/blob/c3ca899c53d2369b7149aba8410576482d42e973/mdk.podspec) 有 Commercial 類型及寬鬆文字，但 target 是 Apple framework，不足以獨自確認這份 Android SDK／GPLv3 Fladder 衍生作品的組合與相應來源義務。`mksrc.sh` 只是從作者 SRC_DIR 複製局部檔案，公開 repo 沒有完整 core source；不能把腳本本身當成已得到 core。
- **avbuild 補取但不冒認**：已取得 FFmpeg binary 日期 2026-09-10 之前的候選 recipe commit `825de1a509a6321c8f7c3700688badecf77c9e69`，包括完整 patches、config-lite 與 CI 配置。此檔案有多套 flavor，僅日期與 FFmpeg base `5b614efc7e6134274fa5d05e240736be2dc203cc` 無法決定實際選項。實際 `.8 libffmpeg.so` 沒擷取到完整 configure string；仍缺 SDK 發布者綁定此 binary 的 avbuild revision、啟用 config、命令、patch set、靜態依賴清單。不使用最新 master 或候選 config 偽裝已核實。
- 新材料在 `artifacts/native-materials-m12/`，manifest 保存官方 URL、resolved commit、bytes、SHA；它們是 **候選/參考材料，不是全部精確相應來源**。M10 已有的精確 pinned mpv、FFmpeg base、JNI 等材料保留，不替換原生庫或升級 SDK。
- 最小解除條件：向 MDK SDK 發布者取得 **MDK 0.38.0/1edab3e、SDK archive SHA-256 c7679fc3…481ee7b** 的 Android 再分發條款與第三方 source/build manifest；對 GPL 組合取得權利人可適用的相容授權／連結例外或符合要求的對應來源。未取得前不自行認定可發布，也不擅自移除 MDK／ASS 來繞過。本紀錄是材料與風險判斷，不是法律認證。
- 自動 publisher 將逐一核對 native hashes、合法依據、reviewer、missing=[] 和材料 SHA，再封裝 native-materials 附在同一 Release；改 status 文字或多放 notices 不能取代這些證據。公開 Prerelease 也受同樣 gate 保護。
- 使用者確認「沒有既有文件」。上述三項不是全部原生材料已通過的聲明；下方 M10 清單尚未補齊的傳遞依賴／notice／建置對應仍保留在 `native-review.json` 的 missing 清單，不能只清掉 MDK 三項就略過其他實際分發元件。

## M10：以實際 APK 為準的原生材料稽核（2026-09-20）

範圍是 `.6 (2006)` 的 `lib/arm64-v8a/` 14 個 ELF；不是僅看 pubspec 的套件名稱。`artifacts/checks/m10/native-inventory.json` 保存每檔 SHA-256、ELF build ID、與本機 AAR/JAR/SDK 的對應。對 strip 過的檔案以 build ID 關聯，**不把 build ID 相同冒稱 byte-identical 或來源可重現建置 PASS**。本輪不替換任何播放器依賴。

| APK 函式庫／版本 | 授權與來源 | 已備材料／具體缺件及最小補齊方式 |
| --- | --- | --- |
| `libapp.so`／JMS 修改版 | 上游 GPLv3；base `a30343a30754114ca66fcae921a0949003761344` + dirty changes | 每版 source ZIP 包含實際修改、lock、build-inputs、建置工具與 LICENSE；不是只有上游連結。需和該 APK 一起提供並完成下列第三方材料。 |
| `libflutter.so`／Flutter 3.35.7 engine `035316565ad77281a75305515e4682e6c4c6f7ca` | Flutter BSD-3-Clause + 引擎各第三方授權；`flutter/engine` 該 commit | 與 Gradle `io.flutter:arm64_v8a_release` JAR 的 ELF build ID 相同；已補 Flutter LICENSE。尚需相同 engine revision 的 DEPS/第三方 notices 覆蓋、對應來源／建置說明；不能以 framework LICENSE 包辦引擎。 |
| `libmpv.so`／mpv `78d43740f52db817d98bcf24fb30a76ab6fa13ff` | mpv LGPL-2.1-or-later 的非 GPL build；FFmpeg 靜態部分 LGPL-3.0-or-later；其他 components 各自授權 | APK bytes 與 media-kit v1.1.8 **full** JAR 相同。已備 build repo `23d81c8a50c6c9c662ce612422b850016ae54dc6`、mpv source、patches/recipe/license。實際字串 `--disable-gpl --disable-nonfree --enable-version3`，mpv recipe `-Dgpl=false`，不是 encoders-gpl flavor。仍需下表中實際連結依賴來源／notices；取得後依 recipe 重建核對，不能只沿用 build repo 的 MIT 概括 libmpv。 |
| `libmediakitandroidhelper.so`／media-kit helper `42054e5d479f39ccbb0ae604862e2bcaf59b74c2` | MIT；`media-kit/media-kit-android-helper` | APK bytes 與 v1.1.8 full JAR 相同，commit 來自 build recipe。已備 source archive + LICENSE；與上述 libmpv 構建材料一起保留。 |
| `libfvp_plugin.so`／fvp 0.35.0；`libmdk.so`／MDK 0.38.0、git `1edab3e` | fvp wrapper BSD-3-Clause；MDK 閉源核心依作者許可，不能套 wrapper 授權 | fvp pub.lock/cache 原始碼可取得，已補 wrapper LICENSE、SDK 原始 README。MDK 與 SDK ELF build ID 相同。**缺 MDK 精確 SDK 的再散布／與 GPLv3 JMS 組合的許可依據**；「Flutter 免費使用」不等於已取得 GPL 對應來源／連結例外。最小補齊是作者提供相應授權及第三方來源/構建材料，必要時由上游版權人確認例外；本輪不擅自移除 MDK 或判定法律結論。 |
| `libffmpeg.so`／MDK SDK FFmpeg `git-2026-09-10-5b614ef-avbuild`，Lavc 63.11.101 | binary 自述 LGPL-2.1-or-later；上游 FFmpeg base `5b614efc7e6134274fa5d05e240736be2dc203cc` | APK 與 fvp SDK bytes 相同；已取得完整上游 base source/licenses。**仍缺 wang-bin avbuild 這個 SDK 的精確 recipe revision、patches、configure args、靜態依賴版本/notice/source**。僅同上游 base 不證明是完整對應來源，向 SDK 發布者取得 manifest/patch set。 |
| **`libass.so`／MDK SDK 的獨立 libass，版本／commit 尚未證實** | libass 通常 ISC；實際版本、靜態 CJK/font/shaping 依賴須按 SDK 核對 | **APK bytes 精確匹配 fvp MDK SDK，不是 ass-kt AAR 的 libass**。已有 ass-kt source 不能解除此檔缺件。最小補齊：SDK 作者提供這一 build 的 libass revision、patches、依賴版本及 notices/source/build recipe。不能把 app CJK 字型 OFL 當 libass 授權。 |
| `libasskt.so`／ass-kt 0.3.0 | MIT wrapper；`peerless2012/libass-android` `2e7f6a6116b401414352f18e72ced73640ca886e` | 與 AAR 關聯；已備 wrapper source/LICENSE、`libass-cmake` submodule `d3f00a43ca66e42a2c34de964b1a7dbbfa9dbc8b` 來源與 build recipe。其遞迴 submodules 還需完整化，但不可把它們誤認成 APK 獨立 MDK libass 的來源。 |
| `libffmpegJNI.so`／Jellyfin Media3 1.8.0+1，FFmpeg **6.0.2** | AndroidX JNI Apache-2.0；FFmpeg LGPL-2.1-or-later（依實際選項）；Jellyfin build repo LICENSE 為 GPLv3 | 與 Jellyfin AAR ELF 關聯。已備 `jellyfin-androidx-media` `84ef4b7201a9e1edfc699c31acbc505511a4af1f`、FFmpeg submodule `d388c347d41e4eb516dec05910551c5461e65615`（RELEASE=6.0.2）、AndroidX media `b7bbc6e2bc3e45ff3ed99884c114c50f03bba5c9` 的全部 JNI 3 檔及 LICENSE。全 media source ZIP 超過 192 MiB 上限，改取得精確 JNI；Java/Kotlin AAR source/notices 覆蓋仍須隨發布整理。NDK recipe 26.1.10909125，不是以本機 NDK 27 冒稱相同重建。 |
| `libc++_shared.so`／NDK 27.0.12077973 | LLVM Apache-2.0 WITH LLVM-exception 及 toolchain 第三方條款 | 與本機 NDK aarch64 libc++ ELF build ID 相同；已補 NDK NOTICE、NOTICE.toolchain。還需核對這一 runtime 的 LLVM source revision／完整 notice 範圍；NDK 名称與 build ID 不是對全體來源的 blanket PASS。 |
| `libandroidx.graphics.path.so`／graphics-path 1.0.1；`libdatastore_shared_counter.so`／datastore-core-android 1.1.7 | AndroidX Apache-2.0；graphics path 另有 Skia 部分需保留相應 notice | 與指定 Gradle AAR bytes／ELF 關聯。尚需從对应 Google Maven sources.jar/AndroidX source revision 補齊 C++ 與 NOTICE（尤其 Skia）；POM license 不等於全部內嵌程式授權。 |
| `libsqlite3.so`／sqlite3-native-library 3.50.4，sqlite3_flutter_libs 0.5.40 | SQLite public domain；Dart wrapper BSD-3-Clause；`simolus3/sqlite-native-libraries` | 與 `eu.simonbinder:sqlite3-native-library:3.50.4` AAR 相同。已補 wrapper LICENSE；需保留 SQLite 3.50.4 amalgamation/copyright、native build flags/revision。不要只列 Dart wrapper 版本。 |

### libmpv full 的精確傳遞依賴待件

`buildscripts/include/depinfo.sh`、`download-deps.sh`、`scripts/`/patches 已封存於 pinned build repo ZIP。full flavor 使用：FFmpeg 6.0、libass 0.17.1 (ISC)、HarfBuzz 7.2.0 (MIT-like)、FriBidi 1.0.12 (LGPL-2.1-or-later)、FreeType VER-2-13-0 (FTL/GPL 雙授權，需保留選用條款)、MbedTLS 3.4.0 (Apache-2.0)、dav1d 1.2.0 (BSD-2-Clause)、libxml2 2.10.3 (MIT)。發布前從 recipe 所列官方 repo/tag 取得其 source、遞迴 submodules/notice，保存 resolved commit、SHA 及 patch；編碼 GPL 分支才用的 x264/vorbis/vpx 不可無證據列為本 APK 實際內嵌。

已取的 Jellyfin FFmpeg **6.0.2** archive 不可代替這裡的 **6.0**。mpv source 內含 LGPL/GPL 雙授權及 component licenses 原文；只因 ZIP 有 GPL 文字不能反推這個 binary 開啟了 GPL。

### SDK 可重現性與本機已补材料

- fvp `cmake/deps.cmake` 未給 `FVP_DEPS_URL` 時取 **SourceForge nightly**，pubspec.lock 不會鎖住夜版 native binaries。這是具體的重建材料缺口，不在本輪盲目升級／下載替換 SDK。
- 目前已有 `fvp-0.35.0/android/mdk-sdk-android.7z`：18,923,211 bytes，SHA-256 `c7679fc3ee21af93d1053a30fc2b0099c1ef9c5ca1037481ab503ece4781ee7b`；保留原本 local cache，不擅自對外再散布。需取得該內容的可長期固定來源與授權後，才把 build override 鎖到它或可重建等效來源，不能把不斷變動的 nightly URL 稱可重現。
- `scripts/audit_jms_native_sources.py`：以 `.6` APK 查 SHA/ELF 和來源根 archive；`scripts/supplement_jms_native_materials.py`：只下載所列 pinned source/精確 JNI，產生材料 manifest 及原文 notices，沒有执行下載的 build scripts、上傳或修改播放器。
- `artifacts/native-materials-m10/manifest.json`、`supplement-manifest.json`：8 份 root ZIP 和 4 個 AndroidX JNI/license 檔案的網址、commit、SHA、大小。這些 archives 保持本機，不隨 App 發布；`docs/native-notices/provenance.json` 列已補 25 份原文 notices 的來源與 SHA，隨 JMS source ZIP 保存。沒有改寫作者或刪除授權。
- Source ZIP 本身不含 `artifacts/`。日後若核准發布，必須把核對完整的 native-materials 另外封裝並附在同一 Release；不能僅上傳 JMS source ZIP 就稱完整對應來源。上述表格中未完成的項目仍 **BLOCKED／待補**，本輪沒有變更既有 publication guard。
- 技術／授權依據：[MDK 作者 README](https://github.com/wang-bin/mdk-sdk/blob/master/README.md)、[mpv build v1.1.8](https://github.com/media-kit/libmpv-android-video-build/tree/v1.1.8)、[GPLv3 完整條款](https://www.gnu.org/licenses/gpl-3.0.html)。這是材料稽核與風險紀錄，不是法律意見或已完成公開發布合規認證。
