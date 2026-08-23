# WHAT "DEPENDS ON" CAN BE SET TO, worked out without a window.
#
# A dependency is an application id typed into a document, and every way of
# getting it wrong fails late and badly. A misspelled id is not caught until a
# deployment runs and Resolve-HDTApplicationOrder refuses the whole plan - not
# just that application - on the machine in front of somebody. A pair that
# depends on each other the same way, except nothing on the share looks wrong
# until it is too late to fix.
#
# SO IT IS PICKED, NOT TYPED. The list is the applications on this share, which
# makes a missing id impossible to produce; the ones that would close a loop are
# offered but refused, with the loop named, because "why can I not tick this"
# has to be answerable from the window.
#
# THIS IS THE DECISION, NOT THE DIALOG. What is on the list, what is already
# ticked and what cannot be is settled here and asserted against no window at
# all; the dialog binds it and calls Set-HDTApplication with what came back.

# THE COMMANDS UNDER TEST ARE PRIVATE, so this file runs in module scope.
#
# InModuleScope has to resolve the module while Pester is still discovering,
# before any BeforeAll has run, which is why the import sits at file scope here
# rather than only inside one. The body keeps its own indentation: a here-string
# terminator has to stay at column 0, so the wrapper cannot indent what it wraps.
$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

InModuleScope -ModuleName Hephaestus {

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    # The console's application rows, cut down to what the choice reads.
    function New-HDTTestApplicationRow {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an object in a test; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param([string] $Id, [string] $Name, [string[]] $Dependency = @())

        return [pscustomobject] @{
            Id         = $Id
            Name       = $Name
            Dependency = [string[]] $Dependency
            Status     = 'Ok'
        }
    }

    function Get-HDTTestDependencyChoice {
        [CmdletBinding()]
        [OutputType([object])]
        param([object[]] $Application, [string] $Id)

        return InModuleScope -ModuleName 'Hephaestus' -Parameters @{ A = $Application; I = $Id } {
            param($A, $I)
            Get-HDTConsoleDependencyChoice -Application ([object[]] $A) -Id $I
        }
    }

    $script:catalog = @(
        (New-HDTTestApplicationRow -Id '7Zip-24.09' -Name '7-Zip 24.09')
        (New-HDTTestApplicationRow -Id 'Contoso-Suite' -Name 'Contoso Suite' -Dependency @('7Zip-24.09'))
        (New-HDTTestApplicationRow -Id 'Reader-24.2' -Name 'Acrobat Reader 24.2')
    )
}

Describe 'Get-HDTConsoleDependencyChoice' {

    Context 'what is on the list' {

        BeforeAll {
            $script:choice = Get-HDTTestDependencyChoice -Application $script:catalog -Id 'Contoso-Suite'
        }

        It 'offers every other application on the share' {
            @($script:choice | ForEach-Object { [string] $_.Id }) |
                Should -Be @('7Zip-24.09', 'Reader-24.2')
        }

        It 'never offers the application itself' {
            # A dependency of length one is a cycle, and the resolver says so.
            @($script:choice | Where-Object { [string] $_.Id -eq 'Contoso-Suite' }) | Should -BeNullOrEmpty
        }

        It 'shows the name a technician reads, beside the id a document holds' {
            $row = @($script:choice | Where-Object { [string] $_.Id -eq '7Zip-24.09' })[0]

            [string] $row.Display | Should -BeExactly '7-Zip 24.09'
        }

        It 'is in name order, so the list does not reshuffle as the share grows' {
            @($script:choice | ForEach-Object { [string] $_.Display }) |
                Should -Be @('7-Zip 24.09', 'Acrobat Reader 24.2')
        }
    }

    Context 'what is already ticked' {

        It 'ticks what the document already depends on' {
            $choice = Get-HDTTestDependencyChoice -Application $script:catalog -Id 'Contoso-Suite'

            [bool] @($choice | Where-Object { [string] $_.Id -eq '7Zip-24.09' })[0].Selected | Should -BeTrue
            [bool] @($choice | Where-Object { [string] $_.Id -eq 'Reader-24.2' })[0].Selected | Should -BeFalse
        }

        It 'ticks nothing for an application that depends on nothing' {
            $choice = Get-HDTTestDependencyChoice -Application $script:catalog -Id '7Zip-24.09'

            @($choice | Where-Object { $_.Selected }) | Should -BeNullOrEmpty
        }
    }

    Context 'a choice that would close a loop' {

        BeforeAll {
            # 7-Zip is depended on BY Contoso Suite, so 7-Zip depending on
            # Contoso Suite would be a pair that can never be ordered.
            $script:looping = Get-HDTTestDependencyChoice -Application $script:catalog -Id '7Zip-24.09'
            $script:blocked = @($script:looping | Where-Object { [string] $_.Id -eq 'Contoso-Suite' })[0]
        }

        It 'is on the list, and refused' {
            # OFFERED AND REFUSED, not hidden: an item that vanishes is a window
            # somebody argues with. The reason is what makes it a window.
            $script:blocked | Should -Not -BeNullOrEmpty
            [bool] $script:blocked.Blocked | Should -BeTrue
        }

        It 'names the loop it would make' {
            [string] $script:blocked.Reason | Should -BeLike '*Contoso Suite*'
            [string] $script:blocked.Reason | Should -BeLike '*7-Zip*'
        }

        It 'leaves everything else choosable' {
            [bool] @($script:looping | Where-Object { [string] $_.Id -eq 'Reader-24.2' })[0].Blocked |
                Should -BeFalse
        }

        It 'follows the chain, not just the first step' {
            # A -> B -> C, so C depending on A closes a loop three long, and the
            # resolver refuses exactly that.
            $chain = @(
                (New-HDTTestApplicationRow -Id 'A' -Name 'A' -Dependency @('B'))
                (New-HDTTestApplicationRow -Id 'B' -Name 'B' -Dependency @('C'))
                (New-HDTTestApplicationRow -Id 'C' -Name 'C')
            )

            $choice = Get-HDTTestDependencyChoice -Application $chain -Id 'C'

            [bool] @($choice | Where-Object { [string] $_.Id -eq 'A' })[0].Blocked | Should -BeTrue
            [bool] @($choice | Where-Object { [string] $_.Id -eq 'B' })[0].Blocked | Should -BeTrue
        }
    }

    Context 'a share with nothing else on it' {

        It 'offers nothing rather than failing' {
            $only = @((New-HDTTestApplicationRow -Id 'Lonely' -Name 'Lonely'))

            @(Get-HDTTestDependencyChoice -Application $only -Id 'Lonely') | Should -BeNullOrEmpty
        }
    }

    Context 'an application that will not read' {

        It 'is not offered, because its id cannot be trusted' {
            # A row whose app.yaml failed to parse has the folder name as its id
            # and nothing else. Depending on it would write an id that may not be
            # what the document says.
            $broken = @(
                (New-HDTTestApplicationRow -Id 'Good' -Name 'Good')
                ([pscustomobject] @{ Id = 'Broken'; Name = 'Broken'; Dependency = [string[]] @(); Status = 'Error' })
            )

            @(Get-HDTTestDependencyChoice -Application $broken -Id 'Good' | ForEach-Object { [string] $_.Id }) |
                Should -Be @()
        }
    }
}


}
