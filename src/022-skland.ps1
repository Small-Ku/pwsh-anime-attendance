####################
# skland
####################

function Invoke-SklandPassportRequest {
	param($Method, $Path, $Body, $Ctx)

	$uri = "https://as.hypergryph.com$Path"
	$params = @{
		Method      = $Method
		Uri         = $uri
		Headers     = @{ 'Content-Type' = 'application/json' }
		UserAgent   = $Ctx.Config.user_agent
		ContentType = 'application/json'
		ErrorAction = 'Stop'
	}
	if ($null -ne $Body -and $Body -ne "") {
		$params.Body = if ($Body -is [string]) { $Body } else { ConvertTo-SkCompactJson -Value $Body }
	}

	try {
		$ret = Invoke-RestMethod @params
		Out-Log -Level 'DEBUG' -Message "[skland-passport] ${Method} ${Uri}: $($ret | ConvertTo-Json -Depth 10)"
		return $ret
	}
	catch {
		return ConvertFrom-SkRequestError -ErrorRecord $_
	}
}

function Get-SklandSignature {
	param($Path, $QueryString, $Body, $Timestamp, $Token, $Ctx)
	return Get-SkSignature -Path $Path -QueryString $QueryString -Body $Body -Timestamp $Timestamp -Token $Token -Platform $Ctx.GameConfig.platform -VName $Ctx.GameConfig.vName -DId $Ctx.DId
}

function Invoke-SklandRequest {
	param($Method, $Path, $Body, $Ctx, $Query)

	$queryString = ""
	if ($Query) {
		$queryParts = @()
		foreach ($k in $Query.Keys) {
			$queryParts += "{0}={1}" -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Query[$k])
		}
		$queryString = ($queryParts -join '&')
	}

	$uri = "$($Ctx.GameConfig.api_base)$Path"
	if ($queryString) { $uri += "?$queryString" }

	$currTs = ([DateTimeOffset]::Now.ToUnixTimeSeconds() + $Ctx.TimeOffset).ToString()
	$bodyText = ConvertTo-SkCompactJson -Value $Body
	$headers = @{
		'Accept'          = '*/*'
		'Accept-Language' = 'en-US,en;q=0.9'
		'Referer'         = $Ctx.GameConfig.referer_url
		'Content-Type'    = 'application/json'
		'sk-language'     = $Ctx.Config.lang
		'platform'        = $Ctx.GameConfig.platform
		'vName'           = $Ctx.GameConfig.vName
		'dId'             = $Ctx.DId
		'timestamp'       = $currTs
		'Origin'          = $Ctx.GameConfig.origin_url
		'Sec-Fetch-Dest'  = 'empty'
		'Sec-Fetch-Mode'  = 'cors'
		'Sec-Fetch-Site'  = 'same-site'
	}
	if ($Ctx.SkGameRole) {
		$headers['sk-game-role'] = $Ctx.SkGameRole
	}
	if ($Ctx.Cred) {
		$headers['cred'] = $Ctx.Cred
	}
	if ($Ctx.Token -and $Path) {
		$headers['sign'] = Get-SklandSignature -Path $Path -QueryString $queryString -Body $bodyText -Timestamp $currTs -Token $Ctx.Token -Ctx $Ctx
	}

	$params = @{
		Method      = $Method
		Uri         = $Uri
		Headers     = $headers
		UserAgent   = $Ctx.Config.user_agent
		ContentType = 'application/json'
		ErrorAction = 'Stop'
	}
	if ($Method -ne 'Get' -or ($bodyText -ne "")) { $params.Body = $bodyText }

	try {
		$ret = Invoke-RestMethod @params
		Out-Log -Level 'DEBUG' -Message "[skland] ${Method} ${Uri}: $($ret | ConvertTo-Json -Depth 10)"
		return $ret
	}
	catch {
		return ConvertFrom-SkRequestError -ErrorRecord $_
	}
}

