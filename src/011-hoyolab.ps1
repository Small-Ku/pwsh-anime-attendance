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

	if ($ret.data) {
		foreach ($field in @(
			@{ Name = 'account_name'; Value = $ret.data.account_name },
			@{ Name = 'email'; Value = $ret.data.email },
			@{ Name = 'mobile'; Value = $ret.data.mobile }
		)) {
			Register-LogSecret -Secret $field.Value -Label $field.Name
		}
	}
	Out-Log -Level 'DEBUG' -Message "Account info: $(Format-LogObject -InputObject $ret)"

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

function Get-HoyolabGameRoleClass {
	param($Game)

	# HoYoLAB activity path and game_biz are separate provider identifiers.
	# Unknown games bypass this preflight rather than being treated as absent.
	switch ([string]$Game.game_id) {
		'sol' { return 'hk4e' }
		'luna/os' { return 'hkrpg' }
		'luna/zzz/os' { return 'nap' }
		default { return $null }
	}
}

function Get-HoyolabBoundRoleClasses {
	param($Cookies, $Config)

	# A game can have a successful /info response with is_sign=false and
	# total_sign_day=0 despite having no bound character. Check the actual
	# account's role bindings before attempting first-day sign-in.
	try {
		$base = 'https://api-os-takumi.mihoyo.com'
		$session = New-WebSession -Cookies $Cookies -For $base
		$reply = Invoke-RestMethod -Method 'Get' -Uri "$base/binding/api/getUserGameRolesByCookie" -Headers @{
			'Accept' = 'application/json, text/plain, */*'
			'x-rpc-client_type' = '5'
		} -UserAgent $Config.user_agent -WebSession $session -ErrorAction Stop
		if ($null -eq $reply -or $reply.retcode -ne 0 -or $null -eq $reply.data -or
			$null -eq $reply.data.list) {
			return @{ Available = $false; Classes = @{} }
		}
		$classes = @{}
		foreach ($role in @($reply.data.list)) {
			$biz = [string]$role.game_biz
			if ($biz) {
				$class = ($biz -split '_')[0]
				$classes[$class] = $true
			}
		}
		return @{ Available = $true; Classes = $classes }
	}
	catch {
		Out-Log -Level 'WARN' -Message 'Unable to verify bound HoYoLAB game roles; attendance will use game API status.'
		return @{ Available = $false; Classes = @{} }
	}
}
function Add-HoyolabAttendanceReward {
	param($Game, $Config, $Headers, $Session, $Info, [string]$InfoUrl, $Embed,
		[bool]$RefreshInfo = $false, [bool]$IsAlready = $false)

	# Only status determines the attendance result. Both already-signed and
	# freshly-signed games should show the same real award/count details.
	try {
		if ($RefreshInfo) {
			$Info = Invoke-RestMethod -Method 'Get' -Uri $InfoUrl -Headers $Headers -ContentType 'application/json;charset=UTF-8' -UserAgent $Config.user_agent -WebSession $Session
		}
		$rewardUrl = "$($Game.api_base)/event/$($Game.game_id)/home?lang=$($Config.lang)&act_id=$($Game.act_id)"
		$reward = Invoke-RestMethod -Method 'Get' -Uri $rewardUrl -Headers $Headers -ContentType 'application/json;charset=UTF-8' -UserAgent $Config.user_agent -WebSession $Session
		if ($null -eq $Info -or $Info.retcode -ne 0 -or $null -eq $Info.data -or
			$null -eq $reward -or $reward.retcode -ne 0 -or $null -eq $reward.data -or $null -eq $reward.data.awards) {
			throw 'Reward information unavailable'
		}
		$totalDays = 0
		if (-not [int]::TryParse([string]$Info.data.total_sign_day, [ref]$totalDays) -or $totalDays -lt 1) {
			throw 'Reward index unavailable'
		}
		$awards = @($reward.data.awards)
		if ($totalDays -gt $awards.Count) { throw 'Reward index unavailable' }
		$todayReward = $awards[$totalDays - 1]
		if (-not $todayReward -or -not $todayReward.name) { throw 'Reward entry unavailable' }

		$rewardName = Format-Text -Text $todayReward.name
		$nl = [char]10
		$full = "$($Info.data.today)$nl**$($Config.discord_text.total_sign_day)**$nl$totalDays$($Config.discord_text.total_sign_day_unit)$nl**$($Config.discord_text.reward)**$nl$rewardName x$($todayReward.cnt)"
		$minimal = "$($Info.data.today) ($totalDays)$nl$rewardName x$($todayReward.cnt)"
		$Embed.fields += @{ name = $Game.name; value = $full; inline = $true; minimal = $minimal }
		Out-Log -Level 'INFO' -Message "Confirmed reward for $($Game.name): $rewardName x$($todayReward.cnt)"
	}
	catch {
		Out-Log -Level 'WARN' -Message "Reward details unavailable after confirmed HoYoLAB attendance for $($Game.name)."
		$prefix = if ($IsAlready) { 'Already signed today' } else { 'Signed today' }
		$Embed.fields += @{ name = $Game.name; value = "$prefix; reward details unavailable"; inline = $true }
	}
}
function Invoke-HoyolabCheckin {
	param($Profiie, $Config, $Embed, $IsReusing)

	$cookieResult = Select-HoyolabCookie -Profiie $Profiie
	if (-not $cookieResult.IsValid) {
		$logMsg = Format-LogIdentity -Value $Profiie.console_name -Label 'console_name'
		Out-Log -Level 'ERROR' -Message "Invalid cookie format for profile: $logMsg"
		return New-AttendanceProfileFailure -Platform 'hoyolab' -Reason 'AuthenticationFailed' -Message 'Missing or rejected credentials'
	}

	$items = @()
	$boundRoleClasses = $null
	$jar = $cookieResult.Jar
	$ltuid = $cookieResult.ltuid
	if ($ltuid -and $ltuid -ne 'Unknown') { Register-LogSecret -Secret $ltuid -Label 'ltuid'; Register-GitHubLogMasks }

	$logLtuid = Format-LogIdentity -Value $ltuid -Label 'account' -Key $ltuid
	$display_name = $ltuid -replace '^(\d{2})\d+(\d{2})$', '$1****$2'
	$Embed.title = $display_name -replace '\*', '\*'
	if ($ltuid -ne "Unknown") { $Embed.description = "ID: ||$ltuid||" }

	# Get detailed account info
	$ac_info = Get-HoyolabAccountInfo -Cookies $jar -Config $Config
	if ($ac_info.Success -and $ac_info.DisplayName) {
		$display_name = $ac_info.DisplayName
		Register-LogSecret -Secret $display_name -Label 'display_name'
		$Embed.title = $display_name -replace '\*', '\*'
	}
	elseif (-not $ac_info.Success) {
		$Embed.fields += @{ 'name' = 'Account'; 'value' = $ac_info.Message }
		Out-Log -Level 'ERROR' -Message "Failed to get account info for ${logLtuid}: $($ac_info.Message)"
		$items += New-AttendanceItemResult -Kind 'Failed' -Identity 'Account' -Reason 'AccountLookupFailed' -Detail 'Account information unavailable'
		if ($ac_info.Message -match "login" -or $ac_info.Message -match "cookie") {
			return New-AttendanceProfileFailure -Platform 'hoyolab' -Reason 'AuthenticationFailed' -Message 'Missing or rejected credentials'
		}
	}

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
		Out-Log -Level 'DEBUG' -Message "Queried info: $(Format-LogObject -InputObject $ret_info)"

		# The HoYoLAB activity returns -10002 with no data when this account
		# has never created a character for the game. No attendance is possible,
		# so this is not a failed signing attempt or an account auth error.
		if ($null -ne $ret_info -and $ret_info.retcode -eq -10002 -and $null -eq $ret_info.data) {
			Out-Log -Level 'INFO' -Message "No character for $($game.name) on $logLtuid; skipping attendance."
			# No game character means no attendance item should be shown in
			# Discord, matching the pre-#3 behavior without pretending success.
			$items += New-AttendanceItemResult -Kind 'Skipped' -Identity $game.name -Reason 'NoGameCharacter'
			continue
		}

		if ($null -eq $ret_info -or ($ret_info.retcode -ne 0 -and $ret_info.retcode -ne -100) -or ($ret_info.retcode -eq 0 -and $null -eq $ret_info.data)) {
			$Embed.fields += @{ name = $game.name; value = 'Cannot verify attendance status'; inline = $true }
			$items += New-AttendanceItemResult -Kind 'Failed' -Identity $game.name -Reason 'InvalidResponse' -Detail 'Attendance status unavailable'
			continue
		}
		if ($ret_info.retcode -eq -100) {
			Out-Log -Level 'ERROR' -Message "Invalid cookie for $($game.name): $logLtuid"
			$Embed.fields += @{ 'name' = $game.name; 'value' = Format-Text -Text $ret_info.message; 'inline' = $true }
			$items += New-AttendanceItemResult -Kind 'Failed' -Identity $game.name -Reason 'AuthenticationFailed' -Detail 'Provider rejected or blocked attendance'
			Continue
		}

		# A zero-day /info is not proof of an existing game character.
		# Only skip when the authoritative role binding list is available
		# and confirms this game has no bound role. Otherwise retain the
		# usual first-day sign-in path.
		$gameRoleClass = Get-HoyolabGameRoleClass -Game $game
		if ($gameRoleClass -and $ret_info.retcode -eq 0 -and $ret_info.data.is_sign -eq $false -and
			[string]$ret_info.data.total_sign_day -eq '0') {
			if ($null -eq $boundRoleClasses) {
				$boundRoleClasses = Get-HoyolabBoundRoleClasses -Cookies $jar -Config $Config
			}
			if ($boundRoleClasses.Available -and -not $boundRoleClasses.Classes.ContainsKey($gameRoleClass)) {
				Out-Log -Level 'INFO' -Message "No bound character for $($game.name) on $logLtuid; skipping attendance."
				$items += New-AttendanceItemResult -Kind 'Skipped' -Identity $game.name -Reason 'NoGameCharacter'
				continue
			}
		}

		# AlreadySigned means no POST, not "discard the original reward".
		if ($ret_info.data.is_sign -eq $true) {
			$items += New-AttendanceItemResult -Kind 'AlreadySigned' -Identity $game.name
			Add-HoyolabAttendanceReward -Game $game -Config $Config -Headers $api_headers -Session $session -Info $ret_info -InfoUrl $api_info_url -Embed $Embed -IsAlready $true
			continue
		}
		# 2. Perform sign-in
		Out-Log -Level 'INFO' -Message "Checking $(Format-LogIdentity -Value $display_name -Label 'account' -Key $ltuid) in for $($game.name)"
		$api_sign_url = "$base_url/event/$($game.game_id)/sign?lang=$($Config.lang)"
		$sign_body = @{ 'act_id' = $act_id } | ConvertTo-Json
		$ret_sign = Invoke-RestMethod -Method 'Post' -Uri $api_sign_url -Body $sign_body -Headers $api_headers -ContentType 'application/json;charset=UTF-8' -UserAgent $Config.user_agent -WebSession $session
		Out-Log -Level 'DEBUG' -Message "Check-in result: $(Format-LogObject -InputObject $ret_sign)"

		if ($ret_sign.retcode -eq -100) {
			Out-Log -Level 'ERROR' -Message "Invalid cookie during sign for $($game.name): $logLtuid"
			$Embed.fields += @{ 'name' = $game.name; 'value' = Format-Text -Text $ret_sign.message; 'inline' = $true }
			$items += New-AttendanceItemResult -Kind 'Failed' -Identity $game.name -Reason 'AuthenticationFailed' -Detail 'Provider rejected or blocked attendance'
			Continue
		}

		# A race between GET and POST may still yield already-signed.
		if ($ret_sign.retcode -eq -10002) {
			$items += New-AttendanceItemResult -Kind 'AlreadySigned' -Identity $game.name
			Add-HoyolabAttendanceReward -Game $game -Config $Config -Headers $api_headers -Session $session -Info $ret_info -InfoUrl $api_info_url -Embed $Embed -RefreshInfo $true -IsAlready $true
			continue
		}
		if ($ret_sign.data.gt_result -and -not ($ret_sign.data.gt_result.risk_code -eq 0 -and -not $ret_sign.data.gt_result.is_risk -and $ret_sign.data.gt_result.success -eq 0)) {
			Out-Log -Level 'ERROR' -Message "Captcha required during attendance for $($game.name)"
			$Embed.fields += @{ name = $game.name; value = $Config.discord_text.need_captcha; inline = $true }
			$items += New-AttendanceItemResult -Kind 'Failed' -Identity $game.name -Reason 'CaptchaRequired'
			continue
		}
		if ($null -eq $ret_sign -or $ret_sign.retcode -ne 0 -or $ret_sign.message -ne 'OK') {
			Out-Log -Level 'ERROR' -Message "Provider did not confirm attendance for $($game.name)"
			$Embed.fields += @{ name = $game.name; value = 'Check-in was not confirmed'; inline = $true }
			$items += New-AttendanceItemResult -Kind 'Failed' -Identity $game.name -Reason 'CheckInUnconfirmed'
			continue
		}

		# Only POST confirmation establishes a Signed result. Reward display
		# and re-sign are optional operations, not attendance confirmation.
		$items += New-AttendanceItemResult -Kind 'Signed' -Identity $game.name
		if ($ret_info.data.sign_cnt_missed -gt 0) {
			try {
				Invoke-HoyolabResign -BaseUrl $base_url -GameId $game.game_id -ActId $act_id -Headers $api_headers -Jar $jar -Config $Config
			}
			catch {
				Out-Log -Level 'WARN' -Message "Optional HoYoLAB re-sign failed for $($game.name)."
			}
		}
		Add-HoyolabAttendanceReward -Game $game -Config $Config -Headers $api_headers -Session $session -Info $ret_info -InfoUrl $api_info_url -Embed $Embed -RefreshInfo $true
	}

	return Complete-AttendanceProfileResult -Platform 'hoyolab' -Items $items
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
