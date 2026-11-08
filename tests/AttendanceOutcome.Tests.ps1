BeforeAll {
	. "$PSScriptRoot/../src/000-common.ps1"
	. "$PSScriptRoot/../src/001-discord.ps1"
	. "$PSScriptRoot/../src/002-outcome.ps1"
	. "$PSScriptRoot/../src/020-skcommon.ps1"
}

Describe 'Attendance result invariants' {
	It 'does not permit a success result with zero items' {
		$r = Complete-AttendanceProfileResult -Platform 'skport' -Items @()
		$r.Kind | Should -Be 'Failure'
		$r.Reason | Should -Be 'NoActionableItems'
		Test-AttendanceRequiresPing -Result $r | Should -BeTrue
	}

	It 'derives partial failures and notification policy from item results' {
		$items = @(
			(New-AttendanceItemResult -Kind 'Signed' -Identity 'game A'),
			(New-AttendanceItemResult -Kind 'Failed' -Identity 'game B' -Reason 'CheckInUnconfirmed')
		)
		$r = Complete-AttendanceProfileResult -Platform 'skport' -Items $items
		$r.Kind | Should -Be 'PartialFailure'
		Test-AttendanceRequiresPing -Result $r | Should -BeTrue
		$embed = Initialize-DiscordEmbed
		Complete-AttendanceEmbed -Result $r -Embed $embed | Out-Null
		$embed.color | Should -Be '16753920'
	}

	It 'rejects contradictory item records and unknown profile outcomes' {
		{ New-AttendanceItemResult -Kind 'Signed' -Identity 'game' -Reason 'Failure' } | Should -Throw
		{ New-AttendanceItemResult -Kind 'Failed' -Identity 'game' } | Should -Throw
		{ Test-AttendanceRequiresPing -Result @{ Kind = 'Success' } } | Should -Throw
	}
	It 'rejects modified outcomes that violate the constructor contract' {
		$item = New-AttendanceItemResult -Kind 'Signed' -Identity 'Game'
		$item.Reason = 'Cannot be a successful failure'
		$r = Complete-AttendanceProfileResult -Platform 'skport' -Items @($item)
		Test-AttendanceProfileResult -Result $r | Should -BeFalse
		{ Test-AttendanceRequiresPing -Result $r } | Should -Throw
		{ New-AttendanceItemResult -Kind 'Signed' -Identity '   ' } | Should -Throw
		{ Complete-AttendanceProfileResult -Platform 'skport' -Items @((New-AttendanceItemResult -Kind 'Signed' -Identity 'Game'), $null) } | Should -Throw
	}
}

