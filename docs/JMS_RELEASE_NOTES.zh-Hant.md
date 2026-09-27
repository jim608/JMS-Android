# JMS 0.11.1-jms.19

## 新增
- 新增 EndeavourOS／Arch Linux x64 桌面版的 pacman 套件與可攜式封裝，使用系統 MPV 播放媒體。
- 新增 Linux 版線上更新整合，可檢查及下載對應平台的新版本，核對套件後由使用者授權 pacman 安裝。

## 調整
- Windows 與 Linux 共用 JMS-Desktop 發布渠道，使用不同的更新資訊檔案，避免下載錯誤平台的安裝包。
- Linux 不包含 MDK 播放器；Android 與 Web 的播放器選擇維持不變。

## 已知問題
- Linux 的登入、GPU 播放、字幕特效及更新後設定保留仍需 EndeavourOS 實機驗證。
- Linux App 內安裝需要桌面 PolicyKit 驗證代理；系統簽章政策若拒絕未簽章的本機測試套件，安裝將被阻擋。

## 更新注意事項
- 首次安裝 Linux 版須下載對應的 pacman 套件；接收後續測試版本時，請於「設定 → 關於」開啟「接收測試版」。
- Web 仍由管理者部署更新，不提供 App 自動更新功能。
