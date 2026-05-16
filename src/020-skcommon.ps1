####################
# skport / skland common
####################

function ConvertTo-SkLowerHex {
	param([byte[]]$Bytes)
	return [System.BitConverter]::ToString($Bytes).Replace('-', '').ToLower()
}

function Get-SkMd5Hex {
	param([string]$Text)
	$md5 = [System.Security.Cryptography.MD5]::Create()
	$bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
	return ConvertTo-SkLowerHex -Bytes $bytes
}

function Get-SkHmacSha256Hex {
	param([string]$Key, [string]$Text)
	$hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Key))
	$bytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
	return ConvertTo-SkLowerHex -Bytes $bytes
}

function ConvertTo-SkCompactJson {
	param($Value)
	if ($null -eq $Value) { return "" }
	if ($Value -is [string]) { return $Value }
	return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-SkSignature {
	param(
		[string]$Path,
		[string]$QueryString = "",
		[string]$Body = "",
		[string]$Timestamp,
		[string]$Token,
		[string]$Platform,
		[string]$VName,
		[string]$DId = ""
	)

	$signatureHeaders = [ordered]@{
		platform  = $Platform
		timestamp = $Timestamp
		dId       = $DId
		vName     = $VName
	}
	$signatureHeaderJson = ConvertTo-SkCompactJson -Value $signatureHeaders
	$raw = "$Path$QueryString$Body$Timestamp$signatureHeaderJson"
	Out-Log -Level 'DEBUG' -Message "Sk Signature Raw String: $raw"

	$hmacHex = Get-SkHmacSha256Hex -Key $Token -Text $raw
	$sign = Get-SkMd5Hex -Text $hmacHex
	Out-Log -Level 'DEBUG' -Message "Sk Signature: $sign"
	return $sign
}

function ConvertFrom-SkRequestError {
	param($ErrorRecord)

	$statusCode = 0
	if ($ErrorRecord.Exception.Response) {
		try { $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode }
		catch {}
	}
	$code = if ($statusCode -gt 0) { - $statusCode } else { -1 }
	$msg = if ($ErrorRecord.Exception.Message) { $ErrorRecord.Exception.Message } else { "Request Failed" }

	if ($ErrorRecord.Exception.Response) {
		try {
			$respBody = $null
			if ($ErrorRecord.Exception.Response.Content) {
				$respBody = $ErrorRecord.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
			}
			elseif ($ErrorRecord.Exception.Response.PSObject.Methods.Name -contains 'GetResponseStream') {
				$stream = $ErrorRecord.Exception.Response.GetResponseStream()
				if ($stream) {
					$reader = [System.IO.StreamReader]::new($stream)
					$respBody = $reader.ReadToEnd()
				}
			}
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

function New-SklandDid {
	return "B$([guid]::NewGuid().ToString('N'))"
}

if (-not $script:SkEndfieldResourceNameMapByLang) {
	$script:SkEndfieldResourceNameMapByLang = @{}
}

function Find-SkEndfieldResourceNameFallback {
	param([string]$ResourceId, [string]$Language)
	if (-not $ResourceId) { return $null }
	if ($Language -and $script:SkEndfieldResourceNameMapByLang.ContainsKey($Language)) {
		$langMap = $script:SkEndfieldResourceNameMapByLang[$Language]
		if ($langMap.ContainsKey($ResourceId)) { return $langMap[$ResourceId] }
	}
	return $null
}

function Update-SkEndfieldResourceNameMapByLang {
	param([string]$Language, $ResourceInfoMap)
	if (-not $Language -or -not $ResourceInfoMap) { return }
	if (-not $script:SkEndfieldResourceNameMapByLang.ContainsKey($Language)) {
		$script:SkEndfieldResourceNameMapByLang[$Language] = @{}
	}
	$langMap = $script:SkEndfieldResourceNameMapByLang[$Language]
	foreach ($prop in $ResourceInfoMap.PSObject.Properties) {
		$id = [string]$prop.Name
		$entry = $prop.Value
		if (-not $entry) { continue }
		$name = $entry.name
		if ($name -and ([string]$name).Trim().Length -gt 0) { $langMap[$id] = [string]$name }
	}
}

function Ensure-SkEndfieldPublicResourceMap {
	param($Ctx)
	if (-not $Ctx -or -not $Ctx.PlatformConfig) { return }
	$lang = if ($Ctx.PlatformConfig.lang) { [string]$Ctx.PlatformConfig.lang } else { "zh_Hans" }
	$mappedLang = if ($lang -eq 'zh_CN') { 'zh_Hans' } else { $lang }
	if ($script:SkEndfieldResourceNameMapByLang.ContainsKey($lang) -and $script:SkEndfieldResourceNameMapByLang[$lang].Count -gt 0) { return }

	try {
		$headers = @{
			'Accept' = '*/*'; 'Content-Type' = 'application/json'; 'sk-language' = $mappedLang
		}
		$params = @{
			Method = 'Get'; Uri = 'https://zonai.skport.com/web/v1/game/endfield/attendance'; Headers = $headers
			UserAgent = $Ctx.PlatformConfig.user_agent; ContentType = 'application/json'; ErrorAction = 'Stop'
		}
		$ret = Invoke-RestMethod @params
		if ($ret.code -eq 0 -and $ret.data -and $ret.data.resourceInfoMap) {
			Update-SkEndfieldResourceNameMapByLang -Language $mappedLang -ResourceInfoMap $ret.data.resourceInfoMap
			if ($mappedLang -ne $lang) {
				$script:SkEndfieldResourceNameMapByLang[$lang] = @{}
				foreach ($k in $script:SkEndfieldResourceNameMapByLang[$mappedLang].Keys) {
					$script:SkEndfieldResourceNameMapByLang[$lang][$k] = $script:SkEndfieldResourceNameMapByLang[$mappedLang][$k]
				}
			}
		}
	}
	catch {
		Out-Log -Level 'DEBUG' -Message "Failed loading public Endfield resource map for lang=${lang}(mapped=${mappedLang}): $($_.Exception.Message)"
	}
}

function Get-SkProviderProfile {
	param([string]$Provider)

	switch ($Provider) {
		'skport' {
			return @{
				name = 'skport'
				passport = $null
				auth = @{ mode = 'refresh' }
				paths = @{
					refresh = '/web/v1/auth/refresh'; user = '/web/v2/user'; binding = '/api/v1/game/player/binding'
					attendance = @{
						default = @{ post = '/web/v1/game/{app_code}/attendance'; get = '/web/v1/game/{app_code}/attendance'; body = 'none'; query = 'none' }
					}
				}
				user_extract = @{ nickname = 'user.basicUser.nickname'; id = 'user.basicUser.id' }
			}
		}
		'skland' {
			return @{
				name = 'skland'
				passport = @{ base_url = 'https://as.hypergryph.com'; grant = '/user/oauth2/v2/grant' }
				auth = @{ mode = 'passport_oauth'; appCode = '4ca99fa6b56cc2ba'; grantType = 0; kind = 1; credPath = '/web/v1/user/auth/generate_cred_by_code' }
				paths = @{
					refresh = '/web/v1/auth/refresh'; user = '/web/v1/user'; binding = '/api/v1/game/player/binding'
					attendance = @{
						default = @{ post = '/api/v1/game/attendance'; get = '/api/v1/game/attendance'; body = 'uid_gameId'; query = 'uid_gameId' }
						endfield = @{ post = '/api/v1/game/endfield/attendance'; get = '/api/v1/game/endfield/attendance'; body = 'none'; query = 'none' }
					}
				}
				user_extract = @{ nickname = 'user.nickname'; id = 'user.id' }
			}
		}
		default { throw "Unsupported SK provider: $Provider" }
	}
}

function Get-SkValueByPath {
	param($Data, [string]$Path)
	if (-not $Data -or [string]::IsNullOrWhiteSpace($Path)) { return $null }
	$curr = $Data
	foreach ($seg in $Path.Split('.')) {
		if ($null -eq $curr) { return $null }
		$curr = $curr.$seg
	}
	return $curr
}

function Invoke-SkPassportRequest {
	param($Method, [string]$Path, $Body, $Ctx)
	$uri = "$($Ctx.ProviderProfile.passport.base_url)$Path"
	$params = @{ Method = $Method; Uri = $uri; Headers = @{ 'Content-Type' = 'application/json' }; UserAgent = $Ctx.PlatformConfig.user_agent; ContentType = 'application/json'; ErrorAction = 'Stop' }
	if ($null -ne $Body -and $Body -ne '') { $params.Body = ConvertTo-SkCompactJson -Value $Body }
	try {
		$ret = Invoke-RestMethod @params
		Out-Log -Level 'DEBUG' -Message "[$($Ctx.ProviderProfile.name)-passport] ${Method} ${uri}: $($ret | ConvertTo-Json -Depth 10)"
		return $ret
	}
	catch { return ConvertFrom-SkRequestError -ErrorRecord $_ }
}

function Invoke-SkApiRequest {
	param($Method, [string]$Path, $Body, $Ctx, $Query)

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
		'Accept' = '*/*'; 'Accept-Language' = 'en-US,en;q=0.9'; 'Referer' = $Ctx.GameConfig.referer_url
		'Content-Type' = 'application/json'; 'sk-language' = $Ctx.PlatformConfig.lang
		'platform' = $Ctx.GameConfig.platform; 'vName' = $Ctx.GameConfig.vName
		'timestamp' = $currTs; 'Origin' = $Ctx.GameConfig.origin_url
		'Sec-Fetch-Dest' = 'empty'; 'Sec-Fetch-Mode' = 'cors'; 'Sec-Fetch-Site' = 'same-site'
	}
	if ($Ctx.DId) { $headers['dId'] = $Ctx.DId }
	if ($Ctx.Cred) { $headers['cred'] = $Ctx.Cred }
	if ($Ctx.SkGameRole) { $headers['sk-game-role'] = $Ctx.SkGameRole }
	if ($Ctx.Token -and $Path) {
		$headers['sign'] = Get-SkSignature -Path $Path -QueryString $queryString -Body $bodyText -Timestamp $currTs -Token $Ctx.Token -Platform $Ctx.GameConfig.platform -VName $Ctx.GameConfig.vName -DId $Ctx.DId
	}

	$params = @{ Method = $Method; Uri = $uri; Headers = $headers; UserAgent = $Ctx.PlatformConfig.user_agent; ContentType = 'application/json'; ErrorAction = 'Stop' }
	if ($Method -ne 'Get' -or ($bodyText -ne '')) { $params.Body = $bodyText }

	try {
		$ret = Invoke-RestMethod @params
		Out-Log -Level 'DEBUG' -Message "[$($Ctx.ProviderProfile.name)] ${Method} ${uri}: $($ret | ConvertTo-Json -Depth 10)"
		return $ret
	}
	catch { return ConvertFrom-SkRequestError -ErrorRecord $_ }
}

function Initialize-SkAuthState {
	param($Ctx)
	$mode = $Ctx.ProviderProfile.auth.mode
	if ($mode -eq 'refresh') {
		$res = Invoke-SkApiRequest -Method 'Get' -Path $Ctx.ProviderProfile.paths.refresh -Ctx $Ctx
		if ($res.code -ne 0) {
			Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) token refresh failed ($($res.code)): $($res.message)"
			return $false
		}
		$Ctx.Token = $res.data.token
		$Ctx.TimeOffset = [Int64]$res.timestamp - [DateTimeOffset]::Now.ToUnixTimeSeconds()
		return $true
	}

	$grantBody = @{ appCode = $Ctx.ProviderProfile.auth.appCode; token = $Ctx.Profile.token; type = $Ctx.ProviderProfile.auth.grantType }
	$grant = Invoke-SkPassportRequest -Method 'Post' -Path $Ctx.ProviderProfile.passport.grant -Body $grantBody -Ctx $Ctx
	if ($grant.status -ne 0 -or -not $grant.data.code) {
		Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) grant authorize code failed: $($grant.msg)"
		return $false
	}
	$authBody = @{ code = $grant.data.code; kind = $Ctx.ProviderProfile.auth.kind }
	$res = Invoke-SkApiRequest -Method 'Post' -Path $Ctx.ProviderProfile.auth.credPath -Body $authBody -Ctx $Ctx
	if ($res.code -ne 0) {
		Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) generate cred failed ($($res.code)): $($res.message)"
		return $false
	}
	$Ctx.Token = $res.data.token
	$Ctx.Cred = $res.data.cred
	$Ctx.TimeOffset = [Int64]$res.timestamp - [DateTimeOffset]::Now.ToUnixTimeSeconds()
	[void](Invoke-SkApiRequest -Method 'Get' -Path $Ctx.ProviderProfile.paths.refresh -Ctx $Ctx)
	return $true
}

