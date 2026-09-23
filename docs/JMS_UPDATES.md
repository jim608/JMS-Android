# JMS Android 更新：條件式一鍵發布

## 現行授權與單一入口（M12）

使用者已明確授權本輪與後續 JMS 指定工作完成後，通過所有發布檢查即直接向 **jim608/JMS-Android** 提交／推送審查過的來源、tag、完整 Release 資產，並驗證匿名下載，**不再逐版詢問上傳授權，也不只停在本機 APK**。此授權不延伸其他 repository、強制推送、公開秘密、換鍵／換 applicationId、手機操作或任何安全／授權檢查豁免。舊里程碑的「未發布」保留為當時事實，不再是現行禁令。

從專案根目錄執行（預設真的發布，但任何 gate 失敗就停止遠端寫入）：

    rtk proxy powershell -NoProfile -File scripts/publish_jms_android.ps1

只做本機／唯讀預檢，不 commit/build/push/publish：

    rtk proxy powershell -NoProfile -File scripts/publish_jms_android.ps1 -DryRun

預設 **Prerelease**。`-Channel stable` 額外要求綁定同一版 APK hash 的手機穩定驗收證據；不會自動升穩定版。普通 `flutter build`、既有 build/prepare、測試或存檔不會呼叫此入口。後續無新工作不製造版本、不常駐輪詢。

### 正式版本說明

`CHANGELOG.md` 是各版本對外變更的單一來源。每次只比較上一個已公開版本與實際新 APK／來源，於 `# JMS <實際版本>` 下使用有內容的「新增、調整、修正、移除、已知問題、更新注意事項」章節；已在前版提供的功能不重複列為新增。歷史錯誤用勘誤或當版已知問題說明，不改寫舊版 APK 的事實。

    rtk proxy python scripts/jms_release_notes.py --version <實際版本> --write

此命令從 `CHANGELOG.md` 產生當版 `docs/JMS_RELEASE_NOTES.zh-Hant.md`。發布入口與打包工具要求兩者完全一致，並檢查標題、空章節、占位字、聊天式工作回報、敏感字串及本機路徑。GitHub Release 標題從 APK 版本生成為 `JMS <實際版本>`；內文與發布包的 `RELEASE_NOTES.zh-Hant.md` 使用同一份當版內容，App 線上更新讀取該 Release 內文。測試與建置證據留在 `JMS_STATUS.md`，不混入對外說明。已發布資產與 tag 不因文案勘誤而替換。

### 執行與接續

M13 補充：本機候選建置與對外發布分開。可先執行 `scripts/build_jms_android.ps1` 及 `scripts/verify_jms_android_native.py --apk <候選 APK>`，不需先把舊 APK 的 native hash 當作新 APK 唯一允許值。單一發布入口會對照當前核准稽核的實際 APK/hash，再核對待發布候選的每個 ELF。變更不會被無條件放行。

已有本機候選時，發布入口不重建：核對原始 build record、嵌入 build ID、完整 inputs 與新 snapshot commit 的逐檔相同性後，另寫 `publication-build-inputs.json`，保留原 build record 與原始 commit/hash。發布 tag、update.json、來源 ZIP 指向包含這些完全相同 App inputs 的審查後 snapshot；不是偽造重建或改 APK 版本。Flutter／Python 測試採各自相關來源 hash 與日誌 hash 快取；只改發布文件不再重跑全部 App 測試。

