# JMS 0.11.1-jms.58

## 繁體中文 / Traditional Chinese

### 新增

- 新增同帳號 JMS 裝置遙控，可在手機選擇播放裝置，操作播放、暫停、進度及主字幕。
- 播放端預設不接收遙控，需明確啟用；關閉遙控面板後仍保留本次啟用狀態，重新啟動應用程式後恢復關閉。

### 調整

- 遙控命令綁定裝置、影片、媒體來源與播放階段，拒絕過期、重複、其他帳號或失效裝置的操作。
- 分開顯示已送出與播放端確認狀態，逾時保留結果未知，不自動重送可能已執行的操作。

### 修正

- 避免換帳號、換片、停止播放或關閉接收後，舊的非同步操作與進度回報覆蓋新狀態。

### 已知問題

- 真實 Jellyfin、實體手機與 Tesla 車機的遙控驗收尚未完成，雙瀏覽器驗證不代表實車驗收。
- 兩端都需要支援此遙控協定的 JMS，目前只控制已開始播放的影片及主字幕，播放端應保持開啟並在前景運作。
- 既有 Web ASS、SSA、點陣、燒錄及 HLS 字幕限制仍適用，原生播放保留既有字幕路徑；遙控不會新增格式支援、背景服務或喚醒休眠的程式與瀏覽器。
- 實體 Android、Windows、Linux 與 Steam Deck 的遙控、GPU、音訊及真實媒體驗收仍未完成；Flatpak Portal、舊版升級與實體跨裝置 SyncPlay 仍需獨立驗收。

### 更新注意事項

- 原先發布的 .58 僅更新 Web，當時未發布 Android、Windows 或 Linux 安裝套件；2026-11-03 的原生跟進準備維持 0.11.1-jms.58+67，不重新部署 Web，原生候選尚未發布。
- Android 候選規劃為測試金鑰預發布版，不能當作既有正式簽章的升級包；Windows Setup 維持未簽署；Linux 候選規劃為簽署 TEST，正式 Flatpak origin 與自動更新來源不變，簽署及發布仍以實際紀錄為準。
- SyncPlay 期間暫停接收遙控，房間同步與遙控維持獨立；帳號設定及既有字幕修正予以保留。

## English

### Added

- Add same-account JMS device control from a phone, including device selection, play, pause, seeking and primary subtitles.
- Receiving is off by default and requires explicit opt-in; closing the panel preserves the current opt-in, while restarting the application turns it off.

### Changed

- Bind remote commands to the device, item, media source and playback occurrence, rejecting expired, duplicate, foreign-account and stale-device input.
- Distinguish sent commands from receiver confirmation, keeping timed-out results unknown without automatically replaying a possibly completed action.

### Fixed

- Prevent old asynchronous operations and progress reports from overwriting new state after account changes, replacement playback, stopping or disabling receiving.

### Known issues

- Remote control acceptance on real Jellyfin, a physical phone and a Tesla browser remains incomplete; two-browser verification is not vehicle acceptance.
- Both clients need a JMS build supporting this remote protocol; only already-playing video and primary subtitles are controlled, and the receiver should remain open and active in the foreground.
- Existing Web ASS, SSA, bitmap, burned-in and HLS subtitle limitations still apply, while native playback retains its existing subtitle path; remote control adds no format support, background service or ability to wake a suspended app or browser.
- Physical Android, Windows, Linux and Steam Deck remote control, GPU, audio and real-media acceptance remain incomplete; Flatpak Portal, previous-version upgrades and physical cross-device SyncPlay require separate acceptance.

### Update notes

- The original .58 release updated Web only, without Android, Windows or Linux packages; native catch-up preparation on 2026-11-03 keeps 0.11.1-jms.58+67, does not redeploy Web, and has not published native candidates.
- The Android candidate is planned as a test-key prerelease and cannot serve as an upgrade signed with the existing production key; Windows Setup remains unsigned; the Linux candidate is planned as a signed TEST with the formal Flatpak origin and automatic-update feed unchanged, subject to actual signing and publication records.
- Receiving pauses during SyncPlay so room synchronization and remote control remain separate; account settings and existing subtitle fixes are preserved.
