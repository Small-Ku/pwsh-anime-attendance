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
		try {
			$statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
		}
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
		if ($langMap.ContainsKey($ResourceId)) {
			return $langMap[$ResourceId]
		}
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
		if ($name -and ([string]$name).Trim().Length -gt 0) {
			$langMap[$id] = [string]$name
		}
	}
}

function Ensure-SkEndfieldPublicResourceMap {
	param($Ctx)
	if (-not $Ctx -or -not $Ctx.Config) { return }
	$lang = if ($Ctx.Config.lang) { [string]$Ctx.Config.lang } else { "zh_Hans" }
	$mappedLang = if ($lang -eq 'zh_CN') { 'zh_Hans' } else { $lang }
	if ($script:SkEndfieldResourceNameMapByLang.ContainsKey($lang) -and $script:SkEndfieldResourceNameMapByLang[$lang].Count -gt 0) {
		return
	}

	try {
		$headers = @{
			'Accept'       = '*/*'
			'Content-Type' = 'application/json'
			'sk-language'  = $mappedLang
		}
		$params = @{
			Method      = 'Get'
			Uri         = 'https://zonai.skport.com/web/v1/game/endfield/attendance'
			Headers     = $headers
			UserAgent   = $Ctx.Config.user_agent
			ContentType = 'application/json'
			ErrorAction = 'Stop'
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
			$count = $script:SkEndfieldResourceNameMapByLang[$lang].Count
			Out-Log -Level 'DEBUG' -Message "Loaded public Endfield resource map for lang=$lang(mapped=$mappedLang) count=$count"
		}
	}
	catch {
		Out-Log -Level 'DEBUG' -Message "Failed loading public Endfield resource map for lang=${lang}(mapped=${mappedLang}): $($_.Exception.Message)"
	}
}
