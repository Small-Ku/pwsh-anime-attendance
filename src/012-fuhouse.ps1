####################
# Fuhouse (boylove.cc)
####################

function Select-FuhouseCookie {
	param($Profile)
	
	$jar = @{}
	$CookieString = $Profile.cookies
	if ($CookieString) {
		foreach ($c in ($CookieString -split ';')) {
			$c = $c.Trim()
			if ($c) {
				$c_pair = $c -split '=', 2
				if ($c_pair.Count -eq 2) {
					$jar[$c_pair[0]] = $c_pair[1]
				}
			}
		}
		if ($jar.ContainsKey('PHPSESSID')) {
			return @{ IsValid = $true; Jar = $jar }
		}
	}
	return @{ IsValid = $false }
}

function Invoke-FuhouseRequest {
	param(
		[string]$Uri,
		[string]$Method = 'Post',
		[string]$Body = $null,
		$Headers,
		[string]$UserAgent,
		$Session
	)

	$params = @{
		Method     = $Method
		Uri        = $Uri
		Headers    = $Headers
		UserAgent  = $UserAgent
		WebSession = $Session
	}

	if ($Method -eq 'Post' -and $null -ne $Body) {
		$params['Body'] = $Body
		$params['ContentType'] = 'application/x-www-form-urlencoded; charset=UTF-8'
	}

	$res = Invoke-RestMethod @params
	if ($res -is [string] -and ($res -like '*{*' -or $res -like '*[*')) {
		try { $res = $res | ConvertFrom-Json } catch {}
	}
	return $res
}

function Get-FuhouseResponseCode {
	param($Response)

	$code = 0
	if ($null -ne $Response -and $null -ne $Response.code) {
		[void][int]::TryParse("$($Response.code)", [ref]$code)
	}
	return $code
}

function Get-FuhouseTaskClaimState {
	param($Response)

	switch (Get-FuhouseResponseCode -Response $Response) {
		200 { return 'Claimed' }
		400 { return 'AlreadyClaimed' }
		401 { return 'RequirementsNotMet' }
		default { return 'Unknown' }
	}
}

