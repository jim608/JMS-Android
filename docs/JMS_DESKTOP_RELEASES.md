# JMS 桌面發布與更新來源

Windows 與 Linux 共用 [JMS-Android 的 jms 分支](https://github.com/jim608/JMS-Android/tree/jms)，各發布倉庫只保存文件及發布記錄，不另維護 Flutter 原始碼。

| 平台 | 發布倉庫 | 更新資訊 | 適用範圍 |
| --- | --- | --- | --- |
| Windows | [JMS-Desktop](https://github.com/jim608/JMS-Desktop/releases) | update.json | Windows x64 |
| Linux | [JMS-Linux](https://github.com/jim608/JMS-Linux/releases) | update-linux.json | EndeavourOS／Arch x86_64 |
| Android | [JMS-Android](https://github.com/jim608/JMS-Android/releases) | 既有 Android 格式 | 維持既有渠道 |

自動檢查不會自動安裝。安裝前核對平台、架構、版本、檔案大小及 SHA256；穩定版不接收測試版，不同平台不得互相作為備援。

## Linux 0.11.1-jms.21

[此版本已提供測試版下載](https://github.com/jim608/JMS-Linux/releases/tag/v0.11.1-jms.21)，包含 pacman 套件、可攜式套件、完整來源、更新資訊、SHA256 清單與原生插件材料。

已在隔離 Arch 桌面環境驗證安裝、啟動、套件升級及設定保留。Seerr 工作階段使用 Secret Service，已檢查跨程序讀取、服務重啟後還原及登出清除。需要已解鎖的桌面金鑰圈；安全儲存不可用時不採用明文替代。

實體 EndeavourOS 的 GPU 播放、真實帳號登入與 Polkit 安裝視窗仍需驗證，不宣稱支援所有 Linux 發行版。

## Windows 發布條件

Windows 建置使用 `build_jms_windows.ps1`，以 `SourceCommit` 綁定已提交來源，並以 `NativeMaterials` 指定與 `config/jms_windows_native.json` 相符的二進位及相應來源快取。檢查器核對 DLL、一般與延遲載入依賴、套件與來源 SHA256，不能沿用 Android 的材料核准。

目前 Windows 尚未提供公開 Release。既有 ANGLE 封存內的相依元件仍需補齊精確來源／授權材料，原生二進位與相應來源中的上游建置路徑、測試金鑰及特殊封存也須完成逐項隱私核對；能啟動或安裝不代表這些發布條件已完成。Windows 安裝程式未簽章。

## 發布記錄

`publish_jms_release.py --platform linux` 或 `--platform windows` 沿用共同的草稿上傳、雜湊核對、公開及匿名下載驗證流程。完整資產清單與平台材料核對記錄先提交於對應發布倉庫；tag 指向該發布記錄提交，`sourceCommit` 另外記錄共用 Flutter 來源。

GitHub 自動產生的 Source code.zip 僅包含發布倉庫文件。每個 Release 必須另外附上與建置 commit 逐檔一致的完整來源封存，並包含固定修訂的子模組。不得以未提交工作樹或另一個平台的產物替代。

保留 Fladder／DonutWare 署名、GPLv3 與所有必要第三方材料；公開資料僅使用設定說明與範本。