function New-SklandCred {
	param($Ctx)

	$grantBody = @{ appCode = '4ca99fa6b56cc2ba'; token = $Ctx.PassportToken; type = 0 }
	$grant = Invoke-SklandPassportRequest -Method 'Post' -Path '/user/oauth2/v2/grant' -Body $grantBody -Ctx $Ctx
	if ($grant.status -ne 0 -or -not $grant.data.code) {
		Out-Log -Level 'WARN' -Message "Skland grant authorize code failed: $($grant.msg)"
		return $false
	}

	$authBody = @{ code = $grant.data.code; kind = 1 }
	$res = Invoke-SklandRequest -Method 'Post' -Path '/web/v1/user/auth/generate_cred_by_code' -Body $authBody -Ctx $Ctx
	if ($res.code -eq 0) {
		$Ctx.Token = $res.data.token
		$Ctx.Cred = $res.data.cred
		$Ctx.TimeOffset = [Int64]$res.timestamp - [DateTimeOffset]::Now.ToUnixTimeSeconds()
		return $true
	}

	Out-Log -Level 'WARN' -Message "Skland generate cred failed ($($res.code)): $($res.message)"
	return $false
}

function New-SklandToken {
	param($Ctx)
	$res = Invoke-SklandRequest -Method 'Get' -Path '/web/v1/auth/refresh' -Ctx $Ctx
	if ($res.code -eq 0) {
		$Ctx.Token = $res.data.token
		$Ctx.TimeOffset = [Int64]$res.timestamp - [DateTimeOffset]::Now.ToUnixTimeSeconds()
		return $true
	}
	Out-Log -Level 'WARN' -Message "Skland token refresh failed ($($res.code)): $($res.message)"
	return $false
}

function Get-SklandBinding {
	param($Ctx)
	$res = Invoke-SklandRequest -Method 'Get' -Path '/api/v1/game/player/binding' -Ctx $Ctx
	if ($res.code -eq 0) { return $res.data }
	Out-Log -Level 'WARN' -Message "Skland binding error ($($res.code)): $($res.message)"
	return $null
}

function Get-SklandUser {
	param($Ctx)
	$res = Invoke-SklandRequest -Method 'Get' -Path '/web/v1/user' -Ctx $Ctx
	if ($res.code -eq 0) { return $res.data }
	Out-Log -Level 'WARN' -Message "Skland user error ($($res.code)): $($res.message)"
	return $null
}

function Find-SklandNickname {
	param($UserData)
	if ($UserData) {
		if ($UserData.user -and $UserData.user.nickname) { return $UserData.user.nickname }
	}
	return $null
}

function Find-SklandUserId {
	param($UserData)
	if ($UserData) {
		if ($UserData.user -and $UserData.user.id) { return $UserData.user.id }
	}
	return $null
}

function Find-SklandRoles {
	param($BindingData)
	if (-not $BindingData.list) { return @() }

	$roles = @()
	foreach ($app in $BindingData.list) {
		if (-not $app.bindingList) { continue }
		foreach ($binding in $app.bindingList) {
			# Match skland-kit behavior:
			# - endfield: one attendance per role
			# - arknights/others: one attendance per binding profile (official/bilibili split is here)
			if ($app.appCode -eq 'endfield' -and $binding.roles -and $binding.roles.Count -gt 0) {
				$seenEndfield = @{}
				foreach ($role in $binding.roles) {
					$key = "$($app.appCode)|$($binding.uid)|$($role.roleId)|$($role.serverId)"
					if ($seenEndfield[$key]) { continue }
					$seenEndfield[$key] = $true
					$roles += @{
						appCode    = $app.appCode
						gameId     = $binding.gameId
						gameName   = Format-Text -Text $binding.gameName
						channelName = Format-Text -Text $binding.channelName
						channelMasterId = $binding.channelMasterId
						uid        = $binding.uid
						roleId     = $role.roleId
						serverId   = $role.serverId
						nickname   = Format-Text -Text $role.nickname
						serverName = Format-Text -Text $role.serverName
					}
				}
			}
			else {
				if ($binding.roles -and $binding.roles.Count -gt 1) {
					foreach ($role in $binding.roles) {
						$roles += @{
							appCode    = $app.appCode
							gameId     = $binding.gameId
							gameName   = Format-Text -Text $binding.gameName
							channelName = Format-Text -Text $binding.channelName
							channelMasterId = $binding.channelMasterId
							uid        = $binding.uid
							roleId     = $role.roleId
							serverId   = $role.serverId
							nickname   = Format-Text -Text $role.nickname
							serverName = if ($role.serverName) { Format-Text -Text $role.serverName } else { Format-Text -Text $binding.channelName }
						}
					}
				}
				else {
					$roles += @{
						appCode    = $app.appCode
						gameId     = $binding.gameId
						gameName   = Format-Text -Text $binding.gameName
						channelName = Format-Text -Text $binding.channelName
						channelMasterId = $binding.channelMasterId
						uid        = $binding.uid
						roleId     = $null
						serverId   = $null
						nickname   = Format-Text -Text $binding.nickName
						serverName = Format-Text -Text $binding.channelName
					}
				}
			}
		}
	}
	return $roles
}

