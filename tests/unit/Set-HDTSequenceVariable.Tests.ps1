# THE VARIABLES BLOCK, EDITABLE AFTER THE WIZARD HAS CLOSED.
#
# New-HDTTaskSequence's window asks for the administrator password, the OS image
# and the organisation, writes them into the sequence's variables: block, and
# then nothing could ever change them again: the editor edits steps, the detail
# pane edits name and description, and there was no command for the block in
# between. An administrator who mistyped the password re-created the sequence.
#
# WHAT AN AUTHOR IS EXPECTED TO CHANGE, says the template's own comment above
# that block - and it was the one part of a sequence a window could not touch.
#
# IT RETURNS LINES AND WRITES NOTHING, like every other editing command here:
# Save-HDTSequenceDocument is what touches the share, so an edit can be composed
# and abandoned without a file changing.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # ConvertFrom-HDTSequenceLine is private, so reading a spliced document back
    # goes through the module's own scope rather than a second parser.
    function Get-HDTTestSequenceDocument {
        [CmdletBinding()]
        [OutputType([object])]
        param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string[]] $Line)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ Document = $Line } {
            param($Document)
            ConvertFrom-HDTSequenceLine -Line ([string[]] $Document)
        }
    }

    # A sequence with a variables block, comments inside it, and steps after -
    # the shape New-HDTTaskSequence writes from the template.
    $script:withBlock = [string[]] @(
        '# The lab client sequence.'
        'schemaVersion: 1'
        'id: DEMO'
        'name: Demo'
        ''
        'variables:'
        '  # WHAT AN AUTHOR IS EXPECTED TO CHANGE.'
        '  HDTOSImage: Win11-LTSC-2024'
        '  HDTOSImageIndex: 1'
        ''
        'steps:'
        '  - name: Gather'
        '    type: Gather'
    )

    # A sequence that never declared one. New-HDTTaskSequence writes the block,
    # but a hand-written sequence need not, and the console must be able to add
    # the first variable to one.
    $script:withoutBlock = [string[]] @(
        'schemaVersion: 1'
        'id: BARE'
        'name: Bare'
        ''
        'steps:'
        '  - name: Gather'
        '    type: Gather'
    )
}

Describe 'Set-HDTSequenceVariable' {

    Context 'a block that is already there' {

        It 'changes a value the block already declares' {
            $after = Set-HDTSequenceVariable -Line $script:withBlock -Name 'HDTOSImage' -Value 'WS2025-Std' -Confirm:$false

            (Get-HDTTestSequenceDocument -Line $after).Variable['HDTOSImage'] | Should -BeExactly 'WS2025-Std'
        }

        It 'adds one the block does not have' {
            $after = Set-HDTSequenceVariable -Line $script:withBlock -Name 'HDTAdminPassword' -Value 'P@ssw0rd!' -Confirm:$false

            (Get-HDTTestSequenceDocument -Line $after).Variable['HDTAdminPassword'] | Should -BeExactly 'P@ssw0rd!'
        }

        It 'leaves the comment inside the block alone' {
            # The template writes a comment there explaining what the block is
            # for, and an edit that ate it would make the next author wonder.
            $after = Set-HDTSequenceVariable -Line $script:withBlock -Name 'HDTOSImage' -Value 'WS2025-Std' -Confirm:$false

            $after | Should -Contain '  # WHAT AN AUTHOR IS EXPECTED TO CHANGE.'
        }

        It 'leaves every other line byte-identical' {
            $after = Set-HDTSequenceVariable -Line $script:withBlock -Name 'HDTOSImage' -Value 'WS2025-Std' -Confirm:$false

            $changed = @(Compare-Object -ReferenceObject $script:withBlock -DifferenceObject $after |
                    ForEach-Object { [string] $_.InputObject })

            @($changed | Where-Object { $_ -notlike '*HDTOSImage*' }) | Should -BeNullOrEmpty
        }

        It 'removes one, because a variable set by mistake has to be removable' {
            $after = Set-HDTSequenceVariable -Line $script:withBlock -Name 'HDTOSImageIndex' -Remove -Confirm:$false

            (Get-HDTTestSequenceDocument -Line $after).Variable.Contains('HDTOSImageIndex') | Should -BeFalse
            (Get-HDTTestSequenceDocument -Line $after).Variable['HDTOSImage'] | Should -BeExactly 'Win11-LTSC-2024'
        }
    }

    Context 'a sequence with no variables block' {

        It 'builds the block, before the steps' {
            # After the header and before steps: - a variables: block written
            # under steps: belongs to the last step, or to nothing.
            $after = Set-HDTSequenceVariable -Line $script:withoutBlock -Name 'HDTAdminPassword' -Value 'P@ssw0rd!' -Confirm:$false

            (Get-HDTTestSequenceDocument -Line $after).Variable['HDTAdminPassword'] | Should -BeExactly 'P@ssw0rd!'

            [array]::IndexOf($after, 'variables:') | Should -BeLessThan ([array]::IndexOf($after, 'steps:'))
        }

        It 'keeps the steps readable afterwards' {
            $after = Set-HDTSequenceVariable -Line $script:withoutBlock -Name 'HDTAdminPassword' -Value 'x' -Confirm:$false

            @((Get-HDTTestSequenceDocument -Line $after).Step).Count | Should -Be 1
        }
    }

    Context 'what it refuses' {

        It 'refuses a name that is not an HDT variable' {
            # The same rule rules.yaml is held to: every deployment variable is
            # prefixed HDT, and a sequence that set 'ComputerName' would set
            # something nothing reads.
            { Set-HDTSequenceVariable -Line $script:withBlock -Name 'ComputerName' -Value 'PC-1' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*HDT*'
        }

        It 'refuses an engine-owned name' {
            { Set-HDTSequenceVariable -Line $script:withBlock -Name '_HDTStepName' -Value 'x' -Confirm:$false } |
                Should -Throw -ExpectedMessage '*engine*'
        }

        It 'refuses a document it cannot read' {
            { Set-HDTSequenceVariable -Line @('not: [a sequence') -Name 'HDTOSImage' -Value 'x' -Confirm:$false } |
                Should -Throw
        }

        It 'refuses removing one that is not there, rather than doing nothing' {
            { Set-HDTSequenceVariable -Line $script:withBlock -Name 'HDTNotHere' -Remove -Confirm:$false } |
                Should -Throw -ExpectedMessage '*HDTNotHere*'
        }
    }

    Context 'the command surface' {

        It 'is exported' {
            Get-Command -Name 'Set-HDTSequenceVariable' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'writes nothing itself' {
            # Save-HDTSequenceDocument is the only writer, so an edit can be
            # composed, reviewed and abandoned.
            (Get-Command -Name 'Set-HDTSequenceVariable').Parameters.Keys | Should -Not -Contain 'Path'
        }

        It 'supports ShouldProcess, like every other editing command' {
            (Get-Command -Name 'Set-HDTSequenceVariable').Parameters.Keys | Should -Contain 'WhatIf'
        }
    }
}
