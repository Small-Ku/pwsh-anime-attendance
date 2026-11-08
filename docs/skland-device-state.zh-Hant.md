# Skland 裝置狀態

這是 Skland profile-owned 裝置狀態的 technical contract。一般使用仍然只需要設定 token，不需要手動建立這些欄位。

## 設定格式

本機成功執行後，Skland profile 可能會自動出現以下受管理狀態：

```json
{
    "platform": "skland",
    "console_name": "skland-main",
    "token": "...",
    "device": {
        "id": "B...",
        "seed": "..."
    }
}
```

`device.id` 是快速路徑：存在時直接使用設定好的 dId，不呼叫數美裝置指紋服務。`device.seed` 是持久化 recovery material，可以重建相同的 synthetic fingerprint identity material，但不能在本機直接算出 dId；數美回傳的 dId 仍然是 authoritative result。

## 狀態轉換

| `device.id` | `device.seed` | 行為 |
|---|---|---|
| 有 | 有 | 直接使用設定好的 dId。 |
| 有 | 無 | 直接使用設定好的 dId；如果日後失效，便沒有 recovery material。 |
| 無 | 有 | 發出 warning，使用 seed 重建 fingerprint、向數美註冊，並使用本輪回傳的 dId 繼續執行。 |
| 無 | 無，本機執行 | 自動產生 seed、註冊裝置，並把 `id` 和 `seed` 寫回 `sign.json`。 |
| 無 | 無，GitHub Actions | 在建立 ephemeral device 前 fail；先在本機 provision 狀態。 |

狀態屬於各自的 profile。除非明確使用共用的 `device_ref`，不同 profile 會分別 cache 及 provision。

## 被拒絕 dId 的 recovery

當 Skland 明確拒絕已設定的 dId，而 profile 還有 seed 時，腳本會：

1. 使用 seed 重建 synthetic fingerprint identity。
2. 向數美註冊。
3. 使用服務回傳的 replacement dId。
4. 重新嘗試 authentication 一次。
5. 在設定來源可寫入時保存 replacement state。

只有 response 明確指出 device、dId 或 fingerprint 被拒絕時才會進行 recovery。一般 token、timestamp 或其他 auth error 仍然會視為失敗。

## 自動化 runner

只有 `device.seed` 而沒有 `device.id` 的 runner 可以完成本輪 recovery。runner 可能能修改暫存的 `sign.json`，但不能自動更新來源 `CHECK_SECRET`；請在本機執行一次並更新持久化設定，避免下次再次註冊。

如果 GitHub Actions 同時沒有 `device.id` 和 `device.seed`，腳本會拒絕建立新的 random device，因為該 identity 無法存活到下一輪執行。

請確保本機設定檔可寫入，第一次執行及 replacement dId 才能保存。
