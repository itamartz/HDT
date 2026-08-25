# What the Drivers tab says a selection profile will actually inject.
#
# A PROFILE NAME IS A PROMISE AND THIS IS THE LIST. Without it a share whose HP
# folder somebody renamed looks EXACTLY like a healthy one: same profile in the
# box, same hint underneath, and the only mention of the missing folder is a
# Write-Warning two and a half minutes into Update Boot Image, in scrollback.
# That is how a boot image ships without one vendor's storage drivers and is
# found on a bench.
#
# THEY PROJECT, THEY DO NOT READ. Expand-HDTSelectionProfile has already been to
# the disk - Show-HDTBootImageWindow does that, because it has an IFileSystem and
# the view model deliberately has not.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    function New-HDTTestProfile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        [OutputType([object])]
        param(
            [Parameter()] [AllowNull()] [object[]] $Resolved,
            [Parameter()] [switch] $NoResolved
        )

        $entry = [pscustomobject] @{
            Id = 'boot-critical'; Name = 'Boot critical - Dell and HP'
            Include = [string[]] @(); IsBuiltIn = $false; Path = 'C:\S\Control\selection-profiles.yaml'
        }

        if (-not $NoResolved) {
            $entry | Add-Member -NotePropertyName 'Resolved' -NotePropertyValue ([object[]] @($Resolved)) -Force
        }

        return $entry
    }

    $script:bothPresent = @(
        [pscustomobject] @{ Path = 'Drivers\WinPE\Dell WinPE 11 x64'; FullPath = 'C:\S\Drivers\WinPE\Dell WinPE 11 x64'; Present = $true }
        [pscustomobject] @{ Path = 'Drivers\WinPE\HP WinPE 11 x64'; FullPath = 'C:\S\Drivers\WinPE\HP WinPE 11 x64'; Present = $true }
    )

    $script:oneMissing = @(
        [pscustomobject] @{ Path = 'Drivers\WinPE\Dell WinPE 11 x64'; FullPath = 'C:\S\Drivers\WinPE\Dell WinPE 11 x64'; Present = $true }
        [pscustomobject] @{ Path = 'Drivers\WinPE\HP WinPE 10 x64'; FullPath = 'C:\S\Drivers\WinPE\HP WinPE 10 x64'; Present = $false }
    )

    $script:call = {
        param([string] $Command, [object] $Entry)

        $module = Get-Module -Name Hephaestus
        return & $module {
            param($Name, $Entry)
            & $Name -SelectionProfile $Entry
        } $Command $Entry
    }
}

Describe 'Get-HDTConsoleProfileFolder' {

    It 'gives one row per folder, in the profile''s declared order' {
        $row = @(& $script:call 'Get-HDTConsoleProfileFolder' (New-HDTTestProfile -Resolved $script:bothPresent))

        @($row | ForEach-Object { $_.Path }) |
            Should -Be @('Drivers\WinPE\Dell WinPE 11 x64', 'Drivers\WinPE\HP WinPE 11 x64')
    }

    # THE ROW SURVIVES, MARKED. Dropping it is what makes a half-injected boot
    # image look like a correct one.
    It 'keeps a folder that is not on the share and says which' {
        $row = @(& $script:call 'Get-HDTConsoleProfileFolder' (New-HDTTestProfile -Resolved $script:oneMissing))

        @($row).Count | Should -Be 2
        $row[1].Present | Should -BeFalse
        $row[1].Detail | Should -BeExactly 'not on the share'
    }

    It 'says nothing about a folder that is there' {
        $row = @(& $script:call 'Get-HDTConsoleProfileFolder' (New-HDTTestProfile -Resolved $script:bothPresent))

        $row[0].Detail | Should -BeExactly ''
    }

    # THE DECLARED-BUT-UNKNOWN ROW HAS NO Resolved PROPERTY AT ALL, and under
    # Set-StrictMode -Version Latest reaching for one is an error, not a null.
    It 'answers nothing for a profile that was never expanded' {
        @(& $script:call 'Get-HDTConsoleProfileFolder' (New-HDTTestProfile -NoResolved)) |
            Should -BeNullOrEmpty
    }

    It 'answers nothing for no profile at all' {
        @(& $script:call 'Get-HDTConsoleProfileFolder' $null) | Should -BeNullOrEmpty
    }
}

Describe 'Get-HDTConsoleProfileSummary' {

    It 'counts the folders when they are all there' {
        & $script:call 'Get-HDTConsoleProfileSummary' (New-HDTTestProfile -Resolved $script:bothPresent) |
            Should -BeExactly '2 folders, each injected with everything under it.'
    }

    It 'says one folder rather than 1 folders' {
        $one = @([pscustomobject] @{ Path = 'Drivers'; FullPath = 'C:\S\Drivers'; Present = $true })

        & $script:call 'Get-HDTConsoleProfileSummary' (New-HDTTestProfile -Resolved $one) |
            Should -BeExactly '1 folder, injected with everything under it.'
    }

    # IT LEADS WITH THE COUNT THAT IS SHORT. A boot image missing one vendor's
    # drivers builds cleanly, boots, and fails on a bench.
    It 'leads with what is missing when something is' {
        $text = & $script:call 'Get-HDTConsoleProfileSummary' (New-HDTTestProfile -Resolved $script:oneMissing)

        $text | Should -BeLike '1 of 2 folders*'
        $text | Should -BeLike '*1 is not on the share*'
    }

    It 'is not a complaint about a profile that includes nothing' {
        & $script:call 'Get-HDTConsoleProfileSummary' (New-HDTTestProfile -Resolved @()) |
            Should -BeExactly 'This profile includes nothing, so no drivers are injected.'
    }
}

Describe 'the Drivers tab rows the view model builds' {

    BeforeAll {
        $script:line = [string[]] @(
            'schemaVersion: 1'
            'id: HDT-LAB'
            'name: HDT deployment share'
            'deployRoot: \\host\HdtShare'
            'bootImage:'
            '  drivers: boot-critical'
        )

        $script:view = & (Get-Module -Name Hephaestus) {
            param($Line, $Entry)
            Get-HDTConsoleBootImageSetting -Line $Line -Path 'C:\S\workspace.yaml' `
                -Component @() -SelectionProfile ([object[]] @($Entry))
        } $script:line (New-HDTTestProfile -Resolved $script:oneMissing)
    }

    It 'hangs the folders on the row that names the profile' {
        $row = @($script:view.Driver.Choice | Where-Object { $_.Name -eq 'boot-critical' })

        @($row[0].Folder).Count | Should -Be 2
        $row[0].Summary | Should -BeLike '1 of 2 folders*'
    }

    # EVERY ROW CARRIES BOTH PROPERTIES OR BINDING TO ONE OF THEM THROWS. The
    # "no drivers" row is built by hand and is the one that would be missed.
    It 'gives every row a Folder and a Summary, the empty one included' {
        foreach ($row in @($script:view.Driver.Choice)) {
            @($row.PSObject.Properties.Name) | Should -Contain 'Folder'
            @($row.PSObject.Properties.Name) | Should -Contain 'Summary'
        }
    }

    It 'tells the truth on the "no drivers" row rather than leaving it blank' {
        $empty = @($script:view.Driver.Choice)[0]

        $empty.Name | Should -BeExactly ''
        @($empty.Folder) | Should -BeNullOrEmpty
        $empty.Summary | Should -BeLike '*No drivers are injected*'
    }
}
