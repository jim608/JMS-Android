# JMS 網站入口設定

`/jms-config.json` 提供部署時的服務來源設定。使用 [JSON 範本](../config/jms-config.example.json) 與 [nginx 片段](../config/jms-entry-config.nginx.conf)，私人設定保存在主機，唯讀掛載至既有 JMS 容器。

## 設定內容與可見性

設定只包含 `baseUrl`、`seerrBaseUrl` 與 `diagnosticsEndpoint`。`baseUrl` 必填，為 Jellyfin 的 HTTPS 基底網址；`seerrBaseUrl` 為 Seerr 的 HTTPS 基底網址，可省略或為 `null`。服務網址不得包含帳密、查詢參數或 fragment。`diagnosticsEndpoint` 可省略或為 `null`，也可填入形如 `https://example.invalid/api/jms/diagnostics/v1` 的 HTTPS 位址；確認既有接收端可用後才填入。此欄位不代表使用者已同意傳送診斷。

## App 使用方式

在原本的伺服器欄位輸入網站入口，例如 `media.example.invalid/jms/`。App 會補上 HTTPS，讀取該路徑下的 `jms-config.json`，確認 Jellyfin 服務後沿用原本登入流程。使用者不必輸入 JSON 路徑；直接填 Jellyfin 網址仍可使用，HTTP 區網服務只走既有直接連線探測。

設定保存在裝置並按服務與帳號隔離；入口短暫故障時可沿用上次有效設定。登入後可在「設定 → 服務整合 → 網站入口設定」查看來源並手動重新讀取，不會在每次播放時重新請求。明確設定的手動值保留優先權。Jellyfin 或 Seerr 來源變更須確認並重新登入／連動，舊憑證不會移轉到新來源；診斷接收端變更須重新取得上傳同意。

App 不內建部署者的私人服務網址；使用者設定後，裝置仍會取得並保存這些網址。入口快取與診斷設定不包含在設定備份或匯出中。

主機上的真正 JSON 不得加入 Git、App 建置輸入或來源封存，也不得包含密碼、Cookie、Token、API Key 或私鑰。若檔案位於工作樹內，先以 `git check-ignore` 確認它已被忽略；也可放在工作樹之外的專用主機目錄。

「不進 Git」不代表網址對網站使用者保密：能讀取這個 HTTP 入口的人可取得其服務位址。沿用現有反向代理的存取限制，避免把來源網址寫入公開日誌或檢查輸出。

## 主機檔案權限與唯讀掛載

以既有容器的 `id` 確認 nginx 執行者 UID／GID。JSON 使用 `0400`，所有者須能被該執行者讀取；需要群組讀取時使用 `0440` 並配置相符 GID。上層目錄也須允許該身分通行，不能只修改檔案權限。

以下環境變數由部署者在主機設定，不提交實值：

- `JMS_EXISTING_IMAGE`：目前使用的精確 JMS Web 映像名稱或 digest。
- `JMS_PRIVATE_CONFIG_FILE`：私人 JSON 的絕對路徑。
- `JMS_ENTRY_CONFIG_TEMPLATE`：上述 nginx 片段的主機絕對路徑。

將私人 JSON 掛載為 `/run/jms-private/jms-config.json`，nginx 片段掛載為 `/run/jms-entry-config.conf`，兩者都使用唯讀 bind mount。對容器執行者不可讀的 JSON 會導致存取失敗，不能改成所有人可讀來繞過權限問題。

## 沿用既有 nginx 產生流程

新版 `Dockerfile.web` 映像已內建入口設定路由。將私人 JSON 唯讀掛載到 `/run/jms-private/jms-config.json` 即可；路由會配合 `JMS_WEBPATH`，不存在時回傳 JSON 404，首頁與原本的 Web 設定維持既有流程。設定不合法或掛載不可讀時，容器啟動會拒絕使用該設定。

以下啟動包裝方式僅供尚未包含入口路由的舊映像使用；新版不需重複加入 nginx 片段。

此範本適用於 `Dockerfile.web` 使用的 `web/jms-entrypoint.sh`，容器內路徑為 `/docker-entrypoint.sh`。它會依環境產生 `/tmp/jms.conf`；把片段直接放到 `conf.d/` 不會自動載入，也不要新增第二個同埠的 server。

在既有 Compose 設定中，將下列欄位合併到 JMS 服務。保留原本的環境變數、連接埠、網路與資料掛載；服務名稱以實際設定為準。這個啟動命令每次從原入口程式產生暫存副本，只加入一個 include；原映像、入口程式及完整 server 設定不必另存一份。

```yaml
services:
  jms:
    image: ${JMS_EXISTING_IMAGE}
    entrypoint: ["/bin/sh", "-ec"]
    command:
      - |
        awk '
          BEGIN { matches = 0 }
          $$0 == "    include /tmp/jms-diagnostics.conf;" {
            print
            print "    include /run/jms-entry-config.conf;"
            matches++
            next
          }
          { print }
          END { if (matches != 1) exit 42 }
        ' /docker-entrypoint.sh > /tmp/jms-entry-config-start.sh
        exec /bin/sh /tmp/jms-entry-config-start.sh
    volumes:
      - type: bind
        source: ${JMS_PRIVATE_CONFIG_FILE}
        target: /run/jms-private/jms-config.json
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: ${JMS_ENTRY_CONFIG_TEMPLATE}
        target: /run/jms-entry-config.conf
        read_only: true
        bind:
          create_host_path: false
```

