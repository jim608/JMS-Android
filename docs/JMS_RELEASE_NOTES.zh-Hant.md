# JMS 0.11.1-jms.35

## 新增
- 提供 Linux x86_64 Flatpak 測試版，使用獨立沙箱設定目錄與隨包媒體解碼元件。

## 調整
- Flatpak 安裝由 Flatpak 管理更新，設定頁提供軟體庫與本機套件的更新說明。
- 支援尋找 Discord Flatpak 的播放狀態連線，仍需使用者啟用分享。

## 已知問題
- 實體 Linux 桌面的 GPU、音效與本人服務登入仍需驗收。

## 更新注意事項
- 本版僅交付 GitHub Linux Flatpak 測試版，既有 Android、Windows、Arch 套件版本維持原發布。
- 更新前請關閉 JMS，再安裝新版 `.flatpak`；首次安裝需要下載 GNOME runtime。
- Flatpak 設定與快取保存在沙箱專用目錄；離線媒體存入使用者選擇並授權的目錄。首次安裝不會自動搬移 Arch／Portable 的設定或登入資訊。
