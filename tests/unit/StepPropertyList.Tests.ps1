# A step property whose value is a LIST, spliced like every other edit.
#
# WHY Set-HDTStepProperty CANNOT DO IT. That one writes a SCALAR, and
# Get-HDTConsoleScalarText quotes anything opening with '[' - correctly, because
# a scalar that starts a flow sequence would otherwise stop being a scalar. Ask
# it for successCodes and the file gets
#
#     successCodes: '[0, 3010]'
#
# which parses back as one string, and Invoke-HDTCommandLineStep casts each
# entry to [int] and dies on the bracket. The console offered no way to edit
# these at all, which is how that went unnoticed.
#
# FLOW, NOT BLOCK, AND THAT IS A DECISION. A block list
#
#     features:
#       - Web-Server
#
# reads better and every template in this repo still writes the flow form -
# 'successCodes: [0, 3010]', 'features: []'. It is also the only form that is
# safe today: Get-HDTStepKey ends its scan of a step at the first line matching
# '^\s*-\s', so a block list under a key would hide every key BELOW it from
# Set-HDTStepProperty. One line per property keeps the splice to one line too.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:text = @'
schemaVersion: 1
id: DEMO-M4
name: Windows 11 bare metal

steps:
  # successCodes is 0 and 3010 because almost every installer wants both.
  - name: Install the agent
    type: CommandLine
    command: setup.exe /q
    successCodes: [0, 3010]

  - name: Install Roles and Features
    type: InstallRoles
    features: []
    includeManagementTools: true
'@

    $script:line = $script:text -split "`r?`n"
}

Describe 'Set-HDTStepPropertyList' {

    Context 'the command is shaped like the rest of the toolkit' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Set-HDTStepPropertyList' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'has comment-based help' {
            (Get-Help -Name 'Set-HDTStepPropertyList').Synopsis | Should -Not -BeNullOrEmpty
        }

        It 'supports ShouldProcess, because it rewrites a document' {
            (Get-Command -Name 'Set-HDTStepPropertyList').Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }
    }

    Context 'a list the step already carries' {

        It 'writes a flow sequence the parser reads back as numbers' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install the agent' `
                    -Property 'successCodes' -Item @('0', '1641', '3010'))

            $result | Should -Contain '    successCodes: [0, 1641, 3010]'
        }

        It 'keeps the comment above the step, like every other splice' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install the agent' `
                    -Property 'successCodes' -Item @('0'))

            $result | Should -Contain '  # successCodes is 0 and 3010 because almost every installer wants both.'
        }

        It 'leaves the document exactly as long, because it replaces one line' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install the agent' `
                    -Property 'successCodes' -Item @('0', '1641'))

            $result.Count | Should -Be $script:line.Count
        }

        It 'touches nothing else in the step' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install the agent' `
                    -Property 'successCodes' -Item @('0'))

            $result | Should -Contain '    command: setup.exe /q'
        }
    }

    Context 'a list the step does not carry yet' {

        It 'adds it, so a page can offer a setting the file has never named' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install the agent' `
                    -Property 'rebootCodes' -Item @('3010', '1641'))

            $result | Should -Contain '    rebootCodes: [3010, 1641]'
        }
    }

    Context 'an empty list' {

        It 'writes [] rather than removing the key' {
            # The key being present and empty is a different statement from the
            # key being absent - Install Roles ships with 'features: []' exactly
            # so the sheet has something to show. Removing it would make an
            # emptied list look like a setting nobody had touched.
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install Roles and Features' `
                    -Property 'features' -Item @())

            $result | Should -Contain '    features: []'
        }
    }

    Context 'entries that would break the line they are written on' {

        It 'quotes one carrying a comma, so the list still has the length it was given' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install Roles and Features' `
                    -Property 'features' -Item @('Web-Server', 'Odd, Name'))

            $result | Should -Contain "    features: [Web-Server, 'Odd, Name']"
        }

        It 'quotes one carrying a bracket, which would otherwise close the sequence' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install Roles and Features' `
                    -Property 'features' -Item @('Web-Server]'))

            $result | Should -Contain "    features: ['Web-Server]']"
        }

        It 'drops an entry that is nothing but space, because it is not a value' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install the agent' `
                    -Property 'successCodes' -Item @('0', '  ', '3010'))

            $result | Should -Contain '    successCodes: [0, 3010]'
        }
    }

    Context 'what it writes, read back by the engine' {

        It 'comes back as a list of numbers rather than one string' {
            $result = @(Set-HDTStepPropertyList -Line $script:line -Name 'Install the agent' `
                    -Property 'successCodes' -Item @('0', '1641', '3010'))

            $path = Join-Path -Path $TestDrive -ChildPath 'sequence.yaml'
            Set-Content -LiteralPath $path -Value $result -Encoding UTF8

            $document = Import-HDTSequenceDocument -Path $path -FileSystem (New-HDTFileSystem)
            $step = @($document.Step | Where-Object { $_.Name -eq 'Install the agent' })[0]

            @($step.Property['successCodes']).Count | Should -Be 3
            [int] @($step.Property['successCodes'])[1] | Should -Be 1641
        }
    }

    Context 'a step that is not there' {

        It 'refuses by name rather than writing the wrong step' {
            { Set-HDTStepPropertyList -Line $script:line -Name 'No such step' `
                    -Property 'successCodes' -Item @('0') -ErrorAction Stop } | Should -Throw
        }
    }
}
