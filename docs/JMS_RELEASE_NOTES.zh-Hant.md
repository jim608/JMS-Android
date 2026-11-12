# JMS 0.11.1-jms.59

## 繁體中文 / Traditional Chinese

### 修正

- 關閉接收或斷線時立即撤銷舊的遠端控制權限，避免尚未完成的播放器操作更新新狀態。
- 重新啟用接收時，若舊操作仍未結束，暫時顯示不可用並拒絕新指令，待舊操作完成後恢復。

### 已知問題

- 本版為測試版；實體 Android、Windows、Linux、Steam Deck、Tesla、真實 Jellyfin 與舊版升級仍未完成驗收。
- 自動化測試不代表實機影音、GPU、音效、Flatpak Portal 或跨裝置連線已通過。

## English

### Fixed

- Revoke stale remote control immediately when receiving is disabled or disconnected, preventing unfinished player operations from updating newer state.
- Reject new commands as temporarily unavailable after re-enabling receiving until an outstanding player operation settles, then restore availability.

### Known issues

- This is a test release; physical Android, Windows, Linux, Steam Deck, Tesla, real Jellyfin and previous-version upgrade acceptance remain incomplete.
- Automated tests do not establish physical playback, GPU, audio, Flatpak Portal or cross-device acceptance.