function Find-SklandAwardsText {
	param($Data, $Ctx)

	function Get-ShanghaiDateKeyFromUnixTs {
		param([long]$UnixTs)
		$dto = [DateTimeOffset]::FromUnixTimeSeconds($UnixTs)
		$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("China Standard Time")
		$local = [System.TimeZoneInfo]::ConvertTime($dto, $tz)
		return $local.ToString('yyyy-MM-dd')
	}

	function Get-ShanghaiTodayKey {
		$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("China Standard Time")
		$local = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $tz)
		return $local.ToString('yyyy-MM-dd')
	}

	function Format-RewardLine {
		param($Name, $Count)
		$safeName = if ($Name) { Format-Text -Text ([string]$Name) } else { "Unknown reward" }
		$safeCount = if ($Count) { $Count } else { 1 }
		return "$safeName x$safeCount"
	}

	$lang = if ($Ctx -and $Ctx.Config -and $Ctx.Config.lang) { [string]$Ctx.Config.lang } else { $null }
	if ($Ctx) {
		Ensure-SkEndfieldPublicResourceMap -Ctx $Ctx
	}

	# Arknights attendance POST result shape
	if ($Data.awards) {
		return (($Data.awards | ForEach-Object { Format-RewardLine -Name $_.resource.name -Count $_.count }) -join "`n")
	}

	# Arknights attendance status shape
	if ($Data.records -and $Data.resourceInfoMap) {
		$todayKey = Get-ShanghaiTodayKey
		$todayRecords = @()
		foreach ($record in $Data.records) {
			if (-not $record.ts) { continue }
			$recordDate = Get-ShanghaiDateKeyFromUnixTs -UnixTs ([long]$record.ts)
			if ($recordDate -eq $todayKey) {
				$todayRecords += $record
			}
		}
		if ($todayRecords.Count -gt 0) {
			$lines = @()
			foreach ($record in $todayRecords) {
				$info = $Data.resourceInfoMap.$($record.resourceId)
				$name = if ($info) { $info.name } else { $null }
				if (-not $name) { $name = Find-SkEndfieldResourceNameFallback -ResourceId $record.resourceId -Language $lang }
				$lines += Format-RewardLine -Name $name -Count $record.count
			}
			if ($lines.Count -gt 0) { return ($lines -join "`n") }
		}
	}

	# Endfield attendance status shape (already checked-in path):
	# only show current-day resolvable reward(s), do not dump historical calendar entries.
	if ($Data.hasToday -ne $null -and $Data.calendar -and $Data.resourceInfoMap) {
		$candidates = @()
		$candidates += @($Data.first | Where-Object { $_.done })
		$candidates += @($Data.calendar | Where-Object { $_.done } | Select-Object -Last 1)

		$lines = @()
		foreach ($item in $candidates) {
			if (-not $item) { continue }
			$awardId = if ($item.awardId) { $item.awardId } elseif ($item.resourceId) { $item.resourceId } else { $null }
			if (-not $awardId) { continue }
			$info = $Data.resourceInfoMap.$awardId
			$name = $null
			if ($info -and $info.name) { $name = $info.name }
			if (-not $name) { $name = Find-SkEndfieldResourceNameFallback -ResourceId $awardId -Language $lang }
			if (-not $name) { continue }
			$count = if ($item.count) { $item.count } elseif ($info.count) { $info.count } else { 1 }
			$line = Format-RewardLine -Name $name -Count $count
			if ($lines -notcontains $line) { $lines += $line }
		}
		if ($lines.Count -gt 0) { return ($lines -join "`n") }
	}

	# Endfield attendance POST result shape
	if ($Data.awardIds -and $Data.resourceInfoMap) {
		$items = @()
		foreach ($award in $Data.awardIds) {
			$info = $Data.resourceInfoMap.$($award.id)
			$name = if ($info -and $info.name) { $info.name } else { $null }
			if (-not $name) { $name = Find-SkEndfieldResourceNameFallback -ResourceId $award.id -Language $lang }
			if (-not $name) { continue }
			$count = if ($info -and $info.count) { $info.count } else { 1 }
			$items += Format-RewardLine -Name $name -Count $count
		}
		if ($items.Count -gt 0) { return ($items -join "`n") }
	}

	return ""
}

