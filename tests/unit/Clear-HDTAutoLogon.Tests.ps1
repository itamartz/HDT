# The DESIGN 4.5.3 teardown checklist, item by item (ROADMAP M2).
#
# "MDT's cleanup is a task sequence step, so a failure before it leaves autologon
# armed. In HDT teardown runs from finally around the sequence, AND
# Start-HDTResume.ps1 reconciles on every boot."
#
# The property that matters more than any single item: ONE ITEM FAILING MUST NOT
# STOP THE OTHERS. A teardown that gives up halfway is how a machine ends up
# armed with six of nine artifacts cleared - which is worse than not running at
# all, because the log says it ran.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $script:unattend = 'C:\HDT\unattend.xml'
    $script:statePath = 'C:\HDT\state.json'

    # A registry double that fails one named value and behaves normally for
    # everything else. It is a decorator over the fake rather than a Mock: the
    # point is to prove the checklist keeps going, and Mock would couple the test
    # to the call shape instead of the behaviour (tests/helpers/README.md 10).
    function New-HDTFailingRegistryDouble {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        param([object] $Inner, [string] $FailFor)

        $double = [pscustomobject] @{ Inner = $Inner; FailFor = $FailFor; ServiceName = 'RegistryService' }
        $double | Add-Member -MemberType ScriptProperty -Name Operations -Value { $this.Inner.Operations }

        $double | Add-Member -MemberType ScriptMethod -Name TestPath -Value {
            param([string] $Path) return $this.Inner.TestPath($Path)
        }
        $double | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
            param([string] $Path, [string] $Name) return $this.Inner.GetValue($Path, $Name)
        }
        $double | Add-Member -MemberType ScriptMethod -Name NewKey -Value {
            param([string] $Path) $this.Inner.NewKey($Path)
        }
        $double | Add-Member -MemberType ScriptMethod -Name SetValue -Value {
            param([string] $Path, [string] $Name, [object] $Value, [string] $Type) $this.Inner.SetValue($Path, $Name, $Value, $Type)
        }
        $double | Add-Member -MemberType ScriptMethod -Name RemoveKey -Value {
            param([string] $Path, [bool] $Recurse) $this.Inner.RemoveKey($Path, $Recurse)
        }
        $double | Add-Member -MemberType ScriptMethod -Name RemoveValue -Value {
            param([string] $Path, [string] $Name)

            if ($Name -eq $this.FailFor) {
                throw [System.UnauthorizedAccessException]::new("Access to the registry value '$Name' is denied.")
            }
            $this.Inner.RemoveValue($Path, $Name)
        }

        return $double
    }
}

