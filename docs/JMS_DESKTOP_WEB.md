# JMS 桌面版與網頁版

Windows 與 Web 使用 Android 相同的 Flutter 原始碼與鎖定依賴；本機驗證產物不等於正式發布版本。

## Windows x64

需要 Flutter 3.35.7、Visual Studio 2022 C++ 桌面工作負載，以及 Inno Setup 6。

```powershell
rtk proxy powershell -NoProfile -File scripts/build_jms_windows.ps1 -Version 0.11.1-jms.15-local
```

使用 `-PortableOnly` 可只產出 ZIP。產物位於 `artifacts/windows/<version>/`；解壓 ZIP 後執行 `jms.exe`。安裝版預設使用目前使用者的應用程式目錄，無需提高為管理員權限。兩者都包含建置資訊與 SHA-256 manifest；尚未提供 Windows 程式碼簽章，可能出現 SmartScreen 提示。

Windows 原生 DLL 的授權與相應來源需要獨立核對，Android 已移除 MDK 並不代表 Windows 也已移除。未完成此項核對前不得公開散布 Windows bundle。本人 Session 重啟持久化、實際播放、字幕及環境光仍需 Windows 驗證。

## Web 容器

新流程使用獨立 `Dockerfile.web`，不直接修改既有正式容器。建置階段核對 Flutter revision 並使用 lockfile；runtime 使用非 root nginx、8080 與健康檢查。

```powershell
rtk proxy docker build -f Dockerfile.web --build-arg JMS_VERSION=<version> --build-arg JMS_BUILD_ID=<build-id> --build-arg JMS_SOURCE_COMMIT=<commit> -t jms-web:<version> .
```

`compose.jms-web.yml` 使用版本化映像，預設只綁定本機 18081，不搶占舊站連接埠。部署前明確提供 `JMS_VERSION`；`JELLYFIN_BASE_URL` 與 `SEERR_BASE_URL` 留白時由使用者輸入服務來源，不能把私人預設來源寫入公開映像。

執行期設定不是秘密儲存：瀏覽器可讀取 `assets/config/config.json`。不得放密碼、Cookie、Token 或管理員 API Key。設定網址不得帶帳密、query 或 fragment。

`JMS_WEBPATH` 支援 `/` 或 `/jms/` 等前綴；設定與入口 JavaScript 不快取，其他靜態資料使用短快取。只提供 SPA 路由，不代理正式 Jellyfin／Seerr 憑證。跨來源 Cookie、CORS 與服務權限仍須部署實測，不以首頁成功取代登入／播放驗收。

### 容器契約檢查

```powershell
$env:JMS_TEST_ORIGIN = 'http://127.0.0.1:18081'
$env:JMS_TEST_PREFIX = '/'
rtk proxy .\.jms-tools\python\Scripts\python.exe scripts/test_jms_web_container.py
```

測試涵蓋健康檢查、config JSON／快取、SPA／base href 及 bootstrap 快取。需先啟動明確指定的本機測試容器；一般單元測試不連線正式服務。

## 發布與遷移邊界

- Android、Desktop、Web 發布渠道分別為 `jim608/JMS-Android`、`jim608/JMS-Desktop`、`jim608/JMS-Web`；共用來源不能分別修改三份。
- 正式發布需乾淨 `jms` commit、隱私／授權檢查、相應來源、實際產物雜湊與該平台回歸，不把 dirty 本機產物當可發布來源。
- 正式 Web 遷移先重新核對備份、舊映像與代理設定，再另建 canary；測試通過才切路由，保留原容器及立即回復方法。
- 尚未新增 Desktop 自動安裝更新、遙測後端或 Laya worker；不顯示其已上線。
