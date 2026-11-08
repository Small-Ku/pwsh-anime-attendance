####################
# skland device fingerprint
####################

# Skland validates dId values against Shumei's device-profile service. The
# protocol constants below mirror AEtherside/skland-kit src/utils/env.ts.
$script:SklandDeviceProfileEndpoint = 'https://fp-it.portal101.cn/deviceprofile/v4'
$script:SklandDeviceProfileOrganization = 'UWXspnCCJN4sfYlNfqps'
$script:SklandDeviceProfileRsaModulus = 'psTDa+5/GXk9LRNUfY/5j4saIpz5HjPpOFRiJ/7NJOzeayQH52dHjBEfkIcBb7Ic6NCzZnlJKUfLiJVPxhFa/JjdvLCpsHdoKcoKo9Hj5wZjluL9GVcG0mCvos5IVRZNlf3aC6DG1sum/lJwPJpI74NImFkQcn0bCtoHZe5Zags='

# The cache is deliberately scoped by the caller. Attendance passes a
# profile-owned scope here; only an explicit shared device_ref may make two
# profiles use the same entry. A persisted profile.device.id remains the
# authority across processes.
if (-not $script:SklandDidCache) {
	$script:SklandDidCache = @{}
}

function Get-SklandDeviceConfigProperty {
	param(
		$DeviceConfig,
		[string[]]$Names,
		$Default = $null
	)

	if ($null -eq $DeviceConfig) { return $Default }
	foreach ($name in $Names) {
		if ($DeviceConfig -is [System.Collections.IDictionary]) {
			if ($DeviceConfig.Contains($name)) { return $DeviceConfig[$name] }
		}
		else {
			$property = $DeviceConfig.PSObject.Properties[$name]
			if ($property) { return $property.Value }
		}
	}
	return $Default
}

function ConvertTo-SklandDeviceInteger {
	param(
		$Value,
		[int]$Default,
		[string]$Name,
		[int]$Minimum,
		[int]$Maximum
	)

	if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
	try { $number = [int]$Value }
	catch { throw "Invalid Skland device setting '$Name': '$Value' is not an integer." }
	if ($number -lt $Minimum -or $number -gt $Maximum) {
		throw "Invalid Skland device setting '$Name': expected $Minimum..$Maximum, got $number."
	}
	return $number
}

function Get-SklandDeviceOptions {
	param($DeviceConfig)

	$did = ''
	foreach ($name in @('id', 'did', 'device_id')) {
		$value = Get-SklandDeviceConfigProperty -DeviceConfig $DeviceConfig -Names @($name)
		if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
			$did = ([string]$value).Trim()
			break
		}
	}
	$seed = ''
	foreach ($name in @('seed', 'device_seed')) {
		$value = Get-SklandDeviceConfigProperty -DeviceConfig $DeviceConfig -Names @($name)
		if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
			$seed = ([string]$value).Trim()
			break
		}
	}

	return [ordered]@{
		Did = $did
		Seed = $seed
		TimeoutSec = ConvertTo-SklandDeviceInteger -Value (Get-SklandDeviceConfigProperty -DeviceConfig $DeviceConfig -Names @('timeout_seconds', 'timeout_sec')) -Default 15 -Name 'timeout_seconds' -Minimum 1 -Maximum 120
		MaxRetries = ConvertTo-SklandDeviceInteger -Value (Get-SklandDeviceConfigProperty -DeviceConfig $DeviceConfig -Names @('max_retries')) -Default 3 -Name 'max_retries' -Minimum 0 -Maximum 10
		BaseDelayMs = ConvertTo-SklandDeviceInteger -Value (Get-SklandDeviceConfigProperty -DeviceConfig $DeviceConfig -Names @('retry_base_delay_ms')) -Default 500 -Name 'retry_base_delay_ms' -Minimum 0 -Maximum 10000
		JitterMs = ConvertTo-SklandDeviceInteger -Value (Get-SklandDeviceConfigProperty -DeviceConfig $DeviceConfig -Names @('retry_jitter_ms')) -Default 250 -Name 'retry_jitter_ms' -Minimum 0 -Maximum 5000
	}
}

function Get-SklandDeviceCacheKey {
	param(
		$Options,
		[string]$CacheScopeKey
	)

	$identityParts = @()
	if ($CacheScopeKey) { $identityParts += "scope:$CacheScopeKey" }
	if ($Options.Seed) {
		# The seed is intentionally never logged or used as a plain cache key.
		# Including it here prevents a changed recovery identity from reusing a
		# registration created earlier in the same process.
		$identityParts += "seed:$($Options.Seed)"
	}
	elseif ($Options.Did) {
		$identityParts += "did:$($Options.Did)"
	}
	if ($identityParts.Count -eq 0) { $identityParts += 'unscoped' }
	$identity = $identityParts -join '|'
	return Get-SkMd5Hex -Text $identity
}

