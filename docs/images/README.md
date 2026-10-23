# JMS 說明圖片

這組圖片用於 GitHub 首頁的產品介紹，與安裝／實機驗收證據分開。主要畫廊改用完整 JMS App 的直接截圖。

| 檔案 | 內容與來源 | 標示 |
|---|---|---|
| `jms-desktop-home.png`、`jms-desktop-details.png` | JMS `0.11.1-jms.44+46` 已封存 Web 完整 App，在瀏覽器以 1280 × 720 執行後直接擷取。 | 真實 App 介面；本機示範資料，不是 Windows 原生版或本人媒體庫驗收。 |
| `jms-mobile-home.png`、`jms-mobile-details.png` | 同一份完整 Web App，以 390 × 844 手機寬度執行後直接擷取。 | 真實響應式介面，不是手機硬體截圖或安裝／播放驗收。 |
| `discord-presence.png` | 使用者提供的 Discord JMS 播放卡片原始截圖，已明確同意公開作品名稱、封面與觀看進度。 | 真實 Discord 畫面，保留原始像素；單次畫面不代表所有作品封面皆已驗收。 |
| `jms-overview.svg` | JMS 品牌及功能總覽；字標沿用本專案 `icons/jms/mark.svg`，其餘為本專案繪製的向量說明。 | 功能示意，不是 App 截圖。 |
| `jms-how-it-works.svg` | Jellyfin、JMS 與選用 Seerr 的角色及功能關係。 | 功能示意，不是實際服務連線紀錄。 |
| `desktop-dark.png` | 以 JMS 真實 Flutter 主題與內建靜態字重產生的桌面深色合成預覽。 | 字型與排版預覽，不是完整 App 首頁。 |
| `mobile-light.png` | 同一預覽的手機淺色版。 | 字型與排版預覽，不是本人裝置／媒體庫截圖。 |

JMS App 截圖使用本機展示 API、示範帳號及原創幾何封面；沒有登入私人 Jellyfin、連線私人 Seerr 或使用本人媒體圖片。App 的主程式未修改，來源為 `.44` 已封存 Web runtime，App source `6b2f867e1395cd330ca64ad668767dde20b9ba11`。只將執行時服務設定導向本機展示 API；字型及 UI 仍由完整 App 實際繪製。介面語言為繁體中文。

所有截圖保留瀏覽器或使用者提供的原始輸出，沒有重繪 UI、拼接控制項或修改像素。舊 `desktop-dark.png`、`mobile-light.png` 仍是合成字型預覽，不再作為主要產品畫廊。文件圖片沿用本專案授權；使用者提供圖片僅用於經其核可的 JMS 介紹。JMS／Fladder 與第三方署名見主 [README](../../README.md)，字型授權見 [Noto Sans TC OFL](../../assets/fonts/notosanstc/OFL.txt)。