function Get-SkUserData {
	param($Ctx)
	$res = Invoke-SkApiRequest -Method 'Get' -Path $Ctx.ProviderProfile.paths.user -Ctx $Ctx
	if ($res.code -eq 0) { return $res.data }
	Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) user error ($($res.code)): $($res.message)"
	return $null
}

function Get-SkBindingData {
	param($Ctx)
	$res = Invoke-SkApiRequest -Method 'Get' -Path $Ctx.ProviderProfile.paths.binding -Ctx $Ctx
	if ($res.code -eq 0) { return $res.data }
	Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) binding error ($($res.code)): $($res.message)"
	return $null
}

function Expand-SkRoles {
	param($BindingData, [string]$Provider)
	if (-not $BindingData.list) { return @() }
	$roles = @()
	foreach ($app in $BindingData.list) {
		if (-not $app.bindingList) { continue }
		foreach ($binding in $app.bindingList) {
			if ($Provider -eq 'skland') {
				if ($app.appCode -eq 'endfield' -and $binding.roles -and $binding.roles.Count -gt 0) {
					$seen = @{}
					foreach ($role in $binding.roles) {
						$key = "$($app.appCode)|$($binding.uid)|$($role.roleId)|$($role.serverId)"
						if ($seen[$key]) { continue }
						$seen[$key] = $true
						$roles += @{ appCode = $app.appCode; gameId = $binding.gameId; gameName = Format-Text -Text $binding.gameName; channelName = Format-Text -Text $binding.channelName; channelMasterId = $binding.channelMasterId; uid = $binding.uid; roleId = $role.roleId; serverId = $role.serverId; nickname = Format-Text -Text $role.nickname; serverName = Format-Text -Text $role.serverName }
					}
				}
				elseif ($binding.roles -and $binding.roles.Count -gt 1) {
					foreach ($role in $binding.roles) {
						$roles += @{ appCode = $app.appCode; gameId = $binding.gameId; gameName = Format-Text -Text $binding.gameName; channelName = Format-Text -Text $binding.channelName; channelMasterId = $binding.channelMasterId; uid = $binding.uid; roleId = $role.roleId; serverId = $role.serverId; nickname = Format-Text -Text $role.nickname; serverName = if ($role.serverName) { Format-Text -Text $role.serverName } else { Format-Text -Text $binding.channelName } }
					}
				}
				else {
					$roles += @{ appCode = $app.appCode; gameId = $binding.gameId; gameName = Format-Text -Text $binding.gameName; channelName = Format-Text -Text $binding.channelName; channelMasterId = $binding.channelMasterId; uid = $binding.uid; roleId = $null; serverId = $null; nickname = Format-Text -Text $binding.nickName; serverName = Format-Text -Text $binding.channelName }
				}
			}
			else {
				foreach ($role in $binding.roles) {
					$roles += @{ appCode = $app.appCode; gameId = $binding.gameId; roleId = $role.roleId; serverId = $role.serverId; nickname = Format-Text -Text $role.nickname; serverName = Format-Text -Text $role.serverName }
				}
			}
		}
	}
	return $roles
}