function Get-SklandHttpStatusCode {
	param($ErrorRecord)

	$exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
	while ($exception) {
		$response = $exception.Response
		if ($response) {
			try {
				$statusCode = [int]$response.StatusCode
				if ($statusCode -gt 0) { return $statusCode }
			}
			catch {}
		}
		$message = [string]$exception.Message
		if ($message -match '(?<!\d)([1-5]\d{2})(?!\d)') {
			return [int]$Matches[1]
		}
		$exception = $exception.InnerException
	}
	return 0
}

function Test-SklandDeviceRegistrationRetryable {
	param([int]$StatusCode)

	return $StatusCode -eq 0 -or $StatusCode -eq 408 -or $StatusCode -eq 429 -or ($StatusCode -ge 500 -and $StatusCode -le 599)
}

function Get-SklandDeviceRetryDelayMilliseconds {
	param(
		$Options,
		[int]$Attempt
	)

	$backoffMs = $Options.BaseDelayMs * [math]::Pow(2, $Attempt - 1)
	$jitterMs = if ($Options.JitterMs -gt 0) { Get-Random -Minimum 0 -Maximum ($Options.JitterMs + 1) } else { 0 }
	return [int]($backoffMs + $jitterMs)
}

function Get-SklandDeviceResponseMessage {
	param($Response)

	if ($null -eq $Response) { return 'empty response' }
	foreach ($name in @('msg', 'message', 'error')) {
		$value = Get-SklandDeviceConfigProperty -DeviceConfig $Response -Names @($name)
		if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
			$message = ([string]$value).Trim() -replace '\s+', ' '
			if ($message.Length -gt 200) { $message = $message.Substring(0, 200) }
			return $message
		}
	}
	return 'no message'
}

function Format-SklandDeviceRegistrationFailure {
	param(
		[int]$Attempt,
		[int]$TotalAttempts,
		[int]$HttpStatus,
		[string]$Code = 'unknown',
		[string]$Message = 'no message'
	)

	$statusText = if ($HttpStatus -gt 0) { "HTTP status $HttpStatus" } else { 'HTTP status n/a' }
	return "Skland device registration failed (attempt $Attempt/$TotalAttempts; $statusText; Shumei code $Code; message: $Message)."
}

function Write-SklandDeviceDiagnostic {
	param([Parameter(Mandatory = $true)][string]$Message)
	Out-Log -Level 'WARN' -Message $Message
}
function Protect-SklandDeviceDesValue {
	param(
		[Parameter(Mandatory = $true)]
		$Value,
		[Parameter(Mandatory = $true)]
		[string]$Key
	)

	$plainBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Value)
	$padLength = 8 - ($plainBytes.Length % 8)
	$paddedBytes = [byte[]]::new($plainBytes.Length + $padLength)
	[System.Array]::Copy($plainBytes, $paddedBytes, $plainBytes.Length)

	$des = [System.Security.Cryptography.DES]::Create()
	try {
		$des.Mode = [System.Security.Cryptography.CipherMode]::ECB
		$des.Padding = [System.Security.Cryptography.PaddingMode]::None
		$des.Key = [System.Text.Encoding]::UTF8.GetBytes($Key)
		$encryptor = $des.CreateEncryptor()
		try {
			$encrypted = $encryptor.TransformFinalBlock($paddedBytes, 0, $paddedBytes.Length)
		}
		finally {
			$encryptor.Dispose()
		}
	}
	finally {
		$des.Dispose()
	}

	return [System.Convert]::ToBase64String($encrypted)
}

function Protect-SklandDeviceRsaValue {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Value
	)

	$parameters = [System.Security.Cryptography.RSAParameters]::new()
	$parameters.Modulus = [System.Convert]::FromBase64String($script:SklandDeviceProfileRsaModulus)
	$parameters.Exponent = [byte[]](0x01, 0x00, 0x01)

	$rsa = [System.Security.Cryptography.RSACryptoServiceProvider]::new()
	try {
		$rsa.ImportParameters($parameters)
		$encrypted = $rsa.Encrypt([System.Text.Encoding]::UTF8.GetBytes($Value), $false)
	}
	finally {
		$rsa.Dispose()
	}

	return [System.Convert]::ToBase64String($encrypted)
}

