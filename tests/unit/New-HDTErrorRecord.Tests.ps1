# New-HDTErrorRecord builds the one error shape every configuration failure in
# the engine uses (DESIGN 12.1: "Configuration (bad authoring - fail fast, point
# at the file and line)").
#
# It is private, so every assertion runs inside InModuleScope. The reason it
# exists rather than each caller writing `throw "message"`: a bare string throw
# loses the error id and the target object, and those are exactly what make a
# configuration failure greppable in a log and machine-readable by the console.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTErrorRecord' {

    It 'returns an ErrorRecord' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'something is wrong'

            $record | Should -BeOfType ([System.Management.Automation.ErrorRecord])
        }
    }

    It 'formats the path and line into the message' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'something is wrong' -Path 'C:\ws\rules.yaml' -Line 4

            $record.Exception.Message | Should -BeExactly 'C:\ws\rules.yaml(4): something is wrong'
        }
    }

    It 'formats the path alone when no line is supplied' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'something is wrong' -Path 'C:\ws\rules.yaml'

            $record.Exception.Message | Should -BeExactly 'C:\ws\rules.yaml: something is wrong'
        }
    }

    It 'uses the message alone when no path is supplied' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'something is wrong'

            $record.Exception.Message | Should -BeExactly 'something is wrong'
        }
    }

    It 'defaults the error id to HDTConfigurationError' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'something is wrong'

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }
    }

    It 'accepts an explicit error id' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'powershell-yaml is missing' -ErrorId 'HDTDependencyError'

            $record.FullyQualifiedErrorId | Should -BeLike 'HDTDependencyError*'
        }
    }

    It 'defaults the category to InvalidData' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'something is wrong'

            $record.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::InvalidData)
        }
    }

    It 'accepts an explicit category' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'powershell-yaml is missing' -Category NotInstalled

            $record.CategoryInfo.Category | Should -Be ([System.Management.Automation.ErrorCategory]::NotInstalled)
        }
    }

    It 'sets the path as the target object' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'something is wrong' -Path 'C:\ws\rules.yaml'

            $record.TargetObject | Should -BeExactly 'C:\ws\rules.yaml'
        }
    }

    It 'takes a target object that is not a path' {
        InModuleScope Hephaestus {
            # DESIGN 9.1's refusals are about a DISK, not a file. The target of
            # "disk 0 is the disk this machine booted from" is the number 0, and
            # a console that has to parse it back out of the prose is a console
            # that will get it wrong.
            $record = New-HDTErrorRecord -Message 'disk 0 is the disk this machine booted from' -TargetObject 0

            $record.TargetObject | Should -Be 0
            $record.Exception.Message | Should -BeExactly 'disk 0 is the disk this machine booted from'
        }
    }

    It 'prefers an explicit target object over the path' {
        InModuleScope Hephaestus {
            $record = New-HDTErrorRecord -Message 'something is wrong' -Path 'C:\ws\rules.yaml' -TargetObject 7

            $record.TargetObject | Should -Be 7
            $record.Exception.Message | Should -BeExactly 'C:\ws\rules.yaml: something is wrong'
        }
    }

    It 'keeps the inner exception' {
        InModuleScope Hephaestus {
            $inner = [System.IO.FileNotFoundException]::new('no such file')
            $record = New-HDTErrorRecord -Message 'something is wrong' -InnerException $inner

            $record.Exception.InnerException | Should -Not -BeNullOrEmpty
            $record.Exception.InnerException.Message | Should -BeExactly 'no such file'
        }
    }

    It 'produces FullyQualifiedErrorId starting with the error id when thrown' {
        InModuleScope Hephaestus {
            function Invoke-HDTErrorRecordProbe {
                <#
                    .SYNOPSIS
                        Throws a New-HDTErrorRecord record the way every caller does.
                #>
                [CmdletBinding()]
                [OutputType([void])]
                param()

                $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Message 'something is wrong' -Path 'C:\ws\rules.yaml'))
            }

            $record = $null
            try { Invoke-HDTErrorRecordProbe } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            $record.TargetObject | Should -BeExactly 'C:\ws\rules.yaml'
            $record.Exception.Message | Should -BeExactly 'C:\ws\rules.yaml: something is wrong'
        }
    }

    It 'has comment-based help with a synopsis' {
        InModuleScope Hephaestus {
            $help = Get-Help -Name New-HDTErrorRecord -ErrorAction Stop

            # Get-Help falls back to a fuzzy search when nothing matches exactly
            # and will return another command's help, which passes a bare
            # synopsis assertion. Assert the name first.
            $help.Name | Should -BeExactly 'New-HDTErrorRecord'
            $help.Synopsis | Should -Not -BeNullOrEmpty
            $help.Synopsis | Should -Not -Match 'New-HDTErrorRecord \['
        }
    }
}
