# JMS-SteamDeck 本機發行設計草稿

此目錄是 JMS 共用原始碼內的本機文件 scaffolding，**不是已建立的 GitHub 儲存庫，也不是已發布的 Steam Deck 版本**。使用者已確認可將 Steam Deck 的安裝包、更新說明與手把使用指引分到專用發行庫；儲存庫可見性、實際建立與發布仍待確認。

## 原始碼與發行庫邊界

- UI、輸入、播放器、字幕與 SyncPlay 留在既有共用 Flutter 原始碼，修正集中維護，不複製 `lib/` 建立另一套 App。
- 擬議的 `JMS-SteamDeck` 發行庫只承載已驗證的安裝產物、安裝／更新文件、手把使用指引、版本與來源連結。
- 既有 `JMS-Linux` 仍有自己的 Linux 發行與更新契約。硬體同為 Steam Deck，不足以判定 Android 執行環境與 SteamOS 使用相同套件或渠道。
- 本輪不建立遠端庫、不指定 GitHub 可見性、不 push、不發布，不修改現有更新來源。

## 本輪狀態

共用 UI／手把增量已完成本機實作：完整 Flutter **1,035 通過／3 既有跳過／0 失敗**、分析 **0 issues**、Kotlin policy **4/4**，Android Release Kotlin **offline exit 0**（非 APK 建置）。詳見 [實作與驗證邊界](../JMS_HANDHELD_DEVELOPMENT.md)。此處尚不宣稱任何 Steam Deck 實機或朋友的 Android 執行環境已驗收。

本輪只處理第一個手把／掌機 UI 增量。房間投票選片、同類型隨機選片留待後續；明確排除彈幕。Flatpak、作品評分與留言未確認納入。

## 文件入口

- [手把使用與待驗操作](CONTROLLER_GUIDE.zh-Hant.md)
- [安裝路徑與待確認事項](INSTALL.zh-Hant.md)
- [更新契約設計邊界](UPDATE_POLICY.zh-Hant.md)
- [驗收記錄與實機清單](ACCEPTANCE.zh-Hant.md)

只有確認包裝、更新契約與對應實機結果後，才將這些草稿改寫為可執行的發行說明。未確認前，不提供會改寫使用者系統或 App 的安裝命令。
