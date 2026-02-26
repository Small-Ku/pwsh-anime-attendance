####################
# Utilities
####################

function New-WebSession {
	# From https://stackoverflow.com/questions/69519695
	param(
		[hashtable]$Cookies,
		[Uri]$For
	)

	$newSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()

	foreach ($entry in $Cookies.GetEnumerator()) {
		$cookie = [System.Net.Cookie]::new($entry.Name, $entry.Value)
		if ($For) {
			$newSession.Cookies.Add([uri]::new($For, '/'), $cookie)
		}
		else {
			$newSession.Cookies.Add($cookie)
		}
	}

	return $newSession
}

function Format-Text {
	# Temporary hack for Windows PowerShell that not handle REST requests with UTF-8
	param(
		[String]$Text
	)

	if ($null -eq $Text) { return "" }

	if ($PSVersionTable.PSVersion.Major -le 5) {
		$bytes = [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($Text)
		return [System.Text.Encoding]::UTF8.GetString($bytes)
	}

	return $Text
}

function Out-Log {
	param(
		[Parameter(Mandatory = $true)]
		[ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
		[String]$Level,
		[Parameter(Mandatory = $true)]
		[String]$Message
	)

	$color = switch ($Level) {
		'INFO' { 'Cyan' }
		'WARN' { 'Yellow' }
		'ERROR' { 'Red' }
		'DEBUG' { 'Gray' }
	}

	if ($Level -eq 'DEBUG' -and -not $global:debugging) { return }
	if ($null -ne $conf -and (($conf.display.console -eq 'false') -or (-not $conf.display.console))) { return }

	Write-Host "[$Level] $Message" -ForegroundColor $color
}

####################
# Discord
####################

function Get-DiscordPing {
	param($PingConfig)
	if (-not $PingConfig) { return "" }

	$ping = ""
	if ($PingConfig.user) {
		$ping += "<@" + ($PingConfig.user -join "> <@") + ">"
	}
	if ($PingConfig.user -and $PingConfig.role) {
		$ping += " "
	}
	if ($PingConfig.role) {
		$ping += "<@&" + ($PingConfig.role -join "> <@&") + ">"
	}
	return $ping
}

function Initialize-DiscordEmbed {
	return @{
		'color'       = '16711680' # Default to Red (Error)
		'title'       = "ERROR"
		'description' = "Unknown error. Maybe invalid cookie."
		'fields'      = @()
	}
}

function Send-DiscordNotification {
	param(
		$BotConfig,
		$Embeds,
		$NeedPing,
		$PingString,
		$GlobalConfig
	)

	if (-not $BotConfig.webhook_url) { return }

	$reuse_id = $BotConfig.reuse_msg
	$existing_message = $null
	
	# Fetch existing message if reusing
	if ($reuse_id -and $reuse_id -match '^\d{18,}$') {
		try {
			$uri = "$($BotConfig.webhook_url)/messages/$reuse_id"
			$existing_message = Invoke-RestMethod -Method 'Get' -Uri $uri -ContentType 'application/json;charset=UTF-8'
			Out-Log -Level 'DEBUG' -Message "Fetched existing message with $($existing_message.embeds.Length) embeds"
		}
		catch {
			Out-Log -Level 'WARN' -Message "Failed to fetch existing message for reuse: $_"
			$existing_message = $null
		}
	}

	# Embed Management Strategy: List-based with Footer ID matching
	$AllEmbeds = @()

	# 1. Load Existing Embeds
	if ($existing_message -and $existing_message.embeds -and -not $BotConfig.overwrite) {
		foreach ($ex_embed in $existing_message.embeds) {
			# Create a field map for fast lookups/updates
			$field_map = [ordered]@{}
			if ($ex_embed.fields) {
				foreach ($f in $ex_embed.fields) {
					$field_map[$f.name] = $f
				}
			}

			$AllEmbeds += @{
				'title'       = $ex_embed.title
				'color'       = $ex_embed.color
				'description' = $ex_embed.description
				'footer'      = if ($ex_embed.footer) { @{ 'text' = $ex_embed.footer.text } } else { $null }
				'field_map'   = $field_map
				'_matched'    = $false
			}
		}
	}

	# 2. Merge New Embeds
	foreach ($new_e in $Embeds) {
		$target_embed = $null

		# Search for existing match
		# Priority 1: Footer ID
		if ($new_e.footer -and $new_e.footer.text) {
			foreach ($ex in $AllEmbeds) {
				if ($ex.footer -and $ex.footer.text -eq $new_e.footer.text) {
					$target_embed = $ex
					break
				}
			}
		}

		# Priority 2: Description
		if ($new_e.description) {
			foreach ($ex in $AllEmbeds) {
				if ($ex.description -eq $new_e.description) {
					$target_embed = $ex
					break
				}
			}
		}

		# Priority 3: Title (Fallback for legacy or first run)
		if ($null -eq $target_embed) {
			foreach ($ex in $AllEmbeds) {
				if (-not $ex['_matched'] -and $ex.title -eq $new_e.title) {
					$target_embed = $ex
					break
				}
			}
		}

		if ($null -ne $target_embed) {
			# Update existing
			$target_embed['title'] = $new_e.title
			$target_embed['color'] = $new_e.color
			$target_embed['description'] = $new_e.description
			$target_embed['footer'] = $new_e.footer
			$target_embed['_matched'] = $true
		}
		else {
			# Create new
			$target_embed = @{
				'title'       = $new_e.title
				'color'       = $new_e.color
				'description' = $new_e.description
				'footer'      = $new_e.footer
				'field_map'   = [ordered]@{}
				'_matched'    = $true
			}
			$AllEmbeds += $target_embed
		}

		# Process Fields
		$target_field_map = $target_embed['field_map']
		foreach ($new_f in $new_e.fields) {
			# Determine value based on minimal flag
			$val = if ($BotConfig.minimal -and $new_f.minimal) { $new_f.minimal } else { $new_f.value }
			
			$clean_field = @{
				'name'   = $new_f.name
				'value'  = $val
				'inline' = $new_f.inline
			}

			# Update/Add
			$target_field_map[$new_f.name] = $clean_field
		}
	}

	# 3. Flatten back to Array
	$processed_embeds = @()
	foreach ($embed_entry in $AllEmbeds) {
		$fields_array = @($embed_entry['field_map'].Values)
		
		$final_embed = @{
			'title'       = $embed_entry['title']
			'color'       = $embed_entry['color']
			'description' = $embed_entry['description']
			'fields'      = $fields_array
		}
		if ($embed_entry['footer']) { $final_embed['footer'] = $embed_entry['footer'] }
		
		$processed_embeds += $final_embed
	}

	$discord_body = @{
		'content' = ''
		'embeds'  = $processed_embeds
	}
	if ($BotConfig.discord_name) { $discord_body.username = $BotConfig.discord_name }
	if ($BotConfig.avatar_url) { $discord_body.avatar_url = $BotConfig.avatar_url }

	$discord_body_json = $discord_body | ConvertTo-Json -Depth 10

	Out-Log -Level 'DEBUG' -Message "Discord message body for bot $($BotConfig.discord_name):`n$discord_body_json"

	if ($reuse_id -and $reuse_id -match '^\d{18,}$') {
		$uri = "$($BotConfig.webhook_url)/messages/$reuse_id"
		$ret = Invoke-RestMethod -Method 'Patch' -Uri $uri -Body $discord_body_json -ContentType 'application/json;charset=UTF-8'
	}
	else {
		$uri = $BotConfig.webhook_url + '?wait=true'
		$ret = Invoke-RestMethod -Method 'Post' -Uri $uri -Body $discord_body_json -ContentType 'application/json;charset=UTF-8'
		if ($BotConfig.reuse_msg -eq 'true' -or $BotConfig.reuse_msg -eq $true) {
			$BotConfig.reuse_msg = $ret.id
			$GlobalConfig | ConvertTo-Json -Depth 10 | Set-Content .\sign.json -Encoding 'UTF8'
		}
	}

	if ($NeedPing) {
		$ping_body = @{ 'content' = $PingString } | ConvertTo-Json
		Invoke-RestMethod -Method 'Post' -Uri $BotConfig.webhook_url -Body $ping_body -ContentType 'application/json;charset=UTF-8'
	}
}

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

####################
# skport
####################

function Get-SkportSignature {
	param($Path, $Body, $Timestamp, $Token, $Platform, $VName)

	$s = $Path + $Body + $Timestamp
	$s += '{"platform":"' + $Platform + '","timestamp":"' + $Timestamp + '","dId":"","vName":"' + $VName + '"}'
	Out-Log -Level 'DEBUG' -Message "Skport Signature Raw String: $s"

	$hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Token))
	$hmacBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
	$hmacHex = [System.BitConverter]::ToString($hmacBytes).Replace('-', '').ToLower()

	$md5 = [System.Security.Cryptography.MD5]::Create()
	$md5Bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hmacHex))
	$res = [System.BitConverter]::ToString($md5Bytes).Replace('-', '').ToLower()

	Out-Log -Level 'DEBUG' -Message "Skport Signature: $res"
	return $res
}