Describe 'SK attendance outcomes without network or credentials' {
	BeforeEach {
		$script:scenario = 'empty'
		$script:profile = [pscustomobject]@{ cred = 'synthetic-credential' }
		$script:platformConfig = [pscustomobject]@{
			lang = 'zh_Hans'
			user_agent = 'test'
			games = @([pscustomobject]@{
				name = 'Synthetic game'
				app_code = 'endfield'
				api_base = 'https://example.invalid'
				origin_url = 'https://example.invalid'
				referer_url = 'https://example.invalid/'
				platform = '3'
				vName = '1.0'
			})
		}
		Mock Initialize-SkAuthState { $true }
		Mock Resolve-SkAwardLines { @('Synthetic reward') }
		Mock Invoke-SkApiRequest {
			if ($Path -eq '/web/v2/user') {
				if ($script:scenario -eq 'transport') { return [pscustomobject]@{ code = -1; message = 'Synthetic connection failure'; __TransportFailure = $true; __HttpStatus = 0 } }
				if ($script:scenario -eq 'baduser') { return [pscustomobject]@{ code = 0; data = @{ user = @{ basicUser = @{ nickname = 'Example' } } } } }
				return [pscustomobject]@{ code = 0; data = @{ user = @{ basicUser = @{ nickname = 'Example'; id = '1234' } } } }
			}
			if ($Path -eq '/api/v1/game/player/binding') {
				if ($script:scenario -eq 'malformed') { return [pscustomobject]@{ code = 0; data = @{ other = @() } } }
				if ($script:scenario -eq 'empty') { return [pscustomobject]@{ code = 0; data = @{ list = @() } } }
				$roleList = @(@{ roleId = '1'; serverId = '1'; nickname = 'Hero'; serverName = 'Server' })
				if ($script:scenario -eq 'partial') {
					$roleList += @{ roleId = '2'; serverId = '2'; nickname = 'Second'; serverName = 'Server' }
				}
				return [pscustomobject]@{ code = 0; data = @{ list = @(@{ appCode = 'endfield'; bindingList = @(@{ gameId = 3; uid = 'synthetic-uid'; channelName = 'Synthetic channel'; channelMasterId = 'synthetic-channel'; roles = $roleList }) }) } }
			}
			if ($Method -eq 'Post') {
				if ($script:scenario -eq 'postsuccess' -or ($script:scenario -eq 'partial' -and $Ctx.SkGameRole -like '*_1_1')) {
					return [pscustomobject]@{ code = 0; data = @{} }
				}
				return [pscustomobject]@{ code = 1001; message = 'Synthetic rejection' }
			}
			return [pscustomobject]@{ code = 0; data = @{ hasToday = ($script:scenario -eq 'already') } }
		}
	}

	It 'parses the browser HAR Endfield binding shape into a usable Skport role' {
		$binding = [pscustomobject]@{
			list = @([pscustomobject]@{
				appCode = 'endfield'
				bindingList = @([pscustomobject]@{
					uid = 'synthetic-uid'; gameId = 3
					channelMasterId = 'channel'; channelName = 'Channel'
					gameName = 'Game'
					roles = @([pscustomobject]@{ roleId = 'role-1'; serverId = 'server-1'; nickname = 'Hero'; serverName = 'Server' })
				})
			})
		}
		$roles = @(Expand-SkRoles -BindingData $binding -Provider 'skport')
		$roles.Count | Should -Be 1
		$roles[0].gameId | Should -Be 3
		$roles[0].uid | Should -Be 'synthetic-uid'
		$roles[0].channelMasterId | Should -Be 'channel'
	}

	It 'refreshes and retries only once after an HTTP 401' {
		$script:retries = 0
		Mock Invoke-SkApiRequest {
			$script:retries++
			if ($script:retries -eq 1) { return [pscustomobject]@{ code = 10000; __HttpStatus = 401 } }
			return [pscustomobject]@{ code = 0; data = @{ list = @() } }
		}
		$ctx = @{ ProviderProfile = (Get-SkProviderProfile -Provider 'skport') }
		$ret = Invoke-SkAuthorizedApiRequest -Method 'Get' -Path '/api/v1/game/player/binding' -Ctx $ctx
		$ret.code | Should -Be 0
		$script:retries | Should -Be 2
		Should -Invoke Initialize-SkAuthState -Times 1 -Exactly
	}

	It 'does not repeat a POST after an ambiguous transport failure' {
		Mock Invoke-SkApiRequest {
			return [pscustomobject]@{ code = -1; message = 'Synthetic timeout'; __TransportFailure = $true; __HttpStatus = 0 }
		}
		$ctx = @{ ProviderProfile = (Get-SkProviderProfile -Provider 'skport') }
		$response = Invoke-SkAuthorizedApiRequest -Method 'Post' -Path '/web/v1/game/endfield/attendance' -Ctx $ctx
		$response.code | Should -Be -1
		Should -Invoke Invoke-SkApiRequest -Times 1 -Exactly
		Should -Invoke Initialize-SkAuthState -Times 0 -Exactly
	}

	It 'classifies repeated HTTP 401 as authentication failure instead of no roles' {
		Mock Invoke-SkApiRequest { [pscustomobject]@{ code = 10000; __HttpStatus = 401 } }
		$ctx = @{ ProviderProfile = (Get-SkProviderProfile -Provider 'skport') }
		$ret = Get-SkDataResult -Ctx $ctx -Path '/api/v1/game/player/binding' -Operation 'Binding lookup'
		$ret.Kind | Should -Be 'Failure'
		$ret.Reason | Should -Be 'AuthenticationFailed'
		Should -Invoke Invoke-SkApiRequest -Times 2 -Exactly
	}

	It 'does not POST when the already-signed status is confirmed' {
		$script:scenario = 'already'
		$r = Invoke-SkAttendanceCore -Provider 'skport' -Profile $script:profile -PlatformConfig $script:platformConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'AlreadySigned'
		Should -Invoke Invoke-SkApiRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
	}

	It 'does not POST when the initial attendance status is unavailable' {
		$script:scenario = 'unavailable'
		Mock Invoke-SkApiRequest {
			if ($Path -eq '/web/v2/user') { return [pscustomobject]@{ code = 0; data = @{ user = @{ basicUser = @{ id = '1234'; nickname = 'Example' } } } } }
			if ($Path -eq '/api/v1/game/player/binding') {
				return [pscustomobject]@{ code = 0; data = @{ list = @(@{ appCode = 'endfield'; bindingList = @(@{ uid = 'synthetic-uid'; gameId = 3; roles = @(@{ roleId = '1'; serverId = '1'; nickname = 'Hero' }) }) }) } }
			}
			if ($Method -eq 'Post') { throw 'POST must not execute when status is unknown' }
			return [pscustomobject]@{ code = 503; message = 'Status unavailable' }
		}
		$r = Invoke-SkAttendanceCore -Provider 'skport' -Profile $script:profile -PlatformConfig $script:platformConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Failure'
		$r.Items[0].Reason | Should -Be 'StatusUnavailable'
		Should -Invoke Invoke-SkApiRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
	}

	It 'reports a missing binding as failure requiring a ping' {
		$r = Invoke-SkAttendanceCore -Provider 'skport' -Profile $script:profile -PlatformConfig $script:platformConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Failure'
		$r.Reason | Should -Be 'NoBoundRoles'
		Test-AttendanceRequiresPing -Result $r | Should -BeTrue
	}

	It 'distinguishes connection failure from invalid identity and malformed bindings' {
		foreach ($case in @(
			@{ Scenario = 'transport'; Reason = 'TransportError' },
			@{ Scenario = 'baduser'; Reason = 'InvalidResponse' },
			@{ Scenario = 'malformed'; Reason = 'InvalidResponse' }
		)) {
			$script:scenario = $case.Scenario
			$r = Invoke-SkAttendanceCore -Provider 'skport' -Profile $script:profile -PlatformConfig $script:platformConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
			$r.Kind | Should -Be 'Failure'
			$r.Reason | Should -Be $case.Reason
		}
	}

	It 'does not confuse a successful status GET with a confirmed check-in' {
		$script:scenario = 'notconfirmed'
		$r = Invoke-SkAttendanceCore -Provider 'skport' -Profile $script:profile -PlatformConfig $script:platformConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Failure'
		$r.Items[0].Reason | Should -Be 'CheckInUnconfirmed'
	}

	It 'accepts a confirmed already-signed response' {
		$script:scenario = 'already'
		$r = Invoke-SkAttendanceCore -Provider 'skport' -Profile $script:profile -PlatformConfig $script:platformConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'AlreadySigned'
		Test-AttendanceRequiresPing -Result $r | Should -BeFalse
	}

	It 'preserves partial failure when one role signs successfully' {
		$script:scenario = 'partial'
		$r = Invoke-SkAttendanceCore -Provider 'skport' -Profile $script:profile -PlatformConfig $script:platformConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'PartialFailure'
		$r.Items.Count | Should -Be 2
		Test-AttendanceRequiresPing -Result $r | Should -BeTrue
	}
}
Describe 'Discord notifications derive from validated outcomes' {
	BeforeEach {
		$script:webCalls = @()
		Mock Invoke-RestMethod {
			$script:webCalls += [pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body }
			if ($Method -eq 'Get') {
				return [pscustomobject]@{
					embeds = @([pscustomobject]@{
						title = 'Previous success'
						color = 5635840
						description = 'Old user'
						fields = @([pscustomobject]@{ name = 'Game'; value = 'green result'; inline = $true })
					})
				}
			}
			return [pscustomobject]@{ id = '111111111111111111' }
		}
		$script:bot = @{
			webhook_url = 'https://discord.invalid/webhook'
			reuse_msg = '123456789012345678'
			minimal = $false
			overwrite = $false
			discord_name = 'Example bot'
		}
	}

	It 'replaces stale green embeds on failure and pings configured recipients' {
		$failure = New-AttendanceProfileFailure -Platform 'skport' -Reason 'NoBoundRoles' -Message 'No roles'
		$embed = Initialize-DiscordEmbed
		Complete-AttendanceEmbed -Result $failure -Embed $embed | Out-Null
		Send-DiscordNotification -BotConfig $script:bot -Embeds @($embed) -NeedPing $true -PingString '<@12345>' -GlobalConfig @{}
		$patched = @($script:webCalls | Where-Object Method -eq 'Patch')
		$patched.Count | Should -Be 1
		$body = $patched[0].Body | ConvertFrom-Json
		@($body.embeds).Count | Should -Be 1
		$body.embeds[0].color | Should -Be 16711680
		$body.embeds[0].title | Should -Be 'skport attendance: Failure'
		@($script:webCalls | Where-Object Method -eq 'Post').Count | Should -Be 1
	}

	It 'never posts an empty mention when recipients are not configured' {
		$failure = New-AttendanceProfileFailure -Platform 'skport' -Reason 'NoBoundRoles' -Message 'No roles'
		$embed = Initialize-DiscordEmbed
		Complete-AttendanceEmbed -Result $failure -Embed $embed | Out-Null
		Send-DiscordNotification -BotConfig $script:bot -Embeds @($embed) -NeedPing $true -PingString '' -GlobalConfig @{}
		@($script:webCalls | Where-Object Method -eq 'Patch').Count | Should -Be 1
		@($script:webCalls | Where-Object Method -eq 'Post').Count | Should -Be 0
	}
}

