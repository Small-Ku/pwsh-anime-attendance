# pwsh-anime-attendance

> [English](README.md) | 繁體中文

使用 PowerShell 編寫的自動簽到工具，支持 HoYoLAB、Skport、Skland 等線上平台。

## 功能特性

- **多平台支持**：
    - **HoYoLAB**：支持《原神》、《崩壞：星穹鐵道》、《絕區零》等遊戲簽到。
    - **Skport**：支持《明日方舟：終末地》的簽到。
    - **Skland**：支持《明日方舟》與《明日方舟：終末地》的簽到。
- **Discord 整合通知**：
    - **訊息重用**：智能更新同一條 Discord 訊息，避免每天產生新的通知洗版。
    - **精簡模式**：可選擇顯示詳細獎勵資訊或精簡的一行摘要。
    - **錯誤標記**：當 Cookie 過期或需要手動輸入驗證碼時，自動 Tag 指定用戶或身份組。
- **高度自定義**：
    - 支持多帳號、多機器人配置。
    - 可針對不同平台設定不同的 User-Agent 及語言。
- **自動補簽**：針對 HoYoLAB 提供自動執行任務並補簽的功能。

## 簽到結果與警報

各遊戲、角色或任務的結果會先個別確認，再彙整為帳號狀態：

- **Success（綠色）：**所有適用項目均已確認簽到成功或當日已簽到。
- **PartialFailure（橙色）：**部分項目成功，但至少一項失敗。
- **Failure（紅色）：**沒有可確認成功的項目，或使用者驗證、角色綁定、API 回應等必要步驟失敗。

Discord 的顏色與提及通知由彙整結果決定，不會將查不到綁定角色、使用者資料錯誤或未確認的簽到當作成功。失敗時會清除重用訊息中過時的綠色欄位；恢復成功時亦會清除舊的錯誤欄位。即使沒有設定提及對象，仍會送出失敗訊息，而不會發出空白提及。
## 快速開始

### 1. 安裝環境
確保你的系統已安裝 **PowerShell Core (7+)** 或 Windows PowerShell 5.1 (通常為系統內建)。

### 2. 獲取專案
將本倉庫複製或下載到本地目錄。