function Invoke-SkportRequest {
	param($Method, $Path, $Body, $Ctx)

	$Uri = "$($Ctx.GameConfig.api_base)$Path"
	$currTs = ([DateTimeOffset]::Now.ToUnixTimeSeconds() + $Ctx.TimeOffset).ToString()
	$headers = @{
		'Accept'          = '*/*'
		'Accept-Language' = 'en-US,en;q=0.9'
		'Referer'         = $Ctx.GameConfig.referer_url
		'Content-Type'    = 'application/json'
		'sk-language'     = $Ctx.Config.lang
		'cred'            = $Ctx.Cred
		'platform'        = $Ctx.GameConfig.platform
		'vName'           = $Ctx.GameConfig.vName
		'timestamp'       = $currTs
		'Origin'          = $Ctx.GameConfig.origin_url
		'Sec-Fetch-Dest'  = 'empty'
		'Sec-Fetch-Mode'  = 'cors'
		'Sec-Fetch-Site'  = 'same-site'
	}
	if ($Ctx.SkGameRole) {
		$headers['sk-game-role'] = $Ctx.SkGameRole
	}
	if ($Ctx.Token -and $Path) {
		$headers['sign'] = Get-SkportSignature -Path $Path -Body $Body -Timestamp $currTs -Token $Ctx.Token -Platform $Ctx.GameConfig.platform -VName $Ctx.GameConfig.vName
	}

	$params = @{
		Method      = $Method
		Uri         = $Uri
		Headers     = $headers
		UserAgent   = $Ctx.Config.user_agent
		ContentType = 'application/json'
		ErrorAction = 'Stop'
	}
	if ($Method -ne 'Get' -or ($null -ne $Body -and $Body -ne "")) { $params.Body = $Body }

	try {
		$ret = Invoke-RestMethod @params
		Out-Log -Level 'DEBUG' -Message "[skreq] ${Method} ${Uri}: $($ret | ConvertTo-Json -Depth 10)"
		return $ret
	}
	catch {
		$statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
		$code = if ($statusCode -gt 0) { - $statusCode } else { -1 }
		$msg = if ($_.Exception.Message) { $_.Exception.Message } else { "Request Failed" }
		
		if ($_.Exception.Response) {
			try {
				$reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
				$respBody = $reader.ReadToEnd()
				if ($respBody) {
					$json = $respBody | ConvertFrom-Json
					if ($null -ne $json.code) { return $json }
					if ($json.message) { $msg = $json.message }
				}
			}
			catch {}
		}
		return @{ code = $code; message = $msg }
	}
}

