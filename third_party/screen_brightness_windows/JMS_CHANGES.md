# Windows 亮度控制修正

- 基礎版本：screen_brightness_windows 2.1.0（pub.dev 發行套件）。保留原 MIT 授權與原始著作權聲明。
- 原鎖定套件 archive SHA-256：`d3518bf0f5d7a884cee2c14449ae0b36803802866de09f7ef74077874b6b2448`。
- 不在套件註冊時查詢實體螢幕，延至明確的亮度 API 呼叫才初始化。
- 未設定應用程式亮度時，視窗啟用、失焦、尺寸變更與關閉不再讀寫 DDC/MCCS 亮度。
- 未改過應用程式亮度時，reset 不再寫回螢幕。
- 保留使用者明確調整亮度後的前後景還原機制；不改影片解碼或 Android 實作。
- 這些修改隔離不必要的實體螢幕操作，不代表已證明所有黑屏的根因或完成實機驗收。

上游：https://pub.dev/packages/screen_brightness_windows/versions/2.1.0