Describe 'Clear-HDTAutoLogon' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:registry = New-HDTFakeRegistryService -Journal $script:journal -Value @{
            $script:winlogonPath = @{
                AutoAdminLogon    = '1'
                DefaultUserName   = 'Administrator'
                DefaultDomainName = ''
                DefaultPassword   = 'left-behind'
                AutoLogonCount    = 3
            }
            $script:runOncePath  = @{ HDTResume = 'powershell.exe -File C:\HDT\Start-HDTResume.ps1' }
        }
        $script:lsa = New-HDTFakeLsaService -Journal $script:journal -Secret @{ DefaultPassword = 'Sw0rdfish!' }
        $script:fs = New-HDTFakeFileSystem -Journal $script:journal -File @{
            $script:unattend                           = '<unattend/>'
            'C:\Windows\Panther\unattend.xml'          = '<unattend/>'
            'C:\Windows\System32\Sysprep\unattend.xml' = '<unattend/>'
        }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 5, 0, 0, [System.DateTimeKind]::Utc)) -Journal $script:journal
        $script:state = New-HDTRunState -SequenceId 'seq' -RunId 'run-0001' -Phase FullOS -Clock $script:clock
        $script:state.deploymentPassword = 'Sw0rdfish!'
        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock
    }

    Context 'the DESIGN 4.5.3 checklist' {

        It 'clears <_>' -ForEach @('AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'DefaultPassword', 'AutoLogonCount') {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa | Out-Null

            $script:registry.GetValue($script:winlogonPath, $_) | Should -BeNullOrEmpty
        }

        It 'removes the LSA secret' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa | Out-Null

            $script:lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'removes the RunOnce entry' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa | Out-Null

            $script:registry.GetValue($script:runOncePath, 'HDTResume') | Should -BeNullOrEmpty
        }

        It 'deletes every staged unattend it finds' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs | Out-Null

            $script:fs.TestPath($script:unattend) | Should -BeFalse
            $script:fs.TestPath('C:\Windows\Panther\unattend.xml') | Should -BeFalse
            $script:fs.TestPath('C:\Windows\System32\Sysprep\unattend.xml') | Should -BeFalse
        }

        It 'deletes only the unattend paths it was given' {
            $fs = New-HDTFakeFileSystem -File @{ 'D:\staged\unattend.xml' = '<unattend/>'; $script:unattend = '<unattend/>' }

            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $fs -UnattendPath 'D:\staged\unattend.xml' | Out-Null

            $fs.TestPath('D:\staged\unattend.xml') | Should -BeFalse
            $fs.TestPath($script:unattend) | Should -BeTrue
        }

        It 'nulls the deployment password in the state' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -State $script:state | Out-Null

            $script:state.deploymentPassword | Should -BeNullOrEmpty
        }

        It 'marks the state as no longer armed' {
            $script:state.autoLogon.armed = $true

            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -State $script:state | Out-Null

            $script:state.autoLogon.armed | Should -BeFalse
        }

        It 'saves the state when a path and filesystem were given' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs `
                -State $script:state -StatePath $script:statePath -Clock $script:clock | Out-Null

            $script:fs.TestPath($script:statePath) | Should -BeTrue
            (ConvertFrom-Json -InputObject ($script:fs.ReadAllText($script:statePath))).deploymentPassword |
                Should -BeNullOrEmpty
        }

        It 'does not save the state when no path was given' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state | Out-Null

            $script:fs.TestPath($script:statePath) | Should -BeFalse
        }

        It 'leaves no artifact behind' {
            # THE ROADMAP M2 ASSERTION.
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state | Out-Null

            Get-HDTAutoLogonArtifact -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state |
                Should -BeNullOrEmpty
        }

        It 'lists what it cleared' {
            $result = Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state

            $result.Cleared | Should -Contain 'AutoAdminLogon'
            $result.Cleared | Should -Contain 'DefaultUserName'
            $result.Cleared | Should -Contain 'DefaultDomainName'
            $result.Cleared | Should -Contain 'DefaultPassword'
            $result.Cleared | Should -Contain 'AutoLogonCount'
            $result.Cleared | Should -Contain 'LsaSecret:DefaultPassword'
            $result.Cleared | Should -Contain 'RunOnce:HDTResume'
            $result.Cleared | Should -Contain "Unattend:$script:unattend"
            $result.Cleared | Should -Contain 'DeploymentPassword'
        }

        It 'reports nothing failed on a machine it can clear' {
            $result = Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state

            $result.Failed | Should -BeNullOrEmpty
        }
    }

    Context 'best effort' {

        BeforeEach {
            $script:failing = New-HDTFailingRegistryDouble -Inner $script:registry -FailFor 'AutoLogonCount'
        }

        It 'continues after a failing item' {
            Clear-HDTAutoLogon -Registry $script:failing -Lsa $script:lsa -FileSystem $script:fs -State $script:state | Out-Null

            $script:registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -BeNullOrEmpty
            $script:registry.GetValue($script:winlogonPath, 'DefaultUserName') | Should -BeNullOrEmpty
            $script:registry.GetValue($script:runOncePath, 'HDTResume') | Should -BeNullOrEmpty
            $script:state.deploymentPassword | Should -BeNullOrEmpty
        }

        It 'reports the failing item' {
            $result = Clear-HDTAutoLogon -Registry $script:failing -Lsa $script:lsa -FileSystem $script:fs -State $script:state

            @($result.Failed).Count | Should -Be 1
            $result.Failed[0].Item | Should -BeExactly 'AutoLogonCount'
            $result.Failed[0].Message | Should -Match 'denied'
        }

        It 'does not list a failed item as cleared' {
            $result = Clear-HDTAutoLogon -Registry $script:failing -Lsa $script:lsa -FileSystem $script:fs -State $script:state

            $result.Cleared | Should -Not -Contain 'AutoLogonCount'
        }

        It 'does not throw when an item fails' {
            { Clear-HDTAutoLogon -Registry $script:failing -Lsa $script:lsa -FileSystem $script:fs -State $script:state } |
                Should -Not -Throw
        }

        It 'still removes the LSA secret when a registry item failed' {
            # The LSA secret is the artifact worth most. It must not be skipped
            # because something earlier in the checklist blew up.
            Clear-HDTAutoLogon -Registry $script:failing -Lsa $script:lsa -FileSystem $script:fs -State $script:state | Out-Null

            $script:lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
        }
    }

    Context 'idempotence' {

        It 'does not throw on an already-clear machine' {
            { Clear-HDTAutoLogon -Registry (New-HDTFakeRegistryService) -Lsa (New-HDTFakeLsaService) -FileSystem (New-HDTFakeFileSystem) } |
                Should -Not -Throw
        }

        It 'reports nothing cleared on an already-clear machine' {
            $result = Clear-HDTAutoLogon -Registry (New-HDTFakeRegistryService) -Lsa (New-HDTFakeLsaService) -FileSystem (New-HDTFakeFileSystem)

            $result.Cleared | Should -BeNullOrEmpty
            $result.Failed | Should -BeNullOrEmpty
        }

        It 'leaves no artifact after being run twice' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state | Out-Null
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state | Out-Null

            Get-HDTAutoLogonArtifact -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state |
                Should -BeNullOrEmpty
        }

        It 'reports nothing cleared on the second run' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state | Out-Null
            $second = Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state

            $second.Cleared | Should -BeNullOrEmpty
        }
    }

    Context 'ShouldProcess' {

        It 'clears nothing under -WhatIf' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state -WhatIf | Out-Null

            $script:registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -Be '1'
            $script:lsa.GetSecret('DefaultPassword') | Should -BeExactly 'Sw0rdfish!'
            $script:fs.TestPath($script:unattend) | Should -BeTrue
            $script:state.deploymentPassword | Should -BeExactly 'Sw0rdfish!'
        }
    }

    Context 'logging' {

        It 'logs one reboot.teardown record' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state -LogContext $script:log | Out-Null

            $record = @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and $_.Arguments[0] -like '*HDT.jsonl' } |
                    ForEach-Object { ConvertFrom-Json -InputObject $_.Arguments[1] })

            @($record | Where-Object { $_.event -eq 'reboot.teardown' }).Count | Should -Be 1
        }

        It 'lists the cleared items in that record' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state -LogContext $script:log | Out-Null

            $record = @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and $_.Arguments[0] -like '*HDT.jsonl' } |
                    ForEach-Object { ConvertFrom-Json -InputObject $_.Arguments[1] } |
                    Where-Object { $_.event -eq 'reboot.teardown' })

            @($record[0].data.cleared) | Should -Contain 'AutoAdminLogon'
            @($record[0].data.cleared) | Should -Contain 'LsaSecret:DefaultPassword'
        }

        It 'does not put a secret in that record' {
            Clear-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs -State $script:state -LogContext $script:log | Out-Null

            $written = ($script:fs.Operations |
                    Where-Object { $_.Operation -in @('WriteAllText', 'AppendAllText') } |
                    ForEach-Object { $_.Arguments[1] }) -join "`n"

            $written | Should -Not -Match 'Sw0rdfish'
            $written | Should -Not -Match 'left-behind'
        }
    }

    Context 'help' {

        It 'has comment based help' {
            $help = Get-Help -Name Clear-HDTAutoLogon -ErrorAction Stop

            $help.Name | Should -BeExactly 'Clear-HDTAutoLogon'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
