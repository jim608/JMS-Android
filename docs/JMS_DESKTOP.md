# JMS Desktop

JMS（Jim608 Media Server）桌面版與 Android、Web 共用同一份 Flutter 原始碼。Windows 與 Linux 發布渠道統一為 [JMS-Desktop](https://github.com/jim608/JMS-Desktop/releases)，不維護另一份分叉的介面或播放器。

## 支援目標

- Windows x64：安裝程式與 Portable ZIP；未簽章的測試版本可能顯示 SmartScreen 提示。
- EndeavourOS／Arch Linux x64：pacman 套件與可攜式壓縮包。使用系統的 MPV、GTK 3 與 ALSA，不包含 MDK；可攜式版本也需要這些系統依賴。
- Linux 首版不提供 DEB／RPM，也不宣稱其他發行版已驗證。
- 套件是否已可下載以 Release 的實際附件為準。原生依賴與來源材料尚未完成核對的平台不會提供安裝附件。

## 安裝及更新

- 首次使用須手動安裝包含 JMS 更新器的版本。
- 在「設定 → 關於」開啟自動檢查更新。測試版需開啟「接收測試版」。自動檢查最多每 24 小時一次，不會自動下載或靜默安裝。
- Windows 使用 `update.json`；Linux 使用 `update-linux.json`。兩者位於同一個 Release，各自核對平台、版本、大小、SHA-256 與實際套件資訊。
- Linux 安裝使用系統 PolicyKit 與 pacman；使用者確認安裝後才要求系統授權。不修改 pacman 的信任政策，也不執行整台系統的更新。
- EndeavourOS 首次安裝：在已完成正常系統更新的環境下載相應套件後，執行 `sudo pacman -U ./JMS-Linux-版本-x86_64.pkg.tar.xz`。桌面須有運作中的 PolicyKit 驗證代理，才能使用 App 內安裝。
- 安裝完成後重新啟動 JMS，再確認版本。開啟安裝程序不等於更新成功。登入與播放設定不會因安裝而主動清除。
- Linux 套件依循本機 pacman 簽章政策；若系統要求所有本機套件都有簽章，未簽章測試包會被拒絕，不會自動降低檢查。
- Web 不提供 App 自動更新；管理者從 [JMS-Web](https://github.com/jim608/JMS-Web) 部署指定版本。

## 來源與授權

唯一共用來源：[JMS-Android 的 jms 分支](https://github.com/jim608/JMS-Android/tree/jms)。每個平台的建置紀錄與 Release 記錄相同來源提交及各自 Build ID，產物雜湊分開保存。

保留 Fladder 原作者署名與 GPLv3 授權。各平台提供對應修改版來源、依賴鎖定、建置工具與適用的第三方授權材料；測試版同樣適用。

## 開發建置

在乾淨的共用來源提交上使用 `scripts/build_jms_windows.ps1 -SourceCommit <commit>` 或 `scripts/build_jms_linux.ps1 -SourceCommit <commit>`。Linux 使用隔離的 Docker 建置環境，不要求在 Windows 主機安裝 Linux 桌面，也不部署至正式伺服器。

## 已知限制

- Windows 原生依賴的對應材料仍在核對；已有本機測試安裝包不代表已可公開發布。
- Linux 的登入、GPU 播放、ASS 特效及安裝後設定保留需要 EndeavourOS 實機驗證。
- Linux 使用系統 MPV，實際編碼器與硬體解碼能力依已安裝的系統套件及驅動而定。
