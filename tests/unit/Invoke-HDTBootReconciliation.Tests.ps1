# The boot-time reconcile (DESIGN 4.5.2, ROADMAP M2).
#
# "Teardown is a failsafe, not a step. In HDT teardown runs from finally around
# the sequence, AND Start-HDTResume.ps1 reconciles on every boot: if the state
# document says the run is finished, failed, or missing, it clears autologon, the
# LSA secret, the RunOnce entry, and C:\HDT\state.json BEFORE DOING ANYTHING
# ELSE."
#
# This is the second of three backstops. SPIKES.md S8 measured what happens
# without it: Windows only disarms itself after AutoLogonCount is spent, so an
# abandoned run keeps autologging on for up to n more boots. The reconcile is
# what makes that window one boot instead of n.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $script:statePath = 'C:\HDT\state.json'
    $script:now = [datetime]::new(2026, 8, 13, 6, 0, 0, [System.DateTimeKind]::Utc)

    # An armed machine, exactly as Set-HDTAutoLogon leaves it.
    $script:armedRegistry = {
        param($Journal)

        New-HDTFakeRegistryService -Journal $Journal -Value @{
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' = @{
                AutoAdminLogon    = '1'
                DefaultUserName   = 'Administrator'
                DefaultDomainName = ''
                AutoLogonCount    = 3
            }
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'     = @{ HDTResume = 'powershell.exe' }
        }
    }

    # A state document as Save-HDTRunState writes it, with the fields the
    # reconcile reads set explicitly.
    $script:stateJson = {
        param([string] $Status, [datetime] $UpdatedUtc, [int] $StepIndex = 4, [int] $Leg = 2)

        $document = [ordered] @{
            schemaVersion      = 1
            runId              = 'run-0001'
            sequenceId         = 'seq-0001'
            status             = $Status
            phase              = 'FullOS'
            leg                = $Leg
            seq                = 17
            startedUtc         = '2026-08-13T05:00:00.0000000Z'
            updatedUtc         = $UpdatedUtc.ToString('o')
            stepIndex          = $StepIndex
            pauseOnError       = $false
            variable           = @{}
            step               = @()
            autoLogon          = [ordered] @{
                armed       = $true
                userName    = 'Administrator'
                domainName  = ''
                countSet    = 3
                secretName  = 'DefaultPassword'
                runOnceName = 'HDTResume'
            }
            deploymentPassword = 'Sw0rdfish!'
        }

        return (ConvertTo-Json -InputObject $document -Depth 8)
    }
}

