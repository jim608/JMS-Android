# JMS 0.12.0-jms.60

## 繁體中文 / Traditional Chinese

### 新增

- 可在儲存篩選中選擇「固定到首頁」。每列顯示最多 12 筆預覽，點列標題可開啟完整清單。

### 調整

- 整合 Fladder 0.12.0 上游基線，更新至 Flutter 3.50.0。
- 收藏頁按內容類型查詢，媒體庫隱藏首頁最新項目時仍可顯示其中的收藏。
- 全站搜尋與收藏使用分頁。切換媒體庫時優先載入目前選取的媒體庫。

### 修正

- 離線觀看紀錄只同步到原帳號與伺服器，先前請求的回應不會覆寫較新的本機紀錄。
- 保留暫停下載的續傳資料。影片排入下載後再取預覽縮圖，同名字幕分開存檔。
- 修正拖曳時間軸時過早續播，以及關閉播放器或離房後的延遲回呼。

### 已知問題

- 本版為預發行。實機續傳、直接升級與跨裝置同步仍待驗收。來源無法確認的舊離線紀錄會留待同步。

## English

### Added

- Pin a saved library filter to Home. Each row previews up to 12 items and opens the complete list when selected.

### Changed

- Integrate the Fladder 0.12.0 upstream baseline and Flutter 3.50.0.
- Load favourites by media type and include favourites from libraries hidden in Home's latest-items section.
- Page global search and favourites results. Load the selected library when switching libraries.

### Fixed

- Replay offline viewing data only to its original account and server. An older acknowledgement cannot overwrite a newer local update.
- Preserve paused download data across restarts. Queue media before fetching optional thumbnails and store same-named subtitle tracks separately.
- Wait for a timeline seek to finish before resuming, and discard stale callbacks after leaving playback or a room.

### Known issues

- This is a prerelease. Physical-device resume, in-place upgrades and cross-device playback still need acceptance testing. Older offline records without a verified source remain pending.
