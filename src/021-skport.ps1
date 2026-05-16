####################
# skport
####################

function Get-SkportSignature {
	param($Path, $Body, $Timestamp, $Token, $Platform, $VName)
	return Get-SkSignature -Path $Path -Body $Body -Timestamp $Timestamp -Token $Token -Platform $Platform -VName $VName -DId ""
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
		return ConvertFrom-SkRequestError -ErrorRecord $_
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
