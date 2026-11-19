# JMS 0.12.0-jms.61

## 繁體中文 / Traditional Chinese

### 新增

- 首頁輪播一次展示一部作品，可直接播放或繼續觀看。在「設定 → 主題 → 使用舊版介面」可切回經典外觀。

### 調整

- 手機搜尋建議使用更寬的清單，顯示片名、類型和年份。媒體庫的搜尋、篩選和掃描現在都能直接找到。
- 作品詳情列出版本、音訊和字幕，放大字級時可自動換行。桌面設定標示目前類別，手機捲動時保留標題與返回鍵。

### 修正

- 用方向鍵選取搜尋建議後，按 Enter 可直接開啟作品。首頁的詳情與播放鍵可分別用鍵盤或讀屏操作。
- 修正帳號偏好尚未載入時開啟播放器設定會出錯，以及影集缺少年份時顯示空值的問題。

### 已知問題

- 本版為預發行。新介面已在 Flutter 測試環境驗證，實機操作、覆蓋升級及真實伺服器的搜尋延遲仍待驗收。

## English

### Added

- Home now features one title at a time with a play or resume action. Enable the classic interface in the theme settings to switch back.

### Changed

- Search suggestions use more screen space on phones and show the title, media type and year. Library search, filters and scanning are within reach on the mobile toolbar.
- Media details show the selected version, audio and subtitles. These controls wrap at larger text sizes. Desktop settings identify the active category, and mobile settings keep the title and back button visible while scrolling.

### Fixed

- Pressing Enter on a highlighted search suggestion opens the title. The Home detail and play actions can be reached separately with a keyboard or screen reader.
- Player settings open while account preferences are loading. Series with no production year no longer show a null value.

### Known issues

- This is a prerelease. The interface has been exercised in Flutter tests. Physical-device use, in-place upgrades and search latency on a live server still need verification.
