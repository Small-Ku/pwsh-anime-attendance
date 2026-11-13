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
	$diagnostic = @{
		Status = $statusCode
		BodyKind = 'unavailable'
		Edge = 'unknown'
		Challenge = $false
	}

	if ($ErrorRecord.Exception.Response) {
		# Preserve safe transport diagnostics, not raw HTML/cookies/tokens or
		# request headers. HTTP 403 may come from the gateway instead of Skland.
		$response = $ErrorRecord.Exception.Response
		try {
			$contentType = [string]$response.Content.Headers.ContentType.MediaType
			if (-not $contentType) { $contentType = [string]$response.ContentType }
			if ($contentType -match 'json') { $diagnostic.BodyKind = 'json' }
			elseif ($contentType -match 'html') { $diagnostic.BodyKind = 'html' }
			elseif ($contentType -match 'text') { $diagnostic.BodyKind = 'text' }
		}
		catch {}
		try {
			$headers = $response.Headers
			if ($headers) {
				if ($headers.ToString() -match '(?im)^cf-ray\s*:') { $diagnostic.Edge = 'cloudflare' }
				elseif ($headers.ToString() -match '(?im)^server\s*:\s*cloudflare') { $diagnostic.Edge = 'cloudflare' }
			}
		}
		catch {}
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
			# PowerShell may have consumed the failed response body before
			# throwing. In that case ErrorDetails.Message retains the JSON.
			if (-not $respBody -and $ErrorRecord.ErrorDetails.Message) {
				$respBody = [string]$ErrorRecord.ErrorDetails.Message
			}
			if ($respBody) {
				if ($respBody -match '(?i)cloudflare|cf[-_]ray|challenge-platform|error\s*1020|access\s*denied') {
					$diagnostic.Challenge = $true
					if ($respBody -match '(?i)cloudflare|cf[-_]ray|challenge-platform') { $diagnostic.Edge = 'cloudflare' }
				}
				$json = $respBody | ConvertFrom-Json -ErrorAction SilentlyContinue
				if ($json) {
					$diagnostic.ResponseFields = @($json.PSObject.Properties.Name | Where-Object { $_ -in @(
						'code', 'status', 'statusCode', 'message', 'msg', 'error', 'error_description', 'detail', 'reason', 'data', 'success'
					) })
					$errorText = @($json.message, $json.msg, $json.error, $json.error_description, $json.reason) |
						Where-Object { $_ -is [string] } | Select-Object -First 1
					if ($errorText -match '(?i)already|signed|\u5df2\u7b7e\u5230|\u5df2\u7c3d\u5230') { $diagnostic.ReasonClass = 'already-signed' }
					elseif ($errorText -match '(?i)sign|signature|\u7b7e\u540d|\u7c3d\u540d') { $diagnostic.ReasonClass = 'signature' }
					elseif ($errorText -match '(?i)risk|captcha|challenge|verify|\u98ce\u63a7|\u98a8\u63a7') { $diagnostic.ReasonClass = 'risk-or-challenge' }
					elseif ($errorText -match '(?i)role|channel|account|uid|\u89d2\u8272|\u6e20\u9053') { $diagnostic.ReasonClass = 'role-or-account' }
					elseif ($errorText -match '(?i)forbidden|permission|denied|access|\u6388\u6743|\u6388\u6b0a') { $diagnostic.ReasonClass = 'permission' }
					elseif ($errorText -match '(?i)device|dId|\u8bbe\u5907|\u8a2d\u5099') { $diagnostic.ReasonClass = 'device' }
					elseif ($errorText -match '(?i)frequency|frequent|limit|\u9891\u7e41|\u983b\u7e41') { $diagnostic.ReasonClass = 'frequency' }
					elseif ($errorText -match '(?i)request|parameter|payload|invalid|\u53c2\u6570|\u53c3\u6578') { $diagnostic.ReasonClass = 'invalid-request' }
					elseif ($errorText) { $diagnostic.ReasonClass = 'unclassified' }
					else { $diagnostic.ReasonClass = 'missing' }
				}
				if ($null -ne $json -and $null -ne $json.code) {
					$json | Add-Member -NotePropertyName __HttpStatus -NotePropertyValue $statusCode -Force
					$json | Add-Member -NotePropertyName __TransportDiagnostic -NotePropertyValue $diagnostic -Force
					return $json
				}
				if ($json -and $json.message) { $msg = $json.message }
			}
		}
		catch {}
	}

	return @{ code = $code; message = $msg; __TransportFailure = $true; __HttpStatus = $statusCode; __TransportDiagnostic = $diagnostic }
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
				passport = @{
					base_url = 'https://as.hypergryph.com'; grant = '/user/oauth2/v2/grant'
					user_agent = 'Mozilla/5.0 (Linux; Android 12; SM-A5560 Build/V417IR; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/101.0.4951.61 Safari/537.36 SKLand/1.52.1'
					x_requested_with = 'com.hypergryph.skland'
				}
				auth = @{
					mode = 'passport_oauth'; appCode = '4ca99fa6b56cc2ba'; grantType = 0; kind = 1; credPath = '/web/v1/user/auth/generate_cred_by_code'
					platform = '3'; vName = '1.0.0'; origin = 'https://www.skland.com'; referer = 'https://www.skland.com/'
					user_agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36'
				}
				signature = @{
					platform = '3'; vName = '1.0.0'
					arknightsUserAgent = 'Skland/1.5.1 (com.hypergryph.skland; build:100501001; Android 34; ) Okhttp/4.11.0'
				}
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

function Resolve-SkPassportToken {
	param($Token)
	if ($null -eq $Token) { return $null }

	$tokenText = ([string]$Token).Trim()
	if ([string]::IsNullOrWhiteSpace($tokenText)) { return $tokenText }
	try {
		$parsed = $tokenText | ConvertFrom-Json -ErrorAction 'Stop'
		if ($parsed.data -and $parsed.data.content -is [string]) { return $parsed.data.content }
	}
	catch { $parsed = $null }
	return $tokenText
}

