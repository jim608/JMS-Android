# JMS Git 與發布規範

## 分支與提交

所有 JMS 修改使用 `jms`。每批目的單一的修改完成相關檢查、staged diff 與隱私檢查後即提交；同一修正及必要測試可以同筆。只加入審查過的路徑或 hunk，不使用整包暫存，不混入既有無關修改。

訊息使用 `fix(seerr): 修正工作階段還原`、`test(seerr): 補齊登入競態測試`、`chore(git): 新增提交前隱私檢查` 等格式。作者及提交者使用已確認的 GitHub noreply 身分。訊息、文件及公開檢查輸出不得包含私人網址、信箱、本機使用者路徑或憑證。

commit、push、Release 是三件事。小批次 commit 不觸發 APK 建置；依授權在里程碑 push；實際新版本及所有 gate 通過後才發布。純規則／文件維護不增加 App 版本。

開始工作與準備發布時核對 remote URL、`git ls-remote --symref <upstream> HEAD`、共同祖先與新增提交。官方來源為 [DonutWare/Fladder](https://github.com/DonutWare/Fladder)。remote 名称不代表身分；本機的 `origin` 目前指向官方來源，不是 JMS 發布庫。

2026-09-27 核對：官方 HEAD 指向 `develop`。本庫原為 shallow clone，補齊官方 `main` 歷史後，確認與 `develop` 有共同祖先，兩側分別有 74／7 筆提交，不能宣稱不相關歷史。既有追蹤的 `main` 沒有待合併更新；改採官方預設 `develop` 是來源分支決策，不能在大量 dirty App 成果上逕自切換／合併。本輪不建立假的 master，不使用 unrelated-histories、ours 或強制推送。正常且可追溯的更新才合併至 `jms`，保留 JMS 修改並測試受影響範圍；沒有更新不建立空合併、不輪詢。發布器對未整合的官方預設分支更新會停止。

## 新 clone 的 hook 安裝

在 clone 根目錄，用可用的 Python 3 執行：

```text
python scripts/install_jms_git_hooks.py
python scripts/install_jms_git_hooks.py --check
```

安裝會設定本庫 `core.hooksPath=.githooks`；政策尚未建立時回傳失敗。用 `git rev-parse --git-path jms-private-domains` 找到政策位置，在本機填入已知私人 domain、私人信箱與需要禁止的精確值，每行一項，支援註解。不得提交這份政策，CI 使用合成政策做測試。沒有政策或政策為空，檢查拒絕放行。Windows hook 優先使用專案工具 Python，其他 clone 需要 PATH 中可用的 python3。

`pre-commit` 讀實際 index；`commit-msg` 檢查訊息及作者／提交者；`pre-push` 拒絕寫官方 upstream、拒絕更新 main、檢查 outgoing 每筆提交和最終 tree。檢查已在隔離 repository 實際執行，不只是檔案存在。不得略過 hook 或改寫／編碼私人字串躲避檢查。

## 隱私範圍與限制

檢查已知私人網址／信箱、私人網路端點、本機使用者路徑、憑證 URL／標頭、Token／Cookie／密碼／API Key 字串模式及私鑰檔案。推送檢查涵蓋新提交訊息、身分及中間檔案版本，即使後一筆刪除敏感值仍會拒絕。文件、測試及日誌沒有通用免檢規則；只回報安全的位置和類型。

發布器直接執行 tree、outgoing history 與每項實際資產檢查，不依賴 hook。ZIP、APK、JAR、AAR 逐層讀取，二進位內的已知明文字串也會掃描。字串檢查無法證明不存在所有未知、加密或執行期取得的秘密；本機政策必須維護完整。測試使用保留的範例網域及明確 `fixture-` 憑證，不把真實值加入公開測試。

Git tree 檢查會報告 blob 數與未展開的外部 gitlink 數。子模組內容不存於本庫 blob，也不假稱已掃描；若實際打包子模組，仍須經資產檢查及既有第三方來源稽核。

`AGENTS.md` 與本機歷史交接 `docs/JMS_STATUS.md` 不進後續來源 ZIP。上游署名、LICENSE、第三方授權與公開來源連結仍保留。既有 dirty 文件不得為了提交隱私修正而整份混入其他修改。

## 服務來源

公開來源沒有私人預設網址。既有帳號的來源與本人連動資料保留；新安裝透過既有使用者設定或部署配置提供來源。可選的 `JMS_SEERR_SOURCE`／`JMS_LEGACY_SEERR_SOURCE` 編譯設定僅在兩者都明確提供時啟用既有的精確來源遷移。

舊配置已保存在 Git 管理目錄的 `jms-private-build.json`，不會自動讀入公開建置。不進 Git 不代表不出現在 APK：若自行以 dart-define-from-file 將私人來源編譯進 APK，網址可被擷取，發布資產檢查仍會拒絕。不得將这种 APK 宣稱為已完全去除私人網址。

來源遷移整合測試需明確提供合成設定：

```text
flutter test --no-pub --dart-define=JMS_SEERR_SOURCE=https://jellyseerr.jms.example.invalid --dart-define=JMS_LEGACY_SEERR_SOURCE=https://jellyseer.jms.example.invalid
flutter test test/jms_seerr_private_source_test.dart --no-pub
```

發布器的測試入口使用上述合成設定；第二個命令另外驗證無預設來源的行為，不操作真實帳號或裝置。

## 可追溯發布

既有入口 `scripts/publish_jms_android.ps1` 呼叫發布器：

1. 要求乾淨的 `jms` HEAD、index 和非忽略工作檔；依 `config/jms_upstream.json` 核對已選定的官方 `main` 分支及祖先關係，必要更新尚未合併就停止。上游預設 `develop` 不會在發布時自動取代既有來源線；變更追蹤線需另行審查。
2. 在建置前檢查 outgoing history、tag 和非快轉條件。測試、簽章、原生授權及版本 gate 保留。
3. 使用真實 HEAD 建置；build record 的 sourceCommit、workspaceCommit 與 gitSourceVerified 必須一致，逐一核對建置輸入雜湊。舊 dirty APK 不得重新綁定乾淨 commit；換行轉換造成輸入 bytes 不符也必須停止，不能偽稱同一來源。
4. 保留完整核准來源 ZIP、輸入 manifest、Build ID 與 APK metadata；來源包直接讀該 commit，不生成 commit-tree 或另一條 snapshot 歷史。ZIP 包含 hooks；不附帶可能重現被刪秘密的歷史 patch。
5. 所有資產通過檢查後，atomic push 真實 commit 到 JMS 發布庫的 `jms` 與新 tag；不更新 main。非快轉、異動 tag 或舊 snapshot publication state 都停止。
6. 草稿、完整上傳與核對、Prerelease、匿名下載驗證順序不變。既有版本／附件不可覆蓋；手機未驗收不升 stable。中斷接續沿用同一來源與 state，已完成 atomic push 可冪等重入。

## 歷史處理須另行確認

本輪沒有猜測拆分既有大型功能提交，也沒有重寫已發布歷史。新增追蹤的發布腳本採用可核對的既有發布來源作基線，只將本輪目的相關的工具／測試納入；大量其他 dirty 成果仍留原位。

2026-09-27 定向掃描 10 個可用本機／遠端 ref 的目前 tree，已知私人政策字串未命中；不等於每個祖先 commit 已清理。GitHub 共有 50 個 Release 資產的 metadata 被核對；`.11`～`.14` 的 4 份來源 ZIP 和 4 個 APK 與本機 SHA-256 相符，內含已知私人來源。另有 `.10` 的本機來源 ZIP／APK 殘留，未確認是遠端資產。

本機與遠端 jms 已分歧，目前不推送。本輪不重新處理既有 tags 或附件。清理前需確認：先將 refs、tag OID、資產、update.json、雜湊和舊 sourceCommit 對照做私下備份；列出受影響使用者、clone、更新器及下載連結；決定是否接受移除舊附件／重写公開歷史的影響。若核准，保留不含私人值的舊版本追溯對照，透過真正新版本交付修正，不替換同版 APK，不宣稱可撤回既有 clone／已下載檔案。

另核對到 5 版既有資產 metadata 的 sourceCommit 與目前遠端 tag OID 不同。這是既有追溯差異，不能以改寫舊 metadata、tag 或假定本輪重建來掩蓋；清理決策前必須保留這份對照。