function Get-SklandDeviceTnMaterial {
	param(
		[Parameter(Mandatory = $true)]
		[System.Collections.IDictionary]$Values
	)

	$keys = [string[]]@($Values.Keys | ForEach-Object { [string]$_ })
	[System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
	$parts = foreach ($key in $keys) {
		$value = $Values[$key]
		if ($value -is [System.Collections.IDictionary]) {
			Get-SklandDeviceTnMaterial -Values $value
		}
		elseif (
			$value -is [byte] -or $value -is [sbyte] -or
			$value -is [int16] -or $value -is [uint16] -or
			$value -is [int32] -or $value -is [uint32] -or
			$value -is [int64] -or $value -is [uint64] -or
			$value -is [single] -or $value -is [double] -or $value -is [decimal]
		) {
			([decimal]$value * 10000).ToString('0.############################', [System.Globalization.CultureInfo]::InvariantCulture)
		}
		else {
			[string]$value
		}
	}
	return ($parts -join '')
}

function Get-SklandSmId {
	param(
		[datetime]$Now = [datetime]::Now,
		[string]$Uuid = ([guid]::NewGuid().ToString())
	)

	$uidMd5 = Get-SkMd5Hex -Text $Uuid
	$value = "$($Now.ToString('yyyyMMddHHmmss'))${uidMd5}00"
	$smskWeb = (Get-SkMd5Hex -Text "smsk_web_${value}").Substring(0, 14)
	return "${value}${smskWeb}0"
}

function Get-SklandStableUuid {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Seed,
		[Parameter(Mandatory = $true)]
		[string]$Purpose
	)

	if ([string]::IsNullOrWhiteSpace($Seed)) { throw 'Skland device seed cannot be empty.' }
	$hex = Get-SkMd5Hex -Text "skland-device-v1|$Purpose|$Seed"
	# Format the deterministic digest as an RFC 4122-looking UUID. Shumei
	# receives this as synthetic browser identity material; it is not a local
	# dId and cannot be used to bypass registration.
	$hex = $hex.Substring(0, 12) + '4' + $hex.Substring(13, 3) + '8' + $hex.Substring(17)
	return '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

function ConvertTo-SklandDeviceGzipBase64 {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Text
	)

	$inputBytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
	$memory = [System.IO.MemoryStream]::new()
	try {
		$gzip = [System.IO.Compression.GZipStream]::new($memory, [System.IO.Compression.CompressionMode]::Compress, $true)
		try {
			$gzip.Write($inputBytes, 0, $inputBytes.Length)
		}
		finally {
			$gzip.Dispose()
		}
		$compressed = $memory.ToArray()
	}
	finally {
		$memory.Dispose()
	}

	# skland-kit normalizes the gzip OS byte to 19 before encrypting it.
	if ($compressed.Length -gt 9) { $compressed[9] = 19 }
	return [System.Convert]::ToBase64String($compressed)
}

function Protect-SklandDeviceAesValue {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Value,
		[Parameter(Mandatory = $true)]
		[string]$Key
	)

	$aes = [System.Security.Cryptography.Aes]::Create()
	try {
		$aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
		$aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
		$aes.Key = [System.Text.Encoding]::UTF8.GetBytes($Key)
		$aes.IV = [System.Text.Encoding]::UTF8.GetBytes('0102030405060708')
		$encryptor = $aes.CreateEncryptor()
		try {
			$plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
			$encrypted = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
		}
		finally {
			$encryptor.Dispose()
		}
	}
	finally {
		$aes.Dispose()
	}

	return ([System.BitConverter]::ToString($encrypted).Replace('-', '').ToLowerInvariant())
}

function ConvertTo-SklandDeviceJson {
	param(
		[Parameter(Mandatory = $true)]
		[System.Collections.IDictionary]$Value
	)

	# skland-kit inserts a single space between adjacent JSON string members.
	$json = $Value | ConvertTo-Json -Depth 20 -Compress
	return $json.Replace('":"', '": "').Replace('","', '", "')
}