function Invoke-SkPassportRequest {
	param($Method, [string]$Path, $Body, $Ctx)

	$uri = "$($Ctx.ProviderProfile.passport.base_url)$Path"
	$headers = @{ 'Content-Type' = 'application/json' }
	$userAgent = $Ctx.PlatformConfig.user_agent
	if ($Ctx.ProviderProfile.passport.user_agent) { $userAgent = $Ctx.ProviderProfile.passport.user_agent }
	if ($Ctx.DId) { $headers['dId'] = $Ctx.DId }
	if ($Ctx.ProviderProfile.passport.x_requested_with) { $headers['x-requested-with'] = $Ctx.ProviderProfile.passport.x_requested_with }

	$params = @{ Method = $Method; Uri = $uri; Headers = $headers; UserAgent = $userAgent; ContentType = 'application/json'; ErrorAction = 'Stop' }
	if ($null -ne $Body -and $Body -ne '') { $params.Body = ConvertTo-SkCompactJson -Value $Body }
	try {
		$ret = Invoke-RestMethod @params
		Out-Log -Level 'DEBUG' -Message "[$($Ctx.ProviderProfile.name)-passport] ${Method} ${uri}: $(Format-LogObject -InputObject $ret)"
		return $ret
	}
	catch { return ConvertFrom-SkRequestError -ErrorRecord $_ }
}

function Get-SkGameSignatureOptions {
	param($Ctx, [string]$Path)

	if ($Ctx.ProviderProfile.name -ne 'skland') { return $null }
	# The game-specific app version belongs to the signed request contract.
	# The existing user config may already track a newer Skland 1.x release.
	if ($Ctx.GameConfig.app_code -eq 'arknights' -and $Path -eq '/api/v1/game/attendance') {
		# The Arknights attendance API uses the Skland app request profile,
		# distinct from Endfield's web profile. Cred generation continues to
		# use the separately configured passport user agent and device ID.
		return @{
			platform = '1'
			vName = '1.5.1'
			dId = [string]$Ctx.DId
			userAgent = [string]$Ctx.ProviderProfile.signature.arknightsUserAgent
			appRequest = $true
		}
	}
	if ($Ctx.GameConfig.app_code -eq 'endfield' -and $Path -eq '/api/v1/game/endfield/attendance') {
		return @{ platform = '3'; vName = '1.0.0'; dId = '' }
	}
	return $null
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

	$platform = $Ctx.GameConfig.platform
	$vName = $Ctx.GameConfig.vName
	if ($Ctx.ProviderProfile.signature) {
		if ($Ctx.ProviderProfile.signature.platform) { $platform = $Ctx.ProviderProfile.signature.platform }
		if ($Ctx.ProviderProfile.signature.vName) { $vName = $Ctx.ProviderProfile.signature.vName }
	}

	$referer = $Ctx.GameConfig.referer_url
	$origin = $Ctx.GameConfig.origin_url
	$userAgent = $Ctx.PlatformConfig.user_agent
	$requestDId = $Ctx.DId
	$sendEmptyDId = $false
	$isAppAttendanceRequest = $false
	$isAuthWebRequest = $false
	if ($Ctx.ProviderProfile.auth -and $Ctx.ProviderProfile.auth.user_agent) {
		$isAuthWebRequest = ($Path -eq $Ctx.ProviderProfile.auth.credPath) -or ($Path -eq $Ctx.ProviderProfile.paths.refresh)
	}
	if ($isAuthWebRequest) {
		$platform = $Ctx.ProviderProfile.auth.platform
		$vName = $Ctx.ProviderProfile.auth.vName
		$referer = $Ctx.ProviderProfile.auth.referer
		$origin = $Ctx.ProviderProfile.auth.origin
		$userAgent = $Ctx.ProviderProfile.auth.user_agent
	}
	elseif ($gameSignature = Get-SkGameSignatureOptions -Ctx $Ctx -Path $Path) {
		$platform = $gameSignature.platform
		$vName = $gameSignature.vName
		if ($gameSignature.ContainsKey('dId')) {
			$requestDId = $gameSignature.dId
			$sendEmptyDId = $true
		}
		if ($gameSignature.appRequest) {
			$isAppAttendanceRequest = $true
			$userAgent = $gameSignature.userAgent
		}
	}

	$currTs = ([DateTimeOffset]::Now.ToUnixTimeSeconds() + $Ctx.TimeOffset).ToString()
	$bodyText = ConvertTo-SkCompactJson -Value $Body
	$headers = @{
		'Accept' = '*/*'; 'Accept-Language' = 'en-US,en;q=0.9'; 'Referer' = $referer
		'Content-Type' = 'application/json'; 'sk-language' = $Ctx.PlatformConfig.lang
		'platform' = $platform; 'vName' = $vName
		'timestamp' = $currTs; 'Origin' = $origin
		'Sec-Fetch-Dest' = 'empty'; 'Sec-Fetch-Mode' = 'cors'; 'Sec-Fetch-Site' = 'same-site'
	}
	if ($isAppAttendanceRequest) {
		# Do not claim to be a browser CORS request while presenting an
		# Android Skland app identity to the attendance endpoint.
		foreach ($header in @('Origin', 'Referer', 'Sec-Fetch-Dest', 'Sec-Fetch-Mode', 'Sec-Fetch-Site')) {
			[void]$headers.Remove($header)
		}
	}
	if ($requestDId -or $sendEmptyDId) { $headers['dId'] = [string]$requestDId }
	if ($Ctx.Cred) { $headers['cred'] = $Ctx.Cred }
	if ($Ctx.SkGameRole) { $headers['sk-game-role'] = $Ctx.SkGameRole }
	if ($Ctx.ProviderProfile.passport.x_requested_with -and $Path -ne $Ctx.ProviderProfile.auth.credPath) { $headers['x-requested-with'] = $Ctx.ProviderProfile.passport.x_requested_with }
	if ($Ctx.Token -and $Path) {
		$headers['sign'] = Get-SkSignature -Path $Path -QueryString $queryString -Body $bodyText -Timestamp $currTs -Token $Ctx.Token -Platform $platform -VName $vName -DId $requestDId
	}

	$params = @{ Method = $Method; Uri = $uri; Headers = $headers; UserAgent = $userAgent; ContentType = 'application/json'; ErrorAction = 'Stop' }
	if ($Method -ne 'Get' -or ($bodyText -ne '')) { $params.Body = $bodyText }
	# The provider returns HTTP 403 *with a valid JSON body* for its
	# AlreadySigned (10001) outcome. On PowerShell 7, parse that body normally
	# rather than losing it in the exception path and inventing code -403.
	# PowerShell 5.1 lacks SkipHttpErrorCheck and retains the error parser.
	if ($PSVersionTable.PSVersion.Major -ge 7 -and $Ctx.ProviderProfile.name -eq 'skland' -and
		$Method -eq 'Post' -and $Path -eq '/api/v1/game/attendance') {
		$params.SkipHttpErrorCheck = $true
	}

	try {
		$ret = Invoke-RestMethod @params
		Out-Log -Level 'DEBUG' -Message "[$($Ctx.ProviderProfile.name)] ${Method} ${uri}: $(Format-LogObject -InputObject $ret)"
		return $ret
	}
	catch {
		$failure = ConvertFrom-SkRequestError -ErrorRecord $_
		if ($failure.__TransportDiagnostic) {
			$script:SkLastHttpDiagnostic = $failure.__TransportDiagnostic
		}
		return $failure
	}
}