function Invoke-SklandAttendance {
	param($Profiie, $Config, $Embed, $IsReusing)

	if (-not $Profiie.token) {
		Out-Log -Level 'ERROR' -Message 'Skland profile missing token.'
		$Embed.fields += @{ 'name' = "Skland"; 'value' = "Missing token"; 'inline' = $true }
		return @{ NeedPing = $true }
	}

	if ($Config.games.Count -eq 0) {
		Out-Log -Level 'ERROR' -Message "No Skland games configured."
		return $null
	}

	$ctx = @{
		PassportToken = $Profiie.token; Cred = $null; Token = $null; TimeOffset = 0; DId = (New-SklandDid);
		SkGameRole = $null; Config = $Config; GameConfig = $Config.games[0]
	}

	if (-not (New-SklandCred -Ctx $ctx)) {
		$Embed.fields += @{ 'name' = "Skland"; 'value' = "Failed to initialize cred/token"; 'inline' = $true }
		return @{ NeedPing = $true }
	}
	[void](New-SklandToken -Ctx $ctx)

	$userData = Get-SklandUser -Ctx $ctx
	$nickname = Find-SklandNickname -UserData $userData
	$userId = Find-SklandUserId -UserData $userData

	$bindingData = Get-SklandBinding -Ctx $ctx
	$roles = Find-SklandRoles -BindingData $bindingData
	if ($roles.Count -eq 0) {
		Out-Log -Level 'WARN' -Message "No bound roles found for Skland user."
		$Embed.fields += @{ 'name' = "Skland"; 'value' = "No bound roles found"; 'inline' = $true }
		return $null
	}

	$Embed.title = if ($nickname) { (Format-Text -Text $nickname) } else { "Unknown Skland User" }
	$Embed.description = ""
	if ($null -ne $userId) { $Embed.description = "ID: ||$userId||" }
	$Embed.color = '5635840'
	$any_ping = $false

	foreach ($role in $roles) {
		$game = $Config.games | Where-Object { $_.app_code -eq $role.appCode } | Select-Object -First 1
		if (-not $game) { continue }

		$roleCtx = @{
			PassportToken = $ctx.PassportToken; Cred = $ctx.Cred; Token = $ctx.Token; TimeOffset = $ctx.TimeOffset; DId = $ctx.DId;
			Config = $Config; GameConfig = $game; SkGameRole = $null
		}
		if ($role.roleId -and $role.serverId) { $roleCtx.SkGameRole = "$($role.gameId)_$($role.roleId)_$($role.serverId)" }
		$channelKey = if ($role.channelMasterId) { [string]$role.channelMasterId } elseif ($role.channelName) { [string]$role.channelName } else { "" }
		$fieldKey = "$($role.appCode)|$channelKey|$($role.uid)|$($role.roleId)|$($role.serverId)|$($role.serverName)"
		$fieldTitle = if ($game.name) { $game.name } elseif ($role.gameName) { $role.gameName } else { $role.appCode }
		$identityPrefix = if ($role.channelName -and ($role.serverName -notlike "*$($role.channelName)*")) { "$($role.channelName) / " } else { "" }
		$fieldIdentity = if ($role.serverName) { "$identityPrefix$($role.serverName) - $($role.nickname)" } elseif ($role.nickname) { "$identityPrefix$($role.nickname)" } else { "$identityPrefix$($role.uid)" }
		$logIdentity = if ([string]::IsNullOrWhiteSpace($fieldIdentity)) { $role.appCode } else { $fieldIdentity }
		$logTitle = if ([string]::IsNullOrWhiteSpace([string]$fieldTitle)) { $role.appCode } else { $fieldTitle }

		$resPost = $null
		$resGet = $null
		if ($role.appCode -eq 'endfield') {
			Out-Log -Level 'INFO' -Message "Checking in for $logIdentity ($logTitle)"
			$resPost = Invoke-SklandRequest -Method 'Post' -Path '/api/v1/game/endfield/attendance' -Ctx $roleCtx
			Out-Log -Level 'INFO' -Message "Checking status for $logIdentity ($logTitle)"
			$resGet = Invoke-SklandRequest -Method 'Get' -Path '/api/v1/game/endfield/attendance' -Ctx $roleCtx
		}
		else {
			$opt = @{ uid = $role.uid; gameId = $role.gameId }
			Out-Log -Level 'INFO' -Message "Checking in for $logIdentity ($logTitle)"
			$resPost = Invoke-SklandRequest -Method 'Post' -Path '/api/v1/game/attendance' -Body $opt -Ctx $roleCtx
			Out-Log -Level 'INFO' -Message "Checking status for $logIdentity ($logTitle)"
			$resGet = Invoke-SklandRequest -Method 'Get' -Path '/api/v1/game/attendance' -Ctx $roleCtx -Query $opt
		}

		$data = $null
		$isAlready = $false
		if ($resPost.code -eq 0) {
			$data = $resPost.data
		}
		elseif ($resGet.code -eq 0) {
			$data = $resGet.data
			if ($resGet.data.hasToday -or ($resGet.data.calendar | Where-Object { $_.done } | Select-Object -Last 1)) { $isAlready = $true }
		}
		else {
			$Embed.fields += @{ 'name' = $fieldTitle; 'value' = "$fieldIdentity`nERROR: $($resPost.code) $($resPost.message)"; 'inline' = $true; 'key' = $fieldKey }
			$any_ping = $true
			continue
		}

		$awardText = Find-SklandAwardsText -Data $data -Ctx $roleCtx
		if (($role.appCode -eq 'endfield') -and $isAlready -and [string]::IsNullOrWhiteSpace($awardText)) {
			$awardText = "Reward detail unavailable from Skland API for already-checked-in Endfield."
		}
		if ($isAlready) {
			Out-Log -Level 'INFO' -Message "[$fieldIdentity] Already checked in. Awards: $awardText"
		}
		else {
			Out-Log -Level 'INFO' -Message "[$fieldIdentity] Check-in success! Awards: $awardText"
		}
		$statusPrefix = if ($isAlready) { "[Already] " } else { "" }
		$fieldValue = "$fieldIdentity`n$statusPrefix$awardText"
		$Embed.fields += @{ 'name' = $fieldTitle; 'value' = $fieldValue; 'inline' = $true; 'key' = $fieldKey }
	}

	return @{ NeedPing = $any_ping }
}