function New-SkportToken {
	param($Ctx)
	$res = Invoke-SkportRequest -Method 'Get' -Path "/web/v1/auth/refresh" -Ctx $Ctx
	if ($res.code -eq 0) {
		$Ctx.Token = $res.data.token
		$Ctx.TimeOffset = [Int64]$res.timestamp - [DateTimeOffset]::Now.ToUnixTimeSeconds()
		return $true
	}
	Out-Log -Level 'WARN' -Message "Skport token refresh failed ($($res.code)): $($res.message)"
	return $false
}

function Get-SkportBinding {
	param($Ctx)
	$res = Invoke-SkportRequest -Method 'Get' -Path "/api/v1/game/player/binding" -Ctx $Ctx
	if ($res.code -eq 0) {
		return $res.data
	}
	Out-Log -Level 'WARN' -Message "Skport binding error ($($res.code)): $($res.message)"
	return $null
}

function Get-SkportUser {
	param($Ctx)
	$res = Invoke-SkportRequest -Method 'Get' -Path "/web/v2/user" -Ctx $Ctx
	if ($res.code -eq 0) {
		return $res.data
	}
	Out-Log -Level 'WARN' -Message "Skport user error ($($res.code)): $($res.message)"
	return $null
}

function Find-SkportNickname {
	param($UserData)
	if ($UserData) {
		return $UserData.user.basicUser.nickname
	}
	return $null
}

