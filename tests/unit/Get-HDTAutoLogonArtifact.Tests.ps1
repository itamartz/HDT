# The single assertion every teardown test in this phase leans on.
#
# DESIGN 4.5.3 lists nine artifacts a finished deployment must not leave behind.
# Nine separate assertions would stop at the first failure and tell you about one
# survivor; this helper lists ALL of them, so
#
#     Get-HDTAutoLogonArtifact -Registry $r -Lsa $l -FileSystem $f -State $s |
#         Should -BeNullOrEmpty
#
# fails with the complete list. A helper that under-reported survivors would make
# every teardown test in this phase pass for the wrong reason, so it gets its own
# tests first, like everything else.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $script:unattend = 'C:\HDT\unattend.xml'
}

Describe 'Get-HDTAutoLogonArtifact' {

    It 'returns nothing for a clean machine' {
        $artifact = Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) `
            -Lsa (New-HDTFakeLsaService) -FileSystem (New-HDTFakeFileSystem)

        $artifact | Should -BeNullOrEmpty
    }

    It 'reports <_>' -ForEach @('AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'DefaultPassword', 'AutoLogonCount') {
        $registry = New-HDTFakeRegistryService -Value @{ $script:winlogon = @{ $_ = '1' } }

        $artifact = @(Get-HDTAutoLogonArtifact -Registry $registry)

        $artifact | Should -Be @($_)
    }

    It 'reports the LSA secret' {
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }

        $artifact = @(Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) -Lsa $lsa)

        $artifact | Should -Be @('LsaSecret:DefaultPassword')
    }

    It 'does not report an LSA secret that Windows blanked' {
        # SPIKES.md S8: when the count is spent Windows leaves the secret in
        # place at zero length rather than deleting it. That is not an armed
        # machine, and reporting it as one would make teardown look broken.
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = '' }

        Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) -Lsa $lsa | Should -BeNullOrEmpty
    }

    It 'reports the RunOnce entry' {
        $registry = New-HDTFakeRegistryService -Value @{ $script:runOnce = @{ HDTResume = 'powershell.exe' } }

        @(Get-HDTAutoLogonArtifact -Registry $registry) | Should -Be @('RunOnce:HDTResume')
    }

    It 'reports a staged unattend' {
        $fs = New-HDTFakeFileSystem -File @{ $script:unattend = '<unattend/>' }

        @(Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) -FileSystem $fs) |
            Should -Be @("Unattend:$script:unattend")
    }

    It 'reports every staged unattend it is told about' {
        $fs = New-HDTFakeFileSystem -File @{
            'C:\HDT\unattend.xml'                        = '<unattend/>'
            'C:\Windows\Panther\unattend.xml'            = '<unattend/>'
            'C:\Windows\System32\Sysprep\unattend.xml'   = '<unattend/>'
        }

        @(Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) -FileSystem $fs).Count | Should -Be 3
    }

    It 'reports a state document still marked armed' {
        # THE STATE CARRIES NO SECRET OF ITS OWN any more - the engine arms with
        # HDTAdminPassword, the administrator's own value, which belongs to the
        # machine afterwards. What is left to report is the flag saying this
        # machine is still expecting to come back.
        $state = [pscustomobject] @{ autoLogon = [pscustomobject] @{ armed = $true } }

        @(Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) -State $state) |
            Should -Be @('State:autoLogon.armed')
    }

    It 'does not report a state that has already been disarmed' {
        $state = [pscustomobject] @{ autoLogon = [pscustomobject] @{ armed = $false } }

        Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) -State $state | Should -BeNullOrEmpty
    }

    It 'reports every artifact when everything is armed' {
        $registry = New-HDTFakeRegistryService -Value @{
            $script:winlogon = @{
                AutoAdminLogon    = '1'
                DefaultUserName   = 'Administrator'
                DefaultDomainName = ''
                DefaultPassword   = 'Sw0rdfish!'
                AutoLogonCount    = 3
            }
            $script:runOnce  = @{ HDTResume = 'powershell.exe' }
        }
        $lsa = New-HDTFakeLsaService -Secret @{ DefaultPassword = 'Sw0rdfish!' }
        $fs = New-HDTFakeFileSystem -File @{ $script:unattend = '<unattend/>' }
        $state = [pscustomobject] @{ autoLogon = [pscustomobject] @{ armed = $true } }

        $artifact = @(Get-HDTAutoLogonArtifact -Registry $registry -Lsa $lsa -FileSystem $fs -State $state)

        # The DESIGN 4.5.3 checklist, all nine items.
        $artifact.Count | Should -Be 9
        $artifact | Should -Contain 'AutoAdminLogon'
        $artifact | Should -Contain 'DefaultUserName'
        $artifact | Should -Contain 'DefaultDomainName'
        $artifact | Should -Contain 'DefaultPassword'
        $artifact | Should -Contain 'AutoLogonCount'
        $artifact | Should -Contain 'LsaSecret:DefaultPassword'
        $artifact | Should -Contain 'RunOnce:HDTResume'
        $artifact | Should -Contain "Unattend:$script:unattend"
        $artifact | Should -Contain 'State:autoLogon.armed'
    }

    It 'reports an empty DefaultDomainName as present' {
        # DESIGN 4.5.1 writes an empty string for a workgroup machine, so the
        # value existing at all is the artifact - not its content.
        $registry = New-HDTFakeRegistryService -Value @{ $script:winlogon = @{ DefaultDomainName = '' } }

        @(Get-HDTAutoLogonArtifact -Registry $registry) | Should -Be @('DefaultDomainName')
    }

    It 'works without an Lsa, FileSystem or State' {
        { Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) } | Should -Not -Throw
    }

    It 'honours an explicit -UnattendPath' {
        $fs = New-HDTFakeFileSystem -File @{ 'D:\staged\unattend.xml' = '<unattend/>' }

        @(Get-HDTAutoLogonArtifact -Registry (New-HDTFakeRegistryService) -FileSystem $fs -UnattendPath 'D:\staged\unattend.xml') |
            Should -Be @('Unattend:D:\staged\unattend.xml')
    }
}