### 3. 配置參數
1. 將 `sign.example.json` 修改或另存為 `sign.json`。
2. 根據需求填入憑證資訊：
   - **HoYoLAB**: 登入 [HoYoLAB 官網](https://www.hoyolab.com/)，打開瀏覽器開發者工具，獲取 Cookie 中的 `ltoken_v2`、`ltmid_v2` 與 `ltuid_v2`。
   - **Skport**: 參考下方 [如何獲取 Skport 憑證](#如何獲取-skport-憑證) 章節（`profiles[].cred`）。
   - **Skland**: 可先參考下方 [如何獲取 Skland Token](#如何獲取-skland-token) 章節，再填入 `profiles[].token`。
3. 配置 **Discord Webhook**:
   - 在 `display.discord.bots` 中填入你的 Webhook 網址（如不需要可留空）。
   - 若想啟用訊息更新功能，將 `reuse_msg` 設為 `true`。

#### 如何獲取 Skport 憑證
1. 安裝 **Violentmonkey** 擴充功能（[官網](https://violentmonkey.github.io/)）。
2. 前往 [腳本鏈接](https://github.com/cptmacp/blobs/raw/refs/heads/main/fetch_cred_user.js) 並安裝/匯入。
3. 打開 [終末地簽到頁面](https://game.skport.com/endfield/sign-in?header=0&hg_media=skport&hg_link_campaign=tools) 並稍等片刻。
4. 頁面會彈出包含 `cred` 的視窗，將其複製到 `sign.json` 即可。

#### 如何獲取 Skland Token
1. 登錄 [鹰角网络通行证](https://user.hypergryph.com/login) 後，打開 `https://web-api.hypergryph.com/account/info/hg`，記下 `content` 字段的憑據值。
2. 或者登錄 [森空島网页版](https://www.skland.com/) 後，打開 `https://web-api.skland.com/account/info/hg`，記下 `content` 字段的憑據值。
3. 在本專案中，將憑據填入 `profiles[].token`（`platform: "skland"` 對應的 profile）。

第一次本機執行時，腳本會自動為該 Skland profile provision 並保存裝置狀態，不需要手動設定 device ID 或 seed。

### 4. 運行腳本
打開 PowerShell 並切換到專案目錄，執行：
```powershell
./sign.ps1
```

## 配置細項說明

### Discord 機器人配置 (`bots`)
- `discord_name`: 機器人顯示名稱。
- `reuse_msg`:
    - `false`: 每次發送新訊息。
    - `true`: 首次發送後自動記錄 ID，並在之後執行時更新該訊息。
    - `[訊息ID]`: 手動指定要更新的訊息 ID。
- `minimal`: 是否開啟精簡顯示（僅顯示獎勵簡稱）。
- `profiles`: 列表形式，可填入帳號索引 (以 `0` 開始) 或特定帳號的 `console_name`。

### 帳號配置 (`profiles`)
- `platform`: `hoyolab`、`skport`、`skland` 或 `fuhouse`。
- HoYoLAB 憑證：`ltoken`/`ltoken_v2` 與相關 Cookie 欄位。
- Skport 憑證：必填 `cred`。
- Skland 憑證：必填 `token`。
- Skland 裝置狀態會在第一次成功執行後按 profile 自動管理。
- Fuhouse 憑證：必填 `cookies`（特別是 `PHPSESSID` cookie 欄位）。
- `console_name`: 用於日誌顯示及機器人匹配的自定義名稱。

## 自動化運行

可以使用內置的 `sign_schedule.ps1` 自動註冊 Windows **工作排程器 (Task Scheduler)**：

1. 以 **管理員權限** 開啟 PowerShell。
2. 執行：`./sign_schedule.ps1`。
3. 該腳本會自動建立名為 `AnimeAttendance` 的定時任務，設定在 **每日 00:00 (UTC+8)** 以及 **系統啟動時** 自動執行。

## 免責聲明

本專案僅供學習與交流使用，請勿用於任何商業用途。使用本工具引發的任何帳號問題（如封號、異常等）由使用者自行承擔。

## 主控台輸出與憑證保護

建議使用 `"display": { "console": { "enabled": true, "redact": "always" } }`，顯示簽到進度、各帳號結果與錯誤。無論本機還是 CI，日誌預設都會遮罩已知敏感資料，包括設定檔內的 Token、Cookie、Discord webhook、裝置 ID 與 Seed，以及 API 回應中的敏感欄位；DEBUG 日誌亦不例外。

`enabled: false` 只用來關閉主控台訊息，無須再為保護憑證而關閉所有日誌。舊版 `"console": false` 與 `"console": "pause"` 繼續支援；暫停互動會正規化為獨立的 `runtime.pause`。若回應中出現未識別的敏感欄位，不應將未審核的完整輸出貼到公開場所。
## Skport 終末地憑證恢復

Skport 網頁使用的 `cred` 可能獨立於刷新 API 回傳的簽名 Token 失效。刷新 API 回報成功，不代表隨後的使用者與角色查詢一定通過。現在收到認證拒絕時只會刷新並重試一次；持續失敗會明確回報認證錯誤，不再誤稱「沒有綁定角色」。簽到前亦會先查詢 `hasToday`，避免重複 POST。

如 `profiles[].cred` 已過期，可將你自己的 Skport 網頁 HAR 儲存到 Windows 電腦（支援原始 .har 或 .har.tar.zst），於專案目錄執行：

```powershell
pwsh -File .\tools\Import-SkportCredentialFromHar.ps1 -HarArchivePath 'C:\path\to\game.skport.com_Archive.har' -ConfigPath .\sign.json
```

匯入工具只會從確認成功的 HTTPS 終末地簽到回應選取憑證；先使用不會簽到的 API 請求驗證帳號與角色，再只更新本機 `cred` 欄位。工具不會印出憑證，並會清理臨時解壓檔案。**不要將原始 HAR 提交到 Git、公開張貼或放入 PR**，因為其中含有工作階段憑證。