Describe 'Invoke-HDTBootReconciliation' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:registry = & $script:armedRegistry $script:journal
        $script:lsa = New-HDTFakeLsaService -Journal $script:journal -Secret @{ DefaultPassword = 'Sw0rdfish!' }
        $script:clock = New-HDTFakeClock -UtcNow $script:now -Journal $script:journal
        $script:fs = New-HDTFakeFileSystem -Journal $script:journal
        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock
    }

    Context 'no state document' {

        # ROADMAP M2: "after a run whose state document is missing entirely".

        BeforeEach {
            $script:result = Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $script:fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock
        }

        It 'reports Teardown' {
            $script:result.Action | Should -BeExactly 'Teardown'
        }

        It 'gives no state document as the reason' {
            $script:result.Reason | Should -BeExactly 'no state document'
        }

        It 'clears autologon' {
            $script:registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -BeNullOrEmpty
            $script:lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'leaves no artifact behind' {
            Get-HDTAutoLogonArtifact -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs |
                Should -BeNullOrEmpty
        }

        It 'does not throw' {
            { Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $script:fs `
                    -Registry $script:registry -Lsa $script:lsa -Clock $script:clock } | Should -Not -Throw
        }

        It 'returns a null state' {
            $script:result.State | Should -BeNullOrEmpty
        }

        It 'does not try to remove a state file that is not there' {
            @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'RemoveItem' -and $_.Arguments[0] -eq $script:statePath }) |
                Should -BeNullOrEmpty
        }
    }

    Context 'an unreadable state document' {

        BeforeEach {
            $script:fs.SeedFile($script:statePath, '{ "schemaVersion": 1, "runId": ')
            $script:result = Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $script:fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock -LogContext $script:log
        }

        It 'reports Teardown' {
            $script:result.Action | Should -BeExactly 'Teardown'
        }

        It 'gives unreadable state document as the reason' {
            $script:result.Reason | Should -BeExactly 'unreadable state document'
        }

        It 'clears autologon' {
            $script:registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -BeNullOrEmpty
            $script:lsa.GetSecret('DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'leaves no artifact behind' {
            Get-HDTAutoLogonArtifact -Registry $script:registry -Lsa $script:lsa -FileSystem $script:fs |
                Should -BeNullOrEmpty
        }

        It 'does not rethrow the parse error' {
            $registry = & $script:armedRegistry $null
            $fs = New-HDTFakeFileSystem -File @{ $script:statePath = '{ not json' }

            { Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $fs `
                    -Registry $registry -Lsa (New-HDTFakeLsaService) -Clock $script:clock } | Should -Not -Throw
        }

        It 'logs the parse message at Warning' {
            # The only branch in this function that swallows an exception, so the
            # exception has to survive as a log line.
            $record = @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and $_.Arguments[0] -like '*HDT.jsonl' } |
                    ForEach-Object { ConvertFrom-Json -InputObject $_.Arguments[1] } |
                    Where-Object { $_.level -eq 'Warning' })

            $record | Should -Not -BeNullOrEmpty
            ($record | ForEach-Object { $_.msg }) -join ' ' | Should -Not -BeNullOrEmpty
        }

        It 'removes the corrupt state file' {
            $script:fs.TestPath($script:statePath) | Should -BeFalse
        }
    }

    Context 'an abandoned run' {

        # ROADMAP M2: "after an abandoned run (state document present but
        # stale)".

        It "reports Teardown for a <Name> state" -ForEach @(
            @{ Name = 'Running past the age limit'; Status = 'Running'; Age = 13 }
            @{ Name = 'Succeeded'; Status = 'Succeeded'; Age = 0 }
            @{ Name = 'Failed'; Status = 'Failed'; Age = 0 }
        ) {
            $fs = New-HDTFakeFileSystem -File @{
                $script:statePath = (& $script:stateJson $Status $script:now.AddHours(-$Age))
            }

            $result = Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock

            $result.Action | Should -BeExactly 'Teardown'
        }

        It 'gives run finished as the reason for a <Status> state' -ForEach @(
            @{ Status = 'Succeeded' }
            @{ Status = 'Failed' }
        ) {
            $fs = New-HDTFakeFileSystem -File @{ $script:statePath = (& $script:stateJson $Status $script:now) }

            $result = Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock

            $result.Reason | Should -BeExactly 'run finished'
        }

        It 'gives run abandoned as the reason for a stale Running state' {
            $fs = New-HDTFakeFileSystem -File @{ $script:statePath = (& $script:stateJson 'Running' $script:now.AddHours(-13)) }

            $result = Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock

            $result.Reason | Should -BeExactly 'run abandoned'
        }

        It 'clears autologon and leaves no artifact behind for a <Status> state' -ForEach @(
            @{ Status = 'Running'; Age = 13 }
            @{ Status = 'Succeeded'; Age = 0 }
            @{ Status = 'Failed'; Age = 0 }
        ) {
            $journal = [System.Collections.ArrayList]::new()
            $registry = & $script:armedRegistry $journal
            $lsa = New-HDTFakeLsaService -Journal $journal -Secret @{ DefaultPassword = 'Sw0rdfish!' }
            $fs = New-HDTFakeFileSystem -Journal $journal -File @{
                $script:statePath                 = (& $script:stateJson $Status $script:now.AddHours(-$Age))
                'C:\Windows\Panther\unattend.xml' = '<unattend/>'
            }

            Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $fs `
                -Registry $registry -Lsa $lsa -Clock $script:clock | Out-Null

            Get-HDTAutoLogonArtifact -Registry $registry -Lsa $lsa -FileSystem $fs | Should -BeNullOrEmpty
        }

        It 'removes the state file' {
            $fs = New-HDTFakeFileSystem -File @{ $script:statePath = (& $script:stateJson 'Succeeded' $script:now) }

            Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock | Out-Null

            $fs.TestPath($script:statePath) | Should -BeFalse
        }

        It 'honours -MaxAgeHour' {
            # Two hours stale: abandoned at -MaxAgeHour 1, alive at the default.
            $body = (& $script:stateJson 'Running' $script:now.AddHours(-2))

            $tight = Invoke-HDTBootReconciliation -StatePath $script:statePath `
                -FileSystem (New-HDTFakeFileSystem -File @{ $script:statePath = $body }) `
                -Registry (& $script:armedRegistry $null) -Lsa (New-HDTFakeLsaService -Secret @{ DefaultPassword = 'x' }) `
                -Clock $script:clock -MaxAgeHour 1

            $loose = Invoke-HDTBootReconciliation -StatePath $script:statePath `
                -FileSystem (New-HDTFakeFileSystem -File @{ $script:statePath = $body }) `
                -Registry (& $script:armedRegistry $null) -Lsa (New-HDTFakeLsaService -Secret @{ DefaultPassword = 'x' }) `
                -Clock $script:clock

            $tight.Action | Should -BeExactly 'Teardown'
            $loose.Action | Should -BeExactly 'Resume'
        }

        It 'reads the time only through the injected clock' {
            $fs = New-HDTFakeFileSystem -Journal $script:journal -File @{
                $script:statePath = (& $script:stateJson 'Running' $script:now.AddHours(-13))
            }

            Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock | Out-Null

            @($script:journal | Where-Object { $_.Service -eq 'Clock' }) | Should -Not -BeNullOrEmpty

            $source = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Invoke-HDTBootReconciliation.ps1') -Raw
            $source | Should -Not -Match 'Get-Date'
            $source | Should -Not -Match '\[datetime\]::(UtcNow|Now)'
        }
    }

    Context 'a live run' {

        BeforeEach {
            $script:fs.SeedFile($script:statePath, (& $script:stateJson 'Running' $script:now.AddMinutes(-4) 4 2))
            $script:result = Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $script:fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock -LogContext $script:log
        }

        It 'reports Resume' {
            $script:result.Action | Should -BeExactly 'Resume'
        }

        It 'returns the state' {
            $script:result.State | Should -Not -BeNullOrEmpty
            $script:result.State.runId | Should -BeExactly 'run-0001'
        }

        It 'increments the leg' {
            $script:result.State.leg | Should -Be 3
        }

        It 'does not clear autologon' {
            # The assertion that keeps the reconcile from disarming the run it
            # exists to continue.
            $script:registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -Be '1'
            $script:registry.GetValue($script:runOncePath, 'HDTResume') | Should -Not -BeNullOrEmpty
            $script:lsa.GetSecret('DefaultPassword') | Should -BeExactly 'Sw0rdfish!'
        }

        It 'does not remove the state file' {
            $script:fs.TestPath($script:statePath) | Should -BeTrue
        }

        It 'logs a reboot.resume record' {
            $record = @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and $_.Arguments[0] -like '*HDT.jsonl' } |
                    ForEach-Object { ConvertFrom-Json -InputObject $_.Arguments[1] })

            @($record | Where-Object { $_.event -eq 'reboot.resume' }).Count | Should -Be 1
        }

        It 'names the step it will resume at in the reason' {
            $script:result.Reason | Should -BeExactly 'resuming at step 4'
        }

        It 'does not run any step' {
            # The caller runs the sequence; 03-04 owns Start-HDTResume.ps1.
            @($script:journal | Where-Object { $_.Service -in @('ProcessService', 'ScriptInvoker', 'PowerService') }) |
                Should -BeNullOrEmpty
        }

        It 'does not put the deployment password in the log' {
            $written = ($script:fs.Operations |
                    Where-Object { $_.Operation -in @('WriteAllText', 'AppendAllText') } |
                    ForEach-Object { $_.Arguments[1] }) -join "`n"

            $written | Should -Not -Match 'Sw0rdfish'
        }
    }

    Context 'order of operations' {

        It 'clears autologon before returning, and before it removes the state file' {
            # DESIGN 4.5.2's "before doing anything else", made checkable: the
            # journal shows the disarm ahead of the state file deletion, so a
            # crash between the two leaves a disarmed machine rather than an
            # armed one.
            $fs = New-HDTFakeFileSystem -Journal $script:journal -File @{
                $script:statePath = (& $script:stateJson 'Failed' $script:now)
            }

            Invoke-HDTBootReconciliation -StatePath $script:statePath -FileSystem $fs `
                -Registry $script:registry -Lsa $script:lsa -Clock $script:clock | Out-Null

            $order = @($script:journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation })

            $disarm = [array]::IndexOf($order, 'RegistryService.RemoveValue')
            $secret = [array]::IndexOf($order, 'LsaService.RemoveSecret')
            $delete = [array]::LastIndexOf($order, 'FileSystem.RemoveItem')

            $disarm | Should -BeGreaterThan -1
            $secret | Should -BeGreaterThan -1
            $delete | Should -BeGreaterThan $disarm
            $delete | Should -BeGreaterThan $secret
        }
    }

    Context 'help' {

        It 'has comment based help' {
            $help = Get-Help -Name Invoke-HDTBootReconciliation -ErrorAction Stop

            $help.Name | Should -BeExactly 'Invoke-HDTBootReconciliation'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