Describe 'HoYoLAB returns typed check-in results' {
	BeforeAll {
		. "$PSScriptRoot/../src/011-hoyolab.ps1"
	}
	BeforeEach {
		$script:hoyoProfile = [pscustomobject]@{ lang = 'en-us'; ltoken = ('a' * 40); ltuid = '12345' }
		$script:hoyoConfig = [pscustomobject]@{
			lang = 'en-us'
			user_agent = 'test'
			discord_text = [pscustomobject]@{ need_captcha = 'Captcha required' }
			games = @([pscustomobject]@{
				name = 'Synthetic game'
				api_base = 'https://example.invalid'
				origin_url = 'https://example.invalid'
				referer_url = 'https://example.invalid/'
				game_id = 'test-game'
				act_id = 'test-act'
			})
		}
		Mock Get-HoyolabAccountInfo { @{ Success = $true; DisplayName = 'Example' } }
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ sign_cnt_missed = 0; is_sign = $false; total_sign_day = 1; today = 'Today' } } }
			if ($Uri -like '*/sign?*') { return [pscustomobject]@{ retcode = 1999; message = 'Synthetic check-in rejection' } }
			throw 'Unexpected synthetic request'
		}
	}

	It 'reports a non-authentication API rejection rather than silently continuing' {
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Failure'
		$r.Items[0].Reason | Should -Be 'CheckInUnconfirmed'
		Test-AttendanceRequiresPing -Result $r | Should -BeTrue
	}

	It 'reports a confirmed already-signed provider response without a reward fetch' {
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ sign_cnt_missed = 0; is_sign = $true; total_sign_day = 1; today = 'Today' } } }
			if ($Uri -like '*/sign?*') { return [pscustomobject]@{ retcode = -10002; message = 'Already signed' } }
			throw 'Unexpected synthetic request'
		}
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'AlreadySigned'
		Test-AttendanceRequiresPing -Result $r | Should -BeFalse
	}
	It 'does not issue a POST when the initial status confirms already signed' {
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') {
				return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $true; total_sign_day = 1 } }
			}
			throw 'The provider should not receive another sign-in request'
		}
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'AlreadySigned'
		Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
	}

	It 'keeps a confirmed sign-in when reward enrichment fails' {
		$embed = Initialize-DiscordEmbed
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') {
				return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $false; sign_cnt_missed = 0; total_sign_day = 1 } }
			}
			if ($Uri -like '*/sign?*') { return [pscustomobject]@{ retcode = 0; message = 'OK' } }
			if ($Uri -like '*/home?*') { throw 'Synthetic reward service outage' }
			throw 'Unexpected request'
		}
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed $embed -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'Signed'
		$embed.fields[0].value | Should -Be 'Signed today; reward details unavailable'
	}
}

