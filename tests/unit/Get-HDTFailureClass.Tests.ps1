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
                $record = $null
                try {
                    $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Message 'bad authoring' -Path 'C:\ws\sequence.yaml'))
                } catch {
                    $record = $_
                }

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
}
