BeforeAll {
	. "$PSScriptRoot/../src/000-common.ps1"
	. "$PSScriptRoot/../src/001-discord.ps1"
	. "$PSScriptRoot/../src/002-outcome.ps1"
	. "$PSScriptRoot/../src/019-skland-device.ps1"
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

	It 'keeps actual AlreadySigned reward fields when reusing a Discord message' {
		$script:scenario = 'already'
		$embed = Initialize-DiscordEmbed
		$result = Invoke-SkAttendanceCore -Provider 'skport' -Profile $script:profile -PlatformConfig $script:platformConfig -Embed $embed -IsReusing $true
		$result.Kind | Should -Be 'Success'
		$result.Items[0].Kind | Should -Be 'AlreadySigned'
		$embed.fields | Should -HaveCount 1
		$embed.fields[0].value | Should -Match 'Synthetic reward'
		$embed.fields[0].key | Should -Not -BeNullOrEmpty
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
Describe 'Skland Arknights calendar and signature behavior (synthetic)' {
	BeforeEach {
		$script:day = [DateTimeOffset]::Parse('2026-11-08T12:00:00+08:00').ToUnixTimeSeconds()
		$script:arkProfile = [pscustomobject]@{ token = 'fake-token'; cred = 'fake-cred'; device = [pscustomobject]@{ id = 'Bsynthetic-device'; seed = 'synthetic-device-seed' } }
		$script:arkConfig = [pscustomobject]@{
			lang = 'zh_Hans'; user_agent = 'Synthetic-client'
			games = @([pscustomobject]@{
				name = 'Synthetic Arknights'; app_code = 'arknights'; platform = '3'; vName = '1.0.0'
				api_base = 'https://example.invalid'; origin_url = 'https://example.invalid'
				referer_url = 'https://example.invalid/'
			})
		}
		$script:arkCalls = @()
		$script:arkState = 'Signed'
		$script:arkPost = -101
		Mock Initialize-SkAuthState { $true }
		Mock Resolve-SkAwardLines { @('Synthetic reward') }
		Mock Invoke-SkApiRequest {
			if ($Path -eq '/web/v1/user') {
				return [pscustomobject]@{ code = 0; data = @{ user = @{ nickname = 'SyntheticAccount'; id = 'uid-a' } } }
			}
			if ($Path -eq '/api/v1/game/player/binding') {
				return [pscustomobject]@{ code = 0; data = @{
					list = @(@{ appCode = 'arknights'; bindingList = @(@{
						gameId = 1; channelMasterId = '2'; uid = 'uid-a'
						channelName = 'Synthetic channel'; nickName = 'Synthetic Hero'
					}) })
				} }
			}
			if ($Path -eq '/api/v1/game/attendance') {
				$script:arkCalls += [pscustomobject]@{
					method = $Method; queryGameId = $Query.gameId; bodyGameId = $Body.gameId
				}
				if ($Method -eq 'Post') { return [pscustomobject]@{ code = $script:arkPost; message = 'Synthetic response' } }
				$index = @($script:arkCalls | Where-Object method -eq 'Get').Count
				$signed = $script:arkState -eq 'Signed' -or ($script:arkState -eq 'AfterPost' -and $index -gt 1)
				$calendar = @(
					1..30 | ForEach-Object { [pscustomobject]@{ done = $false; available = $true } }
				)
				$calendar[7].done = $signed
				$records = if ($signed) { @([pscustomobject]@{ ts = $script:day; resourceId = 'fake-item' }) } else { @() }
				return [pscustomobject]@{ code = 0; data = [pscustomobject]@{
					currentTs = $script:day; records = $records; calendar = $calendar
				} }
			}
			throw 'Unexpected synthetic request'
		}
	}

	It 'recognizes signed status from Arknights records and calendar, without hasToday' {
		$calendar = @(1..30 | ForEach-Object { [pscustomobject]@{ done = $false } })
		$calendar[7].done = $true
		$response = @{ code = 0; data = @{
			currentTs = $script:day; records = @(@{ ts = $script:day }); calendar = $calendar
		} }
		Get-SkAttendanceState -Provider 'skland' -AppCode 'arknights' -Response $response | Should -Be 'Signed'
		$response.data.records = @()
		Get-SkAttendanceState -Provider 'skland' -AppCode 'arknights' -Response $response | Should -Be 'Signed'
		$calendar[7].done = $false
		Get-SkAttendanceState -Provider 'skland' -AppCode 'arknights' -Response $response | Should -Be 'NotSigned'
		$response.data.currentTs = $null
		Get-SkAttendanceState -Provider 'skland' -AppCode 'arknights' -Response $response | Should -Be 'Unknown'
	}

	It 'accepts Endfield hasToday only when explicitly boolean' {
		Get-SkAttendanceState -Provider 'skport' -AppCode 'endfield' -Response @{ code = 0; data = @{ hasToday = $true } } | Should -Be 'Signed'
		Get-SkAttendanceState -Provider 'skland' -AppCode 'endfield' -Response @{ code = 0; data = @{ hasToday = $false } } | Should -Be 'NotSigned'
		Get-SkAttendanceState -Provider 'skland' -AppCode 'endfield' -Response @{ code = 0; data = @{ records = @() } } | Should -Be 'Unknown'
	}

	It 'skips POST when Arknights already checked in and uses channelMasterId for the GET' {
		$result = Invoke-SkAttendanceCore -Provider 'skland' -Profile $script:arkProfile -PlatformConfig $script:arkConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$result.Kind | Should -Be 'Success'
		$result.Items[0].Kind | Should -Be 'AlreadySigned'
		@($script:arkCalls | Where-Object method -eq 'Post').Count | Should -Be 0
		@($script:arkCalls | Where-Object method -eq 'Get').Count | Should -Be 1
		$script:arkCalls[0].queryGameId | Should -Be '2'
	}

	It 'accepts confirmed post-race calendar despite nonzero POST code' {
		$script:arkState = 'AfterPost'
		$result = Invoke-SkAttendanceCore -Provider 'skland' -Profile $script:arkProfile -PlatformConfig $script:arkConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$result.Kind | Should -Be 'Success'
		$result.Items[0].Kind | Should -Be 'AlreadySigned'
		@($script:arkCalls | Where-Object method -eq 'Post').Count | Should -Be 1
		@($script:arkCalls | Where-Object method -eq 'Get').Count | Should -Be 2
		@($script:arkCalls | Where-Object method -eq 'Post')[0].bodyGameId | Should -Be '2'
	}

	It 'accepts explicit provider already-signed confirmation even if Bilibili calendar is empty' {
		$script:arkState = 'NotSigned'
		$script:arkPost = 10001
		Mock Invoke-SkApiRequest {
			if ($Path -eq '/web/v1/user') { return [pscustomobject]@{ code = 0; data = @{ user = @{ nickname = 'SyntheticAccount'; id = 'uid-a' } } } }
			if ($Path -eq '/api/v1/game/player/binding') {
				return [pscustomobject]@{ code = 0; data = @{
					list = @(@{ appCode = 'arknights'; bindingList = @(@{
						gameId = 1; channelMasterId = '2'; uid = 'uid-a'; channelName = 'Bilibili'; nickName = 'Synthetic'
					}) })
				} }
			}
			if ($Path -eq '/api/v1/game/attendance') {
				if ($Method -eq 'Post') {
					return [pscustomobject]@{ code = 10001; message = (([char]0x5df2, [char]0x7b7e, [char]0x5230) -join ''); __HttpStatus = 403 }
				}
				$cal = @(1..30 | ForEach-Object { [pscustomobject]@{ done = $false; available = $false } })
				return [pscustomobject]@{ code = 0; data = [pscustomobject]@{
					currentTs = $script:day; records = @(); calendar = $cal
				} }
			}
			throw 'Unexpected synthetic request'
		}
		$embed = Initialize-DiscordEmbed
		$result = Invoke-SkAttendanceCore -Provider 'skland' -Profile $script:arkProfile -PlatformConfig $script:arkConfig -Embed $embed -IsReusing $false
		$result.Kind | Should -Be 'Success'
		$result.Items[0].Kind | Should -Be 'AlreadySigned'
		$result.Items[0].Reason | Should -Be ''
		Test-AttendanceRequiresPing -Result $result | Should -BeFalse
		$embed.fields | Should -HaveCount 1
		$embed.fields[0].value | Should -Match 'Synthetic reward'
		$embed.fields[0].value | Should -Not -Match 'ERROR|ProviderStateConflict'
		Should -Invoke Resolve-SkAwardLines -Times 1 -Exactly -ParameterFilter { $UseCalendarToday }
	}

	It 'keeps ambiguous 10001 without an already-signed message as a failure' {
		$script:arkState = 'NotSigned'
		$script:arkPost = 10001
		$result = Invoke-SkAttendanceCore -Provider 'skland' -Profile $script:arkProfile -PlatformConfig $script:arkConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$result.Kind | Should -Be 'Failure'
		$result.Items[0].Reason | Should -Be 'CheckInUnconfirmed'
		Test-AttendanceRequiresPing -Result $result | Should -BeTrue
	}

	It 'only accepts Arknights already-signed responses with clear provider messages' {
		$valid = [pscustomobject]@{code=10001; message=(([char]0x5df2,[char]0x7b7e,[char]0x5230) -join '')}
		Test-SkAlreadySignedResponse -Provider 'skland' -AppCode 'arknights' -Response $valid | Should -BeTrue
		Test-SkAlreadySignedResponse -Provider 'skland' -AppCode 'endfield' -Response $valid | Should -BeFalse
		Test-SkAlreadySignedResponse -Provider 'skport' -AppCode 'arknights' -Response $valid | Should -BeFalse
		Test-SkAlreadySignedResponse -Provider 'skland' -AppCode 'arknights' -Response ([pscustomobject]@{code=10001;message='Unauthorized'}) | Should -BeFalse
		Test-SkAlreadySignedResponse -Provider 'skland' -AppCode 'arknights' -Response ([pscustomobject]@{code=10001;message='Invalid game role'}) | Should -BeFalse
		Test-SkAlreadySignedResponse -Provider 'skland' -AppCode 'arknights' -Response ([pscustomobject]@{code=0;message='Already signed'}) | Should -BeFalse
	}
	It 'preserves POST -403 as failure even when the follow-up GET itself succeeds' {
		$script:arkState = 'NotSigned'
		$script:arkPost = -403
		$result = Invoke-SkAttendanceCore -Provider 'skland' -Profile $script:arkProfile -PlatformConfig $script:arkConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$result.Kind | Should -Be 'Failure'
		$result.Items[0].Reason | Should -Be 'CheckInUnconfirmed'
		$result.Items[0].Detail | Should -Match 'POST: -403; GET: 0'
		@($script:arkCalls | Where-Object method -eq 'Post').Count | Should -Be 1
		@($script:arkCalls | Where-Object method -eq 'Get').Count | Should -Be 2
	}
	It 'does not call a failed POST successful when calendar stays unsigned' {
		$script:arkState = 'NotSigned'
		$result = Invoke-SkAttendanceCore -Provider 'skland' -Profile $script:arkProfile -PlatformConfig $script:arkConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$result.Kind | Should -Be 'Failure'
		$result.Items[0].Reason | Should -Be 'CheckInUnconfirmed'
	}

	It 'selects the Arknights app signature independently of stale browser settings' {
		$provider = Get-SkProviderProfile -Provider 'skland'
		$game = $script:arkConfig.games[0]
		$ctx = @{ GameConfig = $game; ProviderProfile = $provider; PlatformConfig = $script:arkConfig; DId = 'Bsynthetic-device'; Cred = 'synthetic-cred'; Token = 'synthetic-signing-token'; TimeOffset = 0 }
		$options = Get-SkGameSignatureOptions -Ctx $ctx -Path '/api/v1/game/attendance'
		$options.platform | Should -Be '1'
		$options.vName | Should -Be '1.5.1'
		$options.dId | Should -Be 'Bsynthetic-device'
		$options.appRequest | Should -BeTrue
		$options.userAgent | Should -Be 'Skland/1.5.1 (com.hypergryph.skland; build:100501001; Android 34; ) Okhttp/4.11.0'
		$ctx.GameConfig = [pscustomobject]@{ app_code = 'arknights'; platform = '1'; vName = '1.21.0' }
		$modern = Get-SkGameSignatureOptions -Ctx $ctx -Path '/api/v1/game/attendance'
		$modern.vName | Should -Be '1.5.1'
		$modern.dId | Should -Be 'Bsynthetic-device'
		$ctx.GameConfig = [pscustomobject]@{ app_code = 'endfield'; platform = '1'; vName = '1.21.0' }
		$endfield = Get-SkGameSignatureOptions -Ctx $ctx -Path '/api/v1/game/endfield/attendance'
		$endfield.platform | Should -Be '3'
		$endfield.vName | Should -Be '1.0.0'
		$endfield.dId | Should -Be ''
		$endfield.appRequest | Should -BeNullOrEmpty
		Get-SkGameSignatureOptions -Ctx $ctx -Path '/web/v1/user/auth/generate_cred_by_code' | Should -BeNullOrEmpty
	}


}
Describe 'HTTP error response retains the provider API code (synthetic)' {
	It 'uses JSON ErrorDetails after PowerShell consumes an HTTP 403 response body' {
		$response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
		$response.Content = [System.Net.Http.StringContent]::new('', [Text.Encoding]::UTF8, 'application/json')
		$record = [pscustomobject]@{
			Exception = [pscustomobject]@{ Response = $response; Message = '403 Forbidden' }
			ErrorDetails = [pscustomobject]@{ Message = '{"code":10001,"message":"Already signed today"}' }
		}
		$normalized = ConvertFrom-SkRequestError -ErrorRecord $record
		$normalized.code | Should -Be 10001
		$normalized.__HttpStatus | Should -Be 403
		$normalized.message | Should -Be 'Already signed today'
	}
}
Describe 'Arknights Bilibili scheduled award fallback' {
	BeforeEach {
		$script:rewardTime = [DateTimeOffset]::Parse('2026-11-13T12:00:00+08:00').ToUnixTimeSeconds()
		$script:rewardCtx = @{
			ProviderProfile = (Get-SkProviderProfile -Provider 'skland')
			GameConfig = [pscustomobject]@{ app_code = 'arknights' }
			PlatformConfig = [pscustomobject]@{ lang = 'zh_Hans' }
		}
		$script:rewardCalendar = @(1..30 | ForEach-Object {
			[pscustomobject]@{ resourceId = '2003'; type = 'daily'; count = 1; done = $false; available = $false }
		})
		$script:rewardCalendar[12].count = 2
		$script:rewardData = [pscustomobject]@{
			currentTs = $script:rewardTime
			calendar = $script:rewardCalendar
			first = $null
			records = @()
			resourceInfoMap = @{ '2003' = [pscustomobject]@{ name = 'Synthetic calendar item'; count = 99 } }
		}
	}

	It 'uses the Bilibili role own calendar after explicit AlreadySigned, not its done flag' {
		@(Resolve-SkAwardLines -Data $script:rewardData -Ctx $script:rewardCtx) | Should -Be @('Reward detail unavailable from provider API.')
		$lines = @(Resolve-SkAwardLines -Data $script:rewardData -Ctx $script:rewardCtx -UseCalendarToday)
		$lines | Should -HaveCount 1
		$lines[0] | Should -Be 'Synthetic calendar item x2'
	}

	It 'will not fabricate calendar rewards when the date or resource metadata is unavailable' {
		$script:rewardData.currentTs = $null
		@(Resolve-SkAwardLines -Data $script:rewardData -Ctx $script:rewardCtx -UseCalendarToday) | Should -Be @('Reward detail unavailable from provider API.')
		$script:rewardData.currentTs = $script:rewardTime
		$script:rewardData.resourceInfoMap = @{}
		@(Resolve-SkAwardLines -Data $script:rewardData -Ctx $script:rewardCtx -UseCalendarToday) | Should -Be @('Reward detail unavailable from provider API.')
	}

	It 'does not reuse the Arknights fallback for Skport or Endfield' {
		$script:rewardCtx.ProviderProfile = Get-SkProviderProfile -Provider 'skport'
		@(Resolve-SkAwardLines -Data $script:rewardData -Ctx $script:rewardCtx -UseCalendarToday) | Should -Be @('Reward detail unavailable from provider API.')
		$script:rewardCtx.ProviderProfile = Get-SkProviderProfile -Provider 'skland'
		$script:rewardCtx.GameConfig.app_code = 'endfield'
		@(Resolve-SkAwardLines -Data $script:rewardData -Ctx $script:rewardCtx -UseCalendarToday) | Should -Be @('Reward detail unavailable from provider API.')
	}

	It 'prefers actual POST awards to any scheduled calendar entry' {
		$script:rewardData | Add-Member -NotePropertyName awards -NotePropertyValue @(
			[pscustomobject]@{ resource = [pscustomobject]@{ name = 'Real POST reward' }; count = 3 }
		)
		$lines = @(Resolve-SkAwardLines -Data $script:rewardData -Ctx $script:rewardCtx -UseCalendarToday)
		$lines | Should -HaveCount 1
		$lines[0] | Should -Be 'Real POST reward x3'
	}
}
Describe 'Skland attendance wire contract without high-level API mocks' {
	It 'uses app headers for Arknights POST while keeping signed JSON identical to wire body' {
		$script:arkRequestParams = $null
		Mock Invoke-RestMethod {
			$script:arkRequestParams = @{ Method = $Method; Headers = $Headers; UserAgent = $UserAgent; Body = $Body; SkipHttpErrorCheck = $SkipHttpErrorCheck }
			return [pscustomobject]@{ code = 0; data = @{} }
		}
		$provider = Get-SkProviderProfile -Provider 'skland'
		$gameConfig = [pscustomobject]@{
			app_code = 'arknights'; platform = '1'; vName = '1.21.0'
			api_base = 'https://example.invalid'
			origin_url = 'https://example.invalid'
			referer_url = 'https://example.invalid/'
		}
		$platformConfig = [pscustomobject]@{ lang = 'zh_Hans'; user_agent = 'Synthetic client'; games = @($gameConfig) }
		$ctx = @{
			GameConfig = $gameConfig
			ProviderProfile = $provider
			PlatformConfig = $platformConfig
			DId = 'Bsynthetic-device'
			Cred = 'synthetic-cred'
			Token = 'synthetic-signing-token'
			TimeOffset = 0
			SkGameRole = $null
		}
		$result = Invoke-SkApiRequest -Method Post -Path '/api/v1/game/attendance' -Ctx $ctx -Body @{ uid = 'synthetic-uid'; gameId = '2' }
		$result.code | Should -Be 0
		$script:arkRequestParams.Headers.platform | Should -Be '1'
		$script:arkRequestParams.Headers.vName | Should -Be '1.5.1'
		$script:arkRequestParams.Headers.dId | Should -Be 'Bsynthetic-device'
		$script:arkRequestParams.UserAgent | Should -Be 'Skland/1.5.1 (com.hypergryph.skland; build:100501001; Android 34; ) Okhttp/4.11.0'
		$script:arkRequestParams.Headers.ContainsKey('Origin') | Should -BeFalse
		$script:arkRequestParams.Headers.ContainsKey('Referer') | Should -BeFalse
		$script:arkRequestParams.Headers.ContainsKey('Sec-Fetch-Mode') | Should -BeFalse
		$script:arkRequestParams.Headers.ContainsKey('sk-game-role') | Should -BeFalse
		$script:arkRequestParams.Headers.sign | Should -Match '^[a-f0-9]{32}$'
		$script:arkRequestParams.SkipHttpErrorCheck | Should -BeTrue
		$wireBody = $script:arkRequestParams.Body | ConvertFrom-Json
		$wireBody.uid | Should -Be 'synthetic-uid'
		$wireBody.gameId | Should -Be '2'
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

Describe 'Skipped item outcome contract' {
	It 'does not classify a non-applicable game as signed or failed' {
		$skipped = New-AttendanceItemResult -Kind 'Skipped' -Identity 'uncreated-game' -Reason 'NoGameCharacter'
		$profile = Complete-AttendanceProfileResult -Platform 'hoyolab' -Items @($skipped)
		$profile.Kind | Should -Be 'Skipped'
		Test-AttendanceProfileResult -Result $profile | Should -BeTrue
		Test-AttendanceRequiresPing -Result $profile | Should -BeFalse
		$profile.Reason | Should -Be 'NoActionableItems'
	}
	It 'preserves a failed other game alongside a skipped game' {
		$items = @(
			(New-AttendanceItemResult -Kind 'Skipped' -Identity 'uncreated-game' -Reason 'NoGameCharacter'),
			(New-AttendanceItemResult -Kind 'Failed' -Identity 'failed-game' -Reason 'InvalidResponse')
		)
		$result = Complete-AttendanceProfileResult -Platform 'hoyolab' -Items $items
		$result.Kind | Should -Be 'Failure'
		Test-AttendanceProfileResult -Result $result | Should -BeTrue
		Test-AttendanceRequiresPing -Result $result | Should -BeTrue
	}
	It 'rejects skipped outcomes without an explicit reason' {
		{ New-AttendanceItemResult -Kind 'Skipped' -Identity 'uncreated-game' } | Should -Throw
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

	It 'skips a never-created game character without POST or failure notification' {
		$embed = Initialize-DiscordEmbed
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') { return [pscustomobject]@{ retcode = -10002; message = 'No character created'; data = $null } }
			throw 'POST and reward endpoints must not be called for an absent character'
		}

		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed $embed -IsReusing $false
		$r.Kind | Should -Be 'Skipped'
		$r.Items | Should -HaveCount 1
		$r.Items[0].Kind | Should -Be 'Skipped'
		$r.Items[0].Reason | Should -Be 'NoGameCharacter'
		Test-AttendanceProfileResult -Result $r | Should -BeTrue
		Test-AttendanceRequiresPing -Result $r | Should -BeFalse
		Complete-AttendanceEmbed -Result $r -Embed $embed | Out-Null
		@($embed.fields).Count | Should -Be 0
		Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
	}

	It 'treats unknown status errors as real failures, not absent characters' {
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') { return [pscustomobject]@{ retcode = -500001; message = 'Temporary problem'; data = $null } }
			throw 'No POST may occur'
		}
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Failure'
		$r.Items[0].Reason | Should -Be 'InvalidResponse'
		Test-AttendanceRequiresPing -Result $r | Should -BeTrue
		Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
	}

	It 'keeps other games successful while skipping a game without characters' {
		$script:hoyoConfig.games = @(
			[pscustomobject]@{ name = 'No character'; api_base = 'https://example.invalid'; game_id = 'absent-game'; act_id = 'test'; origin_url = 'https://example.invalid'; referer_url = 'https://example.invalid/' },
			[pscustomobject]@{ name = 'Signed game'; api_base = 'https://example.invalid'; game_id = 'signed-game'; act_id = 'test'; origin_url = 'https://example.invalid'; referer_url = 'https://example.invalid/' }
		)
		Mock Invoke-RestMethod {
			if ($Uri -like '*/absent-game/info?*') { return [pscustomobject]@{ retcode = -10002; data = $null } }
			if ($Uri -like '*/signed-game/info?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $true } } }
			throw 'Unexpected POST or reward request'
		}
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Success'
		@($r.Items | Where-Object Kind -eq 'Skipped').Count | Should -Be 1
		@($r.Items | Where-Object Kind -eq 'AlreadySigned').Count | Should -Be 1
		Test-AttendanceRequiresPing -Result $r | Should -BeFalse
	}
	It 'recognizes the HoYoLAB game identifiers used by the role bindings API' {
		Get-HoyolabGameRoleClass -Game ([pscustomobject]@{game_id='sol'}) | Should -Be 'hk4e'
		Get-HoyolabGameRoleClass -Game ([pscustomobject]@{game_id='luna/os'}) | Should -Be 'hkrpg'
		Get-HoyolabGameRoleClass -Game ([pscustomobject]@{game_id='luna/zzz/os'}) | Should -Be 'nap'
		Get-HoyolabGameRoleClass -Game ([pscustomobject]@{game_id='unknown'}) | Should -BeNullOrEmpty
	}

	It 'skips zero-day ZZZ when the account only binds a Star Rail role' {
		$script:hoyoConfig.games[0].game_id = 'luna/zzz/os'
		Mock Get-HoyolabBoundRoleClasses { return @{ Available = $true; Classes = @{ hkrpg = $true } } }
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') {
				return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $false; total_sign_day = 0; today = 'Synthetic today' } }
			}
			throw 'An unbound game must not trigger a sign-in POST or reward lookup'
		}
		$embed = Initialize-DiscordEmbed
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed $embed -IsReusing $false
		$r.Kind | Should -Be 'Skipped'
		$r.Items[0].Kind | Should -Be 'Skipped'
		$r.Items[0].Reason | Should -Be 'NoGameCharacter'
		$embed.fields | Should -HaveCount 0
		Test-AttendanceRequiresPing -Result $r | Should -BeFalse
		Should -Invoke Get-HoyolabBoundRoleClasses -Times 1 -Exactly
		Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
	}

	It 'does not skip a real ZZZ first-day check-in when a bound role exists' {
		$script:hoyoConfig.games[0].game_id = 'luna/zzz/os'
		$script:dayInfoCalls = 0
		Mock Get-HoyolabBoundRoleClasses { return @{ Available = $true; Classes = @{ nap = $true } } }
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') {
				$script:dayInfoCalls++
				if ($script:dayInfoCalls -eq 1) {
					return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $false; total_sign_day = 0; today = 'Synthetic today' } }
				}
				return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $true; total_sign_day = 1; today = 'Synthetic today' } }
			}
			if ($Uri -like '*/sign?*') { return [pscustomobject]@{ retcode = 0; message = 'OK' } }
			if ($Uri -like '*/home?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ awards = @(@{ name = 'First-day item'; cnt = 3 }) } } }
			throw 'Unexpected request'
		}
		$embed = Initialize-DiscordEmbed
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed $embed -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'Signed'
		$embed.fields | Should -HaveCount 1
		$embed.fields[0].value | Should -Match 'First-day item x3'
		Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' }
	}

	It 'does not silently skip a first-day game when role verification is unavailable' {
		$script:hoyoConfig.games[0].game_id = 'luna/zzz/os'
		Mock Get-HoyolabBoundRoleClasses { return @{ Available = $false; Classes = @{} } }
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $false; total_sign_day = 0 } } }
			if ($Uri -like '*/sign?*') { return [pscustomobject]@{ retcode = -500001; message = 'Synthetic failure' } }
			throw 'Unexpected request'
		}
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed (Initialize-DiscordEmbed) -IsReusing $false
		$r.Kind | Should -Be 'Failure'
		$r.Items[0].Reason | Should -Be 'CheckInUnconfirmed'
		Test-AttendanceRequiresPing -Result $r | Should -BeTrue
	}
	It 'shows original reward, sign-in day and count for AlreadySigned without POST, including reused embeds' {
		$script:hoyoConfig.discord_text | Add-Member -NotePropertyName total_sign_day -NotePropertyValue 'Days' -Force
		$script:hoyoConfig.discord_text | Add-Member -NotePropertyName total_sign_day_unit -NotePropertyValue 'd' -Force
		$script:hoyoConfig.discord_text | Add-Member -NotePropertyName reward -NotePropertyValue 'Award' -Force
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $true; total_sign_day = 2; today = 'Synthetic day' } } }
			if ($Uri -like '*/home?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ awards = @(@{name='Old reward';cnt=2},@{name='Current reward';cnt=5}) } } }
			throw 'No POST should occur when info confirms signed'
		}
		$embed = Initialize-DiscordEmbed
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed $embed -IsReusing $true
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'AlreadySigned'
		Test-AttendanceRequiresPing -Result $r | Should -BeFalse
		$embed.fields | Should -HaveCount 1
		$embed.fields[0].value | Should -Be ("Synthetic day" + [char]10 + '**Days**' + [char]10 + '2d' + [char]10 + '**Award**' + [char]10 + 'Current reward x5')
		$embed.fields[0].minimal | Should -Be ("Synthetic day (2)" + [char]10 + 'Current reward x5')
		Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*/home?*' }
		Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
	}

	It 'recovers reward details when POST says already signed after an unsigned status' {
		$script:hoyoConfig.discord_text | Add-Member -NotePropertyName reward -NotePropertyValue 'Award' -Force
		$script:infoCalls = 0
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') {
				$script:infoCalls++
				return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = ($script:infoCalls -gt 1); total_sign_day = 1; today = 'Day one' } }
			}
			if ($Uri -like '*/sign?*') { return [pscustomobject]@{ retcode = -10002; message = 'Already signed' } }
			if ($Uri -like '*/home?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ awards = @(@{ name = 'Confirmed prize'; cnt = 1 }) } } }
			throw 'Unexpected request'
		}
		$embed = Initialize-DiscordEmbed
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed $embed -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'AlreadySigned'
		$embed.fields[0].value | Should -Match 'Confirmed prize x1'
		Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' }
		Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*/info?*' }
	}

	It 'preserves an already-signed result even if reward enrichment fails' {
		Mock Invoke-RestMethod {
			if ($Uri -like '*/info?*') { return [pscustomobject]@{ retcode = 0; data = [pscustomobject]@{ is_sign = $true; total_sign_day = 1 } } }
			if ($Uri -like '*/home?*') { throw 'Synthetic reward service outage' }
			throw 'No POST permitted'
		}
		$embed = Initialize-DiscordEmbed
		$r = Invoke-HoyolabCheckin -Profiie $script:hoyoProfile -Config $script:hoyoConfig -Embed $embed -IsReusing $false
		$r.Kind | Should -Be 'Success'
		$r.Items[0].Kind | Should -Be 'AlreadySigned'
		$embed.fields[0].value | Should -Be 'Already signed today; reward details unavailable'
		Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'Post' }
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