Describe 'Fuhouse reports partial failures for individual tasks' {
	BeforeAll {
		. "$PSScriptRoot/../src/012-fuhouse.ps1"
	}
	BeforeEach {
		$script:fuhouseScenario = 'signfailure'
		$script:fuhouseProfile = [pscustomobject]@{ cookies = 'PHPSESSID=test-cookie' }
		$script:fuhouseConfig = [pscustomobject]@{ base_url = 'https://example.invalid'; user_agent = 'test'; discord_text = $null }
		Mock Invoke-FuhouseRequest {
			if ($Uri -like '*/home/user/index.html') { return '<p class="name">Example</p><script>__PC_HISTORY_UID = 12345</script>' }
			if ($Uri -like '*/home/Api/signupNew.html') {
				if ($script:fuhouseScenario -eq 'signfailure') { return [pscustomobject]@{ code = 500; msg = 'synthetic sign failure' } }
				return [pscustomobject]@{ code = 2000; msg = 'signed' }
			}
			if ($Uri -like '*/home/signup/completetask') { return [pscustomobject]@{ code = 400; msg = 'already claimed' } }
			throw "Unexpected synthetic request $Uri"
		}
	}

	It 'does not show a green aggregate when sign-in fails but tasks are claimed' {
		$r = Invoke-FuhouseAttendance -Profiie $script:fuhouseProfile -Config $script:fuhouseConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'PartialFailure'
		@($r.Items | Where-Object Kind -eq 'Failed').Count | Should -Be 1
		Test-AttendanceRequiresPing -Result $r | Should -BeTrue
	}

	It 'reports success only when sign-in and both tasks are confirmed' {
		$script:fuhouseScenario = 'success'
		$r = Invoke-FuhouseAttendance -Profiie $script:fuhouseProfile -Config $script:fuhouseConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items.Count | Should -Be 3
		Test-AttendanceRequiresPing -Result $r | Should -BeFalse
	}
}

