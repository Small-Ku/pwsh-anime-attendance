# Adding a New Platform

Use this guide when introducing a real supported provider.

## 1. Add the source file
- Create a new file in `src/` with a numeric prefix so merge order stays explicit.
- Keep private helpers above the platform entrypoint.
- Export only the public entrypoint with `##MOD_EXEC## Export-ModuleMember ...` when it must be visible from the merged module.

Example:

```powershell
src/013-myplatform.ps1
function Invoke-MyPlatformAttendance { ... }
```

## 2. Match the handler contract
The dispatcher in `src/991-sign.ps1` expects a platform handler shaped like this:

```powershell
function Invoke-MyPlatformAttendance {
	param($Profiie, $Config, $Embed, $IsReusing)
	# update $Embed
	return @{ NeedPing = $true | $false }
}
```

Expected behavior:
- Set `Embed.title` and, when useful, `Embed.description` so the account is identifiable in Discord.
- Give each embed a stable identifier for reuse matching. Prefer `footer.text`; a stable unique description is the fallback.
- Append result rows to `Embed.fields`.
- Add stable field keys when the same logical row should be updated across runs.
- Return `@{ NeedPing = $true }` for expired credentials, captcha/manual action, or failures that should trigger a Discord ping.
- Use `Out-Log` for operator-facing output and `Format-Text` when provider text needs decoding cleanup.
- Remember that the default embed starts in an error state. On success, clear the default error description and set the color to green (`'5635840'`).

## 3. Wire config and dispatch
- Add a sample profile to `sign.example.json` under `profiles[]`.
- Add provider settings under `platforms.<name>`.
- Add the new dispatch branch in `src/991-sign.ps1`.
- If the provider has required config, add validation near `Test-SkV2Config` or create a separate validator.

## 4. Reuse existing plumbing
- Prefer existing helpers such as `New-WebSession`, `Initialize-DiscordEmbed`, and `Send-DiscordNotification`.
- Keep the current embed field style unless the provider genuinely needs a different shape.
- Move logic into `000-common.ps1` only when at least two providers need the same helper.
- Do not copy the SK shared-core path unless the new provider actually uses the same auth and request-signing model.
- For dynamic pages, inspect scripts and network behavior for AJAX endpoints or embedded JSON before relying on HTML parsing alone.
- Prefer API-driven prechecks when possible. Calling the real claim/check-in endpoint is usually more reliable than inferring state from page markup.

## 5. Validate before commit
Run:

```powershell
./Merge-ModuleScripts.ps1
./sign.ps1
```

`./Merge-ModuleScripts.ps1` is the minimum validation gate. If the config contract changes, update both `README.md` and `README_ZH.md`.

## Common Pitfalls & Conventions

- **Default config merging**: Do not scatter inline fallback strings through the implementation. Define a local `$discordText` hashtable with English defaults near the top of the handler, merge in `$Config.discord_text`, and use that dictionary consistently.
- **Spelling of `$Profiie`**: Keep the exact parameter name `$Profiie`. The dispatcher and existing handlers use that spelling, so changing it creates avoidable mismatches.
- **Colon after variables in double quotes**: PowerShell parses `$variable: text` as a scope-qualified variable reference. Use `$($variable): text` instead so syntax validation passes.
- **Avoid raw Chinese literals in regexes/code**: Windows PowerShell 5.1 can corrupt non-BOM Chinese text under the active ANSI code page. Prefer provider-returned messages directly, and use Unicode escapes such as `\u89c2\u770b` only when literal matching is unavoidable.
- **Respect response charset handling**: Use `Format-Text` only when the response is decoded incorrectly because the server omitted `charset=utf-8`. If the response already declares UTF-8, forcing `Format-Text` will corrupt text into `?`.
