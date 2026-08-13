# DESIGN 12.1's three failure classes, decided in one place.
#
#   Transient      retry per the step's retry policy
#   Configuration  bad authoring - fail fast, point at the file and line
#   Environment    hardware or network - fail with diagnostics attached
#
# The classification is not decoration: it decides whether the step is retried.
# A Configuration failure is never retried, because retrying bad authoring
# spends a deployment's time three times over and buries the message that would
# have fixed it under two more copies of itself.
#
# It is private, so every assertion runs inside InModuleScope.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'Get-HDTFailureClass' {

    Context 'Configuration' {

        It 'classes an HDTConfigurationError as Configuration' {
            InModuleScope Hephaestus {
                # A real one, raised the way every HDT configuration failure is
                # raised, rather than a hand-built record.
                $record = $null
                try { ConvertFrom-HDTStepCondition -Condition 'this is not a condition' } catch { $record = $_ }

                $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Configuration'
            }
        }

        It 'matches any function that raised one' {
            InModuleScope Hephaestus {
                # The id is "<ErrorId>,<FunctionName>", so the wildcard is what
                # makes this independent of which function threw.
                $exception = New-Object -TypeName System.Exception -ArgumentList 'bad authoring'
                $record = New-Object -TypeName System.Management.Automation.ErrorRecord `
                    -ArgumentList $exception, 'HDTConfigurationError,Invoke-HDTContosoStep', 'InvalidData', $null

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Configuration'
            }
        }
    }

    Context 'the refusal error ids' {

        # DESIGN 9.1's refusals are bad authoring, not bad luck. A refusal to wipe
        # a disk that got retried three times would be absurd - and it would print
        # the sentence that would have fixed it three times over.
        #
        # The list is NAMED, not a wildcard on 'HDT*Error'. A wildcard would
        # silently swallow every error id a later phase invents, including ones
        # that really are transient.

        It 'classifies <_> as Configuration' -ForEach @(
            'HDTAmbiguousTargetError',
            'HDTUnsafeTargetError',
            'HDTNoTargetDiskError',
            'HDTAmbiguousImageError'
        ) {
            InModuleScope Hephaestus -Parameters @{ ErrorId = $_ } {
                param($ErrorId)

                $exception = New-Object -TypeName System.Exception -ArgumentList 'a refusal'
                $record = New-Object -TypeName System.Management.Automation.ErrorRecord `
                    -ArgumentList $exception, ('{0},Select-HDTTargetDisk' -f $ErrorId), 'InvalidData', $null

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Configuration'
            }
        }

        It 'still classifies an unknown HDT error id as Transient' {
            InModuleScope Hephaestus {
                $exception = New-Object -TypeName System.Exception -ArgumentList 'something a later phase invented'
                $record = New-Object -TypeName System.Management.Automation.ErrorRecord `
                    -ArgumentList $exception, 'HDTSomethingElseError,Invoke-HDTContosoStep', 'InvalidData', $null

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Transient'
            }
        }
    }

    Context 'Environment' {

        It 'classes an IOException as Environment' {
            InModuleScope Hephaestus {
                $record = $null
                try { throw [System.IO.IOException]::new('the device is not ready') } catch { $record = $_ }

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Environment'
            }
        }

        It 'classes a FileNotFoundException as Environment' {
            InModuleScope Hephaestus {
                $record = $null
                try { throw [System.IO.FileNotFoundException]::new('no install.wim') } catch { $record = $_ }

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Environment'
            }
        }

        It 'classes a DirectoryNotFoundException as Environment' {
            InModuleScope Hephaestus {
                $record = $null
                try { throw [System.IO.DirectoryNotFoundException]::new('no share') } catch { $record = $_ }

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Environment'
            }
        }

        It 'classes a Win32Exception as Environment' {
            InModuleScope Hephaestus {
                $record = $null
                try { throw [System.ComponentModel.Win32Exception]::new('the system cannot find the file specified') } catch { $record = $_ }

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Environment'
            }
        }

        It 'classes a TimeoutException as Environment' {
            InModuleScope Hephaestus {
                $record = $null
                try { throw [System.TimeoutException]::new('it never came back') } catch { $record = $_ }

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Environment'
            }
        }

        It 'classes a timeout as Environment' {
            InModuleScope Hephaestus {
                Get-HDTFailureClass -TimedOut | Should -BeExactly 'Environment'
            }
        }

        It 'classes a timeout as Environment even when the exception says otherwise' {
            InModuleScope Hephaestus {
                $exception = New-Object -TypeName System.Exception -ArgumentList 'bad authoring'
                $record = New-Object -TypeName System.Management.Automation.ErrorRecord `
                    -ArgumentList $exception, 'HDTConfigurationError,Invoke-HDTContosoStep', 'InvalidData', $null

                Get-HDTFailureClass -ErrorRecord $record -TimedOut | Should -BeExactly 'Environment'
            }
        }
    }

    Context 'Transient' {

        It 'classes a failed exit code as Transient' {
            InModuleScope Hephaestus {
                # A step that returned Failed with an exit code reported a
                # failure without an exception at all.
                Get-HDTFailureClass | Should -BeExactly 'Transient'
            }
        }

        It 'classes a null as Transient' {
            InModuleScope Hephaestus {
                Get-HDTFailureClass -ErrorRecord $null | Should -BeExactly 'Transient'
            }
        }

        It 'classes an unknown exception as Transient' {
            InModuleScope Hephaestus {
                $record = $null
                try { throw [System.InvalidOperationException]::new('something else entirely') } catch { $record = $_ }

                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Transient'
            }
        }
    }

    Context 'unwrapping' {

        It 'unwraps a MethodInvocationException to the innermost exception' {
            InModuleScope Hephaestus {
                # tests/helpers/README.md section 5: a ScriptMethod on a
                # pscustomobject - which is every real adapter - wraps what it
                # threw in MethodInvocationException over RuntimeException. A
                # classifier that looked only at the outer type would call every
                # adapter failure Transient and retry a missing file three times.
                $adapter = [pscustomobject] @{}
                $adapter | Add-Member -MemberType ScriptMethod -Name Boom -Value {
                    throw [System.IO.IOException]::new('the device is not ready')
                }

                $record = $null
                try { $adapter.Boom() } catch { $record = $_ }

                $record.Exception | Should -BeOfType ([System.Management.Automation.MethodInvocationException])
                Get-HDTFailureClass -ErrorRecord $record | Should -BeExactly 'Environment'
            }
        }

        It 'takes a bare exception as well as an ErrorRecord' {
            InModuleScope Hephaestus {
                Get-HDTFailureClass -ErrorRecord ([System.IO.IOException]::new('the device is not ready')) |
                    Should -BeExactly 'Environment'
            }
        }
    }

    Context 'a refusal that arrived as result data' {

        # A step NEVER lets a refusal escape as a terminating error: the step
        # contract requires a result whose Status is in the closed set, and a
        # step that threw for a minimal step would turn that contract red. So
        # DiskPartition catches its own refusal and returns
        #
        #   New-HDTStepResult -Status Failed -Data @{ errorId = 'HDT...Error' }
        #
        # which means the errorId reaches this classifier through the RESULT
        # rather than through an ErrorRecord. Without this leg, 04-02's "a
        # refusal is never retried" would silently stop being true the moment
        # the refusal became a result - the step would be Transient and a
        # sequence declaring retry: 2 would refuse to wipe the same disk three
        # times.

        It 'classifies a result carrying <_> as Configuration' -ForEach @(
            'HDTConfigurationError',
            'HDTAmbiguousTargetError',
            'HDTUnsafeTargetError',
            'HDTNoTargetDiskError',
            'HDTAmbiguousImageError'
        ) {
            InModuleScope Hephaestus -Parameters @{ ErrorId = $_ } {
                Get-HDTFailureClass -ResultData ([ordered] @{ errorId = $ErrorId }) |
                    Should -BeExactly 'Configuration'
            }
        }

        It 'reads the errorId case-insensitively' {
            InModuleScope Hephaestus {
                Get-HDTFailureClass -ResultData ([ordered] @{ ErrorId = 'HDTUnsafeTargetError' }) |
                    Should -BeExactly 'Configuration'
            }
        }

        It 'reads an errorId off a pscustomobject as well as a dictionary' {
            InModuleScope Hephaestus {
                Get-HDTFailureClass -ResultData ([pscustomobject] @{ errorId = 'HDTNoTargetDiskError' }) |
                    Should -BeExactly 'Configuration'
            }
        }

        It 'classifies a result with no errorId as Transient' {
            InModuleScope Hephaestus {
                Get-HDTFailureClass -ResultData ([ordered] @{ exitCode = 1 }) | Should -BeExactly 'Transient'
            }
        }

        It 'classifies an errorId this list does not name as Transient' {
            # The named list again: a later phase's id is not swallowed by a
            # wildcard on HDT*Error.
            InModuleScope Hephaestus {
                Get-HDTFailureClass -ResultData ([ordered] @{ errorId = 'HDTDriverInjectionError' }) |
                    Should -BeExactly 'Transient'
            }
        }

        It 'tolerates result data that is not a dictionary' {
            InModuleScope Hephaestus {
                Get-HDTFailureClass -ResultData 'the apply failed' | Should -BeExactly 'Transient'
                Get-HDTFailureClass -ResultData @(1, 2, 3) | Should -BeExactly 'Transient'
                Get-HDTFailureClass -ResultData $null | Should -BeExactly 'Transient'
            }
        }

        It 'prefers the thrown error over the result data' {
            InModuleScope Hephaestus {
                # The exception is the stronger evidence: it says what actually
                # went wrong, where the data says what the step believed.
                $record = $null
                try { throw [System.IO.IOException]::new('the device is not ready') } catch { $record = $_ }

                Get-HDTFailureClass -ErrorRecord $record -ResultData ([ordered] @{ errorId = 'HDTAmbiguousTargetError' }) |
                    Should -BeExactly 'Environment'
            }
        }

        It 'still puts a timeout above everything' {
            InModuleScope Hephaestus {
                Get-HDTFailureClass -ResultData ([ordered] @{ errorId = 'HDTAmbiguousTargetError' }) -TimedOut |
                    Should -BeExactly 'Environment'
            }
        }
    }
}
