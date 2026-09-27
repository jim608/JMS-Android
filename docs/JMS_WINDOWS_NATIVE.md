# Windows 原生依賴分發材料

## MDK 排除

Windows 不再註冊 fvp，僅提供 MPV。舊 MDK 偏好保留，但執行時改用 MPV。
Android 仍保留 MPV 與 Native；這不是新增 Windows Native 播放器。
打包會拒絕 MDK、fvp、MDK FFmpeg 與 libass 獨立 DLL，避免增量建置留下的檔案混入。

## MPV 的實際來源

- media_kit_libs_windows_video 1.0.11，鎖定 media-kit revision `cb56b5a6149f1e51086eba473c7e48041c54ab12`。
- Windows 二進位取自 [DonutWare 20260531 release](https://github.com/DonutWare/mpv-winbuild-cmake/releases/tag/20260531)，檔案 `mpv-dev-x86_64-20260531-git-13a3e3a.7z`。
- 實際 libmpv 回報 MPV `v0.41.0-697-g13a3e3ad0`、FFmpeg `N-124693-gfd9e4fa08`。
- 已取得 MPV `13a3e3ad0e7d21c0db7c85aab3c8f63b47f784d4` 與 FFmpeg `fd9e4fa0813d65bdc04b98043437c3d2b2380dde` 官方來源封存。
- 建置 recipe tag 對應 `5efd298cb51513c2410e4e9029b5e56b83c2aaac`；已保存同版腳本與補丁。

封存 SHA-256：

| 材料 | SHA-256 |
|---|---|
| MPV source | `9a4d356f4c476cc8f26a9d989ea7d1e680157f74a2dae5473f9e9832e809cc97` |
| FFmpeg source | `2c201db7d4c5586131b7621c200c821b4781688b3c1cdf934a75c092f40ce859` |
| Windows recipe | `4f0418959e38abc53af611af90e021d873247dd061995b8af62a7d836dc9d8ac` |

## 尚缺的對應材料

該 recipe 的 libass、FFmpeg、MPV ExternalProject 使用 Git repository，未固定 GIT_TAG。
工作流程建置前執行 update，且使用浮動工具鏈映像；不能把今天的分支內容當成既有 DLL 的對應來源。
Release 未提供完整依賴來源包；可查的 20260531 workflow run `26713208608` 未留下可下載 artifact。

仍需該二進位的相依元件版本清單、適用修改與完整相應來源及 notices；尤其是靜態鏈入的依賴。
不能沿用 Android 的原生依賴稽核取代 Windows 材料。
若無法向二進位提供者取得，替代方案是以完整鎖定來源重新建置 Windows libmpv，另行驗證 ABI、解碼與字幕功能。
目前取得兩個主要元件來源及 recipe，不等於所有分發要求已齊備。

## 本機驗證界線

`scripts/check_jms_windows_mpv.py` 使用實際 libmpv 載入合法 H.264／內封 ASS 素材，確認版本與選中軌道。
此無視窗測試不能證明 GPU 輸出、ASS 動畫視覺結果或實體螢幕閃黑已解決。
