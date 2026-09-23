# JMS — Jim608 Media Server

JMS 是以 [Fladder](https://github.com/DonutWare/Fladder) 為基礎的 Jellyfin 用戶端，保留媒體瀏覽、搜尋、播放、字幕與音軌選擇、下載及離線播放等既有功能。Android 為主要驗收平台。

## 主要功能

- 媒體庫瀏覽、帳號切換、影片播放、字幕與音軌選擇。
- 可調整強度與擴散範圍的播放環境光，以及睡眠計時與非敏感設定備份。
- 原生點片、申請紀錄與影片問題回報介面，使用現有 Jellyseerr／Seerr 服務；登入與提交仍須依服務權限確認。
- 透過 [JMS Android Releases](https://github.com/jim608/JMS-Android/releases) 手動檢查、下載並由 Android 系統確認安裝更新。

## 安裝與更新

從 [GitHub Releases](https://github.com/jim608/JMS-Android/releases) 下載符合裝置 ABI 的完整 APK。目前提供 Android ARM64 測試版，套件識別碼為 `com.jim608.jms`，可與原版並存，但不會自動繼承原版的登入資料。測試版使用既有相容簽章；請勿將 Prerelease 視為已通過穩定版手機驗收。

在 App 的「設定 → 關於 → JMS Android 線上更新」可手動檢查更新；要接收 Prerelease，先開啟「接收測試版」。更新器不會靜默安裝，也不會清除既有 App 資料。各版變更與已知問題見[版本紀錄](CHANGELOG.md)。

## 點片與問題回報

JMS 公開版本不內建私人點片服務網址。請在 App 的 Seerr 連線設定使用你自己的 Jellyseerr／Seerr 服務網址；程式碼與測試中的 `example.invalid` 僅為不可路由的測試佔位值。JMS 不以共用管理員 API 密鑰替使用者點片。

從「點片」可搜尋、查看申請狀態及「我的紀錄」；媒體詳情與播放選單可開啟原生回報表單。Seerr 本人登入、申請、留言及回報是否可用，仍取決於部署版本與帳號權限。舊版保存的錯誤預設網址會於新版定向遷移，舊 Seerr 工作階段不會帶到新來源，可能需要重新確認服務綁定。

## 建置與授權

使用 Flutter **3.35.7**、Dart **3.9.2**、JDK **21**、Android API **37** 及鎖定的依賴版本；建置步驟見 [DEVELOPEMENT.md](DEVELOPEMENT.md) 與 [INSTALL.md](INSTALL.md)。發布流程與來源材料見 [JMS_UPDATES.md](docs/JMS_UPDATES.md)、[JMS_SOURCES.md](docs/JMS_SOURCES.md)。

本專案源自 DonutWare 與貢獻者的 Fladder，保留原作者署名、[GPLv3 授權](LICENSE)及必要第三方授權。JMS 修改版及原生依賴的對應來源材料隨發布版提供；上游連結僅供來源署名，不是 JMS 更新來源。
