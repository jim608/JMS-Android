# JMS Desktop

JMS（Jim608 Media Server）桌面版與 Android、Web 共用同一份 Flutter 原始碼。Windows 使用 [JMS-Desktop](https://github.com/jim608/JMS-Desktop/releases)，Linux 使用 [JMS-Linux](https://github.com/jim608/JMS-Linux/releases)，各渠道獨立發布與更新。

## 支援目標

- Windows x64：安裝程式與 Portable ZIP；未簽章的測試版本可能顯示 SmartScreen 提示。
- EndeavourOS／Arch Linux x64：pacman 套件與可攜式壓縮包。使用系統的 MPV、GTK 3 與 ALSA，不包含 MDK；可攜式版本也需要這些系統依賴。
- Linux Flatpak x86_64：從 JMS-Linux 的 Flatpak Release 安裝，使用 GNOME runtime 與隨包的 MPV／FFmpeg／libass，設定與離線資料位於獨立沙箱。
- Linux 首版不提供 DEB／RPM，也不宣稱其他發行版已驗證。
- 套件是否已可下載以 Release 的實際附件為準。原生依賴與來源材料尚未完成核對的平台不會提供安裝附件。

## 安裝及更新

- 首次使用須手動安裝包含 JMS 更新器的版本。
- 在「設定 → 關於」開啟自動檢查更新。測試版需開啟「接收測試版」。自動檢查最多每 24 小時一次，不會自動下載或靜默安裝。
- Windows 使用 `update.json`；Arch 套件使用 `update-linux.json`。各自從對應平台的公開 Release 核對平台、版本、大小、SHA-256 與實際套件資訊；Flatpak 使用下方的獨立安裝方式。
- Arch 套件安裝使用系統 PolicyKit 與 pacman；使用者確認安裝後才要求系統授權。不修改 pacman 的信任政策，也不執行整台系統的更新。
- EndeavourOS 首次安裝：在已完成正常系統更新的環境下載相應套件後，執行 `sudo pacman -U ./JMS-Linux-版本-x86_64.pkg.tar.xz`。桌面須有運作中的 PolicyKit 驗證代理，才能使用 App 內安裝。
- 安裝完成後重新啟動 JMS，再確認版本。開啟安裝程序不等於更新成功。登入與播放設定不會因安裝而主動清除。
- Linux 套件依循本機 pacman 簽章政策；若系統要求所有本機套件都有簽章，未簽章測試包會被拒絕，不會自動降低檢查。
- Web 不提供 App 自動更新，由管理者部署指定版本。

## GitHub Linux Flatpak

從 [JMS-Linux Releases](https://github.com/jim608/JMS-Linux/releases) 選擇提供 `.flatpak` 的版本，下載套件與同版 `SHA256SUMS.txt`，先核對下載套件的 SHA256。已安裝 Flatpak 的 x86_64 Linux 桌面可執行：

```bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./JMS-Linux-0.11.1-jms.35-x86_64.flatpak
flatpak run com.jim608.jms
```

首次安裝會取得 GNOME 50 runtime。Flathub remote 用於取得 runtime，JMS 套件由 GitHub 提供。更新前請關閉 JMS，下載並核對新版 `.flatpak`，再執行 `flatpak install --user ./新版套件.flatpak`。本機 bundle 不會隨 `flatpak update` 自動取得下一個 GitHub bundle；App 也不呼叫 pacman／PolicyKit 或下載 Arch 套件。

設定與快取依 XDG 規範保存於 `~/.var/app/com.jim608.jms/`；離線媒體存入使用者選擇並授權的目錄。不自動搬移原有 Arch／Portable 資料或登入資訊。卸載時不要加 `--delete-data`，即可保留沙箱資料；外部目錄的離線媒體需另外管理。Seerr 使用桌面 Secret Service，需可解鎖的金鑰圈，沒有明文憑證備援。

沙箱允許網路、顯示、音訊與 DRI 裝置；下載目錄可寫，其餘檔案透過選擇器 portal 授權。Discord 僅開放固定 IPC socket 與其 Flatpak IPC 目錄，播放狀態仍需在 JMS 內啟用。沒有整個家目錄、host filesystem 或完整 session/system D-Bus 存取。

Release 附完整 JMS 來源、Flatpak 原生依賴來源與安裝內容驗證。安裝包以同版 SHA256 核對，未提供發行者簽章。隔離桌面驗證不等於實體 GPU、喇叭、本人登入與長時間播放驗收。

## Linux pacman 與本機 yay 配方

適用 EndeavourOS／Arch x86_64。官方 `.pkg.tar.xz` 安裝套件名稱為 `jms`；可攜式版本仍使用系統 MPV、GTK 3、ALSA 與其餘套件相依。

提供配方的 Release 另附 `JMS-Linux-版本-jms-bin-aur.tar.gz`，內含 `PKGBUILD`、`.SRCINFO` 與使用說明。配方固定下載同一 Release 的 x86_64 安裝套件，核對 SHA256、App 版本、來源提交與 Build ID，再將原始程式檔案封裝為 `jms-bin`，不重新編譯或修改原生二進位。

從該 Release 下載並核對 `SHA256SUMS.txt` 後解開配方封存，先閱讀 `jms-bin/PKGBUILD`。yay 的本機配方操作需要 Git 工作目錄與本機追蹤分支；在解開封存後、包含 `jms-bin` 的目錄，以一般使用者執行以下步驟，不要重設既有 Git 倉庫。提交身分可換成自己的公開 noreply 身分：

```bash
git init --initial-branch=jms-local ./jms-bin
git -C ./jms-bin add -- PKGBUILD .SRCINFO README.zh-Hant.md
git -C ./jms-bin -c user.name=jim608 -c user.email=60721672+jim608@users.noreply.github.com commit -m "chore(package): 核對 JMS Linux 本機配方"
git -C ./jms-bin branch jms-local-source
git -C ./jms-bin branch --set-upstream-to=jms-local-source jms-local
yay -Bi ./jms-bin
```

[yay 官方文件](https://github.com/Jguer/yay#examples-of-custom-operations) 支援從本機目錄建置配方。兩個本機分支指向同一筆已核對的配方提交，不需要設定遠端或推送。未使用 yay 時，可改用：

```bash
cd jms-bin
makepkg --verifysource
makepkg -si
```

這是本機配方安裝方式，不表示已刊登 AUR；AUR 尚未刊登時，不能使用 `yay -S jms-bin`。使用本機配方的後續升級，需下載新版配方後再次執行。`PKGBUILD` 與 `.SRCINFO` 必須隨同產物版本及 SHA256 一起更新，不能使用 `SKIP` 代替完整性檢查。

`jms-bin` 與官方 `jms` 互斥，切換時須明確確認移除原套件。App 更新器下載官方 `jms` 套件，不是 AUR 更新器；AUR／本機配方安裝者應先選擇更新渠道，不能把自動檢查當成已同意切換套件。套件移除與升級不主動刪除使用者家目錄中的 JMS 設定。

正式安裝依循本機 pacman 簽章政策及系統授權；測試版未提供正式發行者簽章，不自動修改信任政策。完整相應來源、原生依賴材料及必要授權附於同一平台的 Release，GitHub 自動產生的 Source code.zip 不是完整 Flutter 來源。

## 來源與授權

唯一共用來源：[JMS-Android 的 jms 分支](https://github.com/jim608/JMS-Android/tree/jms)。每個平台的建置紀錄與 Release 記錄相同來源提交及各自 Build ID，產物雜湊分開保存。

保留 Fladder 原作者署名與 GPLv3 授權。各平台提供對應修改版來源、依賴鎖定、建置工具與適用的第三方授權材料；測試版同樣適用。

## 開發建置

在乾淨的共用來源提交上使用 `scripts/build_jms_windows.ps1 -SourceCommit <commit>` 或 `scripts/build_jms_linux.ps1 -SourceCommit <commit>`。Linux 使用隔離的 Docker 建置環境，不要求在 Windows 主機安裝 Linux 桌面，也不部署至正式伺服器。

## 已知限制

- 每個新版本仍須核對實際原生二進位、來源材料與授權；不得套用另一平台的材料結論。
- Linux 的登入、GPU 播放、ASS 特效及安裝後設定保留需要 EndeavourOS 實機驗證。
- Linux 的 Seerr 工作階段使用 Secret Service，需可解鎖的桌面金鑰圈；無法安全儲存時不使用明文替代。隔離環境的跨程序還原、服務重啟與清除驗證，不代表實體桌面的本人登入已驗收。
- Arch／Portable 使用系統 MPV；Flatpak 使用隨包 MPV。硬體解碼能力仍取決於實體裝置與驅動。
