# JMS 0.11.1-jms.55

## 繁體中文 / Traditional Chinese

### 修正

- 觸控播放器可點擊背景切換控制列，閒置十秒後收起，暫停畫面也適用；按住互動或開啟選單時保留控制列。
- 首頁刷新失敗時保留原有內容並允許再次嘗試，避免較舊回應在離開頁面或重新刷新後覆蓋狀態。
- 修正橫向清單取消捲動或關閉頁面後的動畫例外，並清理清單自身的焦點資源。

### 已知問題

- 舊版 Android 若開啟包含測試版更新，仍可能被歷史發布缺少更新資料的問題阻擋。
- Linux Portal 升級、Steam Deck 實機操作與實體觸控裝置仍需相應環境驗收。
- SyncPlay 仍由房間協調手動章節與段落跳轉，群組播放停用各裝置自動跳過。

### 更新注意事項

- 此候選保留既有歷史發布與 Linux 簽署更新來源，不會自動切換正式來源。

## English

### Fixed

- Touch player backgrounds toggle the controls, which hide after ten idle seconds even when paused; held interactions and open menus keep controls available.
- Failed home refreshes preserve existing content and allow another attempt, while stale responses cannot overwrite state after navigation or a newer refresh.
- Fixes animation exceptions after horizontal scrolling is cancelled or its page closes, and cleans up focus resources owned by the list.

### Known issues

- Older Android installations that include test releases may still be unable to retrieve updates because historical releases have incomplete update metadata.
- Linux Portal upgrades, physical Steam Deck operation and touch on physical devices still require validation in the corresponding environments.
- SyncPlay continues to coordinate manual chapter and segment seeks through the room, with per-device automatic skipping disabled during group playback.

### Update notes

- This candidate preserves historical releases and the existing signed Linux update origin, without automatically changing the production origin.