function Resolve-SkAttendanceEndpoints {
	param($Ctx, $Role)
	$att = $Ctx.ProviderProfile.paths.attendance
	if ($att.ContainsKey($Role.appCode)) { return $att[$Role.appCode] }
	return $att.default
}

function Build-SkIdentity {
	param($Role, $Game)
	$fieldTitle = if ($Game.name) { $Game.name } elseif ($Role.gameName) { $Role.gameName } else { $Role.appCode }
	$serverName = if ($Role.channelName -and ($Role.serverName -notlike "*$($Role.channelName)*")) { "$($Role.channelName) / " } else { "" }
	if ($Role.serverName) { $serverName += $Role.serverName }
	$nickname = $Role.nickname

	$fieldIdentity = if ($serverName) { "$serverName - $nickname" } else { $nickname }
	if ([string]::IsNullOrWhiteSpace($fieldIdentity)) { $fieldIdentity = $Role.appCode }
	return @{
		title = $fieldTitle
		identity = $fieldIdentity
		server_name = $serverName
		nickname = $nickname
	}
}

function Resolve-SkAwardLines {
	param($Data, $Ctx)
	function New-Line([string]$Name, $Count) {
		if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
		$safeName = Format-Text -Text $Name
		$safeCount = if ($Count) { $Count } else { 1 }
		return "$safeName x$safeCount"
	}

	$lang = if ($Ctx.PlatformConfig.lang) { [string]$Ctx.PlatformConfig.lang } else { $null }
	Ensure-SkEndfieldPublicResourceMap -Ctx $Ctx
	$lines = @()

	if ($Data.awards) {
		foreach ($a in $Data.awards) {
			$line = New-Line -Name $a.resource.name -Count $a.count
			if ($line) { $lines += $line }
		}
	}
	elseif ($Data.awardIds -and $Data.resourceInfoMap) {
		foreach ($award in $Data.awardIds) {
			$info = $Data.resourceInfoMap.$($award.id)
			$name = if ($info -and $info.name) { $info.name } else { Find-SkEndfieldResourceNameFallback -ResourceId $award.id -Language $lang }
			$line = New-Line -Name $name -Count $(if ($info -and $info.count) { $info.count } else { 1 })
			if ($line) { $lines += $line }
		}
	}
	elseif ($Data.records -and $Data.resourceInfoMap) {
		$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
		$today = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $tz).ToString('yyyy-MM-dd')
		foreach ($record in $Data.records) {
			if (-not $record.ts) { continue }
			$recordDate = [System.TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeSeconds([long]$record.ts), $tz).ToString('yyyy-MM-dd')
			if ($recordDate -ne $today) { continue }
			$info = $Data.resourceInfoMap.$($record.resourceId)
			$name = if ($info) { $info.name } else { Find-SkEndfieldResourceNameFallback -ResourceId $record.resourceId -Language $lang }
			$line = New-Line -Name $name -Count $record.count
			if ($line) { $lines += $line }
		}
	}
	elseif ($Data.calendar -and $Data.resourceInfoMap) {
		$candidates = @()
		$candidates += @($Data.first | Where-Object { $_.done })
		$candidates += @($Data.calendar | Where-Object { $_.done } | Select-Object -Last 1)
		foreach ($item in $candidates) {
			if (-not $item) { continue }
			$awardId = if ($item.awardId) { $item.awardId } elseif ($item.resourceId) { $item.resourceId } else { $null }
			if (-not $awardId) { continue }
			$info = $Data.resourceInfoMap.$awardId
			$name = if ($info -and $info.name) { $info.name } else { Find-SkEndfieldResourceNameFallback -ResourceId $awardId -Language $lang }
			$line = New-Line -Name $name -Count $(if ($item.count) { $item.count } elseif ($info.count) { $info.count } else { 1 })
			if ($line -and ($lines -notcontains $line)) { $lines += $line }
		}
	}

	if ($lines.Count -eq 0) {
		return @('Reward detail unavailable from provider API.')
	}
	return $lines
}

