####################
# HoYoLAB
####################

function Select-HoyolabCookie {
	param($Profiie)
	
	$jar = @{ 'mi18nLang' = $Profiie.lang }
	$ltuid = "Unknown"
	
	$isV2Valid = ($Profiie.ltoken_v2) -and ($Profiie.ltoken_v2 -match '^v2_[^\s;]{114,}$') -and ($Profiie.ltmid_v2 -match '^[0-9a-zA-Z_]{13}$') -and ($Profiie.ltuid_v2 -match '^\d+$')
	if ($isV2Valid) {
		$jar['ltoken_v2'] = $Profiie.ltoken_v2
		$jar['ltmid_v2'] = $Profiie.ltmid_v2
		$jar['ltuid_v2'] = $Profiie.ltuid_v2
		return @{ IsValid = $true; Jar = $jar; ltuid = $Profiie.ltuid_v2 }
	}
	
	$isV1Valid = ($Profiie.ltoken) -and ($Profiie.ltoken -match '^[0-9a-zA-Z]{40}$') -and ($Profiie.ltuid -match '^\d+$')
	if ($isV1Valid) {
		$jar['ltoken'] = $Profiie.ltoken
		$jar['ltuid'] = $Profiie.ltuid
		return @{ IsValid = $true; Jar = $jar; ltuid = $Profiie.ltuid }
	}
	
	$CookieString = $Profiie.cookies
	if ($CookieString) {
		$isValidFallback = (($CookieString -like "*ltoken_v2=*") -and ($CookieString -match 'ltoken_v2=v2_[^\s;]{114,}') -and ($CookieString -match 'ltmid_v2=[0-9a-zA-Z_]{13}') -and ($CookieString -match 'ltuid_v2=(\d+)')) -or (($CookieString -match 'ltoken=[0-9a-zA-Z]{40}') -and ($CookieString -match 'ltuid=(\d+)'))
		if ($isValidFallback) {
			foreach ($c in ($CookieString -split ';')) {
				$c = $c.Trim()
				if ($c) {
					$c_pair = $c -split '=', 2
					$jar[$c_pair[0]] = $c_pair[1]
				}
			}
			if ($CookieString -match 'ltuid(_v2)?=(\d+)') { $ltuid = $Matches[2] }
			return @{ IsValid = $true; Jar = $jar; ltuid = $ltuid }
		}
	}
	return @{ IsValid = $false }
}

function Get-HoyolabAccountInfo {
	param($Cookies, $Config)

	$session = New-WebSession -Cookies $Cookies -For $Config.account.api_base
	$headers = @{
		'Accept'          = 'application/json, text/plain, */*'
		'Accept-Language' = 'en-US,en;q=0.9'
		'Origin'          = $Config.account.origin_url
		'Referer'         = $Config.account.referer_url
		'Sec-Fetch-Site'  = 'same-site'
		'Sec-Fetch-Mode'  = 'cors'
		'Sec-Fetch-Dest'  = 'empty'
	}
	$uri = $Config.account.api_base + '/auth/api/getUserAccountInfoByLToken'
	$ret = Invoke-RestMethod -Method 'Get' -Uri $uri -Headers $headers -ContentType 'application/json;charset=UTF-8' -UserAgent $Config.user_agent -WebSession $session

	Out-Log -Level 'DEBUG' -Message "Account info: $ret data: $($ret.data)"

	if ($ret.retcode -eq 0) {
		$display_name = ''
		if ($Config.account.info_display.name -and $ret.data.account_name) { $display_name = $ret.data.account_name }
		elseif ($Config.account.info_display.email -and $ret.data.email) { $display_name = $ret.data.email }
		elseif ($Config.account.info_display.id -and $ret.data.account_id) { $display_name = $ret.data.account_id }
		elseif ($Config.account.info_display.phone -and $ret.data.mobile) { $display_name = $ret.data.mobile }

		return @{ Success = $true; DisplayName = $display_name }
	}

	return @{ Success = $false; Message = $ret.message }
}

