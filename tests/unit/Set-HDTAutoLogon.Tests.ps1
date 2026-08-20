# Arming autologon (DESIGN 4.5.1, DESIGN 4.5.2, ROADMAP M2).
#
# The one assertion this whole design exists for is in Context 'the password':
# the password goes to LSA and NOT to the registry. SPIKES.md S7 showed Windows
# itself doing that, and S8 drove three autologons with the registry
# DefaultPassword absent throughout - so this is the supported path, not a
# workaround, and there is no -PasswordStorage fallback to fall back to.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $script:defaultResume = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HDT\Start-HDTResume.ps1'
    $script:password = 'Zq7!mK3pT#w9Rd2X'
}

Describe 'Set-HDTAutoLogon' {

    BeforeEach {
        $script:journal = [System.Collections.ArrayList]::new()
        $script:registry = New-HDTFakeRegistryService -Journal $script:journal
        $script:lsa = New-HDTFakeLsaService -Journal $script:journal
        $script:fs = New-HDTFakeFileSystem -Journal $script:journal
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 4, 46, 15, [System.DateTimeKind]::Utc)) -Journal $script:journal
        $script:log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
            -FileSystem $script:fs -Clock $script:clock
    }

    Context 'the Winlogon values' {

        It 'sets AutoAdminLogon to 1' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValue($script:winlogonPath, 'AutoAdminLogon') | Should -Be '1'
        }

        It 'sets AutoAdminLogon as a string' {
            # Winlogon reads it as a REG_SZ. A DWord 1 is ignored.
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValueType($script:winlogonPath, 'AutoAdminLogon') | Should -BeExactly 'String'
        }

        It 'sets DefaultUserName' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'HDTAdmin' -Password $script:password -RemainingLeg 3

            $script:registry.GetValue($script:winlogonPath, 'DefaultUserName') | Should -BeExactly 'HDTAdmin'
        }

        It 'sets DefaultDomainName' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -DomainName 'CONTOSO'

            $script:registry.GetValue($script:winlogonPath, 'DefaultDomainName') | Should -BeExactly 'CONTOSO'
        }

        It 'sets DefaultDomainName to an empty string when none was given' {
            # A workgroup machine. Leaving a stale domain there would send
            # Winlogon looking for an account that does not exist.
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValue($script:winlogonPath, 'DefaultDomainName') | Should -BeExactly ''
        }

        It 'sets AutoLogonCount to the remaining legs' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 3
        }

        It 'writes AutoLogonCount as a DWord' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValueType($script:winlogonPath, 'AutoLogonCount') | Should -BeExactly 'DWord'
        }

        It 'writes to the DESIGN 4.5.1 Winlogon key path' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $written = @($script:registry.Operations |
                    Where-Object { $_.Operation -eq 'SetValue' -and $_.Arguments[1] -ne 'HDTResume' } |
                    ForEach-Object { $_.Arguments[0] } | Sort-Object -Unique)

            $written | Should -Be @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon')
        }
    }

    Context 'the password' {

        It 'stores the password as an LSA secret named DefaultPassword' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:lsa.GetSecret('DefaultPassword') | Should -BeExactly $script:password
        }

        It 'never writes DefaultPassword to the registry' {
            # THE assertion of DESIGN 4.5.2. No registry write anywhere in this
            # function may carry that value name.
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            @($script:registry.Operations |
                    Where-Object { $_.Operation -eq 'SetValue' -and $_.Arguments[1] -eq 'DefaultPassword' }) |
                Should -BeNullOrEmpty
        }

        It 'never puts the password into any registry write at all' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            ($script:registry.Operations | Out-String) | Should -Not -Match ([regex]::Escape($script:password))
        }

        It 'removes a registry DefaultPassword left by something else' {
            # An image, or another tool, may have left one. DESIGN 4.5.2's whole
            # point is that the password is not in the registry.
            $registry = New-HDTFakeRegistryService -Value @{
                $script:winlogonPath = @{ DefaultPassword = 'left-behind' }
            }

            Set-HDTAutoLogon -Registry $registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $registry.GetValue($script:winlogonPath, 'DefaultPassword') | Should -BeNullOrEmpty
        }

        It 'does not put the password in the log' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -LogContext $script:log

            $written = ($script:fs.Operations |
                    Where-Object { $_.Operation -in @('WriteAllText', 'AppendAllText') } |
                    ForEach-Object { $_.Arguments[1] }) -join "`n"

            $written | Should -Not -Match ([regex]::Escape($script:password))
        }

        It 'does not put the password in the reboot.arm data' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -LogContext $script:log

            $record = @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and $_.Arguments[0] -like '*HDT.jsonl' } |
                    ForEach-Object { $_.Arguments[1] })

            $record | Should -Not -BeNullOrEmpty
            ($record -join "`n") | Should -Not -Match ([regex]::Escape($script:password))
        }
    }

    Context 'the RunOnce entry' {

        It 'registers HDTResume under RunOnce' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValue($script:runOncePath, 'HDTResume') | Should -Not -BeNullOrEmpty
        }

        It 'uses the DESIGN 4.5.1 default resume command' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValue($script:runOncePath, 'HDTResume') | Should -BeExactly $script:defaultResume
        }

        It 'accepts an explicit resume command' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 `
                -ResumeCommand 'powershell.exe -File D:\HDT\Resume.ps1'

            $script:registry.GetValue($script:runOncePath, 'HDTResume') | Should -BeExactly 'powershell.exe -File D:\HDT\Resume.ps1'
        }

        It 'writes it to the RunOnce key path' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $written = @($script:registry.Operations |
                    Where-Object { $_.Operation -eq 'SetValue' -and $_.Arguments[1] -eq 'HDTResume' } |
                    ForEach-Object { $_.Arguments[0] })

            $written | Should -Be @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')
        }

        It 'writes the resume command as a string' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValueType($script:runOncePath, 'HDTResume') | Should -BeExactly 'String'
        }
    }

    Context 'the count is the remaining legs' {

        It 'sets 3 for three remaining legs' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            $script:registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 3
        }

        It 'sets 1 for the last leg' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 1

            $script:registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 1
        }

        It 'rejects a remaining leg count below 1' {
            # SPIKES.md S8: n buys exactly n autologons, so 0 is not "one more" -
            # it is a machine that will not come back.
            #
            # The identity of the failure is asserted, not merely that one
            # happened: "it threw" passes against CommandNotFoundException, so it
            # is green before the function exists and green after it is deleted
            # (tests/helpers/README.md 12). Watched failing for exactly that
            # reason on the first run of this file.
            $record = $null
            try {
                Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 0
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'ParameterArgumentValidationError*'
        }
    }

    Context 'idempotence' {

        It 'leaves the same state when armed twice' {
            # ROADMAP M2: "arming is idempotent across repeated restarts".
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3
            $first = Get-HDTAutoLogonState -Registry $script:registry -Lsa $script:lsa

            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3
            $second = Get-HDTAutoLogonState -Registry $script:registry -Lsa $script:lsa

            ($second | ConvertTo-Json -Depth 4) | Should -BeExactly ($first | ConvertTo-Json -Depth 4)
        }

        It 'registers the RunOnce entry once, not twice' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            @($script:registry.Key[$script:runOncePath].Keys) | Should -Be @('HDTResume')
        }

        It 'updates the count on a second arm' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 2

            $script:registry.GetValue($script:winlogonPath, 'AutoLogonCount') | Should -Be 2
        }
    }

    Context 'the state document' {

        It 'records armed, userName, countSet, secretName and runOnceName on the state' {
            $state = New-HDTRunState -SequenceId 'seq' -RunId 'run-0001' -Phase FullOS -Clock $script:clock

            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -State $state

            $state.autoLogon.armed | Should -BeTrue
            $state.autoLogon.userName | Should -BeExactly 'Administrator'
            $state.autoLogon.domainName | Should -BeExactly ''
            $state.autoLogon.countSet | Should -Be 3
            $state.autoLogon.secretName | Should -BeExactly 'DefaultPassword'
            $state.autoLogon.runOnceName | Should -BeExactly 'HDTResume'
        }

        It 'does not save the state itself' {
            # The caller owns the write order; 03-04 saves immediately after.
            $state = New-HDTRunState -SequenceId 'seq' -RunId 'run-0001' -Phase FullOS -Clock $script:clock

            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -State $state -LogContext $script:log

            # The log context appends; only a state save would use WriteAllText,
            # and Set-HDTAutoLogon has no filesystem to save through at all.
            @($script:fs.GetOperationName() | Where-Object { $_ -eq 'WriteAllText' }) | Should -BeNullOrEmpty
            (Get-Command Set-HDTAutoLogon).Parameters.Keys | Should -Not -Contain 'FileSystem'
        }

        It 'does not put the password in the state document' {
            # The state carries no password field, and arming must not add one:
            # the secret belongs in the LSA store Winlogon reads and nowhere
            # else this command writes.
            $state = New-HDTRunState -SequenceId 'seq' -RunId 'run-0001' -Phase FullOS -Clock $script:clock

            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -State $state

            $state.PSObject.Properties['deploymentPassword'] | Should -BeNullOrEmpty

            $saved = $state | ConvertTo-Json -Depth 8
            $saved | Should -Not -BeLike ('*{0}*' -f $script:password)
        }
    }

    Context 'ShouldProcess' {

        It 'writes nothing under -WhatIf' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -LogContext $script:log -WhatIf

            @($script:registry.Operations) | Should -BeNullOrEmpty
            @($script:lsa.Operations) | Should -BeNullOrEmpty
        }

        It 'does not touch the state under -WhatIf' {
            $state = New-HDTRunState -SequenceId 'seq' -RunId 'run-0001' -Phase FullOS -Clock $script:clock

            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -State $state -WhatIf

            $state.autoLogon.armed | Should -BeFalse
        }
    }

    Context 'logging' {

        It 'logs one reboot.arm record' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -LogContext $script:log

            $record = @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and $_.Arguments[0] -like '*HDT.jsonl' } |
                    ForEach-Object { ConvertFrom-Json -InputObject $_.Arguments[1] })

            @($record | Where-Object { $_.event -eq 'reboot.arm' }).Count | Should -Be 1
        }

        It 'names the user and the count in that record' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -LogContext $script:log

            $record = @($script:fs.Operations |
                    Where-Object { $_.Operation -eq 'AppendAllText' -and $_.Arguments[0] -like '*HDT.jsonl' } |
                    ForEach-Object { ConvertFrom-Json -InputObject $_.Arguments[1] } |
                    Where-Object { $_.event -eq 'reboot.arm' })

            $record[0].data.userName | Should -BeExactly 'Administrator'
            $record[0].data.count | Should -Be 3
        }

        It 'logs nothing when no log context was given' {
            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3

            @($script:fs.Operations) | Should -BeNullOrEmpty
        }
    }

    Context 'the artifacts it leaves' {

        It 'leaves exactly the DESIGN 4.5.3 checklist armed' {
            $state = New-HDTRunState -SequenceId 'seq' -RunId 'run-0001' -Phase FullOS -Clock $script:clock

            Set-HDTAutoLogon -Registry $script:registry -Lsa $script:lsa -UserName 'Administrator' -Password $script:password -RemainingLeg 3 -State $state

            $artifact = @(Get-HDTAutoLogonArtifact -Registry $script:registry -Lsa $script:lsa -State $state)

            # No registry DefaultPassword and no staged unattend: arming does not
            # create either.
            $artifact | Should -Contain 'AutoAdminLogon'
            $artifact | Should -Contain 'DefaultUserName'
            $artifact | Should -Contain 'DefaultDomainName'
            $artifact | Should -Contain 'AutoLogonCount'
            $artifact | Should -Contain 'LsaSecret:DefaultPassword'
            $artifact | Should -Contain 'RunOnce:HDTResume'
            $artifact | Should -Not -Contain 'DefaultPassword'
        }
    }

    Context 'help' {

        It 'has comment based help' {
            $help = Get-Help -Name Set-HDTAutoLogon -ErrorAction Stop

            $help.Name | Should -BeExactly 'Set-HDTAutoLogon'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