1. OS 檔案鎖防止同工作區雙 publisher；程序結束自動釋放，不依靠會永久卡住的 PID lock。固定 repository、login=jim608/public/write 權限；保留 upstream origin，只能推送固定 HTTPS JMS 目標。
2. 核對本機 `.8` APK/hash/實際簽章、與 `.8` 完全相同的 checker/source/brand source hashes；官方 Releases list、update.json schemaVersion=1 及資產命名規則不變。未來若更新器程式改變，此相容性 gate 停止，須補凍結舊更新器測試，不能默認新程式等於 `.8`。
3. 全套 Flutter tests、analyze、Python 發布工具測試，退出碼非零即停止。結果綁定實際 source fingerprint/log hashes；同份程式可接續沿用，變更即失效。
4. `config/jms_publication.json` 綁定簽章及原生稽核證據；每份證據以 path+SHA-256 取得。簽章須有擁有者保管/分享陳述、有限外洩檢查、同一已安裝 signer；**不再只因 Android Debug 字樣／test 檔名拒絕**，但未知不當作安全。native 證據須逐檔 ELF hashes、reviewer/legalBasis、missing=[] 及完整材料 SHA；不允許只改一個 PASS 旗標。
5. 真正的新 `pubspec` 整數版本必須高於 2008 及所有已發布 metadata；不得低於其他本機候選。允許沿用同版、尚未發布且來源逐檔相符的本機候選，不能覆寫已發布 APK 或改 metadata 偽裝升版。`.9+9` 為 2009；本輪實際包含 Android MDK 排除與發布整合，不把 `.8` metadata 改成 2009。
6. 白名單掃描已追蹤／未追蹤的實際來源，拒絕私檔、PAT／私鑰／授權 URL 模式與 symlink；`.github/` 上游自動工作流不推送，避免無意觸發另一套發布。暫存 Git index + 精確 blob 建立來源 snapshot commit，不改目前 HEAD/index，不盲目 `git add .`。初次空庫以審查過的 JMS 根 commit 起始並保留上游來源聲明；後續只以已知已發布的 JMS main 作父 commit，未知遠端歷史先停下核對。沒有推送本機不明歷史。
7. 現有 build script 以 `-SourceCommit` 綁定 snapshot；只建一次完整 ARM64 APK。重跑有 APK 時重新核對 source/hash/簽章，符合才沿用，不覆寫或自動重新建置。若來源變動須新版本。
8. 沿用 prepare 工具，把實際 snapshot 的完整 sources/lock/patch/license/build materials 封裝；另附核准的 native-materials ZIP。先在可接續的 `.pending-<build ID>` 完成封裝，再原子 rename 成最終目錄；既有完整包不覆寫。
9. 全部 gates 通過才 atomic/non-force push main+版本 tag（tag 指真實修改 snapshot，非舊 Fladder commit）→建立 draft→逐資產上傳及實際下載校驗→publish。state 位於 `artifacts/publication/v<version>/state.json`；既有相同資產只校驗，不重複 upload。已公開內容不同、tag 不同／channel 不同一律拒絕，不偷偷替換。
10. 用不含登入 Token 的 `.8` checker 從 2008 檢查 Prerelease，匿名串流下載全部 assets；校驗 APK size/SHA/package/version/minSdk/ABI/signer 與 source/materials checksums。快取傳播至多 3 次驗證（3/10 秒間隔）；失敗保留「已發布、匿名驗證未過」狀態，下次只接續驗證。手機安裝與設定保留永遠另列待驗。

### 工具與憑證

- 專案 portable GitHub CLI `.jms-tools/gh/bin/gh.exe` 2.101.0，官方 ZIP SHA-256 `bc6c814367b193cd8e713611d61e36013c0ef843b8f516458fe3eda039192794` 已核對；不改全域 Codex 或 PATH。
- 使用已有 gh 登入；沒有時，僅非互動向現有 Git Credential Manager 取 `jim608` GitHub 憑證，在目前程序及 gh 子程序記憶體使用，不寫 Token 檔、不把 Token 放命令列。帳號不符就停止，不切換登入。M12 實測 `jim608` 有本庫 push 權限。
- 工具鏈沿用 Flutter 3.35.7／Dart 3.9.2／本機 SDK／JDK 21。私鑰仍留原 `.android/debug.keystore`，不搬去雲端、不產生新 key。
- `artifacts/publication/preflight.json` 是一次性整合阻塞清單；`quality.json` 與分階段 log 保存可追溯結果。缺簽章/授權/秘密/工具/權限/相容性證據時不推送任何來源或 Release。

入口：**設定 → 關於 → JMS Android 線上更新**。首次须手動安裝含更新器版本；.4/.5 不會因 GitHub 放置檔案而自動升級。環境光與 ASS 實作不變。

## 來源

- Fladder 上游 origin = https://github.com/DonutWare/Fladder.git，僅來源追溯，更新器拒絕它。
- 公開來源及更新 repository：**https://github.com/jim608/JMS-Android**，初始為空庫；最新是否已發布以 JMS_STATUS.md M12 與 publisher state 為準。不能把 upstream origin 當 JMS 來源，不改任何既有私人庫公開性。
- 唯一來源設定：config/jms_updates.json 的 owner、repo；不要填 URL、Token 或私人庫。建置時寫入 Dart defines 並納入 build ID。
- `.6` 不支援執行時填 owner/repo。`.7` 由集中設定編入已確認來源，須手動安裝一次（不卸載、不清資料）；日後新版本才可走 feed。沒有第二套更新器。
- 首版只支援 ARM64 完整 APK，預設排除 draft/prerelease；測試版開關預設關閉。取 Releases list API 最近 20 筆中最大的相容整数 versionCode，正式版本須保留在此範圍。不支援 AAB/split-only。
- update.json、APK、source 必須為同一 release 的 uploaded assets。不完整資料拒絕，不拼接其他 release。200 空清單表示已連線但本頻道無發布版本；401/403/404 表示不存在或無權限；403 的限流 header／429 表示限流。均不報「最新版」。

