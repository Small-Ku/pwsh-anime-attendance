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

	$script:conf = Get-Content $ConfigPath -Raw -Encoding 'UTF8' | ConvertFrom-Json
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

		$result = switch ($platform) {
			'hoyolab' { Invoke-HoyolabCheckin -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
			'skport' { Invoke-SkportAttendance -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
			'skland' { Invoke-SklandAttendance -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
			Default { Out-Log -Level 'ERROR' -Message "Unknown platform: $platform"; continue }
		}
		Out-Log -Level 'DEBUG' -Message "Attendance result:`n$($result | ConvertTo-Json -Depth 10)"

		foreach ($bot_name in $bot_results.Keys) {
			$bot_data = $bot_results[$bot_name]
			$bot_config = $bot_data.BotConfig
			if (Test-DiscordBotProfileMatch -BotConfig $bot_config -Profile $profiie -ProfileIndex $profile_idx) {
				$bot_data.Embeds += $embed
				if ($null -ne $result -and $result.NeedPing) { $bot_data.AnyNeedPing = $true }
			}
		}
	}

	foreach ($bot_name in $bot_results.Keys) {
		$bot_data = $bot_results[$bot_name]
		if ($bot_data.Embeds.Count) {
			Out-Log -Level 'DEBUG' -Message "Sending notification:`n$($bot_data | ConvertTo-Json -Depth 10)"
			Send-DiscordNotification -BotConfig $bot_data.BotConfig -Embeds $bot_data.Embeds -NeedPing $bot_data.AnyNeedPing -PingString (Get-DiscordPing -PingConfig $bot_data.BotConfig.ping) -GlobalConfig $conf
		}
	}

	if ($conf.display.console -is [string] -and $conf.display.console -eq 'pause') {
		Out-Log -Level 'INFO' -Message 'Press ENTER to continue ...'
		Read-Host
	}
}
##MOD_EXEC## Export-ModuleMember -Function Invoke-AnimeAttendance
