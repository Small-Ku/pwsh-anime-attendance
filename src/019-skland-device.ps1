####################
# skland device fingerprint
####################

# Skland validates dId values against Shumei's device-profile service. The
# protocol constants below mirror AEtherside/skland-kit src/utils/env.ts.
$script:SklandDeviceProfileEndpoint = 'https://fp-it.portal101.cn/deviceprofile/v4'
$script:SklandDeviceProfileOrganization = 'UWXspnCCJN4sfYlNfqps'
$script:SklandDeviceProfileRsaModulus = 'psTDa+5/GXk9LRNUfY/5j4saIpz5HjPpOFRiJ/7NJOzeayQH52dHjBEfkIcBb7Ic6NCzZnlJKUfLiJVPxhFa/JjdvLCpsHdoKcoKo9Hj5wZjluL9GVcG0mCvos5IVRZNlf3aC6DG1sum/lJwPJpI74NImFkQcn0bCtoHZe5Zags='

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
	$uid = [guid]::NewGuid().ToString()
	$priId = (Get-SkMd5Hex -Text $uid).Substring(0, 16)
	$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

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
		vpw = [guid]::NewGuid().ToString()
		svm = $nowMs
		trees = [guid]::NewGuid().ToString()
		pmf = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		protocol = 102
		organization = $script:SklandDeviceProfileOrganization
		appId = 'default'
		os = 'web'
		version = '3.0.0'
		sdkver = '3.0.0'
		box = ''
		rtype = 'all'
		smid = Get-SklandSmId
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
	$body = Get-SklandDeviceProfilePayload
	try {
		$response = Invoke-RestMethod -Method 'Post' -Uri $script:SklandDeviceProfileEndpoint -Headers @{ 'Content-Type' = 'application/json' } -ContentType 'application/json' -Body (ConvertTo-SkCompactJson -Value $body) -ErrorAction 'Stop'
	}
	catch {
		throw "Skland device registration failed: $($_.Exception.Message)"
	}

	if ($response.code -ne 1100 -or -not $response.detail.deviceId) {
		$code = if ($null -ne $response.code) { $response.code } else { 'unknown' }
		throw "Skland device registration failed (code: $code)."
	}
	return "B$($response.detail.deviceId)"
}