function Get-SkFieldKey {
	param($Role)
	$channelKey = if ($Role.channelMasterId) { [string]$Role.channelMasterId } elseif ($Role.channelName) { [string]$Role.channelName } else { '' }
	return "$($Role.appCode)|$channelKey|$($Role.uid)|$($Role.roleId)|$($Role.serverId)|$($Role.serverName)"
}

function Invoke-SkAttendanceCore {
	param(
		[string]$Provider,
		$Profile,
		$PlatformConfig,
		$Embed,
		[bool]$IsReusing
	)

	if (-not $PlatformConfig -or -not $PlatformConfig.games -or $PlatformConfig.games.Count -eq 0) {
		Out-Log -Level 'ERROR' -Message "No ${Provider} games configured."
		return $null
	}
	if ($Provider -eq 'skport' -and -not $Profile.cred) {
		Out-Log -Level 'ERROR' -Message 'Skport profile missing cred.'
		$Embed.fields += @{ 'name' = 'Skport'; 'value' = 'Missing cred'; 'inline' = $true }
		return @{ NeedPing = $true }
	}
	if ($Provider -eq 'skland' -and -not $Profile.token) {
		Out-Log -Level 'ERROR' -Message 'Skland profile missing token.'
		$Embed.fields += @{ 'name' = 'Skland'; 'value' = 'Missing token'; 'inline' = $true }
		return @{ NeedPing = $true }
	}

	$providerProfile = Get-SkProviderProfile -Provider $Provider
	$ctx = @{ Profile = $Profile; ProviderProfile = $providerProfile; PlatformConfig = $PlatformConfig; GameConfig = $PlatformConfig.games[0]; Cred = $Profile.cred; Token = $null; TimeOffset = 0; DId = if ($Provider -eq 'skland') { New-SklandDid } else { '' }; SkGameRole = $null }
	if (-not (Initialize-SkAuthState -Ctx $ctx)) {
		$Embed.fields += @{ 'name' = ("{0}" -f ($Provider.Substring(0,1).ToUpper() + $Provider.Substring(1))); 'value' = 'Failed to initialize auth state'; 'inline' = $true }
		return @{ NeedPing = $true }
	}

	$userData = Get-SkUserData -Ctx $ctx
	$nickname = Get-SkValueByPath -Data $userData -Path $providerProfile.user_extract.nickname
	$userId = Get-SkValueByPath -Data $userData -Path $providerProfile.user_extract.id
	$Embed.title = if ($nickname) { Format-Text -Text $nickname } else { "Unknown $Provider User" }
	$Embed.description = if ($null -ne $userId) { "ID: ||$userId||" } else { '' }
	$Embed.color = '5635840'

	$bindingData = Get-SkBindingData -Ctx $ctx
	$roles = Expand-SkRoles -BindingData $bindingData -Provider $Provider
	if ($roles.Count -eq 0) {
		Out-Log -Level 'WARN' -Message "No bound roles found for $Provider user."
		$Embed.fields += @{ 'name' = ("{0}" -f ($Provider.Substring(0,1).ToUpper() + $Provider.Substring(1))); 'value' = 'No bound roles found'; 'inline' = $true }
		return $null
	}

	$anyPing = $false
	foreach ($role in $roles) {
		$game = $PlatformConfig.games | Where-Object { $_.app_code -eq $role.appCode } | Select-Object -First 1
		if (-not $game) { continue }
		$roleCtx = @{ Profile = $Profile; ProviderProfile = $providerProfile; PlatformConfig = $PlatformConfig; GameConfig = $game; Cred = $ctx.Cred; Token = $ctx.Token; TimeOffset = $ctx.TimeOffset; DId = $ctx.DId; SkGameRole = $null }
		if ($role.roleId -and $role.serverId) { $roleCtx.SkGameRole = "$($role.gameId)_$($role.roleId)_$($role.serverId)" }

		$ident = Build-SkIdentity -Role $role -Game $game
		$fieldKey = Get-SkFieldKey -Role $role
		$ep = Resolve-SkAttendanceEndpoints -Ctx $roleCtx -Role $role
		$postPath = $ep.post.Replace('{app_code}', $game.app_code)
		$getPath = $ep.get.Replace('{app_code}', $game.app_code)
		$body = if ($ep.body -eq 'uid_gameId') { @{ uid = $role.uid; gameId = $role.gameId } } else { '' }
		$query = if ($ep.query -eq 'uid_gameId') { @{ uid = $role.uid; gameId = $role.gameId } } else { $null }

		Out-Log -Level 'INFO' -Message "Checking in for $($ident.identity) ($($ident.title))"
		$resPost = Invoke-SkApiRequest -Method 'Post' -Path $postPath -Body $body -Ctx $roleCtx
		Out-Log -Level 'INFO' -Message "Checking status for $($ident.identity) ($($ident.title))"
		$resGet = Invoke-SkApiRequest -Method 'Get' -Path $getPath -Ctx $roleCtx -Query $query

		$data = $null
		$isAlready = $false
		if ($resPost.code -eq 0) { $data = $resPost.data }
		elseif ($resGet.code -eq 0) {
			$data = $resGet.data
			$isAlready = [bool]$resGet.data.hasToday
			if (-not $isAlready -and $resGet.data.calendar) { $isAlready = [bool]($resGet.data.calendar | Where-Object { $_.done } | Select-Object -Last 1) }
		}
		else {
			Out-Log -Level 'ERROR' -Message "[$($ident.identity)] Error (Code: $($resPost.code)): $($resPost.message)"
			$Embed.fields += @{ 'name' = $ident.title; 'value' = "$($ident.identity)`nERROR: $($resPost.code) $($resPost.message)"; 'inline' = $true; 'key' = $fieldKey }
			$anyPing = $true
			continue
		}

		$awardLines = Resolve-SkAwardLines -Data $data -Ctx $roleCtx
		$awardText = $awardLines -join "`n"
		if ($isAlready) {
			Out-Log -Level 'INFO' -Message "[$($ident.identity)] Already checked in. Awards: $awardText"
		}
		else {
			Out-Log -Level 'INFO' -Message "[$($ident.identity)] Check-in success! Awards: $awardText"
		}
		if (-not $IsReusing -or -not $isAlready) {
			$Embed.fields += @{ 'name' = $ident.title; 'value' = "*$($ident.server_name)* - $($ident.nickname)`n$awardText"; 'inline' = $true; 'key' = $fieldKey }
		}
	}

	return @{ NeedPing = $anyPing }
}
