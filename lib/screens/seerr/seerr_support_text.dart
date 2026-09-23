import 'package:flutter/material.dart';
import 'package:fladder/seerr/seerr_connection.dart';

String seerrText(BuildContext context, String english, String chinese) =>
    Localizations.localeOf(context).languageCode == 'zh' ? chinese : english;

String seerrError(BuildContext context, Object error) {
  final code = error is SeerrFailure ? error.code : 'network_error';
  final messages = <String, (String, String)>{
    'request_rejected_unknown': (
      'Request denied; cause not yet confirmed. Copy the connection diagnostic.',
      '請求被拒絕，原因待確認。請複製連線診斷。'
    ),
    'unexpected_html': (
      'The API returned a non-JSON page. Check the connection diagnostic.',
      'API 回傳非 JSON 頁面，請檢查連線診斷。'
    ),
    'access_challenge': (
      'An access challenge blocked the API. Password retry will not help.',
      '存取驗證阻擋 API，重試密碼無法解決。'
    ),
    'proxy_challenge': (
      'An access challenge blocked the API. Password retry will not help.',
      '存取驗證阻擋 API，重試密碼無法解決。'
    ),
    'edge_dns_error': (
      'Cloudflare Error 1000 blocked the API before Seerr login. Check this domain\'s DNS routing.',
      'Cloudflare Error 1000 在 Seerr 登入前阻擋 API，請檢查此網域的 DNS 路由。'
    ),
    'edge_rejected_unknown': (
      'The edge service rejected the API request before Seerr login.',
      '邊緣服務在 Seerr 登入前拒絕 API 請求。'
    ),
    'login_policy_denied': (
      'Seerr rejected this login under its account policy.',
      'Seerr 帳號政策拒絕此次登入。'
    ),
    'connection_timeout': (
      'Connection timed out. Retry when the service is reachable.',
      '連線逾時，服務恢復後請重試。'
    ),
    'dns_error': ('The service hostname could not be resolved.', '無法解析服務主機名稱。'),
    'tls_error': (
      'Secure connection failed. Check the certificate and service URL.',
      '安全連線失敗，請檢查憑證與服務網址。'
    ),
    'service_access_blocked': (
      'Service/proxy access was refused before account verification. No password retry.',
      '服務或反向代理在帳號驗證前拒絕連線；不會重試密碼。'
    ),
    'binding_unverified': (
      'Cannot securely verify the advertised Jellyfin server.',
      '無法安全核對 Seerr 公告的 Jellyfin 伺服器。'
    ),
    'identity_mismatch': (
      'Identity mismatch. No session was adopted.',
      '身分或伺服器不相符，未採用此工作階段。'
    ),
    'binding_required': (
      'Confirm the service binding first.',
      '請先確認此 Jellyfin 與點片服務的來源綁定。'
    ),
    'quickconnect_unavailable': (
      'Quick Connect is unavailable. Verify your Jellyfin account once.',
      '快速連線不可用，請以 Jellyfin 帳號驗證一次。'
    ),
    'quickconnect_fallback': (
      'Quick Connect is unavailable; switching to Jellyfin account verification.',
      '快速連線不可用，正在改用 Jellyfin 帳號驗證。'
    ),
    'needs_auth': (
      'One-time verification needed; library login is preserved.',
      '需要一次重新驗證；媒體庫登入仍保留。'
    ),
    'session_missing': (
      'No request service session is available. Verify your Jellyfin account once.',
      '尚無點片服務工作階段，請驗證一次 Jellyfin 帳號。'
    ),
    'authentication_failed': (
      'Jellyfin account verification failed. Check your password and retry.',
      'Jellyfin 帳號驗證失敗，請確認密碼後重試。'
    ),
    'link_unsupported': (
      'Server is not initialized for supported Jellyfin login.',
      '服務尚未完成可支援的 Jellyfin 登入設定。'
    ),
    'service_unavailable': (
      'Request service or secure storage unavailable; playback is unaffected.',
      '點片服務或安全儲存無法使用；不影響播放。'
    ),
    'connecting': ('Connecting…', '正在連線…'),
    'connected': ('Identity verified.', '已核對本人身分。'),
    'not_configured': (
      'Set up Jellyseerr / Seerr first.',
      '請先設定 Jellyseerr／Seerr。'
    ),
    'invalid_address': (
      'Enter a valid service URL without credentials or query.',
      '請輸入有效服務網址，不含帳密或查詢參數。'
    ),
    'session_expired': (
      'Seerr session expired. Sign in again; Jellyfin is unaffected.',
      'Seerr 工作階段已失效，請重新登入；不影響 Jellyfin 登入。'
    ),
    'permission_denied': ('This account lacks permission.', '此帳號沒有操作權限。'),
    'unknown': (
      'Connection failed for an unknown reason. Copy the connection diagnostic.',
      '連線失敗，原因尚未確認。請複製連線診斷。'
    ),
    'media_not_scanned': (
      'No verified Seerr media record. Save a draft or refresh after a scan.',
      '找不到已核對的 Seerr 媒體紀錄。可保留草稿，待服務掃描後重新整理。'
    ),
    'invalid_report': (
      'Check the report. Do not include URLs, credentials or file paths (maximum 2000 characters).',
      '請檢查回報內容；不可包含網址、憑證或檔案路徑（最多 2000 字）。'
    ),
    'timeout_check_history': (
      'Submission result is uncertain. Check My records before retrying; no automatic resubmission.',
      '送出結果未確認。請先查看「我的紀錄」，不會自動重送；請勿連續重試。'
    ),
    'account_changed': (
      'Account or service changed. Close and reopen this page.',
      '帳號或服務已切換，請關閉並重新開啟此頁。'
    ),
    'incompatible_filter': (
      'Server ignored the account filter. No mixed-account records are shown.',
      '服務未正確套用帳號篩選，已停止顯示混合紀錄。'
    ),
    'unsupported_or_missing': (
      'This API or record is unavailable on this server.',
      '此服務尚未支援該 API，或紀錄不存在。'
    ),
    'quota_or_rate_limit': (
      'Quota or rate limit reached. Check the server and try later.',
      '配額不足或請求過於頻繁，請稍後再試。'
    ),
    'invalid_or_quota': (
      'Server rejected the request. Check selections, quota and permissions.',
      '服務拒絕申請，請檢查選季、配額與權限。'
    ),
    'already_exists': (
      'This request already exists. Refresh My records.',
      '申請已存在，請重新整理「我的紀錄」。'
    ),
    'already_sending': ('Submission in progress.', '正在送出，請勿重複操作。'),
    'redirect_rejected': (
      'Server redirected the request. Verify the exact service URL.',
      '服務要求重新導向；為保護憑證，請核對完整服務網址。'
    ),
    'select_seasons': ('Select at least one season.', '請至少選擇一季。'),
    'invalid_response': (
      'Server returned an incompatible response.',
      '服務回傳格式不相容。'
    ),
  };
  final message = messages[code] ??
      ('Connection failed. Check the service and retry.', '連線失敗，請檢查服務後再試。');
  return seerrText(context, message.$1, message.$2);
}

String seerrIssueStatus(BuildContext context, int status) => switch (status) {
      1 => seerrText(context, 'Open', '未解決'),
      2 => seerrText(context, 'Resolved', '已解決'),
      _ => seerrText(context, 'Unknown status', '未知狀態'),
    };

String seerrIssueCategory(BuildContext context, int type) => switch (type) {
      1 => seerrText(context, 'Video', '影片'),
      2 => seerrText(context, 'Audio', '音訊'),
      3 => seerrText(context, 'Subtitles', '字幕'),
      _ => seerrText(context, 'Other', '其他'),
    };
