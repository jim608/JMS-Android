# JMS 0.11.1-jms.13

## 調整
- 點片服務的重新驗證僅使用目前 Jellyfin 帳號；一般連線介面不再提供 Seerr 本機帳號登入。

## 修正
- 修正以 Jellyfin 帳密登入 JMS 後，點片服務未自動建立本人工作階段的問題。Jellyseerr 連線會先核對 Jellyfin 伺服器，再以本人帳號登入及確認身分。
- 修正 Android 接收、保存及傳送 Jellyseerr Session Cookie 的流程，支援伺服器更新 Cookie，並依來源、路徑、安全屬性及到期時間限制傳送。
- 修正沒有有效 Session 時的連線提示；未登入不再誤顯示為帳號權限不足。

## 更新注意事項
- 已登入 JMS、但沒有有效 Jellyseerr Session 的使用者，可能需要在原生介面輸入一次目前 Jellyfin 帳號密碼；既有 Jellyfin 登入與播放設定不受影響。