function Find-SkportUserId {
	param($UserData)
	if ($UserData) {
		return $UserData.user.basicUser.id
	}
	return $null
}

function Find-SkportRoles {
	param($BindingData)
	
	if (-not $BindingData.list) { return @() }

	$roles = @()
	foreach ($app in $BindingData.list) {
		if ($app.bindingList) {
			foreach ($binding in $app.bindingList) {
				foreach ($role in $binding.roles) {
					$roles += @{
						appCode    = $app.appCode
						gameId     = $binding.gameId
						roleId     = $role.roleId
						serverId   = $role.serverId
						nickname   = Format-Text -Text $role.nickname
						serverName = Format-Text -Text $role.serverName
					}
				}
			}
		}
	}
	return $roles
}

function Find-SkportAwards {
	param($Ctx, $AttendanceData)
	
	$awardIds = $AttendanceData.awardIds

	if (-not $awardIds) {
		$calendar = $AttendanceData.calendar
		$item = $calendar | Where-Object { $_.done } | Select-Object -Last 1
		$awardIds = @{id = $item.awardId }
	}

	return $awardIds | ForEach-Object { $AttendanceData.resourceInfoMap.$($_.id) }
}

function Invoke-SkportAttendance {
	param($Profiie, $Config, $Embed, $IsReusing)

	$cred = $Profiie.cred
	
	# Bootstrap context with first game config to get token and bindings
	if ($Config.games.Count -eq 0) {
		Out-Log -Level 'ERROR' -Message "No Skport games configured."
		return $null
	}
	$bootstrapGame = $Config.games[0]
	$ctx = @{
		Cred = $cred; Token = $null; TimeOffset = 0;
		SkGameRole = $null; Config = $Config; GameConfig = $bootstrapGame
	}

	# 1. Refresh Token
	if (-not (New-SkportToken -Ctx $ctx)) {
		$Embed.fields += @{ 'name' = "Skport"; 'value' = "Failed to get token"; 'inline' = $true }
		return @{ NeedPing = $true }
	}
	
	# 2. Get User Info
	$userData = Get-SkportUser -Ctx $ctx
	$nickname = Find-SkportNickname -UserData $userData
	$userId = Find-SkportUserId -UserData $userData
	$Embed.title = if ($nickname) { $nickname } else { "Unknown Skport User" }
	$Embed.description = ""
	if ($null -ne $userId) { $Embed.description = "ID: ||$userId||" }

	# 3. Get All Roles
	$bindingData = Get-SkportBinding -Ctx $ctx
	$roles = Find-SkportRoles -BindingData $bindingData
	if ($roles.Count -eq 0) {
		Out-Log -Level 'WARN' -Message "No bound roles found for Skport user."
		$Embed.fields += @{ 'name' = "Skport"; 'value' = "No bound roles found"; 'inline' = $true }
		return $null
	}

	$any_ping = $false

	foreach ($role in $roles) {
		$game = $Config.games | Where-Object { $_.app_code -eq $role.appCode } | Select-Object -First 1
		
		if (-not $game) {
			Out-Log -Level 'DEBUG' -Message "Skipping role $($role.nickname) (App: $($role.appCode)) - No matching config."
			Continue
		}

		$display_name = $role.nickname
		$skGameRole = "$($role.gameId)_$($role.roleId)_$($role.serverId)"

		$roleCtx = @{
			Cred = $cred; Token = $ctx.Token; TimeOffset = $ctx.TimeOffset;
			SkGameRole = $skGameRole; Config = $Config; GameConfig = $game
		}

		$path = "/web/v1/game/$($game.app_code)/attendance"

		# 4. POST Attendance
		Out-Log -Level 'INFO' -Message "Checking in for $display_name ($($game.name))"
		$resPost = Invoke-SkportRequest -Method 'Post' -Path $path -Body "" -Ctx $roleCtx

		# 5. GET Attendance Info
		Out-Log -Level 'INFO' -Message "Checking status for $display_name ($($game.name))"
		$resGet = Invoke-SkportRequest -Method 'Get' -Path $path -Body "" -Ctx $roleCtx

		# 6. Handle notification
		$data = $null
		$is_already_checked_in = $false

		if ($resPost.code -eq 0) { 
			$data = $resPost.data 
		}
		elseif ($resGet.code -eq 0) { 
			$data = $resGet.data
			$is_already_checked_in = $resGet.data.hasToday
		}
		else {
			Out-Log -Level 'ERROR' -Message "[$display_name] Error (Code: $($resPost.code)): $($resPost.message)"
			$Embed.fields += @{ 'name' = "$($game.name) - $display_name"; 'value' = "ERROR: $($resPost.code) $($resPost.message)"; 'inline' = $true }
			$any_ping = $true
			continue
		}

		$awards = Find-SkportAwards -Ctx $roleCtx -AttendanceData $data
		$Embed.color = '5635840' # Green
		$award_text = ($awards | ForEach-Object { "$(Format-Text -Text $_.name) x$($_.count)" }) -join "`n"

		if ($is_already_checked_in) {
			Out-Log -Level 'INFO' -Message "[$display_name] Already checked in. Awards: $award_text"
		}
		else {
			Out-Log -Level 'INFO' -Message "[$display_name] Check-in success! Awards: $award_text"
		}

		if (-not $IsReusing -or -not $is_already_checked_in) {
			$field_value = "*$($role.serverName)* - $display_name`n$award_text"
			$Embed.fields += @{ 'name' = $game.name; 'value' = $field_value; 'inline' = $true }
		}
	}

	return @{ NeedPing = $any_ping }
}