function Get-SklandDeviceProfilePayload {
	param([string]$Seed)

	$hasSeed = -not [string]::IsNullOrWhiteSpace($Seed)
	$uid = if ($hasSeed) { Get-SklandStableUuid -Seed $Seed -Purpose 'uid' } else { [guid]::NewGuid().ToString() }
	$priId = (Get-SkMd5Hex -Text $uid).Substring(0, 16)
	$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$vpw = if ($hasSeed) { Get-SklandStableUuid -Seed $Seed -Purpose 'vpw' } else { [guid]::NewGuid().ToString() }
	$trees = if ($hasSeed) { Get-SklandStableUuid -Seed $Seed -Purpose 'trees' } else { [guid]::NewGuid().ToString() }

	$target = [ordered]@{
		plugins = 'MicrosoftEdgePDFPluginPortableDocumentFormatinternal-pdf-viewer1,MicrosoftEdgePDFViewermhjfbmdgcfjbbpaeojofohoefgiehjai1'
		ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0'
		canvas = '259ffe69'
		timezone = -480
		platform = 'Win32'
		url = 'https://www.skland.com/'
		referer = ''
		res = '1920_1080_24_1.25'
		clientSize = '0_0_1080_1920_1920_1080_1920_1080'
		status = '0011'
		vpw = $vpw
		svm = $nowMs
		trees = $trees
		pmf = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		protocol = 102
		organization = $script:SklandDeviceProfileOrganization
		appId = 'default'
		os = 'web'
		version = '3.0.0'
		sdkver = '3.0.0'
		box = ''
		rtype = 'all'
		# smid contains a current timestamp, but its device identity material is
		# derived from the stable uid when a persistent seed is configured.
		smid = Get-SklandSmId -Uuid $uid
		subVersion = '1.0.0'
		time = 0
	}
	$target.tn = Get-SkMd5Hex -Text (Get-SklandDeviceTnMaterial -Values $target)

	$encrypted = [ordered]@{
		kq = Protect-SklandDeviceDesValue -Value $target.plugins -Key 'v51m3pzl'
		bj = Protect-SklandDeviceDesValue -Value $target.ua -Key 'k92crp1t'
		yk = Protect-SklandDeviceDesValue -Value $target.canvas -Key 'snrn887t'
		as = Protect-SklandDeviceDesValue -Value $target.timezone -Key '1uv05lj5'
		gm = Protect-SklandDeviceDesValue -Value $target.platform -Key 'pakxhcd2'
		cf = Protect-SklandDeviceDesValue -Value $target.url -Key 'y95hjkoo'
		ab = Protect-SklandDeviceDesValue -Value $target.referer -Key 'y7bmrjlc'
		hf = Protect-SklandDeviceDesValue -Value $target.res -Key 'whxqm2a7'
		zx = Protect-SklandDeviceDesValue -Value $target.clientSize -Key 'cpmjjgsu'
		an = Protect-SklandDeviceDesValue -Value $target.status -Key '2jbrxxw4'
		ca = Protect-SklandDeviceDesValue -Value $target.vpw -Key 'r9924ab5'
		qr = Protect-SklandDeviceDesValue -Value $target.svm -Key 'fzj3kaeh'
		pi = Protect-SklandDeviceDesValue -Value $target.trees -Key 'acfs0xo4'
		vw = Protect-SklandDeviceDesValue -Value $target.pmf -Key '2mdeslu3'
		protocol = $target.protocol
		dp = Protect-SklandDeviceDesValue -Value $target.organization -Key '78moqjfc'
		xx = Protect-SklandDeviceDesValue -Value $target.appId -Key 'uy7mzc4h'
		pj = Protect-SklandDeviceDesValue -Value $target.os -Key 'je6vk6t4'
		version = $target.version
		sc = Protect-SklandDeviceDesValue -Value $target.sdkver -Key '9q3dcxp2'
		jf = $target.box
		lo = Protect-SklandDeviceDesValue -Value $target.rtype -Key 'x8o2h2bl'
		smid = $target.smid
		ns = Protect-SklandDeviceDesValue -Value $target.subVersion -Key 'eo3i2puh'
		nb = Protect-SklandDeviceDesValue -Value $target.time -Key 'q2t3odsk'
		py = Protect-SklandDeviceDesValue -Value $target.tn -Key 'x9nzj1bp'
	}

	$compressed = ConvertTo-SklandDeviceGzipBase64 -Text (ConvertTo-SklandDeviceJson -Value $encrypted)
	return [ordered]@{
		appId = 'default'
		compress = 2
		data = Protect-SklandDeviceAesValue -Value $compressed -Key $priId
		encode = 5
		ep = Protect-SklandDeviceRsaValue -Value $uid
		organization = $script:SklandDeviceProfileOrganization
		os = 'web'
	}
}

