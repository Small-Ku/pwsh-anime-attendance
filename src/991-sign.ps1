function Invoke-AnimeAttendance {
	<#
	.SYNOPSIS
		Run anime attendance check-in and notification pipeline.

	.DESCRIPTION
		Load configuration, execute platform-specific attendance handlers for each profile,
		and dispatch grouped Discord notifications by bot config.
	#>
	param(
		[string]$ConfigPath = ".\sign.json"
	)

	function Test-SkV2Config {
		param($Profile, $PlatformConfig, [string]$PlatformName)
		$errors = @()
		if (-not $Profile) { $errors += "Missing profile"; return $errors }
		if (-not $PlatformConfig) { $errors += "Missing platforms.$PlatformName config"; return $errors }
		if (-not $PlatformConfig.lang) { $errors += "platforms.$PlatformName.lang is required" }
		if (-not $PlatformConfig.user_agent) { $errors += "platforms.$PlatformName.user_agent is required" }
		if (-not $PlatformConfig.games -or $PlatformConfig.games.Count -eq 0) { $errors += "platforms.$PlatformName.games must be a non-empty array" }
		if ($PlatformName -eq 'skland' -and $PlatformConfig.device) {
			$errors += 'platforms.skland.device is not supported; device state is managed per profiles[]'
		}
		foreach ($game in @($PlatformConfig.games)) {
			foreach ($key in @('name', 'app_code', 'api_base', 'origin_url', 'referer_url', 'platform', 'vName')) {
				if (-not $game.$key) { $errors += "platforms.$PlatformName.games[].$key is required" }
			}
		}
		if ($PlatformName -eq 'skport' -and -not $Profile.cred) { $errors += "profiles[].cred is required for skport" }
		if ($PlatformName -eq 'skland' -and -not $Profile.token) { $errors += "profiles[].token is required for skland" }
		return $errors
	}

	function Test-DiscordBotProfileMatch {
		param(
			$BotConfig,
			$Profile,
			[int]$ProfileIndex
		)

		foreach ($profile_ref in $BotConfig.profiles) {
			if ($profile_ref -is [int] -or $profile_ref -is [long]) {
				if ($profile_ref -eq $ProfileIndex) { return $true }
			}
			elseif ($profile_ref -eq $Profile.console_name) {
				return $true
			}
		}
		return $false
	}

	$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction 'Stop').Path
	$script:AnimeAttendanceConfigPath = $resolvedConfigPath
	$script:conf = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding 'UTF8' | ConvertFrom-Json
	Normalize-AnimeAttendanceConfig -Config $script:conf | Out-Null
	Register-LogSecretsFromConfig -Config $script:conf
	$global:debugging = $env:debug -eq 'pwsh-anime-attendance'

	foreach ($bot in $conf.display.discord.bots) {
		if ($bot.webhook_url -and $bot.reuse_msg -match '^(\d{18,})(len\d+)?$') {
			$dc_reuse_id = $Matches.1
			try {
				$ret = Invoke-RestMethod -Method 'Get' -Uri "$($bot.webhook_url)/messages/$dc_reuse_id" -ContentType 'application/json;charset=UTF-8'
				if (-not $bot.overwrite -and $ret.embeds.Length -ne $bot.profiles.Length) {
					Out-Log -Level 'WARN' -Message "Config has been changed (number of profiles for $($bot.discord_name)). Will not re-use the previous message."
					$bot.reuse_msg = "true"
				}
			}
			catch {
				Out-Log -Level 'WARN' -Message "Failed to fetch previous message for $($bot.discord_name). Resetting reuse."
				$bot.reuse_msg = "true"
			}
		}
	}

	$bot_results = @{}
	foreach ($bot in $conf.display.discord.bots) {
		$bot_results[$bot.discord_name] = @{
			BotConfig   = $bot
			Embeds      = @()
			AnyNeedPing = $false
		}
	}

	for ($profile_idx = 0; $profile_idx -lt $conf.profiles.Length; $profile_idx++) {
		$profiie = $conf.profiles[$profile_idx]
		$platform = $profiie.platform
		$p_conf = $conf.platforms.$platform
		$embed = Initialize-DiscordEmbed
		$preflightError = $null
		if ($platform -in @('skport', 'skland')) {
			$v2Errors = Test-SkV2Config -Profile $profiie -PlatformConfig $p_conf -PlatformName $platform
			if ($v2Errors.Count -gt 0) {
				$msg = ($v2Errors -join '; ')
				Out-Log -Level 'ERROR' -Message "Invalid SK v2 config for profile index $($profile_idx): $msg"
				$embed.title = 'Invalid SK v2 config'
				$embed.description = "Profile index: $profile_idx"
				$embed.fields += @{ name = $platform; value = $msg; inline = $false }
				$preflightError = New-AttendanceProfileFailure -Platform $platform -Reason 'InvalidConfiguration' -Message $msg
			}
		}

		$is_reusing = $false
		foreach ($bot_name in $bot_results.Keys) {
			$bot_config = $bot_results[$bot_name].BotConfig
			if (Test-DiscordBotProfileMatch -BotConfig $bot_config -Profile $profiie -ProfileIndex $profile_idx) {
				$reuse_id = $bot_config.reuse_msg
				if ($reuse_id -and $reuse_id -match '^\d{18,}$' -and -not $bot_config.overwrite) {
					$is_reusing = $true
				}
			}
		}

		$result = $null
		try {
			if ($null -ne $preflightError) {
				$result = $preflightError
			}
			else {
				$result = switch ($platform) {
					'hoyolab' { Invoke-HoyolabCheckin -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
					'fuhouse' { Invoke-FuhouseAttendance -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
					'skport' { Invoke-SkportAttendance -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
					'skland' { Invoke-SklandAttendance -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
					default { New-AttendanceProfileFailure -Platform 'unknown' -Reason 'UnsupportedPlatform' -Message "Unsupported platform: $platform" }
				}
			}
		}
		catch {
			Out-Log -Level 'ERROR' -Message "Unhandled $platform attendance exception ($($_.Exception.GetType().Name))."
			$embed.fields += @{ name = 'Error'; value = 'Unexpected attendance exception'; inline = $false }
			$result = New-AttendanceProfileFailure -Platform $(if ($platform) { $platform } else { 'unknown' }) -Reason 'UnexpectedError' -Message 'Unexpected attendance exception'
		}
		if (-not (Test-AttendanceProfileResult -Result $result)) {
			Out-Log -Level 'ERROR' -Message "Invalid outcome returned by $platform attendance."
			$embed.fields += @{ name = 'Error'; value = 'Handler returned an invalid outcome'; inline = $false }
			$result = New-AttendanceProfileFailure -Platform $(if ($platform) { $platform } else { 'unknown' }) -Reason 'InvalidResult' -Message 'Handler returned an invalid outcome'
		}
		Complete-AttendanceEmbed -Result $result -Embed $embed | Out-Null
		$confirmedCount = @($result.Items | Where-Object { $_.Kind -in @('Signed', 'AlreadySigned') }).Count
		$failedCount = @($result.Items | Where-Object { $_.Kind -eq 'Failed' }).Count
		$skippedCount = @($result.Items | Where-Object { $_.Kind -eq 'Skipped' }).Count
		$statusLevel = switch ($result.Kind) {
			'Success' { 'INFO' }
			'Skipped' { 'INFO' }
			'PartialFailure' { 'WARN' }
			default { 'ERROR' }
		}
		Out-Log -Level $statusLevel -Message "Profile #$profile_idx ($platform): $($result.Kind); confirmed=$confirmedCount, failed=$failedCount, skipped=$skippedCount, reason=$($result.Reason)"

		foreach ($bot_name in $bot_results.Keys) {
			$bot_data = $bot_results[$bot_name]
			$bot_config = $bot_data.BotConfig
			if (Test-DiscordBotProfileMatch -BotConfig $bot_config -Profile $profiie -ProfileIndex $profile_idx) {
				if ($result.Kind -ne 'Skipped') { $bot_data.Embeds += $embed }
				if (Test-AttendanceRequiresPing -Result $result) { $bot_data.AnyNeedPing = $true }
			}
		}
	}

	foreach ($bot_name in $bot_results.Keys) {
		$bot_data = $bot_results[$bot_name]
		if ($bot_data.Embeds.Count) {
			Out-Log -Level 'DEBUG' -Message "Sending notification:`n$(Format-LogObject -InputObject $bot_data)"
			Send-DiscordNotification -BotConfig $bot_data.BotConfig -Embeds $bot_data.Embeds -NeedPing $bot_data.AnyNeedPing -PingString (Get-DiscordPing -PingConfig $bot_data.BotConfig.ping) -GlobalConfig $conf
		}
	}

	if ($conf.runtime.pause -and (Get-AnimeAttendanceConsoleSettings -Config $conf).Enabled) {
		Out-Log -Level 'INFO' -Message 'Press ENTER to continue ...'
		Read-Host
	}
}
##MOD_EXEC## Export-ModuleMember -Function Invoke-AnimeAttendance
