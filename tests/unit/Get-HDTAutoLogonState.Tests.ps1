# Reading the autologon state back (DESIGN 4.5.1).
#
# It reports HasLsaSecret as a boolean and NEVER returns the secret itself: the
# one caller that needs the value is Winlogon, and it does not go through here.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
}

Describe 'Get-HDTAutoLogonState' {

    It 'reports Armed false on a clean machine' {
        $state = Get-HDTAutoLogonState -Registry (New-HDTFakeRegistryService) -Lsa (New-HDTFakeLsaService)

        $state.Armed | Should -BeFalse
    }

    It 'reports Armed true when AutoAdminLogon is 1' {
        $registry = New-HDTFakeRegistryService -Value @{ $script:winlogonPath = @{ AutoAdminLogon = '1' } }

        (Get-HDTAutoLogonState -Registry $registry -Lsa (New-HDTFakeLsaService)).Armed | Should -BeTrue
    }

    It 'reports Armed false when AutoAdminLogon is 0' {
        # SPIKES.md S8: this is exactly what Windows leaves behind when the count
        # is spent, so it is a state HDT will meet in the field.
        $registry = New-HDTFakeRegistryService -Value @{ $script:winlogonPath = @{ AutoAdminLogon = '0' } }

        (Get-HDTAutoLogonState -Registry $registry -Lsa (New-HDTFakeLsaService)).Armed | Should -BeFalse
    }

    It 'reports the user name, domain and count' {
        $registry = New-HDTFakeRegistryService -Value @{
            $script:winlogonPath = @{
                AutoAdminLogon    = '1'
                DefaultUserName   = 'Administrator'
                DefaultDomainName = 'CONTOSO'
                AutoLogonCount    = 2
            }
        }

        $state = Get-HDTAutoLogonState -Registry $registry -Lsa (New-HDTFakeLsaService)

        $state.UserName | Should -BeExactly 'Administrator'
        $state.DomainName | Should -BeExactly 'CONTOSO'
        $state.Count | Should -Be 2
    }

    It 'reports HasLsaSecret' {
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }

        $state = Get-HDTAutoLogonState -Registry (New-HDTFakeRegistryService) -Lsa $lsa

        $state.HasLsaSecret | Should -BeTrue
    }

    It 'reports HasLsaSecret false when there is none' {
        $state = Get-HDTAutoLogonState -Registry (New-HDTFakeRegistryService) -Lsa (New-HDTFakeLsaService)

        $state.HasLsaSecret | Should -BeFalse
    }

    It 'does not return the secret value' {
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }

        $state = Get-HDTAutoLogonState -Registry (New-HDTFakeRegistryService) -Lsa $lsa

        ($state | Out-String) | Should -Not -Match 'Sw0rdfish'
        $state.PSObject.Properties.Name | Should -Not -Contain 'LsaSecret'
    }

    It 'reports HasRegistryPassword when one is present' {
        $registry = New-HDTFakeRegistryService -Value @{ $script:winlogonPath = @{ DefaultPassword = 'left-behind' } }

        $state = Get-HDTAutoLogonState -Registry $registry -Lsa (New-HDTFakeLsaService)

        $state.HasRegistryPassword | Should -BeTrue
    }

    It 'reports HasRegistryPassword false on a machine that follows DESIGN 4.5.2' {
        $registry = New-HDTFakeRegistryService -Value @{ $script:winlogonPath = @{ AutoAdminLogon = '1' } }

        $state = Get-HDTAutoLogonState -Registry $registry -Lsa (New-HDTFakeLsaService)

        $state.HasRegistryPassword | Should -BeFalse
    }

    It 'does not return the registry password value either' {
        $registry = New-HDTFakeRegistryService -Value @{ $script:winlogonPath = @{ DefaultPassword = 'left-behind' } }

        $state = Get-HDTAutoLogonState -Registry $registry -Lsa (New-HDTFakeLsaService)

        ($state | Out-String) | Should -Not -Match 'left-behind'
    }

    It 'reports the RunOnce command' {
        $registry = New-HDTFakeRegistryService -Value @{ $script:runOncePath = @{ HDTResume = 'powershell.exe -File C:\HDT\Start-HDTResume.ps1' } }

        $state = Get-HDTAutoLogonState -Registry $registry -Lsa (New-HDTFakeLsaService)

        $state.RunOnceCommand | Should -BeExactly 'powershell.exe -File C:\HDT\Start-HDTResume.ps1'
    }

    It 'does not throw on a machine with no Winlogon values at all' {
        { Get-HDTAutoLogonState -Registry (New-HDTFakeRegistryService) -Lsa (New-HDTFakeLsaService) } | Should -Not -Throw
    }

    It 'returns every documented property' {
        $state = Get-HDTAutoLogonState -Registry (New-HDTFakeRegistryService) -Lsa (New-HDTFakeLsaService)

        foreach ($name in @('Armed', 'UserName', 'DomainName', 'Count', 'HasRegistryPassword', 'HasLsaSecret', 'RunOnceCommand')) {
            $state.PSObject.Properties.Name | Should -Contain $name
        }
    }

    It 'has comment based help' {
        $help = Get-Help -Name Get-HDTAutoLogonState -ErrorAction Stop

        $help.Name | Should -BeExactly 'Get-HDTAutoLogonState'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
