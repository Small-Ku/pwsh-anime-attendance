BeforeAll {
	. "$PSScriptRoot/../src/000-common.ps1"
	. "$PSScriptRoot/../src/019-skland-device.ps1"
	. "$PSScriptRoot/../src/020-skcommon.ps1"
}

Describe 'Skland device fingerprint' {
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