Describe 'Discord reuse preserves actual attendance reward details' {
	BeforeAll {
		. "$PSScriptRoot/../src/001-discord.ps1"
	}
	It 'replaces an old Already signed today field instead of duplicating it' {
		$script:patchBody = $null
		Mock Invoke-RestMethod {
			if ($Method -eq 'Get') {
				return [pscustomobject]@{
					embeds = @([pscustomobject]@{
						title = 'Synthetic user'; color = 5635840; description = 'ID: synthetic'
						fields = @([pscustomobject]@{ name = 'Synthetic game'; value = 'Already signed today'; inline = $true })
					})
				}
			}
			if ($Method -eq 'Patch') { $script:patchBody = $Body }
			return [pscustomobject]@{ id = '111111111111111111' }
		}
		$embed = @{ title = 'Synthetic user'; description = 'ID: synthetic'; color = '5635840'; fields = @(
			@{ name = 'Synthetic game'; value = 'Day 3 | Award 3 x2'; minimal = 'Award 3 x2'; inline = $true }
		) }
		$bot = @{ webhook_url = 'https://discord.invalid/webhook'; reuse_msg = '123456789012345678'; minimal = $true; overwrite = $false }
		Send-DiscordNotification -BotConfig $bot -Embeds @($embed) -NeedPing $false -PingString '' -GlobalConfig @{}
		$body = $script:patchBody | ConvertFrom-Json
		$body.embeds.Count | Should -Be 1
		@($body.embeds[0].fields).Count | Should -Be 1
		$body.embeds[0].fields[0].value | Should -Be 'Award 3 x2'
	}
	It 'replaces stale two-account HoYoLAB embeds in overwrite/minimal mode' {
		$script:capturedPatch = $null
		$script:patchCount = 0
		Mock Invoke-RestMethod {
			if ($Method -eq 'Get') {
				return [pscustomobject]@{ embeds = @(
					[pscustomobject]@{
						title = 'Account A'; description = 'Account A ref'; color = 5635840
						fields = @(
							[pscustomobject]@{ name = 'Game One'; value = 'Already signed today'; inline = $true },
							[pscustomobject]@{ name = 'Game Two'; value = 'Already signed today'; inline = $true },
							[pscustomobject]@{ name = 'Game Three'; value = 'Already signed today'; inline = $true }
						)
					},
					[pscustomobject]@{
						title = 'Account B'; description = 'Account B ref'; color = 16753920
						fields = @(
							[pscustomobject]@{ name = 'Game One'; value = 'Cannot verify attendance status'; inline = $true },
							[pscustomobject]@{ name = 'Game Two'; value = 'Already signed today'; inline = $true },
							[pscustomobject]@{ name = 'Game Three'; value = 'Already signed today'; inline = $true }
						)
					}
				) }
			}
			if ($Method -eq 'Patch') {
				$script:patchCount++
				$script:capturedPatch = $Body
				return [pscustomobject]@{ id = '123456789012345678' }
			}
			throw 'Unexpected POST; overwrite must edit the existing message'
		}
		$embeds = @(
			@{ title = 'Account A'; description = 'Account A ref'; color = '5635840'; fields = @(
				@{ name = 'Game One'; value = 'Full reward one x1'; minimal = 'Reward one x1'; inline = $true },
				@{ name = 'Game Two'; value = 'Full reward two x2'; minimal = 'Reward two x2'; inline = $true },
				@{ name = 'Game Three'; value = 'Full reward three x3'; minimal = 'Reward three x3'; inline = $true }
			) },
			@{ title = 'Account B'; description = 'Account B ref'; color = '5635840'; fields = @(
				@{ name = 'Game Two'; value = 'Full reward four x4'; minimal = 'Reward four x4'; inline = $true }
			) }
		)
		$bot = @{ webhook_url = 'https://discord.invalid/webhook'; reuse_msg = '123456789012345678'; minimal = $true; overwrite = $true }
		Send-DiscordNotification -BotConfig $bot -Embeds $embeds -NeedPing $false -PingString '' -GlobalConfig @{}
		$script:patchCount | Should -Be 1
		$body = $script:capturedPatch | ConvertFrom-Json
		@($body.embeds).Count | Should -Be 2
		@($body.embeds[0].fields).Count | Should -Be 3
		@($body.embeds[1].fields).Count | Should -Be 1
		$body.embeds[0].color | Should -Be 5635840
		$body.embeds[1].color | Should -Be 5635840
		$body.embeds[1].fields[0].name | Should -Be 'Game Two'
		$body.embeds[1].fields[0].value | Should -Be 'Reward four x4'
		@($body.embeds | ForEach-Object fields | ForEach-Object value | Where-Object { $_ -match 'Already signed today|Cannot verify attendance status|ERROR' }).Count | Should -Be 0
		$body.content | Should -Be ''
	}
	It 'keeps two same-game role fields distinct while updating their awards' {
		$script:patchBody = $null
		Mock Invoke-RestMethod {
			if ($Method -eq 'Get') {
				return [pscustomobject]@{ embeds = @([pscustomobject]@{
					title = 'Synthetic user'; color = 5635840; description = 'ID: synthetic'
					fields = @(
						[pscustomobject]@{ name = 'Same game'; value = 'Server A - Role One' + [char]10 + 'Old reward x1'; inline = $true },
						[pscustomobject]@{ name = 'Same game'; value = 'Server B - Role Two' + [char]10 + 'Old reward x2'; inline = $true }
					)
				}) }
			}
			if ($Method -eq 'Patch') { $script:patchBody = $Body }
			return [pscustomobject]@{ id = '111111111111111111' }
		}
		$embed = @{ title = 'Synthetic user'; description = 'ID: synthetic'; color = '5635840'; fields = @(
			@{ name = 'Same game'; key = 'role-a'; value = 'Server A - Role One' + [char]10 + 'New reward x3'; inline = $true },
			@{ name = 'Same game'; key = 'role-b'; value = 'Server B - Role Two' + [char]10 + 'New reward x4'; inline = $true }
		) }
		$bot = @{ webhook_url = 'https://discord.invalid/webhook'; reuse_msg = '123456789012345678'; minimal = $false; overwrite = $false }
		Send-DiscordNotification -BotConfig $bot -Embeds @($embed) -NeedPing $false -PingString '' -GlobalConfig @{}
		$body = $script:patchBody | ConvertFrom-Json
		@($body.embeds[0].fields).Count | Should -Be 2
		@($body.embeds[0].fields.value | Where-Object {$_ -match 'New reward x3'}).Count | Should -Be 1
		@($body.embeds[0].fields.value | Where-Object {$_ -match 'New reward x4'}).Count | Should -Be 1
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