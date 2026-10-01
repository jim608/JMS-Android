# JMS 匿名診斷回報

在「設定 → 關於」設定診斷接收網址，閱讀回報範圍並選擇「同意並啟用」。預設關閉；關閉後停止送出新回報並取消進行中的連線。網址與回報偏好只保存在目前裝置，未納入 JMS 的設定備份。

接收網址必須使用 HTTPS，路徑為 `/api/jms/diagnostics/v1`，不含帳密、查詢參數或片段識別。沒有合法接收網址時不會傳送資料。App 不會從 Jellyfin、Seerr 或帳號設定推導回報網址。

回報內容只有平台、JMS 版本、Build ID、可用的來源提交、固定錯誤類別及彙總畫面效能數值。錯誤類別為 `flutter_framework`、`unhandled_async` 或 `slow_frames`。畫面效能資料只有 `frameCount`、`slowFrameCount`、`worstFrameMs` 及 `totalDurationMs`。

不傳送錯誤全文、堆疊、日誌、帳號、媒體名稱、服務網址、密碼、Cookie、Token 或裝置識別碼。接收伺服器仍能看到連線 IP；是否保留 IP 由接收端政策決定。

每類最多每五分鐘傳送一次，每次 App 執行最多二十筆，不儲存待傳佇列、不重試失敗回報。網路逾時為三秒，重新導向不會跟隨，診斷故障不影響 App 的錯誤處理與操作。畫面幀資料於前景聚合，進入背景或停止診斷時清除未送出的樣本。

此功能涵蓋 Flutter framework 錯誤、未處理的 Dart 非同步錯誤與 Flutter 慢幀。它不等同於原生程序崩潰收集，也不量測 GPU、影片解碼器、CPU 或音訊中斷。完整本機錯誤日誌仍由原有錯誤日誌功能管理，不會隨匿名回報上傳。

發布建置可使用 `JMS_DIAGNOSTICS_ENDPOINT` 指定預設接收網址；Web 可在 runtime config 使用 `diagnosticsEndpoint`，支援固定同源路徑 `/api/jms/diagnostics/v1`。`JMS_SOURCE_COMMIT` 可記錄完整四十位來源提交。設定預設網址不會代替使用者同意。

編譯或注入至 Web 的網址可以被取得，不屬於秘密。若網址不得出現在公開產物中，應保持建置設定空白，由使用者在裝置設定。私人設定與敏感明細不得提交 Git 或加入來源封存。
