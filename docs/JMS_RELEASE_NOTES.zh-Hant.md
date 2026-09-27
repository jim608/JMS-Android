# JMS 0.11.1-jms.21

## 調整
- Windows 更新來源獨立為 JMS-Desktop，EndeavourOS／Arch Linux x64 更新來源獨立為 JMS-Linux，下載時核對對應倉庫與平台。

## 修正
- Linux 啟動時不再呼叫平台未提供的通知啟動資訊 API。
- Linux 的 Seerr 工作階段改用桌面 Secret Service 持久金鑰圈，支援重新啟動後還原及登出清除，金鑰圈不可用時不使用明文替代。

## 已知問題
- Linux 的 GPU 播放、字幕特效及完整桌面升級仍需 EndeavourOS 實機驗證。
- Windows 安裝程式及 Linux 套件未提供正式發行者簽章。

## 更新注意事項
- Linux 需可解鎖的 Secret Service 金鑰圈，以及供安裝授權使用的 PolicyKit 桌面代理。
- 自動檢查不會自動安裝；接收測試版須在設定中啟用。