####################
# Main
####################

$conf = Get-Content .\sign.json -Raw -Encoding 'UTF8' | ConvertFrom-Json
$global:debugging = $env:debug -eq 'pwsh-anime-attendance'

# Check Discord message reuse
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

# Map bots to their profiles
$bot_results = @{}
foreach ($bot in $conf.display.discord.bots) {
	$bot_results[$bot.discord_name] = @{
		BotConfig   = $bot
		Embeds      = @()
		AnyNeedPing = $false
	}
}

# Process each profile with index tracking
for ($profile_idx = 0; $profile_idx -lt $conf.profiles.Length; $profile_idx++) {
	$profiie = $conf.profiles[$profile_idx]
	$platform = $profiie.platform
	$p_conf = $conf.platforms.$platform

	$embed = Initialize-DiscordEmbed

	# Find which bots this profile belongs to and determine if any are reusing
	$is_reusing = $false
	foreach ($bot_name in $bot_results.Keys) {
		$bot_data = $bot_results[$bot_name]
		$bot_config = $bot_data.BotConfig
		
		# Check if this profile matches any in bot.profiles (by index or name)
		$matching = $false
		foreach ($profile_ref in $bot_config.profiles) {
			if ($profile_ref -is [int] -or $profile_ref -is [long]) {
				# Match by index
				if ($profile_ref -eq $profile_idx) {
					$matching = $true
					break
				}
			}
			else {
				# Match by console_name
				if ($profile_ref -eq $profiie.console_name) {
					$matching = $true
					break
				}
			}
		}
		
		if ($matching) {
			# Check if this bot is reusing messages
			$reuse_id = $bot_config.reuse_msg
			if ($reuse_id -and $reuse_id -match '^\d{18,}$' -and -not $bot_config.overwrite) {
				$is_reusing = $true
			}
		}
	}

	# Perform check-in with IsReusing flag
	$result = switch ($platform) {
		'hoyolab' { Invoke-HoyolabCheckin -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
		'skport' { Invoke-SkportAttendance -Profiie $profiie -Config $p_conf -Embed $embed -IsReusing $is_reusing }
		Default { Out-Log -Level 'ERROR' -Message "Unknown platform: $platform"; continue }
	}
	Out-Log -Level 'DEBUG' -Message "Attendance result:`n$($result | ConvertTo-Json -Depth 10)"

	# Assign embed to matching bots
	foreach ($bot_name in $bot_results.Keys) {
		$bot_data = $bot_results[$bot_name]
		$bot_config = $bot_data.BotConfig
		
		# Check if this profile matches any in bot.profiles (by index or name)
		$matching = $false
		foreach ($profile_ref in $bot_config.profiles) {
			if ($profile_ref -is [int] -or $profile_ref -is [long]) {
				# Match by index
				if ($profile_ref -eq $profile_idx) {
					$matching = $true
					break
				}
			}
			else {
				# Match by console_name
				if ($profile_ref -eq $profiie.console_name) {
					$matching = $true
					break
				}
			}
		}
		
		if ($matching) {
			$bot_data.Embeds += $embed
			if ($null -ne $result -and $result.NeedPing) { $bot_data.AnyNeedPing = $true }
		}
	}
}

# Final Notifications
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