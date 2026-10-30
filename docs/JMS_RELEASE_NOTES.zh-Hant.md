# JMS 0.11.1-jms.56

## 繁體中文 / Traditional Chinese

### 修正

- 修正 SyncPlay 切換字幕後，播放器將暫時閒置誤判為緩衝不足而持續等待的情況，並保留真正快取不足與過期事件的保護。
- 觸控播放器可點按背景切換控制列，閒置十秒後收起；按住操作或開啟選單時保留控制列。
- 首頁重新整理失敗時保留既有內容並允許重試，避免舊回應覆蓋較新的狀態。
- 修正橫向清單取消捲動或離開頁面後的動畫與焦點資源清理。

### 已知問題

- 原生解碼、實際雙端 Jellyfin、Steam Deck 與 Flatpak Portal 的實機驗收尚未完成。
- Android 穩定版仍受對應版本的裝置與簽章驗收條件限制。

### 更新注意事項

- Windows 安裝程式未簽章；Linux 測試套件不會切換正式 Flatpak 更新來源。
- SyncPlay 繼續由房間協調手動章節與片段跳轉，共同播放時停用各裝置自動跳過。

## English

### Fixed

- Fixes SyncPlay waiting loops after subtitle changes when temporary renderer idle is mistaken for insufficient buffering, while preserving real cache-wait and stale-event protection.
- Touch player backgrounds toggle the controls, which hide after ten idle seconds; held interactions and open menus keep controls available.
- Failed home refreshes preserve existing content and allow retry, while stale responses cannot overwrite newer state.
- Fixes animation and focus-resource cleanup after horizontal scrolling is cancelled or its page closes.

### Known issues

- Physical native decoding, live two-client Jellyfin, Steam Deck and Flatpak Portal acceptance remain incomplete.
- Android stable releases remain subject to version-specific device and signing acceptance.

### Update notes

- The Windows installer is unsigned; Linux test packages do not change the production Flatpak update origin.
- SyncPlay continues to coordinate manual chapter and segment seeks through the room, with per-device automatic skipping disabled during group playback.