function Get-SklandDid {
	param(
		$DeviceConfig,
		[string]$CacheScopeKey,
		[switch]$ForceProvision
	)

	$options = Get-SklandDeviceOptions -DeviceConfig $DeviceConfig
	if ($options.Did -and -not $ForceProvision) {
		return $options.Did
	}
	if ($ForceProvision -and -not $options.Seed) {
		throw 'Skland device recovery requires persistent device.seed material.'
	}

	$cacheKey = Get-SklandDeviceCacheKey -Options $options -CacheScopeKey $CacheScopeKey
	if ($script:SklandDidCache.ContainsKey($cacheKey)) {
		return $script:SklandDidCache[$cacheKey]
	}

	# Reuse the exact same profile across attempts. In particular, a lost HTTP
	# response must not cause the retry to look like another new device.
	$body = Get-SklandDeviceProfilePayload -Seed $options.Seed
	$params = @{
		Method = 'Post'
		Uri = $script:SklandDeviceProfileEndpoint
		Headers = @{ 'Content-Type' = 'application/json' }
		ContentType = 'application/json'
		Body = ConvertTo-SkCompactJson -Value $body
		TimeoutSec = $options.TimeoutSec
		ErrorAction = 'Stop'
	}
	$totalAttempts = $options.MaxRetries + 1
	for ($attempt = 1; $attempt -le $totalAttempts; $attempt++) {
		try {
			$response = Invoke-RestMethod @params
		}
		catch {
			$httpStatus = Get-SklandHttpStatusCode -ErrorRecord $_
			$exceptionMessage = ([string]$_.Exception.Message).Trim() -replace '\s+', ' '
			if ([string]::IsNullOrWhiteSpace($exceptionMessage)) { $exceptionMessage = 'request exception' }
			if ($exceptionMessage.Length -gt 200) { $exceptionMessage = $exceptionMessage.Substring(0, 200) }
			if ((Test-SklandDeviceRegistrationRetryable -StatusCode $httpStatus) -and $attempt -lt $totalAttempts) {
				$delayMs = Get-SklandDeviceRetryDelayMilliseconds -Options $options -Attempt $attempt
				$statusText = if ($httpStatus -gt 0) { "HTTP status $httpStatus" } else { 'transport error' }
				Write-SklandDeviceDiagnostic -Message "Skland device registration transient failure (attempt $attempt/$totalAttempts; $statusText; message: $exceptionMessage). Retrying in ${delayMs}ms."
				if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
				continue
			}
			throw (Format-SklandDeviceRegistrationFailure -Attempt $attempt -TotalAttempts $totalAttempts -HttpStatus $httpStatus -Message $exceptionMessage)
		}

		if ($null -eq $response) {
			if ($attempt -lt $totalAttempts) {
				$delayMs = Get-SklandDeviceRetryDelayMilliseconds -Options $options -Attempt $attempt
				Write-SklandDeviceDiagnostic -Message "Skland device registration transient failure (attempt $attempt/$totalAttempts; empty response). Retrying in ${delayMs}ms."
				if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
				continue
			}
			throw (Format-SklandDeviceRegistrationFailure -Attempt $attempt -TotalAttempts $totalAttempts -HttpStatus 0 -Message 'empty response')
		}

		$code = if ($null -ne $response.code) { [string]$response.code } else { 'unknown' }
		$deviceId = if ($response.detail) { [string]$response.detail.deviceId } else { '' }
		if ($code -eq '1100' -and -not [string]::IsNullOrWhiteSpace($deviceId)) {
			$did = "B$deviceId"
			$script:SklandDidCache[$cacheKey] = $did
			return $did
		}
		if ($code -eq '1100' -and $attempt -lt $totalAttempts) {
			$delayMs = Get-SklandDeviceRetryDelayMilliseconds -Options $options -Attempt $attempt
			Write-SklandDeviceDiagnostic -Message "Skland device registration returned code 1100 without detail.deviceId (attempt $attempt/$totalAttempts). Retrying in ${delayMs}ms."
			if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
			continue
		}

		# A 2xx response with a Shumei protocol code other than 1100 is an
		# explicit rejection, not a transport failure. Do not repeat it.
		$protocolMessage = if ($code -eq '1100') { 'missing detail.deviceId' } else { Get-SklandDeviceResponseMessage -Response $response }
		throw (Format-SklandDeviceRegistrationFailure -Attempt $attempt -TotalAttempts $totalAttempts -HttpStatus 0 -Code $code -Message $protocolMessage)
	}

	throw (Format-SklandDeviceRegistrationFailure -Attempt $totalAttempts -TotalAttempts $totalAttempts -HttpStatus 0 -Message 'retry budget exhausted')
}