function Invoke-FuhouseAttendance {
	param($Profiie, $Config, $Embed, $IsReusing)

	# Merge user-defined localization texts with defaults at the beginning
	$discordText = @{
		missing_cookie             = "Missing or invalid cookies (PHPSESSID required)"
		connection_error           = "Connection error occurred"
		failed_fetch_page          = "Failed to fetch user page: {0}"
		session_expired            = "Session expired, please update cookies."
		daily_sign_in              = "Daily Sign-In"
		sign_in_failed             = "Sign-in failed (code: {0})"
		connection_failed          = "Connection failed: {0}"
		ads_task                   = "Ads Task"
		ads_task_claim_failed      = "Claim failed (code: {0})"
		reading_task               = "Reading Task"
		no_available_chapters      = "No chapters available to read"
		reading_task_claim_failed  = "Claim failed (code: {0})"
	}
	if ($Config.discord_text) {
		foreach ($prop in $Config.discord_text.psobject.properties) {
			if ($null -ne $prop.Value -and $prop.Value -ne "") {
				$discordText[$prop.Name] = $prop.Value
			}
		}
	}

	$cookieResult = Select-FuhouseCookie -Profile $Profiie
	if (-not $cookieResult.IsValid) {
		$logMsg = Format-LogIdentity -Value $Profiie.console_name -Label 'console_name'
		Out-Log -Level 'ERROR' -Message "Invalid cookie format for Fuhouse profile: $logMsg"
		$Embed.title = "Fuhouse: $logMsg"
		$Embed.fields += @{ 'name' = 'Error'; 'value' = $discordText.missing_cookie; 'inline' = $false }
		return New-AttendanceProfileFailure -Platform 'fuhouse' -Reason 'InvalidConfiguration' -Message 'Fuhouse account validation failed'
	}

	$items = @()
	$jar = $cookieResult.Jar
	$userAgent = if ($Config.user_agent) { $Config.user_agent } else { "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36" }
	$baseUrl = if ($Config.base_url) { $Config.base_url.TrimEnd('/') } else { "https://boylove.cc" }
	$session = New-WebSession -Cookies $jar -For $baseUrl

	$headers = @{
		'Accept'            = 'application/json, text/plain, */*'
		'Accept-Language'   = 'en-US,en;q=0.9'
		'X-Requested-With'  = 'XMLHttpRequest'
		'Origin'            = $baseUrl
		'Referer'           = "$baseUrl/home/signup"
	}

	# 1. Fetch user profile page to verify session, extract nickname, and extract stable UID
	Out-Log -Level 'DEBUG' -Message "[Fuhouse] Fetching user profile page to extract nickname and UID..."
	try {
		$userHtml = Invoke-FuhouseRequest -Uri "$baseUrl/home/user/index.html" -Method 'Get' -Headers $headers -UserAgent $userAgent -Session $session
	}
	catch {
		$err = $_
		Out-Log -Level 'ERROR' -Message "[Fuhouse] Failed to fetch user page: $($err.Exception.Message)"
		
		$Embed.title = "Fuhouse: Connection Error"
		$Embed.description = $discordText.connection_error
		$Embed.fields += @{ 'name' = 'Error'; 'value' = ($discordText.failed_fetch_page -f $err.Exception.Message); 'inline' = $false }
		return New-AttendanceProfileFailure -Platform 'fuhouse' -Reason 'TransportError' -Message 'Fuhouse account validation failed'
	}

	$displayName = "Unknown"
	$uid = "Unknown"
	if ($userHtml -match 'class="namebars"[^>]*>\s*([^\s<]+)\s*</a>') {
		$displayName = $Matches[1].Trim()
	}
	elseif ($userHtml -match 'class="name"[^>]*>\s*([^\s<]+)\s*</p>') {
		$displayName = $Matches[1].Trim()
	}

	if ($userHtml -match '__PC_HISTORY_UID\s*=\s*(\d+)') {
		$uid = $Matches[1].Trim()
	}

	if ($uid -eq "Unknown" -or $displayName -eq "Unknown") {
		$logMsg = Format-LogIdentity -Value $Profiie.console_name -Label 'console_name'
		Out-Log -Level 'ERROR' -Message "Session expired or invalid cookie for Fuhouse profile: $logMsg"
		
		$Embed.title = "Fuhouse: Session Expired"
		$Embed.description = "Session expired or invalid cookie"
		$Embed.fields += @{ 'name' = 'Error'; 'value' = $discordText.session_expired; 'inline' = $false }
		return New-AttendanceProfileFailure -Platform 'fuhouse' -Reason 'AuthenticationFailed' -Message 'Fuhouse account validation failed'
	}

	$logDisplayName = Format-LogIdentity -Value $displayName -Label 'account' -Key $uid
	Register-LogSecret -Secret $displayName -Label 'nickname'
	Register-LogSecret -Secret $uid -Label 'uid'
	Register-GitHubLogMasks
	$Embed.title = "Fuhouse: $displayName"
	if ($uid -ne "Unknown") {
		$Embed.description = "ID: ||$uid||"
	} else {
		$Embed.description = ""
	}
	Out-Log -Level 'INFO' -Message "Checking $logDisplayName in for Fuhouse"

	# 2. Perform daily sign-in
	$signInMsg = ""
	$signKind = 'Failed'
	try {
		$signInResult = Invoke-FuhouseRequest -Uri "$baseUrl/home/Api/signupNew.html" -Body "td=&auto=true&type=1&autoSign=false" -Headers $headers -UserAgent $userAgent -Session $session
		Out-Log -Level 'DEBUG' -Message "[$logDisplayName] Sign-in response: $(Format-LogObject -InputObject $signInResult)"
		
		if ($signInResult.code -eq 2000 -or $signInResult.code -eq 400) {
			$signKind = if ($signInResult.code -eq 400) { 'AlreadySigned' } else { 'Signed' }
			$signInMsg = $signInResult.msg
			Out-Log -Level 'INFO' -Message "[$logDisplayName] $signInMsg"
		}
		else {
			$signInMsg = if ($signInResult.msg) { $signInResult.msg } else { $discordText.sign_in_failed -f $signInResult.code }
			Out-Log -Level 'ERROR' -Message "[$logDisplayName] $signInMsg"
		}
	}
	catch {
		$err = $_
		$signInMsg = $discordText.connection_failed -f $err.Exception.Message
		Out-Log -Level 'ERROR' -Message "[$logDisplayName] Sign-in exception: $($err.Exception.Message)"
	}

	$Embed.fields += @{ 'name' = $discordText.daily_sign_in; 'value' = $signInMsg; 'inline' = $true }
	if ($signKind -eq 'Failed') {
		$items += New-AttendanceItemResult -Kind 'Failed' -Identity 'Fuhouse sign-in' -Reason 'CheckInUnconfirmed' -Detail 'Daily sign-in failed'
	}
	else {
		$items += New-AttendanceItemResult -Kind $signKind -Identity 'Fuhouse sign-in'
	}

	# 3. Perform Ads Task (taskid=1)
	$adsMsg = ""
	$adsClaimState = 'Failed'
	Out-Log -Level 'INFO' -Message "[$logDisplayName] Checking $($discordText.ads_task) status..."
	try {
		$claimAds = Invoke-FuhouseRequest -Uri "$baseUrl/home/signup/completetask" -Body "taskid=1" -Headers $headers -UserAgent $userAgent -Session $session
		$adsClaimState = Get-FuhouseTaskClaimState -Response $claimAds
		if ($adsClaimState -eq 'AlreadyClaimed') {
			$adsMsg = $claimAds.msg
			Out-Log -Level 'INFO' -Message "[$logDisplayName] $($discordText.ads_task): $adsMsg (Skipped execution)"
		}
		elseif ($adsClaimState -eq 'Claimed') {
			$adsMsg = $claimAds.msg
			Out-Log -Level 'INFO' -Message "[$logDisplayName] $($discordText.ads_task): $adsMsg (Claimed successfully)"
		}
		else {
			Out-Log -Level 'INFO' -Message "[$logDisplayName] Executing $($discordText.ads_task) (Task 1)..."
			for ($i = 1; $i -le 5; $i++) {
				Out-Log -Level 'DEBUG' -Message "[$logDisplayName] Triggering $($discordText.ads_task) ($i/5)"
				$null = Invoke-FuhouseRequest -Uri "$baseUrl/home/signup/recads" -Body "taskid=1" -Headers $headers -UserAgent $userAgent -Session $session
				Start-Sleep -Seconds 1
			}
			
			$claimAds = Invoke-FuhouseRequest -Uri "$baseUrl/home/signup/completetask" -Body "taskid=1" -Headers $headers -UserAgent $userAgent -Session $session
			$adsClaimState = Get-FuhouseTaskClaimState -Response $claimAds
			if ($adsClaimState -eq 'Claimed' -or $adsClaimState -eq 'AlreadyClaimed') {
				$adsMsg = $claimAds.msg
				Out-Log -Level 'INFO' -Message "[$logDisplayName] $($discordText.ads_task): $adsMsg"
			}
			else {
				$adsMsg = if ($claimAds.msg) { $claimAds.msg } else { $discordText.ads_task_claim_failed -f $claimAds.code }
				Out-Log -Level 'WARN' -Message "[$logDisplayName] $($discordText.ads_task): $adsMsg"
			}
		}
	}
	catch {
		$err = $_
		$adsMsg = $discordText.connection_failed -f $err.Exception.Message
		Out-Log -Level 'ERROR' -Message "[$logDisplayName] Ads Task exception: $($err.Exception.Message)"
	}

	$Embed.fields += @{ 'name' = $discordText.ads_task; 'value' = $adsMsg; 'inline' = $true }
	if ($adsClaimState -in @('Claimed', 'AlreadyClaimed')) {
		$items += New-AttendanceItemResult -Kind 'Signed' -Identity 'Fuhouse ads task'
	}
	else {
		$items += New-AttendanceItemResult -Kind 'Failed' -Identity 'Fuhouse ads task' -Reason 'TaskUnconfirmed' -Detail 'Ads task claim not confirmed'
	}

	# 4. Perform Reading Task (taskid=2)
	$readingMsg = ""
	$readingClaimState = 'Failed'
	Out-Log -Level 'INFO' -Message "[$logDisplayName] Checking $($discordText.reading_task) status..."
	try {
		$claimReading = Invoke-FuhouseRequest -Uri "$baseUrl/home/signup/completetask" -Body "taskid=2" -Headers $headers -UserAgent $userAgent -Session $session
		$readingClaimState = Get-FuhouseTaskClaimState -Response $claimReading
		if ($readingClaimState -eq 'AlreadyClaimed') {
			$readingMsg = $claimReading.msg
			Out-Log -Level 'INFO' -Message "[$logDisplayName] $($discordText.reading_task): $readingMsg (Skipped execution)"
		}
		elseif ($readingClaimState -eq 'Claimed') {
			$readingMsg = $claimReading.msg
			Out-Log -Level 'INFO' -Message "[$logDisplayName] $($discordText.reading_task): $readingMsg (Claimed successfully)"
		}
		else {
			Out-Log -Level 'INFO' -Message "[$logDisplayName] Executing $($discordText.reading_task) (Task 2)..."
			# Get daily updated books via API
			$dailyRes = Invoke-FuhouseRequest -Uri "$baseUrl/home/Api/getDailyUpdate.html" -Method 'Post' -Body "widx=11&limit=18&page=0&lastpage=" -Headers $headers -UserAgent $userAgent -Session $session
			
			$bookIds = @()
			if ($dailyRes -and $dailyRes.code -eq 200 -and $null -ne $dailyRes.result) {
				foreach ($item in $dailyRes.result) {
					if ($item.id) {
						$bookIds += $item.id
					}
				}
			}
			
			# If API didn't return books, fallback to parsing static page
			if ($bookIds.Count -eq 0) {
				Out-Log -Level 'WARN' -Message "[$logDisplayName] No books found via API, trying fallback parsing..."
				$dailyHtml = Invoke-FuhouseRequest -Uri "$baseUrl/home/index/dailyupdate1" -Method 'Get' -Headers $headers -UserAgent $userAgent -Session $session
				$matches = [regex]::Matches($dailyHtml, '/home/book/index/id/(\d+)')
				foreach ($m in $matches) {
					$bookIds += $m.Groups[1].Value
				}
				$bookIds = $bookIds | Select-Object -Unique
			}

			# Now find chapters from the books
			$chaptersToRead = @()
			foreach ($bookId in $bookIds) {
				if ($chaptersToRead.Count -ge 5) {
					break
				}
				
				$bookUrl = "$baseUrl/home/book/index/id/$bookId"
				Out-Log -Level 'DEBUG' -Message "[$logDisplayName] Fetching book detail to get chapters: $bookUrl"
				try {
					$bookHtml = Invoke-FuhouseRequest -Uri $bookUrl -Method 'Get' -Headers $headers -UserAgent $userAgent -Session $session
					# Parse chapter IDs from embedded JSON list
					$matches = [regex]::Matches($bookHtml, 'id\\":(\d+)')
					$bookChapters = @()
					foreach ($m in $matches) {
						$bookChapters += $m.Groups[1].Value
					}
					$bookChapters = $bookChapters | Select-Object -Unique
					
					# Add to chapters to read
					foreach ($cid in $bookChapters) {
						if ($chaptersToRead.Count -ge 5) {
							break
						}
						$chaptersToRead += @{ bookId = $bookId; chapterId = $cid }
					}
				}
				catch {
					Out-Log -Level 'WARN' -Message "[$logDisplayName] Failed to fetch chapters for book ($bookId) - $($_.Exception.Message)"
				}
			}

			if ($chaptersToRead.Count -eq 0) {
				$readingMsg = $discordText.no_available_chapters
				Out-Log -Level 'ERROR' -Message "[$logDisplayName] $($discordText.reading_task): $readingMsg"
			}
			else {
				$readSuccess = 0
				$readCount = $chaptersToRead.Count
				for ($i = 0; $i -lt $readCount; $i++) {
					$task = $chaptersToRead[$i]
					$bookId = $task.bookId
					$chapterId = $task.chapterId
					$chapterUrl = "$baseUrl/home/book/capter/id/$chapterId"
					Out-Log -Level 'INFO' -Message "[$logDisplayName] Reading chapter ($($i+1)/$readCount): ID $chapterId (Book $bookId)"

					# Fetch chapter page to trigger any potential cookies/headers setup
					$null = Invoke-FuhouseRequest -Uri $chapterUrl -Method 'Get' -Headers $headers -UserAgent $userAgent -Session $session

					Out-Log -Level 'INFO' -Message "[$logDisplayName] Waiting 10 seconds to satisfy reading duration..."
					Start-Sleep -Seconds 10

					$readRes = Invoke-FuhouseRequest -Uri "$baseUrl/home/book/update_read_count" -Body "bookId=$bookId&chapterId=$chapterId" -Headers $headers -UserAgent $userAgent -Session $session
					$readResStr = "$readRes"
					Out-Log -Level 'DEBUG' -Message "[$logDisplayName] Update read count response: $readResStr"
					if ($readResStr -match '^\d+$' -or $readResStr -eq "success") {
						$readSuccess++
					}
				}

				Out-Log -Level 'DEBUG' -Message "[$logDisplayName] Completed reading $readSuccess/5 chapters."
				
				$claimReading = Invoke-FuhouseRequest -Uri "$baseUrl/home/signup/completetask" -Body "taskid=2" -Headers $headers -UserAgent $userAgent -Session $session
				$readingClaimState = Get-FuhouseTaskClaimState -Response $claimReading
				if ($readingClaimState -eq 'Claimed' -or $readingClaimState -eq 'AlreadyClaimed') {
					$readingMsg = $claimReading.msg
					Out-Log -Level 'INFO' -Message "[$logDisplayName] $($discordText.reading_task): $readingMsg"
				}
				else {
					$readingMsg = if ($claimReading.msg) { $claimReading.msg } else { $discordText.reading_task_claim_failed -f $claimReading.code }
					Out-Log -Level 'WARN' -Message "[$logDisplayName] $($discordText.reading_task): $readingMsg"
				}
			}
		}
	}
	catch {
		$err = $_
		$readingMsg = $discordText.connection_failed -f $err.Exception.Message
		Out-Log -Level 'ERROR' -Message "[$logDisplayName] Reading Task exception: $($err.Exception.Message)"
	}

	$Embed.fields += @{ 'name' = $discordText.reading_task; 'value' = $readingMsg; 'inline' = $true }
	if ($readingClaimState -in @('Claimed', 'AlreadyClaimed')) {
		$items += New-AttendanceItemResult -Kind 'Signed' -Identity 'Fuhouse reading task'
	}
	else {
		$items += New-AttendanceItemResult -Kind 'Failed' -Identity 'Fuhouse reading task' -Reason 'TaskUnconfirmed' -Detail 'Reading task claim not confirmed'
	}

	return Complete-AttendanceProfileResult -Platform 'fuhouse' -Items $items
}