`$$0` 是 Compose 的 dollar escaping，傳給 awk 後為 `$0`。若既有映像的 include 標記不再恰好出現一次，啟動會停止；應先重新核對入口，不能移除這項檢查。

原入口仍產生 `assets/config/config.json`、設定首頁 base href、處理 SPA 路由與診斷代理，再執行 `nginx -t`。私人入口 JSON 不會自行覆寫原本的 `BASE_URL`／`SEERR_BASE_URL` 等環境設定，部署者須依實際用途保持兩者一致。

## 子路徑與錯誤行為

根目錄部署使用範本中的 `/jms-config.json`。當既有 `JMS_WEBPATH=/jms/` 時，首頁仍在 `/jms/`，原設定仍在 `/jms/assets/config/config.json`，App 請求的入口則是 `/jms/jms-config.json`，例如 `https://example.invalid/jms/jms-config.json`。

子路徑部署時，在主機建立片段的部署副本，把唯一的 exact location 改成與 App 相同的入口；以下 `JMS_PRIVATE_NGINX_SNIPPET` 指向部署者自行設定的主機檔案：

```sh
sed 's|^location = /jms-config.json {$|location = /jms/jms-config.json {|' \
  config/jms-entry-config.nginx.conf > "$JMS_PRIVATE_NGINX_SNIPPET"
export JMS_ENTRY_CONFIG_TEMPLATE="$JMS_PRIVATE_NGINX_SNIPPET"
```

其他子路徑依相同方式替換完整 location 路徑，並與 `JMS_WEBPATH` 一致；JSON 實檔及唯讀掛載位置不變。不需要額外建立 server 或另外維護整份 nginx 設定。

片段使用 exact location，回應為 `application/json`、`Cache-Control: no-store` 及 `X-Content-Type-Options: nosniff`。缺少檔案時回傳 HTTP 404 與固定 JSON 錯誤，不會進入首頁的 SPA fallback。路徑不符的請求仍依既有網站路由處理，讀取端須檢查 HTTP 狀態、Content-Type 與 JSON 結構。

## 部署前與更新檢查

先在隔離環境使用合成 JSON 核對，再依既有備份與回復流程處理正式部署。這份範本不會自動建立容器或重載正式服務。

將 curl 的 body 與 header 留在本機暫存檔；以下網址是根目錄部署的合成占位值，子路徑範例改用 `https://example.invalid/jms/jms-config.json`。執行時換成部署者的入口，不公開真正設定內容：

```sh
JMS_VERIFY_DIR=$(mktemp -d)
curl --silent --show-error --max-time 10 \
  --dump-header "$JMS_VERIFY_DIR/headers" \
  --output "$JMS_VERIFY_DIR/body.json" \
  --write-out '%{http_code}\n' \
  https://example.invalid/jms-config.json
```

確認狀態為 200，header 含上述 JSON 與不快取設定。使用 jq 只輸出結構檢查結果：

```sh
jq -e '
  def service_url:
    type == "string" and test("^https://[^[:space:]]+$") and
    (test("@|[?#]") | not);
  type == "object" and
  ((keys - ["baseUrl", "diagnosticsEndpoint", "seerrBaseUrl"]) | length) == 0 and
  (.baseUrl | service_url) and
  (.seerrBaseUrl == null or (.seerrBaseUrl | service_url)) and
  (.diagnosticsEndpoint == null or
   (.diagnosticsEndpoint | type == "string" and
    test("^https://[A-Za-z0-9.-]+(:[0-9]+)?/api/jms/diagnostics/v1$")))
' "$JMS_VERIFY_DIR/body.json"
```

在隔離環境移除掛載內的合成 JSON 後，確認同一路由為 404、body 為 `configuration_not_found`，不含首頁 HTML。分別以根路徑與 `/jms/` 設定確認首頁仍為 HTML，原 `assets/config/config.json` 仍可讀，且 JSON 入口沒有被 SPA fallback 吞掉。

更新主機 JSON 前先檢查結構與權限。若以 atomic rename 替換唯讀 bind-mounted 檔案，原容器仍可能綁定舊 inode；使用既有部署設定手動重新建立容器，使它重新掛載新檔案。只執行 `nginx -s reload` 不能保證更新這種檔案掛載。更新 nginx 片段亦採相同方式，啟動時會再執行 `nginx -t`。最後重新核對 HTTP 入口並重新載入網站，保留可回復的前一份私人設定。

下列命令由部署者在通過隔離檢查與備份後手動執行；`JMS_COMPOSE_FILE` 指向已合併上述欄位的既有 Compose 設定，服務名稱依實際設定調整：

```sh
docker compose -f "$JMS_COMPOSE_FILE" up -d --no-deps --force-recreate jms
docker compose -f "$JMS_COMPOSE_FILE" exec jms nginx -t
```

## 驗證範圍

部署驗收須包含 JSON 結構、nginx 設定載入、HTTP 狀態與內容、錯誤時不進入 SPA fallback，以及首頁和既有 Web 設定正常使用。App 自動化測試或 APK 建置不能代替網站與手機的實際整合驗證。