function Test-SkAuthenticationRejection {
	param($Response)
	if ($null -eq $Response) { return $false }
	return (($Response.__HttpStatus -eq 401) -or ($Response.code -eq 10000))
}

function Invoke-SkAuthorizedApiRequest {
	param($Method, [string]$Path, $Body, $Ctx, $Query)

	$response = Invoke-SkApiRequest -Method $Method -Path $Path -Body $Body -Ctx $Ctx -Query $Query
	if ($Ctx.ProviderProfile.name -ne 'skport' -or
		$Path -eq $Ctx.ProviderProfile.paths.refresh -or
		-not (Test-SkAuthenticationRejection -Response $response)) {
		return $response
	}
	# A 401 means the server did not accept this operation. Refresh once,
	# then retry exactly once. Never retry a POST after an ambiguous timeout.
	Out-Log -Level 'WARN' -Message 'Skport rejected authentication. Refreshing token and retrying once.'
	if (-not (Initialize-SkAuthState -Ctx $Ctx)) { return $response }
	return Invoke-SkApiRequest -Method $Method -Path $Path -Body $Body -Ctx $Ctx -Query $Query
}
function Initialize-SkAuthState {
	param($Ctx)
	$Ctx.LastAuthFailure = $null
	$mode = $Ctx.ProviderProfile.auth.mode
	if ($mode -eq 'refresh') {
		$res = Invoke-SkApiRequest -Method 'Get' -Path $Ctx.ProviderProfile.paths.refresh -Ctx $Ctx
		if ($res.code -ne 0) {
			$Ctx.LastAuthFailure = @{ Stage = 'refresh'; Code = $res.code; Message = [string]$res.message; Response = $res }
			Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) token refresh failed ($($res.code)): $($res.message)"
			return $false
		}
		$Ctx.Token = $res.data.token
		$Ctx.TimeOffset = [Int64]$res.timestamp - [DateTimeOffset]::Now.ToUnixTimeSeconds()
		return $true
	}

	$grantBody = @{ appCode = $Ctx.ProviderProfile.auth.appCode; token = Resolve-SkPassportToken -Token $Ctx.Profile.token; type = $Ctx.ProviderProfile.auth.grantType }
	$grant = Invoke-SkPassportRequest -Method 'Post' -Path $Ctx.ProviderProfile.passport.grant -Body $grantBody -Ctx $Ctx
	if ($grant.status -ne 0 -or -not $grant.data.code) {
		$errMsg = if ($grant.msg) { $grant.msg } elseif ($grant.message) { $grant.message } elseif ($grant.error) { $grant.error } else { 'Unknown error' }
		$Ctx.LastAuthFailure = @{ Stage = 'passport_grant'; Code = $grant.status; Message = [string]$errMsg; Response = $grant }
		Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) grant authorize code failed: $errMsg"
		return $false
	}
	$authBody = @{ code = $grant.data.code; kind = $Ctx.ProviderProfile.auth.kind }
	$res = Invoke-SkApiRequest -Method 'Post' -Path $Ctx.ProviderProfile.auth.credPath -Body $authBody -Ctx $Ctx
	if ($res.code -ne 0) {
		$errMsg = if ($res.msg) { $res.msg } elseif ($res.message) { $res.message } elseif ($res.error) { $res.error } else { 'Unknown error' }
		$Ctx.LastAuthFailure = @{ Stage = 'generate_cred'; Code = $res.code; Message = [string]$errMsg; Response = $res }
		Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) generate cred failed ($($res.code)): $($res.message)"
		return $false
	}
	$Ctx.Token = $res.data.token
	$Ctx.Cred = $res.data.cred
	$Ctx.TimeOffset = [Int64]$res.timestamp - [DateTimeOffset]::Now.ToUnixTimeSeconds()
	[void](Invoke-SkApiRequest -Method 'Get' -Path $Ctx.ProviderProfile.paths.refresh -Ctx $Ctx)
	return $true
}

function Get-SkDataResult {
	param($Ctx, [string]$Path, [string]$Operation)
	$res = Invoke-SkAuthorizedApiRequest -Method 'Get' -Path $Path -Ctx $Ctx
	if ($null -eq $res -or $null -eq $res.code) {
		return [pscustomobject]@{ Kind = 'Failure'; Reason = 'InvalidResponse'; Message = "$Operation response missing code"; Data = $null }
	}
	if ($res.code -ne 0) {
		$reason = if (Test-SkAuthenticationRejection -Response $res) { 'AuthenticationFailed' } elseif ($res.__HttpStatus -gt 0) { 'HttpError' } elseif ($res.__TransportFailure) { 'TransportError' } else { 'ProviderRejected' }
		Out-Log -Level 'WARN' -Message "$($Ctx.ProviderProfile.name) $Operation failed (code $($res.code))"
		return [pscustomobject]@{ Kind = 'Failure'; Reason = $reason; Message = "$Operation failed (code $($res.code))"; Data = $null }
	}
	if ($null -eq $res.data) {
		return [pscustomobject]@{ Kind = 'Failure'; Reason = 'InvalidResponse'; Message = "$Operation response missing data"; Data = $null }
	}
	return [pscustomobject]@{ Kind = 'Success'; Reason = ''; Message = ''; Data = $res.data }
}