function Invoke-HoyolabCheckin {
	param($Profiie, $Config, $Embed, $IsReusing)

	$cookieResult = Select-HoyolabCookie -Profiie $Profiie
	if (-not $cookieResult.IsValid) {
		$logMsg = if ($Profiie.console_name) { $Profiie.console_name } else { "Unknown" }
		Out-Log -Level 'ERROR' -Message "Invalid cookie format for profile: $logMsg"
		return @{ NeedPing = $true }
	}

	$jar = $cookieResult.Jar
	$ltuid = $cookieResult.ltuid

	$display_name = $ltuid -replace '^(\d{2})\d+(\d{2})$', '$1****$2'
	$Embed.title = $display_name -replace '\*', '\*'
	if ($ltuid -ne "Unknown") { $Embed.description = "ID: ||$ltuid||" }

	# Get detailed account info
	$ac_info = Get-HoyolabAccountInfo -Cookies $jar -Config $Config
	if ($ac_info.Success -and $ac_info.DisplayName) {
		$display_name = $ac_info.DisplayName
		$Embed.title = $display_name -replace '\*', '\*'
	}
	elseif (-not $ac_info.Success) {
		$Embed.fields += @{ 'name' = 'Account'; 'value' = $ac_info.Message }
		Out-Log -Level 'ERROR' -Message "Failed to get account info for ${ltuid}: $($ac_info.Message)"
		if ($ac_info.Message -match "login" -or $ac_info.Message -match "cookie") {
			return @{ NeedPing = $true }
		}
	}

	$any_ping = $false
	foreach ($game in $Config.games) {
		Out-Log -Level 'DEBUG' -Message "Signing for: $($game.name)"

		$act_id = $game.act_id
		$base_url = $game.api_base
		$api_headers = @{
			'Accept'            = 'application/json, text/plain, */*'
			'Accept-Encoding'   = 'gzip, deflate, br'
			'Accept-Language'   = 'en-US,en;q=0.9'
			'x-rpc-app_version' = '2.34.1'
			'x-rpc-client_type' = '4'
			'Sec-Fetch-Site'    = 'same-site'
			'Sec-Fetch-Mode'    = 'cors'
			'Sec-Fetch-Dest'    = 'empty'
			'sec-ch-ua'         = '" Not A;Brand";v="99", "Chromium";v="90", "Google Chrome";v="90"'
			'sec-ch-ua-mobile'  = '?0'
			'Origin'            = $game.origin_url
			'Referer'           = $game.referer_url
		}
		if ($game.custom_headers) {
			$game.custom_headers.psobject.properties | ForEach-Object { $api_headers[$_.Name] = $_.Value }
		}

		$session = New-WebSession -Cookies $jar -For $base_url

		# 1. Get info
		$api_info_url = "$base_url/event/$($game.game_id)/info?lang=$($Config.lang)&act_id=$act_id"
		$ret_info = Invoke-RestMethod -Method 'Get' -Uri $api_info_url -Headers $api_headers -ContentType 'application/json;charset=UTF-8' -UserAgent $Config.user_agent -WebSession $session
		Out-Log -Level 'DEBUG' -Message "Queried info: $ret_info data: $($ret_info.data)"

		if ($ret_info.retcode -eq -100) {
			Out-Log -Level 'ERROR' -Message "Invalid cookie for $($game.name): $ltuid"
			$Embed.fields += @{ 'name' = $game.name; 'value' = Format-Text -Text $ret_info.message; 'inline' = $true }
			$any_ping = $true
			Continue
		}

		# 2. Perform sign-in
		Out-Log -Level 'INFO' -Message "Checking $display_name in for $($game.name)"
		$api_sign_url = "$base_url/event/$($game.game_id)/sign?lang=$($Config.lang)"
		$sign_body = @{ 'act_id' = $act_id } | ConvertTo-Json
		$ret_sign = Invoke-RestMethod -Method 'Post' -Uri $api_sign_url -Body $sign_body -Headers $api_headers -ContentType 'application/json;charset=UTF-8' -UserAgent $Config.user_agent -WebSession $session
		Out-Log -Level 'DEBUG' -Message "Check-in result: $ret_sign"

		if ($ret_sign.retcode -eq -100) {
			Out-Log -Level 'ERROR' -Message "Invalid cookie during sign for $($game.name): $ltuid"
			$Embed.fields += @{ 'name' = $game.name; 'value' = Format-Text -Text $ret_sign.message; 'inline' = $true }
			$any_ping = $true
			Continue
		}

		# 3. Handle Resign
		if ($ret_info.data.sign_cnt_missed -gt 0 -and $ret_sign.retcode -ne -10002) {
			Invoke-HoyolabResign -BaseUrl $base_url -GameId $game.game_id -ActId $act_id -Headers $api_headers -Jar $jar -Config $Config
		}

		# 4. Process sign-in outcome
		$skip = $ret_info.data.is_sign -or $ret_sign.retcode -eq -10002
		if ($skip) {
			$msg = Format-Text -Text $ret_sign.message
			Out-Log -Level 'INFO' -Message "[$display_name] $msg"
			if ($ret_sign.retcode -eq -10002) { Continue }

			# Only add to embed if not reusing message to avoid overwrite
			if (-not $IsReusing) {
				$Embed.fields += @{ 'name' = $game.name; 'value' = $msg; 'inline' = $true }
			}
		}
		elseif ($ret_sign.data.gt_result -and -not ($ret_sign.data.gt_result.risk_code -eq 0 -and -not $ret_sign.data.gt_result.is_risk -and $ret_sign.data.gt_result.success -eq 0)) {
			Out-Log -Level 'ERROR' -Message "Captcha requested for $ltuid ($($game.name))"
			$Embed.fields += @{ 'name' = $game.name; 'value' = $Config.discord_text.need_captcha; 'inline' = $true }
			$any_ping = $true
			Continue
		}
		elseif ($ret_sign.message -ne 'OK') {
			Out-Log -Level 'ERROR' -Message "Unknown check-in error for ${ltuid}: $($ret_sign.message)"
			Continue
		}
		else {
			# Success - get updated info
			$ret_info = Invoke-RestMethod -Method 'Get' -Uri $api_info_url -Headers $api_headers -ContentType 'application/json;charset=UTF-8' -UserAgent $Config.user_agent -WebSession $session
		}

		# 5. Get Reward Info
		$api_reward_url = "$base_url/event/$($game.game_id)/home?lang=$($Config.lang)&act_id=$act_id"
		$ret_reward = Invoke-RestMethod -Method 'Get' -Uri $api_reward_url -Headers $api_headers -ContentType 'application/json;charset=UTF-8' -UserAgent $Config.user_agent -WebSession $session
		if (($ret_info.retcode -eq -100) -or ($ret_reward.retcode -eq -100)) {
			$Embed.fields += @{ 'name' = $game.name; 'value' = Format-Text -Text $ret_reward.message }
			Continue
		}

		$current_reward = $ret_reward.data.awards[$ret_info.data.total_sign_day - 1]
		$reward_name = Format-Text -Text $current_reward.name
		Out-Log -Level 'INFO' -Message "[$display_name] $reward_name x$($current_reward.cnt)"

		$Embed.color = '5635840' # Green (Success)
		$reward_text_full = "$($ret_info.data.today)`n**$($Config.discord_text.total_sign_day)**`n$($ret_info.data.total_sign_day)$($Config.discord_text.total_sign_day_unit)`n**$($Config.discord_text.reward)**`n$reward_name x$($current_reward.cnt)"
		$reward_text_minimal = "$($ret_info.data.today) ($($ret_info.data.total_sign_day))`n$reward_name x$($current_reward.cnt)"
		
		$Embed.fields += @{ 'name' = $game.name; 'value' = $reward_text_full; 'inline' = $true; 'minimal' = $reward_text_minimal }
	}

	return @{ NeedPing = $any_ping }
}