## 本機命令（不發布）

從專案根目錄，使用既有 Flutter 3.35.7、Dart 3.9.2、JDK 21、本機 Android SDK 37 / Build Tools 35.0.0。先增加 pubspec.yaml 版本。ARM64 split 代碼是 2000 + base，例如 .6+6 → 2006，不重用已交付代碼。

    rtk proxy powershell -NoProfile -File scripts/build_jms_android.ps1
    rtk proxy powershell -NoProfile -File scripts/prepare_jms_release.ps1 -Apk 'artifacts/JMS-Android-0.11.1-jms.7-release-arm64-test-signed.apk'

第二個命令不建置、不連網、不上傳。從實際 APK 讀 package/version/minSdk/ABI，apksigner 核對簽章，核對 build ID、commit 與所有 app input hashes，產生 artifacts/releases/<build ID>/：
- 原簽章 APK、update.json、SHA256SUMS.txt、繁體中文更新說明。
- 對應 dirty worktree source ZIP、lock、逐檔 SHA、build inputs、基底 commit、修改 patch。
- 來源採白名單，排除 .jms-tools、artifacts、個人設定及金鑰；私鑰/PAT 樣式拒絕。自動掃描不等於完整人工機密稽核。
- publication-status.json 為 LOCAL_ONLY / BLOCKED。原生依賴相應來源稽核依 JMS_SOURCES.md，不因有 ZIP 而宣稱完成。
- 同名目錄拒絕覆寫。APK 建置後更動 app input 必須重建，不能以其他版本源碼配對；纯報告新增不重建 App。

    rtk proxy powershell -NoProfile -File scripts/prepare_jms_release.ps1 -Apk '<已核對 APK 路徑>' -RequirePublicationReady

單獨 prepare 仍只做本機封裝；真正發布必須經上述單一入口。現行 gate 依 hash-bound custody/native evidence 判定，不再依 Debug 字樣直接拒絕。發布授權已取得，但未知保管歷史與原生相應來源／組合許可不能被授權自動解除；沒有繞過開關、不自動產生或換鍵。

## 簽章具體核對（M10）