function Get-SkUserData {
	param($Ctx)
	return Get-SkDataResult -Ctx $Ctx -Path $Ctx.ProviderProfile.paths.user -Operation 'User lookup'
}

function Get-SkBindingData {
	param($Ctx)
	return Get-SkDataResult -Ctx $Ctx -Path $Ctx.ProviderProfile.paths.binding -Operation 'Binding lookup'
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
				foreach ($role in @($binding.roles)) {
					$roles += @{
						appCode = $app.appCode
						gameId = $binding.gameId
						gameName = Format-Text -Text $binding.gameName
						channelName = Format-Text -Text $binding.channelName
						channelMasterId = $binding.channelMasterId
						uid = $binding.uid
						roleId = $role.roleId
						serverId = $role.serverId
						nickname = Format-Text -Text $role.nickname
						serverName = Format-Text -Text $role.serverName
					}
				}
			}
		}
	}
	return $roles
}

function Get-SkAttendanceState {
	param(
		[string]$Provider,
		[string]$AppCode,
		$Response
	)

	if ($null -eq $Response -or $Response.code -ne 0 -or $null -eq $Response.data) { return 'Unknown' }
	$data = $Response.data
	if ($Provider -eq 'skland' -and $AppCode -eq 'arknights') {
		# Arknights returns calendar[] and records[], not Endfield's hasToday.
		# Use the API server's currentTs and the game's UTC+8 calendar day.
		$serverTs = 0L
		if (-not [long]::TryParse([string]$data.currentTs, [ref]$serverTs) -or $serverTs -le 0) { return 'Unknown' }
		try { $serverDay = [DateTimeOffset]::FromUnixTimeSeconds($serverTs).ToOffset([TimeSpan]::FromHours(8)) }
		catch { return 'Unknown' }

		$today = $serverDay.Date
		foreach ($record in @($data.records)) {
			if ($null -eq $record) { continue }
			$recordTs = 0L
			if (-not [long]::TryParse([string]$record.ts, [ref]$recordTs) -or $recordTs -le 0) { continue }
			try {
				if ([DateTimeOffset]::FromUnixTimeSeconds($recordTs).ToOffset([TimeSpan]::FromHours(8)).Date -eq $today) {
					return 'Signed'
				}
			}
			catch { continue }
		}

		$calendar = @($data.calendar)
		if ($calendar.Count -ge $serverDay.Day) {
			$todayEntry = $calendar[$serverDay.Day - 1]
			if ($null -ne $todayEntry -and $todayEntry.done -is [bool]) {
				return $(if ($todayEntry.done) { 'Signed' } else { 'NotSigned' })
			}
		}
		return 'Unknown'
	}

	if ($null -eq $data.hasToday -or $data.hasToday -isnot [bool]) { return 'Unknown' }
	return $(if ($data.hasToday) { 'Signed' } else { 'NotSigned' })
}
function Test-SkAlreadySignedResponse {
	param(
		[string]$Provider,
		[string]$AppCode,
		$Response
	)

	# Arknights can return provider code 10001 and "already signed" even
	# when this role's GET calendar remains unsigned. The explicit POST
	# confirmation is authoritative for the sign-in outcome, while the
	# calendar still controls which reward details are actually available.
	# Never accept code 10001 without a matching message, nor apply this
	# to Endfield (which has a separate API and schema).
	if ($Provider -ne 'skland' -or $AppCode -ne 'arknights' -or $null -eq $Response) { return $false }
	if ([string]$Response.code -ne '10001') { return $false }
	return [bool]([string]$Response.message -match '(?i)already\s*(?:signed|checked)|signed\s*today|\u5df2\u7b7e\u5230|\u5df2\u7c3d\u5230|\u8bf7\u52ff\u91cd\u590d\u7b7e\u5230|\u8acb\u52ff\u91cd\u8907\u7c3d\u5230')
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
	param($Data, $Ctx, [switch]$UseCalendarToday)
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

	# Arknights can confirm an already-completed Bilibili sign-in using
	# code 10001 while GET records[] and calendar[].done are empty/false.
	# Its calendar still describes today's scheduled resource and quantity.
	# Only use this when the caller has confirmed the provider's explicit
	# already-signed message. Do not imply it came from a POST award receipt.
	if ($lines.Count -eq 0 -and $UseCalendarToday -and $Ctx.ProviderProfile.name -eq 'skland' -and
		$Ctx.GameConfig.app_code -eq 'arknights' -and $null -ne $Data -and $null -ne $Data.resourceInfoMap) {
		$serverTs = 0L
		if ([long]::TryParse([string]$Data.currentTs, [ref]$serverTs) -and $serverTs -gt 0) {
			try {
				$serverDate = [DateTimeOffset]::FromUnixTimeSeconds($serverTs).ToOffset([TimeSpan]::FromHours(8))
				$calendar = @($Data.calendar)
				if ($calendar.Count -ge $serverDate.Day) {
					$entry = $calendar[$serverDate.Day - 1]
					$resourceId = if ($entry) { [string]$entry.resourceId } else { '' }
					if ($resourceId) {
						$info = $Data.resourceInfoMap.$resourceId
						if ($info -and $info.name) {
							$line = New-Line -Name $info.name -Count $entry.count
							if ($line) { $lines += $line }
						}
					}
				}
			}
			catch { }
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

function Get-SklandProfileDeviceCacheScope {
	param($Profile)

	$deviceConfig = Get-SklandDeviceConfigProperty -DeviceConfig $Profile -Names @('device')
	$deviceRef = Get-SklandDeviceConfigProperty -DeviceConfig $Profile -Names @('device_ref')
	if (-not $deviceRef) {
		$deviceRef = Get-SklandDeviceConfigProperty -DeviceConfig $deviceConfig -Names @('device_ref')
	}
	if ($deviceRef -and -not [string]::IsNullOrWhiteSpace([string]$deviceRef)) {
		# Sharing is opt-in. The same explicit reference is the only way for
		# different profiles to use one process-level dId cache entry.
		return "ref:$(([string]$deviceRef).Trim())"
	}

	$token = Get-SklandDeviceConfigProperty -DeviceConfig $Profile -Names @('token')
	if ($token -and -not [string]::IsNullOrWhiteSpace([string]$token)) {
		# The raw token never enters the cache key or a log. Hashing the profile
		# credential gives stable per-account isolation even if array order changes.
		return "profile-token:$(Get-SkMd5Hex -Text ([string]$token))"
	}

	$consoleName = Get-SklandDeviceConfigProperty -DeviceConfig $Profile -Names @('console_name')
	if ($consoleName -and -not [string]::IsNullOrWhiteSpace([string]$consoleName)) {
		return "profile-name:$(([string]$consoleName).Trim())"
	}

	# Skland profiles are required to have a token before this function is
	# reached. Keep a non-sharing fallback for malformed/direct callers.
	return "profile-object:$([System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode([object]$Profile))"
}

function Get-SklandProfileDeviceConfig {
	param(
		$Profile,
		[switch]$Create
	)

	$deviceConfig = Get-SklandDeviceConfigProperty -DeviceConfig $Profile -Names @('device')
	if ($null -eq $deviceConfig -and $Create) {
		$deviceConfig = [pscustomobject]@{}
		if ($Profile -is [System.Collections.IDictionary]) {
			$Profile['device'] = $deviceConfig
		}
		else {
			$Profile | Add-Member -MemberType NoteProperty -Name 'device' -Value $deviceConfig -Force
		}
	}
	return $deviceConfig
}

function Set-SklandDeviceConfigProperty {
	param(
		$DeviceConfig,
		[Parameter(Mandatory = $true)]
		[string]$Name,
		$Value
	)

	if ($DeviceConfig -is [System.Collections.IDictionary]) {
		$DeviceConfig[$Name] = $Value
	}
	else {
		$DeviceConfig | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
	}
}

function Remove-SklandDeviceConfigProperty {
	param(
		$DeviceConfig,
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	if ($DeviceConfig -is [System.Collections.IDictionary]) {
		if ($DeviceConfig.Contains($Name)) { [void]$DeviceConfig.Remove($Name) }
	}
	else {
		$property = $DeviceConfig.PSObject.Properties[$Name]
		if ($property) { $DeviceConfig.PSObject.Properties.Remove($Name) }
	}
}

function Save-SklandProfileDeviceState {
	param(
		$Profile,
		[Parameter(Mandatory = $true)]
		[string]$Did,
		[Parameter(Mandatory = $true)]
		[string]$Seed
	)

	if ([string]::IsNullOrWhiteSpace($Did) -or [string]::IsNullOrWhiteSpace($Seed)) { return $false }
	$deviceConfig = Get-SklandProfileDeviceConfig -Profile $Profile -Create
	Set-SklandDeviceConfigProperty -DeviceConfig $deviceConfig -Name 'id' -Value $Did.Trim()
	Set-SklandDeviceConfigProperty -DeviceConfig $deviceConfig -Name 'seed' -Value $Seed.Trim()
	Register-LogSecret -Secret $Did.Trim() -Label 'device.id'
	Register-LogSecret -Secret $Seed.Trim() -Label 'device.seed'
	Register-GitHubLogMasks
	foreach ($legacyName in @('did', 'device_id', 'device_seed')) {
		Remove-SklandDeviceConfigProperty -DeviceConfig $deviceConfig -Name $legacyName
	}

	if ([string]::IsNullOrWhiteSpace([string]$script:AnimeAttendanceConfigPath) -or $null -eq $script:conf) {
		return $false
	}
	Save-AnimeAttendanceConfig -Config $script:conf -Path $script:AnimeAttendanceConfigPath
	return $true
}

function Save-SklandProfileDeviceId {
	param(
		$Profile,
		[Parameter(Mandatory = $true)]
		[string]$Did
	)

	$deviceConfig = Get-SklandProfileDeviceConfig -Profile $Profile
	$seed = Get-SklandDeviceConfigProperty -DeviceConfig $deviceConfig -Names @('seed', 'device_seed')
	if ([string]::IsNullOrWhiteSpace([string]$seed)) { return $false }
	return Save-SklandProfileDeviceState -Profile $Profile -Did $Did -Seed ([string]$seed)
}

function Test-SklandDeviceIdRejection {
	param($Failure)

	if ($null -eq $Failure) { return $false }
	$code = [string](Get-SklandDeviceConfigProperty -DeviceConfig $Failure -Names @('Code', 'code'))
	$message = [string](Get-SklandDeviceConfigProperty -DeviceConfig $Failure -Names @('Message', 'message'))
	$response = Get-SklandDeviceConfigProperty -DeviceConfig $Failure -Names @('Response', 'response')
	$responseMessage = if ($response) {
		@('msg', 'message', 'error', 'detail') | ForEach-Object {
			$value = Get-SklandDeviceConfigProperty -DeviceConfig $response -Names @($_)
			if ($null -ne $value) { [string]$value }
		}
	}
	$text = "$code $message $($responseMessage -join ' ')"
	if ([string]::IsNullOrWhiteSpace($text)) { return $false }

	# The auth endpoints have used both English and Chinese messages, and their
	# numeric code is not stable enough to treat as a standalone contract. Only
	# recover when the response explicitly describes an invalid/rejected device
	# or dId; token, timestamp, and generic auth failures must remain failures.
	$patterns = @(
		'(?i)\b(?:invalid|illegal|unknown|expired|rejected|not\s+found|unregistered)\s+(?:skland\s+)?(?:device(?:\s*id)?|dId)\b',
		'(?i)\b(?:device(?:\s*id)?|dId)\b.{0,60}(?:invalid|illegal|unknown|expired|rejected|not\s+found|unregistered)',
		'(?i)(?:invalid|illegal|unknown|expired|rejected|not\s+found|unregistered).{0,60}(?:device|fingerprint|dId)',
		'(?i)\b(?:device(?:\s*id)?|dId|fingerprint)\b.{0,60}(?:error|failed|failure|denied)',
		'(?:設備|装置|裝置|设备|指紋|指纹|dId).{0,60}(?:無效|无效|失效|拒絕|拒绝|不存在|未知|過期|过期|錯誤|错误|失敗|失败|不合法|非法|不正確|不正确|驗證失敗|验证失败|校驗失敗|校验失败)',
		'(?:無效|无效|失效|拒絕|拒绝|不存在|未知|過期|过期|錯誤|错误|失敗|失败|不合法|非法|不正確|不正确|驗證失敗|验证失败|校驗失敗|校验失败).{0,60}(?:設備|装置|裝置|设备|指紋|指纹|dId)'
	)
	foreach ($pattern in $patterns) {
		if ($text -match $pattern) { return $true }
	}
	return $false
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
		return New-AttendanceProfileFailure -Platform $Provider -Reason 'InvalidConfiguration' -Message 'No games configured'
	}
	if ($Provider -eq 'skport' -and -not $Profile.cred) {
		Out-Log -Level 'ERROR' -Message 'Skport profile missing cred.'
		$Embed.fields += @{ 'name' = 'Skport'; 'value' = 'Missing cred'; 'inline' = $true }
		return New-AttendanceProfileFailure -Platform $Provider -Reason 'InvalidConfiguration' -Message 'Missing cred'
	}
	if ($Provider -eq 'skland' -and -not $Profile.token) {
		Out-Log -Level 'ERROR' -Message 'Skland profile missing token.'
		$Embed.fields += @{ 'name' = 'Skland'; 'value' = 'Missing token'; 'inline' = $true }
		return New-AttendanceProfileFailure -Platform $Provider -Reason 'InvalidConfiguration' -Message 'Missing token'
	}

	$providerProfile = Get-SkProviderProfile -Provider $Provider
	$did = ''
	$deviceConfig = $null
	$deviceScope = $null
	$deviceSeed = ''
	$hadConfiguredDeviceId = $false
	$generatedDeviceSeed = $false
	$isGitHubActions = [string]::Equals([string]$env:GITHUB_ACTIONS, 'true', [System.StringComparison]::OrdinalIgnoreCase)
	if ($Provider -eq 'skland') {
		$deviceConfig = Get-SklandProfileDeviceConfig -Profile $Profile
		$deviceOptions = Get-SklandDeviceOptions -DeviceConfig $deviceConfig
		$hadConfiguredDeviceId = -not [string]::IsNullOrWhiteSpace([string]$deviceOptions.Did)
		$deviceSeed = [string]$deviceOptions.Seed
		if (-not $hadConfiguredDeviceId -and [string]::IsNullOrWhiteSpace($deviceSeed)) {
			if ($isGitHubActions) {
				Write-SklandDeviceDiagnostic -Message 'Skland device.id and device.seed are both missing in GitHub Actions; refusing to create an ephemeral device. Run locally once and persist the profile device state before using Actions.'
				$Embed.fields += @{ 'name' = 'Skland'; 'value' = 'Missing persistent device identity'; 'inline' = $true }
				return New-AttendanceProfileFailure -Platform $Provider -Reason 'InvalidConfiguration' -Message 'Missing persistent device identity'
			}
			$deviceConfig = Get-SklandProfileDeviceConfig -Profile $Profile -Create
			$deviceSeed = [guid]::NewGuid().ToString()
			Set-SklandDeviceConfigProperty -DeviceConfig $deviceConfig -Name 'seed' -Value $deviceSeed
			$generatedDeviceSeed = $true
		}
		elseif (-not $hadConfiguredDeviceId) {
			Write-SklandDeviceDiagnostic -Message 'Skland device ID is missing; recovering from persistent device seed.'
		}
		$deviceScope = Get-SklandProfileDeviceCacheScope -Profile $Profile
		try { $did = Get-SklandDid -DeviceConfig $deviceConfig -CacheScopeKey $deviceScope }
		catch {
			Write-SklandDeviceDiagnostic -Message $_.Exception.Message
			$Embed.fields += @{ 'name' = 'Skland'; 'value' = 'Failed to register device'; 'inline' = $true }
			return New-AttendanceProfileFailure -Platform $Provider -Reason 'DeviceRegistrationFailed' -Message 'Failed to register device'
		}
		if (-not $hadConfiguredDeviceId) {
			try {
				if (-not (Save-SklandProfileDeviceState -Profile $Profile -Did $did -Seed $deviceSeed)) {
					if ($generatedDeviceSeed) {
						Write-SklandDeviceDiagnostic -Message 'Skland device registration succeeded, but the generated device seed and dId could not be persisted. Refusing to continue with an ephemeral device; run locally with a writable sign.json.'
						$Embed.fields += @{ 'name' = 'Skland'; 'value' = 'Could not persist device identity'; 'inline' = $true }
						return New-AttendanceProfileFailure -Platform $Provider -Reason 'DevicePersistenceFailed' -Message 'Could not persist device identity'
					}
					Write-SklandDeviceDiagnostic -Message 'Recovered Skland device for this run, but the recovered device ID cannot be persisted back to CHECK_SECRET automatically. Run locally once and update CHECK_SECRET to avoid re-registration.'
				}
				elseif ($isGitHubActions) {
					Write-SklandDeviceDiagnostic -Message 'Recovered Skland device for this run, but the recovered device ID cannot be persisted back to CHECK_SECRET automatically. Run locally once and update CHECK_SECRET to avoid re-registration.'
				}
			}
			catch {
				if ($generatedDeviceSeed) {
					Write-SklandDeviceDiagnostic -Message "Skland device registration succeeded, but persisting the generated device identity failed: $($_.Exception.Message)"
					$Embed.fields += @{ 'name' = 'Skland'; 'value' = 'Could not persist device identity'; 'inline' = $true }
					return New-AttendanceProfileFailure -Platform $Provider -Reason 'DevicePersistenceFailed' -Message 'Could not persist device identity'
				}
				Write-SklandDeviceDiagnostic -Message 'Recovered Skland device for this run, but the recovered device ID cannot be persisted back to CHECK_SECRET automatically. Run locally once and update CHECK_SECRET to avoid re-registration.'
			}
		}
	}
	$ctx = @{ Profile = $Profile; ProviderProfile = $providerProfile; PlatformConfig = $PlatformConfig; GameConfig = $PlatformConfig.games[0]; Cred = $Profile.cred; Token = $null; TimeOffset = 0; DId = $did; SkGameRole = $null }
	$authInitialized = Initialize-SkAuthState -Ctx $ctx
	if (-not $authInitialized -and $Provider -eq 'skland' -and $hadConfiguredDeviceId) {
		if ($deviceSeed -and (Test-SklandDeviceIdRejection -Failure $ctx.LastAuthFailure)) {
			Write-SklandDeviceDiagnostic -Message 'Configured Skland device ID was rejected. Re-enrolling with the persistent device seed and retrying authentication.'
			$replacementDid = $null
			try {
				$replacementDid = Get-SklandDid -DeviceConfig $deviceConfig -CacheScopeKey $deviceScope -ForceProvision
			}
			catch {
				Write-SklandDeviceDiagnostic -Message "Skland device recovery registration failed: $($_.Exception.Message)"
			}
			if ($replacementDid) {
				$did = $replacementDid
				$ctx.DId = $replacementDid
				$ctx.Token = $null
				$ctx.Cred = $Profile.cred
				$ctx.TimeOffset = 0
				$authInitialized = Initialize-SkAuthState -Ctx $ctx
				if ($authInitialized) {
					$persistedReplacement = $false
					try { $persistedReplacement = Save-SklandProfileDeviceState -Profile $Profile -Did $replacementDid -Seed $deviceSeed }
					catch {
						Write-SklandDeviceDiagnostic -Message "Recovered Skland device for this run, but persisting the replacement device ID failed: $($_.Exception.Message)"
					}
					if (-not $persistedReplacement -or $isGitHubActions) {
						Write-SklandDeviceDiagnostic -Message 'Recovered the Skland device using its persistent seed. Update sign.json locally to persist the replacement device ID.'
					}
					else {
						Write-SklandDeviceDiagnostic -Message 'Configured Skland device ID was rejected. Recovered the device using its persistent seed, and persisted the replacement device ID to sign.json.'
					}
				}
			}
		}
		elseif (Test-SklandDeviceIdRejection -Failure $ctx.LastAuthFailure) {
			Write-SklandDeviceDiagnostic -Message 'Configured Skland device ID was rejected, but no persistent device seed is available for recovery. Run locally once with recovery state configured before retrying.'
		}
	}
	if (-not $authInitialized) {
		$Embed.fields += @{ 'name' = ("{0}" -f ($Provider.Substring(0,1).ToUpper() + $Provider.Substring(1))); 'value' = 'Failed to initialize auth state'; 'inline' = $true }
		return New-AttendanceProfileFailure -Platform $Provider -Reason 'AuthenticationFailed' -Message 'Failed to initialize auth state'
	}

	$userResult = Get-SkUserData -Ctx $ctx
	if ($userResult.Kind -ne 'Success') {
		$Embed.fields += @{ name = $Provider; value = $userResult.Message; inline = $false }
		return New-AttendanceProfileFailure -Platform $Provider -Reason $userResult.Reason -Message $userResult.Message
	}
	$nickname = Get-SkValueByPath -Data $userResult.Data -Path $providerProfile.user_extract.nickname
	$userId = Get-SkValueByPath -Data $userResult.Data -Path $providerProfile.user_extract.id
	if ([string]::IsNullOrWhiteSpace([string]$nickname) -or [string]::IsNullOrWhiteSpace([string]$userId)) {
		$Embed.fields += @{ name = $Provider; value = 'User response missing required identity'; inline = $false }
		return New-AttendanceProfileFailure -Platform $Provider -Reason 'InvalidResponse' -Message 'User response missing required identity'
	}
	Register-LogSecret -Secret $nickname -Label 'nickname'
	Register-LogSecret -Secret $userId -Label 'id'
	Register-GitHubLogMasks
	$Embed.title = if ($nickname) { Format-Text -Text $nickname } else { "Unknown $Provider User" }
	$Embed.description = if ($null -ne $userId) { "ID: ||$userId||" } else { '' }

	$bindingResult = Get-SkBindingData -Ctx $ctx
	if ($bindingResult.Kind -ne 'Success') {
		$Embed.fields += @{ name = $Provider; value = $bindingResult.Message; inline = $false }
		return New-AttendanceProfileFailure -Platform $Provider -Reason $bindingResult.Reason -Message $bindingResult.Message
	}
	if (-not ((($bindingResult.Data -is [System.Collections.IDictionary]) -and $bindingResult.Data.Contains('list')) -or (($bindingResult.Data -isnot [System.Collections.IDictionary]) -and $bindingResult.Data.PSObject.Properties.Name -contains 'list'))) {
		$Embed.fields += @{ name = $Provider; value = 'Binding response missing list'; inline = $false }
		return New-AttendanceProfileFailure -Platform $Provider -Reason 'InvalidResponse' -Message 'Binding response missing list'
	}
	$roles = @(Expand-SkRoles -BindingData $bindingResult.Data -Provider $Provider)
	if ($roles.Count -eq 0) {
		Out-Log -Level 'ERROR' -Message "No bound roles found for $Provider user."
		$Embed.fields += @{ name = $Provider; value = 'No bound roles found'; inline = $true }
		return New-AttendanceProfileFailure -Platform $Provider -Reason 'NoBoundRoles' -Message 'No bound roles found'
	}

	foreach ($role in $roles) {
		foreach ($field in @(
			@{ Name = 'uid'; Value = $role.uid },
			@{ Name = 'role_id'; Value = $role.roleId },
			@{ Name = 'server_id'; Value = $role.serverId },
			@{ Name = 'game_id'; Value = $role.gameId },
			@{ Name = 'channelMasterId'; Value = $role.channelMasterId }
		)) {
			Register-LogSecret -Secret $field.Value -Label $field.Name
		}
		Register-LogSecret -Secret $role.nickname -Label 'nickname'
		Register-LogSecret -Secret (Get-SkFieldKey -Role $role) -Label 'identity_key'
	}
	Register-GitHubLogMasks

	$itemResults = @()
	foreach ($role in $roles) {
		$game = $PlatformConfig.games | Where-Object { $_.app_code -eq $role.appCode } | Select-Object -First 1
		if (-not $game) { continue }
		$roleCtx = @{ Profile = $Profile; ProviderProfile = $providerProfile; PlatformConfig = $PlatformConfig; GameConfig = $game; Cred = $ctx.Cred; Token = $ctx.Token; TimeOffset = $ctx.TimeOffset; DId = $ctx.DId; SkGameRole = $null }
		if ($role.roleId -and $role.serverId) { $roleCtx.SkGameRole = "$($role.gameId)_$($role.roleId)_$($role.serverId)" }

		$ident = Build-SkIdentity -Role $role -Game $game
		$fieldKey = Get-SkFieldKey -Role $role
		$logRole = Format-LogIdentity -Value $ident.nickname -Label 'role' -Key $fieldKey
		$logIdentity = if ($ident.server_name) { "$($ident.server_name) - $logRole" } else { $logRole }
		$ep = Resolve-SkAttendanceEndpoints -Ctx $roleCtx -Role $role
		$postPath = $ep.post.Replace('{app_code}', $game.app_code)
		$getPath = $ep.get.Replace('{app_code}', $game.app_code)
		# Arknights gameId selects the binding channel (official/Bilibili),
		# not the shared top-level game category.
		$attendanceGameId = if ($Provider -eq 'skland' -and $role.appCode -eq 'arknights' -and
			-not [string]::IsNullOrWhiteSpace([string]$role.channelMasterId)) { $role.channelMasterId } else { $role.gameId }
		$body = if ($ep.body -eq 'uid_gameId') { @{ uid = $role.uid; gameId = $attendanceGameId } } else { '' }
		$query = if ($ep.query -eq 'uid_gameId') { @{ uid = $role.uid; gameId = $attendanceGameId } } else { $null }

		$resPost = $null
		$resGet = $null
		$alreadyConfirmed = $false
		# Both platforms expose a readable status endpoint, but the response
		# schema differs by game. Only POST after an explicit "not signed" state.
		Out-Log -Level 'INFO' -Message "Checking status for $logIdentity ($($ident.title))"
		$resGet = Invoke-SkAuthorizedApiRequest -Method 'Get' -Path $getPath -Ctx $roleCtx -Query $query
		$initialState = Get-SkAttendanceState -Provider $Provider -AppCode $role.appCode -Response $resGet
		if ($initialState -eq 'Signed') {
			$alreadyConfirmed = $true
		}
		elseif ($initialState -eq 'NotSigned') {
			Out-Log -Level 'INFO' -Message "Checking in for $logIdentity ($($ident.title))"
			$resPost = Invoke-SkAuthorizedApiRequest -Method 'Post' -Path $postPath -Body $body -Ctx $roleCtx
			$resGet = Invoke-SkAuthorizedApiRequest -Method 'Get' -Path $getPath -Ctx $roleCtx -Query $query
		}
		else {
			$reason = if (Test-SkAuthenticationRejection -Response $resGet) { 'AuthenticationFailed' } else { 'StatusUnavailable' }
			Out-Log -Level 'ERROR' -Message "Cannot verify $Provider attendance state for $($ident.title)."
			$Embed.fields += @{ name = $ident.title; value = 'Attendance status unavailable; no check-in attempted'; inline = $true; key = $fieldKey }
			$itemResults += New-AttendanceItemResult -Kind 'Failed' -Identity $fieldKey -Detail 'Initial attendance status unavailable' -Reason $reason
			continue
		}

		$data = $null
		$isAlready = $alreadyConfirmed
		$useCalendarToday = $false
		if ($alreadyConfirmed) {
			$data = $resGet.data
		}
		elseif ($null -ne $resPost -and $resPost.code -eq 0) {
			$data = $resPost.data
		}
		elseif ((Get-SkAttendanceState -Provider $Provider -AppCode $role.appCode -Response $resGet) -eq 'Signed') {
			$data = $resGet.data
			$isAlready = $true
		}
		elseif (Test-SkAlreadySignedResponse -Provider $Provider -AppCode $role.appCode -Response $resPost) {
			# The provider explicitly confirmed attendance. GET records[] may
			# still appear unsigned on Bilibili, but today's own calendar
			# describes the scheduled reward (not an actual POST receipt).
			$data = if ($null -ne $resGet -and $resGet.code -eq 0) { $resGet.data } else { $null }
			$isAlready = $true
			$useCalendarToday = $true
			Out-Log -Level 'INFO' -Message "[$logIdentity] Provider confirms already signed."
		}
		else {
			$codePost = if ($null -ne $resPost) { $resPost.code } else { 'missing' }
			$codeGet = if ($null -ne $resGet) { $resGet.code } else { 'missing' }
			$detail = "Check-in not confirmed (POST: $codePost; GET: $codeGet)"
			Out-Log -Level 'ERROR' -Message "[$logIdentity] $detail"
			$Embed.fields += @{ name = $ident.title; value = "$($ident.identity): ERROR $detail"; inline = $true; key = $fieldKey }
			$itemResults += New-AttendanceItemResult -Kind 'Failed' -Identity $fieldKey -Detail $detail -Reason 'CheckInUnconfirmed'
			continue
		}
		$itemResults += New-AttendanceItemResult -Kind $(if ($isAlready) { 'AlreadySigned' } else { 'Signed' }) -Identity $fieldKey
		$awardLines = Resolve-SkAwardLines -Data $data -Ctx $roleCtx -UseCalendarToday:$useCalendarToday
		$awardText = $awardLines -join "`n"
		$awardLogText = $awardLines -join ", "
		if ($isAlready) {
			Out-Log -Level 'INFO' -Message "[$logIdentity] Already checked in. Awards: $awardLogText"
		}
		else {
			Out-Log -Level 'INFO' -Message "[$logIdentity] Check-in success! Awards: $awardLogText"
		}
		# Include the actual reward even on reused messages; the role key
		# lets Discord update the matching field rather than drop the result.
			$Embed.fields += @{ 'name' = $ident.title; 'value' = "*$($ident.server_name)* - $($ident.nickname)`n$awardText"; 'inline' = $true; 'key' = $fieldKey }
	}

	return Complete-AttendanceProfileResult -Platform $Provider -Items $itemResults
}