function Invoke-HoyolabResign {
	param($BaseUrl, $GameId, $ActId, $Headers, $Jar, $Config)

	$lang = $Config.lang
	$user_agent = $Config.user_agent

	$api_tasks_url = "$BaseUrl/event/$GameId/task/list?act_id=$ActId&lang=$lang"
	$api_task_complete_url = "$BaseUrl/event/$GameId/task/complete"
	$api_task_award_url = "$BaseUrl/event/$GameId/task/award"

	$session = New-WebSession -Cookies $Jar -For $BaseUrl
	$ret_tasks = Invoke-RestMethod -Method 'Get' -Uri $api_tasks_url -Headers $Headers -ContentType 'application/json;charset=UTF-8' -UserAgent $user_agent -WebSession $session

	foreach ($task in $ret_tasks.data.list) {
		if ($task.status -eq "TT_Award") { Continue }
		$body = @{ "id" = $task.id; "lang" = $lang; "act_id" = $ActId } | ConvertTo-Json
		[void](Invoke-RestMethod -Method 'Post' -Uri $api_task_complete_url -Headers $Headers -Body $body -ContentType 'application/json;charset=UTF-8' -UserAgent $user_agent -WebSession $session)
		[void](Invoke-RestMethod -Method 'Post' -Uri $api_task_award_url -Headers $Headers -Body $body -ContentType 'application/json;charset=UTF-8' -UserAgent $user_agent -WebSession $session)
	}

	$api_resign_info_url = "$BaseUrl/event/$GameId/resign_info?act_id=$ActId&lang=$lang"
	$ret_resign_info = Invoke-RestMethod -Method 'Get' -Uri $api_resign_info_url -Headers $Headers -ContentType 'application/json;charset=UTF-8' -UserAgent $user_agent -WebSession $session

	if (($ret_resign_info.data.resign_cnt_monthly -lt $ret_resign_info.data.resign_limit_monthly) -and ($ret_resign_info.data.resign_cnt_daily -lt $ret_resign_info.data.resign_limit_daily)) {
		$body = @{ "act_id" = $ActId; "lang" = $lang } | ConvertTo-Json
		[void](Invoke-RestMethod -Method 'Post' -Uri "$BaseUrl/event/$GameId/resign" -Headers $Headers -Body $body -ContentType 'application/json;charset=UTF-8' -UserAgent $user_agent -WebSession $session)
	}
}