- `.6` 的 production/release APK 仍以 `JMS_TEST_SIGNING=true` → Gradle `signingConfigs.debug` 簽章；key 在 `C:\Users\a0659\.android\debug.keystore`（2618 bytes）。Gradle signingReport 與實際 APK 憑證一致，不以選項預設猜測。
- 憑證 SHA-256：`4327eedb953fbf51d82b70e2e56c23122c85304d55a67fbbdb37a8f1ffd5f399`。主體 Android Debug、RSA、sha256RSA；有效期 2026-08-09 至 2056-08-01。檔案建立時間與憑證起期相符；這是本機既有 debug 身分，**沒有證據證明是網路公用測試私鑰**。
- ACL 限使用者／Administrators／SYSTEM。本專案 tracked paths、現有淺層 Git objects 與 6 個 source ZIP 均未見該 key；未查所有其他專案、備份、外部分享，不能保證從未外洩。沒有輸出 key、密碼、Token。
- 真正風險是全域開發用途金鑰、標準 debug 管理方式、可能被其他 Android 專案共用、備份／持有人／外部複本未確認。M10 的 fingerprint/Debug subject 一刀切 guard 已由 M12 證據式 guard 取代；不是掃描出了已公開私鑰。沒有取得擁有者陳述仍拒絕，不能把 guard 修改本身當成簽章已安全。
- 未確定必須換鍵。優先請擁有者确认此 key 生成／持有／分享／備份歷史；若無洩漏，可另行核准保留原簽章身分並改為 JMS 專用安全保管及離線備份，維持升級／資料連續性。本輪不搬移或變更保護方式，不擅自將它認證為正式安全金鑰。
- 若確定須換新 key：直接以同 package + 不同 signer 安裝會被拒絕，不可用卸載／清資料解決。Android 9+ 的 APK Signature Scheme v3 lineage 需要舊、新 keys 及裝置測試；目前 JMS 更新器保守要求 signer set 一致，還須先規劃舊簽章過渡版才能處理 rotation。API 24–27 需另留舊 signer 相容路徑，不能承諾一份換鍵 APK 保證所有裝置無損升級。先獲批准、再做遷移，不在本輪自動換鍵。
- 官方背景：[Android App signing](https://developer.android.com/studio/publish/app-signing)、[APK signature rotation](https://source.android.com/docs/security/features/apksigning/v3)。文件屬技術風險說明，不是 Google Play 上架核准或金鑰安全認證。
- AOSP 目前另明示不建議對 Android 12/API 31 以下採取 key rotation；即使支援 v3 也不能保證遷移可行。正式遷移須按使用者實際 Android 版本及來源安裝方式選方案，而非直接重簽。

## 下載與安裝安全

- 官方 API/HTTPS/ETag/JSON 快取；單請求 15 秒、5xx 最多額外重試一次。限流依 retry/reset 暫停並持久化；自動每天最多一次，無背景常駐、無自動彈窗/下載。
- APK 僅指定 repository release asset；官方 release-assets.githubusercontent.com / objects.githubusercontent.com 的 HTTPS 導向可用，其餘外站及 HTTP 拒絕，最多 5 次。
- 原生 worker 以 64 KiB 串流寫 App 私有 cache，限制 300 MiB；SHA 隨下載計算、進度最多每 250ms。取消/中斷清理，手動重試從頭下載。
- 核對大小/SHA、PackageManager 的實際 package/version/minSdk、ZIP 完整 ARM64 app/flutter library、非 split。候選 signer set 與**已安裝 JMS**相同，不信遠端憑證；首版保守拒絕 signer rotation。
- PackageManager 辨識 signer 不等於本 App 完成全部 APK 密碼學驗證。安裝前再 off-main-thread 核對 SHA/身分，**Android installer** 最終強制驗證內容簽章和系統策略。
- 明確點擊後才開安裝；FileProvider 僅授予 update APK content URI，無 file URI 或廣泛儲存權限。
- 拒絕未知來源授權、取消或系統阻擋不清資料、不卸載。下載完成/安裝返回不是成功；下次啟動已安裝 versionCode ≥ pendingCode 才確認，否則待確認。
- 播放 state 非 disposed（含暫停/小窗）或 App 在背景時拒絕下載/安裝，並取消現有下載；離開播放恢復每日檢查資格，不改播放器實作。
- cache 最多保留一個 APK；重試替換，超過 24 小時殘留於下次建立 bridge 時清理；不記錄授權 URL、憑證內容、帳號。

## 發布順序與手機驗收

1. 更新庫已確認為 `jim608/JMS-Android`；仍須確認金鑰与完整 GPL/第三方相應來源，不改私人來源庫可見性。
2. 設定來源、版本、說明；測試、建置、prepare，人工檢查來源和 SHA。
3. 依已取得的常設條件授權，通過全部 gates 後由入口建立 draft，使用測試頻道；不再要求逐版上傳批准。
4. 補齊 APK/update.json/source ZIP/校驗/授權/說明，重新下載核對 SHA、cert、同 release 檔名大小。GitHub 自動上游 commit ZIP 不能取代修改後源碼。
5. 全部核對完成才 publish draft，避免半成品可見；tag 必須指到所有實際修改的 source snapshot。以匿名下載核對，不能只看登入後 gh 結果。
6. 使用者在 `.8` 設定 → 關於 → JMS Android 線上更新，開啟「接收測試版」→檢查→下載→確認系統安裝。核對登入、伺服器、環境光、睡眠及備份設定保留；本機不得自動操作手機。實機成功後才標端到端 PASS。

## 依據與尚缺資訊

- [GitHub Releases API](https://docs.github.com/en/rest/releases/releases)
- [GitHub API 最佳實務](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api)
- [Android PackageManager](https://developer.android.com/reference/android/content/pm/PackageManager)
- [Android FileProvider](https://developer.android.com/training/secure-file-sharing/setup-sharing)

尚待條件以 `artifacts/publication/preflight.json`（實際入口執行當時）、`artifacts/checks/m12/final-gates.json`（使用者回覆後離線核對）、JMS_STATUS.md M12 及 JMS_SOURCES.md 為準：發布授權／owner/repo 已不再缺少；本人建立保管已確認，但分享／備份歷史未明示；使用者確認沒有既有 SDK 授權／建置文件。精確原生材料／GPL 組合依據不可臆測，手機覆蓋升級另待使用者驗收。公開 Prerelease 不是私密測試，不能繞過上述 gates。

M12 最終沒有發布、沒有新 APK：不帶 `-DryRun` 的入口已在 gates 正確停止；`.8` 匿名查詢得到 `noRelease`，不代表已完成下載或升級。`.9 (2009)` 是待接續的來源版本，不是已交付產物。待證據補齊後使用同一命令真正發布並匿名下載驗證，無須重新取得上傳授權。
