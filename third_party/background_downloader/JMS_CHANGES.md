# JMS Android 離線下載修正

以 `background_downloader` 9.3.0 的固定發布來源為基礎，保留原有 Dart、iOS 與下載核心實作。Android 的 `always` 模式在連線前啟動下載前景服務，未知檔案長度不再使該模式失效。

Android 13 以上拒絕通知權限時，仍向系統提供前景服務必要的通知；一般完成、暫停及錯誤通知仍遵守通知權限。這不會授予通知權限，也不會繞過 Android 的前景服務類型、啟動限制或資源限制。

暫停、取消、HTTP 範圍續傳、重試、大小與檔案校驗設定保持原有行為。實際裝置的背景下載、通知權限與省電限制仍須分別驗證。

上游文件中的合成權杖範例統一標示為 `fixture`，不更動 runtime 驗證與憑證處理。

- 固定來源：[pub.dev 9.3.0 封存](https://pub.dev/api/archives/background_downloader-9.3.0.tar.gz)
- 封存 SHA256：`a913b37cc47a656a225e9562b69576000d516f705482f392e2663500e6ff6032`
- 上游：[BBFlight background_downloader](https://github.com/781flyingdutchman/background_downloader)
- 保留上游 `LICENSE`，包含 BSD 3-Clause 與內含 localstore 的 MIT 授權。
- [Android 通知權限](https://developer.android.com/develop/ui/compose/notifications/notification-permission)：啟動前景服務不需 `POST_NOTIFICATIONS`，但仍須提供服務通知。
- [Android 前景服務類型](https://developer.android.com/develop/background-work/services/fgs/service-types#data-sync)：下載使用 `dataSync` 類型與對應 manifest 權限。

本目錄包含完整 runtime library、Android／iOS 平台來源與 Android 原生測試。上游範例 App、一般文件、代理操作指南，以及須另外解析開發依賴與生成 mock 的 Dart 開發測試不參與 App 編譯，因此不納入此修改副本；JMS 既有 App 測試與本次 Android 原生回歸測試仍保留。
