# JMS 0.11.1-jms.54

## 繁體中文 / Traditional Chinese

### 新增
- 播放器新增上一章與下一章，依影片章節跳轉，並提供 Steam Deck 操作提示。
- 片頭與片尾可分別選擇關閉、只顯示提示或自動跳過，預設只顯示提示，並要求伺服器提供明確的起訖標記。
- Linux 與 Steam Deck 使用單一 JMS 啟動入口，可自動選擇介面，或手動指定桌面版與掌機版。

### 修正
- 行動版網頁在觸控操作、選單與全螢幕切換期間維持控制列可用。
- 手動回看、重複播放事件與模式切換不會反覆觸發自動跳過，提示也不再搶走操作焦點。

### 已知問題
- SyncPlay 使用手動章節與片段跳轉，由房間協調，不啟用各裝置的自動跳過。
- 伺服器未提供可靠片段標記時，不顯示片頭或片尾跳過提示，仍可使用影片章節。
- SyncPlay 在媒體權限被拒絕後的重新加入復原仍有已知限制。
- Steam Deck 實機遊戲模式辨識，以及舊版升級後的 KDE 與 Steam 選單快取行為，仍需實機確認。

### 更新注意事項
- 舊 Steam Deck 專用入口改為隱藏，既有 Steam 捷徑與 --handheld 仍可使用，使用者自建捷徑不會被刪除。
- Linux 與 Steam Deck 保留原有簽署 Flatpak 更新來源，安裝仍由系統確認。

## English

### Added
- Adds Previous Chapter and Next Chapter controls using video chapter metadata, with Steam Deck navigation hints.
- Adds separate Off, Prompt only and Auto skip choices for opening and ending segments; prompts are the default and require explicit server start and end markers.
- Uses one JMS launcher on Linux and Steam Deck, with automatic interface selection and manual Desktop or Handheld preferences.

### Fixed
- Keeps mobile Web controls available during touch interaction, menus and fullscreen transitions.
- Prevents repeated automatic skips after manual replay, duplicate playback events or mode changes, and keeps prompts from stealing focus.

### Known issues
- SyncPlay uses manual chapter and segment seeks coordinated by the room; automatic skipping is disabled for individual participants.
- Servers without reliable media-segment markers do not show opening or ending prompts; ordinary video chapters remain available.
- Recovery after a denied SyncPlay media request remains a known limitation.
- Physical Steam Deck Gaming Mode detection and KDE or Steam menu-cache behavior after upgrading an older version still require device validation.

### Update notes
- Hides the legacy Steam Deck launcher while preserving existing Steam shortcuts and --handheld activation; user-created shortcuts are not deleted.
- Linux and Steam Deck retain the existing signed Flatpak update origin, with installation confirmed by the system.
