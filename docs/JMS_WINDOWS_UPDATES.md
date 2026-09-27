# JMS Windows 線上更新

## 使用方式
- 更新來源固定為 [jim608/JMS-Desktop](https://github.com/jim608/JMS-Desktop)。Android 更新來源不變。
- 首次需手動安裝含桌面更新功能的版本。舊版不會因 GitHub 出現檔案而自行取得更新能力。
- 在「設定 → 關於」開啟自動檢查更新；最多每 24 小時檢查一次，也可手動檢查。接收測試版預設關閉。
- 自動檢查不代表自動下載或靜默安裝。新版提供版本說明、檔案大小、下載進度、取消、略過版本與稍後處理。
- 播放中或退到背景暫停更新操作。下載完成後必須點擊安裝，再確認未簽章測試版提示。
- 安裝使用正常 Inno Setup 視窗，不自動卸載、不清除設定、不強制關閉程式。免安裝版改用安裝版，原免安裝資料夾保留；之後請啟動安裝版。
- 開啟安裝視窗只表示安裝待確認。重新啟動且版本代碼達到目標後，才顯示更新成功。

## 發行格式
- 同一 Release 必須包含 `update.json`、完整 x64 installer、相應 source ZIP 及適用第三方來源材料。Portable ZIP 可另附，不作自動替換來源。
- 更新器使用整數 `versionCode`，不以版本名稱排序；不能重用代碼或降版。
- `update.json` schema 1 共用 Android 的應用身分與來源欄位；桌面增加 `platform: windows-x64`、`minWindowsBuild`、`signing: unsigned`，以 `installer` 取代 `apk`。
- `installer` 與 `source` 都包含 `name`、`size`、`sha256`；`sourceCommit` 必須指向實際建置來源；另記錄 `versionName`、`versionCode`、`buildId`。
- 僅接受本庫 HTTPS 資產與 GitHub 官方 asset redirect；有界串流下載、大小／SHA-256 驗證、安裝前再驗證。原生橋接核對安裝檔 ProductName、ProductVersion 與版本資源 build number。
- 現階段沒有 Windows 程式碼簽章憑證。SHA-256 不是發行者簽章；信任基礎是受控 GitHub Release 與 HTTPS。未簽章測試版需使用者確認，Windows 可能顯示 SmartScreen。若未來加入簽章，必須另設可信發行者策略，不可只接受遠端自稱的憑證。

## 建置與本機準備
```powershell
rtk proxy powershell -NoProfile -File scripts/build_jms_windows.ps1 -Version <version> -BuildNumber <new-code> -SourceCommit <reviewed-commit>
rtk proxy powershell -NoProfile -File scripts/prepare_jms_windows_update.ps1 -ArtifactDirectory artifacts/windows/<version>
```
- `BuildNumber` 為 1～65535，必須高於所有已發布 Windows 版本；Android versionCode 不共用此命名空間。
- 準備工具從實際 installer 讀取版本與雜湊，核對建置紀錄與 reviewed source，產生 `update.json`、SHA256SUMS 及 Git source ZIP。它不會上傳或發布。
- 含私人配置的本機包、dirty source build、不完整原生授權材料不能直接發布。Source ZIP 本身不代表已包含所有必要原生材料。
- 完成 Windows 原生授權／秘密／來源／測試檢查後，先建立草稿並上傳完整資產，核對後發布 Prerelease；最後匿名檢查更新資訊及下載雜湊。不能用空 Release 或虛構更新資訊測試一般使用者。
- Android 原有發布入口不會發布 Windows 產物，也不應將 Windows metadata 上傳到 Android 更新庫。

## 原生校驗測試
`windows/runner/tests` 可獨立 CMake 建置，測試實際 installer metadata 與 unsigned policy，不執行安裝程式。參數為 installer 路徑、versionName、versionCode。Dart 更新測試使用 mock，不代表 GitHub 到實機覆蓋升級完成。

## 相容性與限制
- Windows 10 1809 以上、x64；ARM64 原生安裝與差分更新不在本版範圍。
- 沒有可用 Release 時明示尚無版本，不等同於已是最新版。
- 正式覆蓋升級、取消安裝、設定保留與 SmartScreen 行為仍需使用者在實際環境確認。
