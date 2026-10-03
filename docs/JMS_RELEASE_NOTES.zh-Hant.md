# JMS 0.11.1-jms.31

## 新增
- Windows 與 Linux 提供 Discord 播放／暫停狀態分享，每個 JMS 帳號預設關閉；影片名稱須另外取得同意才會分享。
- 停止播放、登出、切換帳號或進入隱身模式時清除 Discord 狀態。Discord 未開啟或連線失敗時不影響播放。

## 已知問題
- Discord 狀態目前只支援 Windows 與 Linux 桌面版，Android 與一般 Web 瀏覽器尚未提供；實際 Discord 個人檔案顯示仍待使用者裝置驗證。
- Linux 支援範圍為 EndeavourOS／Arch x86_64；本機套件配方尚未刊登 AUR，尚未提供 Flatpak 套件。
- Windows 相容顯示路徑目前最高輸出 1920×1080；不同顯示卡、長時間播放及 EndeavourOS／Arch 實體桌面仍待驗證。

## 更新注意事項
- 本版為測試版，須啟用接收測試版；下載完成後仍須由使用者確認安裝。
- Discord 桌面版須在同一台電腦開啟並登入，分享範圍也受 Discord 活動隱私設定影響。
- Windows 與 Linux 未提供正式發行者簽章。保留既有帳號、服務與下載設定，不需解除安裝或清除資料。
- Windows 與 Linux 使用各自的更新來源；Web 由管理者更新網站部署。
