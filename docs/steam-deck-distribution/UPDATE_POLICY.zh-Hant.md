# Steam Deck 更新契約設計草稿

**此文件不新增更新來源，也不選定 Steam Deck 套件格式或渠道。** 未確認前，共用 App 的既有 Android／Windows／Linux 更新路徑維持原契約。

## 目前程式邊界

- `lib/util/linux_update_bridge_io.dart` 的 Linux bridge 指向 `JMS-Linux`，目標為 `linux-x64`，查詢並驗證 pacman 套件，安裝走既有 PolicyKit／pacman 路徑。
- `lib/util/update_checker.dart` 目前辨識 `android`、`windows-x64`、`linux-x64`；Linux metadata 檔名是 `update-linux.json`，並驗證 `JMS-Linux-…-x86_64.pkg.tar.xz` 與 Arch 套件資訊。
- `scripts/jms_desktop_publication.py` 將 Linux 發行綁定 `JMS-Linux`；本輪保留既有變更，不改發布工具或加入 Steam Deck 遠端寫入。

因此，另設 `JMS-SteamDeck` 發行庫不會自動建立可用的 App 內更新渠道，也不能僅替換 repo 名稱便沿用 Arch 安裝器。Android 執行環境仍須按 Android 產物契約評估。

## 後續需確認的契約

1. 目標執行環境、平台與架構識別，以及實際安裝格式。
2. 更新 metadata 的 schema、產物名稱、下載來源及信任邊界。
3. 共用來源 commit、版本、Build ID、大小、SHA-256 與授權材料的綁定方式。
4. 同版／降級／錯平台／錯架構／缺 metadata 的拒絕行為。
5. 下載與安裝確認、失敗重試、取消、設定保留與回復行為。

不得新增跨平台 fallback、略過完整性檢查，或為未驗證產物開放自動安裝。儲存庫可見性、建立、push 與發布需另行確認；本輪沒有執行上述操作。