Describe 'Attendance entrypoint never treats a missing handler result as success' {
	BeforeAll {
		. "$PSScriptRoot/../src/021-skport.ps1"
		. "$PSScriptRoot/../src/991-sign.ps1"
	}
	BeforeEach {
		$script:notice = $null
		Mock Invoke-SkportAttendance { return $null }
		Mock Send-DiscordNotification {
			$script:notice = [pscustomobject]@{
				NeedPing = $NeedPing
				Embeds = @($Embeds)
			}
		}
	}

	It 'renders a failed profile and requests the Discord ping when a handler returns null' {
		$config = @{
			display = @{
				console = $false
				discord = @{
					bots = @(@{
						discord_name = 'test bot'
						webhook_url = 'https://discord.invalid/webhook'
						reuse_msg = $false
						profiles = @(0)
						ping = @{ user = @('12345') }
					})
				}
			}
			profiles = @(@{ platform = 'skport'; console_name = 'Example'; cred = 'synthetic-credential' })
			platforms = @{
				skport = @{
					lang = 'zh_Hans'
					user_agent = 'test'
					games = @(@{
						name = 'Synthetic game'; app_code = 'endfield'
						api_base = 'https://example.invalid'
						origin_url = 'https://example.invalid'
						referer_url = 'https://example.invalid/'
						platform = '3'; vName = '1.0'
					})
				}
			}
		}
		$path = Join-Path $TestDrive 'synthetic-config.json'
		$config | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path -Encoding UTF8
		Invoke-AnimeAttendance -ConfigPath $path | Out-Null
		$script:notice | Should -Not -BeNullOrEmpty
		$script:notice.NeedPing | Should -BeTrue
		$script:notice.Embeds.Count | Should -Be 1
		$script:notice.Embeds[0].color | Should -Be '16711680'
		$script:notice.Embeds[0].fields[0].value | Should -Be 'Handler returned an invalid outcome'
	}
}

Describe 'Discord recovery removes stale failure fields' {
	BeforeAll {
		. "$PSScriptRoot/../src/001-discord.ps1"
	}
	It 'replaces an old red embed with a fresh green confirmation' {
		$script:patchBody = $null
		Mock Invoke-RestMethod {
			if ($Method -eq 'Get') {
				return [pscustomobject]@{
					embeds = @([pscustomobject]@{
						title = 'Old failure'
						color = 16711680
						description = 'Old user'
						fields = @([pscustomobject]@{ name = 'Error'; value = 'No bound roles'; inline = $true })
					})
				}
			}
			if ($Method -eq 'Patch') { $script:patchBody = $Body }
			return [pscustomobject]@{ id = '111111111111111111' }
		}
		$result = Complete-AttendanceProfileResult -Platform 'skport' -Items @((New-AttendanceItemResult -Kind 'AlreadySigned' -Identity 'Game'))
		$embed = Initialize-DiscordEmbed
		Complete-AttendanceEmbed -Result $result -Embed $embed | Out-Null
		$bot = @{ webhook_url = 'https://discord.invalid/webhook'; reuse_msg = '123456789012345678'; minimal = $false; overwrite = $false }
		Send-DiscordNotification -BotConfig $bot -Embeds @($embed) -NeedPing $false -PingString '' -GlobalConfig @{}
		$body = $script:patchBody | ConvertFrom-Json
		$body.embeds.Count | Should -Be 1
		$body.embeds[0].color | Should -Be 5635840
		@($body.embeds[0].fields).Count | Should -Be 0
	}
}