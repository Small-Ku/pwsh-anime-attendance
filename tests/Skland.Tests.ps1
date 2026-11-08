BeforeAll {
	. "$PSScriptRoot/../src/000-common.ps1"
	. "$PSScriptRoot/../src/002-outcome.ps1"
	. "$PSScriptRoot/../src/019-skland-device.ps1"
	. "$PSScriptRoot/../src/020-skcommon.ps1"
}

Describe 'Skland device fingerprint' {
	BeforeEach {
		$script:SklandDidCache = @{}
		$script:conf = $null
		$script:AnimeAttendanceConfigPath = $null
	}

	It 'matches the skland-kit DES padding and cipher contract' {
		Protect-SklandDeviceDesValue -Value 'default' -Key 'uy7mzc4h' | Should -Be 'Xoz/PL65pzA='
	}

	It 'matches the skland-kit smid derivation' {
		$smid = Get-SklandSmId -Now ([datetime]'2026-08-21T00:00:00') -Uuid '00000000-0000-4000-8000-000000000000'
		$smid | Should -Be '202608210000006e9036f9d52b7ac8faea061c38033ffe005a7a52873487400'
	}

	It 'registers the generated fingerprint before returning a dId' {
		Mock Invoke-RestMethod {
			[pscustomobject]@{ code = 1100; detail = [pscustomobject]@{ deviceId = 'registered-device' } }
		} -ParameterFilter { $Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' }

		Get-SklandDid | Should -Be 'Bregistered-device'
		Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' -and
			$Method -eq 'Post' -and
			($Body | ConvertFrom-Json).organization -eq 'UWXspnCCJN4sfYlNfqps' -and
			($Body | ConvertFrom-Json).compress -eq 2 -and
			($Body | ConvertFrom-Json).encode -eq 5
		}
	}

	It 'uses a persisted profile device id without registering another device' {
		Mock Invoke-RestMethod { throw 'The persisted dId path must not call Shumei.' }

		Get-SklandDid -DeviceConfig ([pscustomobject]@{ id = 'Bpersisted-device'; seed = 'private-seed' }) | Should -Be 'Bpersisted-device'
		Should -Invoke Invoke-RestMethod -Times 0 -Exactly
	}

	It 'reuses one registration result for repeated profiles in the same process' {
		Mock Invoke-RestMethod {
			[pscustomobject]@{ code = 1100; detail = [pscustomobject]@{ deviceId = 'cached-device' } }
		} -ParameterFilter { $Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' }

		$config = [pscustomobject]@{ seed = 'private-seed'; max_retries = 0; retry_jitter_ms = 0 }
		Get-SklandDid -DeviceConfig $config | Should -Be 'Bcached-device'
		Get-SklandDid -DeviceConfig $config | Should -Be 'Bcached-device'
		Should -Invoke Invoke-RestMethod -Times 1 -Exactly
	}

	It 'isolates registration cache entries between independent profile scopes' {
		$script:registrationAttempts = 0
		Mock Invoke-RestMethod {
			$script:registrationAttempts++
			[pscustomobject]@{ code = 1100; detail = [pscustomobject]@{ deviceId = "scoped-device-$script:registrationAttempts" } }
		} -ParameterFilter { $Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' }

		$profileA = [pscustomobject]@{ platform = 'skland'; token = 'account-token-a'; console_name = 'ACCOUNT_A' }
		$profileB = [pscustomobject]@{ platform = 'skland'; token = 'account-token-b'; console_name = 'ACCOUNT_B' }
		$scopeA = Get-SklandProfileDeviceCacheScope -Profile $profileA
		$scopeB = Get-SklandProfileDeviceCacheScope -Profile $profileB
		$scopeA | Should -Not -Be $scopeB

		$config = [pscustomobject]@{ seed = 'same-test-seed'; max_retries = 0; retry_jitter_ms = 0 }
		Get-SklandDid -DeviceConfig $config -CacheScopeKey $scopeA | Should -Be 'Bscoped-device-1'
		Get-SklandDid -DeviceConfig $config -CacheScopeKey $scopeB | Should -Be 'Bscoped-device-2'
		Get-SklandDid -DeviceConfig $config -CacheScopeKey $scopeA | Should -Be 'Bscoped-device-1'
		Should -Invoke Invoke-RestMethod -Times 2 -Exactly
	}

	It 'shares a cache scope only when profiles opt into the same device reference' {
		$profileA = [pscustomobject]@{ platform = 'skland'; token = 'account-token-a'; device_ref = 'shared-phone-1' }
		$profileB = [pscustomobject]@{ platform = 'skland'; token = 'account-token-b'; device_ref = 'shared-phone-1' }
		$profileC = [pscustomobject]@{ platform = 'skland'; token = 'account-token-c'; device_ref = 'shared-phone-2' }

		(Get-SklandProfileDeviceCacheScope -Profile $profileA) | Should -Be (Get-SklandProfileDeviceCacheScope -Profile $profileB)
		(Get-SklandProfileDeviceCacheScope -Profile $profileA) | Should -Not -Be (Get-SklandProfileDeviceCacheScope -Profile $profileC)
	}

	It 'reconstructs deterministic fingerprint UUID material from the recovery seed' {
		$first = Get-SklandStableUuid -Seed 'private-seed' -Purpose 'uid'
		$second = Get-SklandStableUuid -Seed 'private-seed' -Purpose 'uid'
		$other = Get-SklandStableUuid -Seed 'private-seed' -Purpose 'vpw'
		$first | Should -Be $second
		$first | Should -Not -Be $other
		$first | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
	}

	It 'force-provisions with the seed instead of trusting a rejected configured id' {
		Mock Invoke-RestMethod {
			[pscustomobject]@{ code = 1100; detail = [pscustomobject]@{ deviceId = 'replacement-device' } }
		} -ParameterFilter { $Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' }

		Get-SklandDid -DeviceConfig ([pscustomobject]@{ id = 'Brejected-device'; seed = 'private-seed'; max_retries = 0; retry_jitter_ms = 0 }) -ForceProvision | Should -Be 'Breplacement-device'
		Should -Invoke Invoke-RestMethod -Times 1 -Exactly
	}

	It 'retries transport failures with a bounded timeout and then caches success' {
		$script:registrationAttempts = 0
		Mock Invoke-RestMethod {
			$script:registrationAttempts++
			if ($script:registrationAttempts -lt 3) { throw 'temporary network failure' }
			[pscustomobject]@{ code = 1100; detail = [pscustomobject]@{ deviceId = 'retried-device' } }
		} -ParameterFilter { $Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' }
		Mock Start-Sleep {}

		$config = [pscustomobject]@{
			seed = 'retry-seed'
			max_retries = 2
			timeout_seconds = 7
			retry_base_delay_ms = 1
			retry_jitter_ms = 0
		}
		Get-SklandDid -DeviceConfig $config | Should -Be 'Bretried-device'
		Get-SklandDid -DeviceConfig $config | Should -Be 'Bretried-device'
		Should -Invoke Invoke-RestMethod -Times 3 -Exactly
		Should -Invoke Start-Sleep -Times 2 -Exactly
		Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 1 }
		Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 2 }
	}

	It 'does not retry an explicit Shumei protocol rejection' {
		Mock Invoke-RestMethod {
			[pscustomobject]@{ code = 2202; msg = 'shared IP rejected'; detail = $null }
		} -ParameterFilter { $Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' }

		$errorMessage = $null
		try {
			Get-SklandDid -DeviceConfig ([pscustomobject]@{ seed = 'rejected-seed' }) | Out-Null
		}
		catch {
			$errorMessage = $_.Exception.Message
		}
		$errorMessage | Should -Match 'Shumei code 2202'
		$errorMessage | Should -Match 'message: shared IP rejected'
		$errorMessage | Should -Match 'attempt 1/4'
		Should -Invoke Invoke-RestMethod -Times 1 -Exactly
	}

	It 'retries a 1100 response that is missing the device id' {
		$script:registrationAttempts = 0
		Mock Invoke-RestMethod {
			$script:registrationAttempts++
			if ($script:registrationAttempts -eq 1) { return [pscustomobject]@{ code = 1100; detail = [pscustomobject]@{} } }
			[pscustomobject]@{ code = 1100; detail = [pscustomobject]@{ deviceId = 'recovered-device' } }
		} -ParameterFilter { $Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' }
		Mock Start-Sleep {}

		$config = [pscustomobject]@{ seed = 'missing-device-id-seed'; max_retries = 1; retry_base_delay_ms = 0; retry_jitter_ms = 0 }
		Get-SklandDid -DeviceConfig $config | Should -Be 'Brecovered-device'
		Should -Invoke Invoke-RestMethod -Times 2 -Exactly
		Should -Invoke Start-Sleep -Times 0 -Exactly
	}

	It 'classifies transport, rate-limit, and server failures as retryable only' {
		Test-SklandDeviceRegistrationRetryable -StatusCode 0 | Should -BeTrue
		Test-SklandDeviceRegistrationRetryable -StatusCode 429 | Should -BeTrue
		Test-SklandDeviceRegistrationRetryable -StatusCode 503 | Should -BeTrue
		Test-SklandDeviceRegistrationRetryable -StatusCode 400 | Should -BeFalse
	}

	It 'classifies explicit device rejection messages without treating generic auth errors as recovery' {
		Test-SklandDeviceIdRejection -Failure @{ Code = 1002; Message = 'configured dId is invalid' } | Should -BeTrue
		Test-SklandDeviceIdRejection -Failure @{ Code = 1003; Message = 'timestamp is outside the allowed window' } | Should -BeFalse
		Test-SklandDeviceIdRejection -Failure @{ Code = 401; Message = 'invalid token' } | Should -BeFalse
	}

	It 'persists the recovered id and seed as profile-owned state' {
		$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("anime-attendance-skland-$([guid]::NewGuid().ToString('N')).json")
		$profile = [pscustomobject]@{
			platform = 'skland'
			token = 'account-token'
			device = [pscustomobject]@{ seed = 'private-seed'; did = 'legacy-device-id'; device_seed = 'legacy-seed' }
		}
		$script:conf = [pscustomobject]@{ profiles = @($profile) }
		$script:AnimeAttendanceConfigPath = $tempPath
		try {
			Save-SklandProfileDeviceState -Profile $profile -Did 'Brecovered-device' -Seed 'private-seed' | Should -BeTrue
			$saved = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json
			$saved.profiles[0].device.id | Should -Be 'Brecovered-device'
			$saved.profiles[0].device.seed | Should -Be 'private-seed'
			$saved.profiles[0].device.did | Should -BeNullOrEmpty
			$saved.profiles[0].device.device_seed | Should -BeNullOrEmpty
		}
		finally {
			if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
		}
	}

	It 're-enrols with the persistent seed when Skland rejects the configured id' {
		$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("anime-attendance-skland-$([guid]::NewGuid().ToString('N')).json")
		$profile = [pscustomobject]@{
			platform = 'skland'
			token = 'account-token'
			device = [pscustomobject]@{ id = 'Brejected-device'; seed = 'private-seed' }
		}
		$platform = [pscustomobject]@{
			lang = 'zh_CN'
			user_agent = 'test-agent'
			games = @([pscustomobject]@{
				name = 'Arknights'
				app_code = 'arknights'
				api_base = 'https://zonai.skland.com'
				origin_url = 'https://www.skland.com'
				referer_url = 'https://www.skland.com/'
				platform = '1'
				vName = '1.0.0'
			})
		}
		$embed = [pscustomobject]@{ fields = @(); title = ''; description = ''; color = '' }
		$script:conf = [pscustomobject]@{ display = [pscustomobject]@{ console = $false }; profiles = @($profile) }
		$script:AnimeAttendanceConfigPath = $tempPath
		$script:authAttempts = 0
		try {
			Mock Invoke-RestMethod {
				[pscustomobject]@{ code = 1100; detail = [pscustomobject]@{ deviceId = 'replacement-device' } }
			} -ParameterFilter { $Uri -eq 'https://fp-it.portal101.cn/deviceprofile/v4' }
			Mock Initialize-SkAuthState {
				param($Ctx)
				$script:authAttempts++
				if ($script:authAttempts -eq 1) {
					$Ctx.LastAuthFailure = @{ Code = 1002; Message = 'configured dId is invalid' }
					return $false
				}
				$Ctx.Token = 'auth-token'
				return $true
			}
			Mock Get-SkUserData { [pscustomobject]@{ Kind = 'Success'; Data = [pscustomobject]@{ user = [pscustomobject]@{ nickname = 'Test'; id = '1' } } } }
			Mock Get-SkBindingData { [pscustomobject]@{ Kind = 'Success'; Data = [pscustomobject]@{ list = @() } } }

			Invoke-SkAttendanceCore -Provider 'skland' -Profile $profile -PlatformConfig $platform -Embed $embed -IsReusing:$false | Out-Null

			$script:authAttempts | Should -Be 2
			$profile.device.id | Should -Be 'Breplacement-device'
			$profile.device.seed | Should -Be 'private-seed'
			Should -Invoke Invoke-RestMethod -Times 1 -Exactly
		}
		finally {
			if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
		}
	}

	It 'refuses an ephemeral device when GitHub Actions has no persistent state' {
		$oldGitHubActions = $env:GITHUB_ACTIONS
		$env:GITHUB_ACTIONS = 'true'
		$profile = [pscustomobject]@{ platform = 'skland'; token = 'account-token' }
		$platform = [pscustomobject]@{
			lang = 'zh_CN'
			user_agent = 'test-agent'
			games = @([pscustomobject]@{ name = 'Arknights'; app_code = 'arknights'; api_base = 'https://zonai.skland.com'; origin_url = 'https://www.skland.com'; referer_url = 'https://www.skland.com/'; platform = '1'; vName = '1.0.0' })
		}
		$embed = [pscustomobject]@{ fields = @(); title = ''; description = ''; color = '' }
		$script:conf = [pscustomobject]@{ display = [pscustomobject]@{ console = $false }; profiles = @($profile) }
		Mock Invoke-RestMethod { throw 'Ephemeral device registration must not be attempted.' }
		try {
			$result = Invoke-SkAttendanceCore -Provider 'skland' -Profile $profile -PlatformConfig $platform -Embed $embed -IsReusing:$false
			$result.Kind | Should -Be 'Failure'
			Test-AttendanceRequiresPing -Result $result | Should -BeTrue
			Should -Invoke Invoke-RestMethod -Times 0 -Exactly
		}
		finally {
			if ($null -eq $oldGitHubActions) { Remove-Item Env:GITHUB_ACTIONS -ErrorAction SilentlyContinue } else { $env:GITHUB_ACTIONS = $oldGitHubActions }
		}
	}

	It 'honors the console-off policy for device diagnostics' {
		$script:capturedHostMessage = $null
		$script:conf = [pscustomobject]@{ display = [pscustomobject]@{ console = $false } }
		Mock Write-Host { param($Object); $script:capturedHostMessage = [string]$Object }

		Write-SklandDeviceDiagnostic -Message 'Skland device registration failed (attempt 1/4; HTTP status 503; Shumei code unknown; message: unavailable).'

		$script:capturedHostMessage | Should -BeNullOrEmpty
	}
}

Describe 'Skland authentication request parity' {
	BeforeEach {
		$script:provider = Get-SkProviderProfile -Provider 'skland'
		$script:platformConfig = [pscustomobject]@{
			user_agent = 'custom-test-agent'
			lang = 'zh_CN'
			games = @([pscustomobject]@{
				api_base = 'https://zonai.skland.com'
				origin_url = 'https://game.skland.com'
				referer_url = 'https://game.skland.com/'
				platform = '1'
				vName = '1.21.0'
			})
		}
		$script:ctx = @{
			ProviderProfile = $script:provider
			PlatformConfig = $script:platformConfig
			GameConfig = $script:platformConfig.games[0]
			DId = 'Bregistered-device'
			Cred = $null
			Token = $null
			TimeOffset = 0
			SkGameRole = $null
		}
	}

	It 'sends dId and app identity to the Hypergryph grant endpoint' {
		Mock Invoke-RestMethod { [pscustomobject]@{ status = 0; data = [pscustomobject]@{ code = 'ok' } } }

		$null = Invoke-SkPassportRequest -Method 'Post' -Path $script:provider.passport.grant -Body @{ token = 'token' } -Ctx $script:ctx

		Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$Uri -eq 'https://as.hypergryph.com/user/oauth2/v2/grant' -and
			$Headers['dId'] -eq 'Bregistered-device' -and
			$Headers['x-requested-with'] -eq 'com.hypergryph.skland' -and
			$UserAgent -like '*SKLand/1.52.1'
		}
	}

	It 'uses skland-kit web headers for generate_cred_by_code' {
		Mock Invoke-RestMethod { [pscustomobject]@{ code = 0; data = [pscustomobject]@{} } }

		$null = Invoke-SkApiRequest -Method 'Post' -Path $script:provider.auth.credPath -Body @{ code = 'code'; kind = 1 } -Ctx $script:ctx

		Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
			$Uri -eq 'https://zonai.skland.com/web/v1/user/auth/generate_cred_by_code' -and
			$Headers['dId'] -eq 'Bregistered-device' -and
			$Headers['platform'] -eq '3' -and
			$Headers['vName'] -eq '1.0.0' -and
			$Headers['Origin'] -eq 'https://www.skland.com' -and
			$Headers['Referer'] -eq 'https://www.skland.com/' -and
			-not $Headers.ContainsKey('x-requested-with') -and
			$UserAgent -like '*Chrome/129.0.0.0*'
		}
	}

	It 'accepts the raw account-info response as the configured token' {
		Resolve-SkPassportToken -Token '{"data":{"content":"oauth-token"}}' | Should -Be 'oauth-token'
		Resolve-SkPassportToken -Token 'oauth-token' | Should -Be 'oauth-token'
	}
}
