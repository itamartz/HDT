function New-HDTConsoleNode {
    <#
        .SYNOPSIS
            Builds one display row for the console window.

        .DESCRIPTION
            One row shape, built in one place, so the host can treat every row
            identically and no caller can invent a row missing the member the
            window binds to.

            THE ROWS ARE BOTH A TREE AND A LIST, AND BOTH ARE BUILT HERE. The
            window is a WPF TreeView - it expands, it collapses, and each row
            carries an icon, because that is what Deployment Workbench looks like
            and the console is meant to transfer muscle memory rather than to be a novel shape. The
            TreeView needs nesting, so every node carries Children; a test, a
            Format-Table and a screenshot want a flat ordered reading, so every
            node also carries Depth and Display, which is Text with its
            indentation already applied.

            NEITHER SHAPE IS BUILT BY THE HOST. The host binds Children through a
            HierarchicalDataTemplate and reads Icon, Text and IsExpanded from the
            row - it never works out what nests inside what, which node is open,
            or which picture belongs to a task sequence. That is what keeps the
            one component with no tests free of decisions.

            THE HEADER TRAVELS ON THE ROW. The banner above the tree names the
            share the selected row belongs to, and with several shares open that
            changes as the selection moves. Carrying it here means the host sets
            three more text properties from the selected row and still decides
            nothing - the alternative is the host working out which share a row
            came from, which is a branch, in the one component with no tests.

        .PARAMETER Depth
            0 for the root, 1 for a share, 2 for a category, 3 for an item.

        .PARAMETER Kind
            What the row is: Root, Share, Category, TaskSequence,
            OperatingSystem, BootImage or Empty.

        .PARAMETER Status
            Ok, Error or Missing. The window shows the row either way.

        .PARAMETER Text
            The row itself, without indentation.

        .PARAMETER Field
            The labelled fields the detail pane shows for this row, as
            New-HDTConsoleField builds them. Detail is rendered from them, so a
            console reading and a screen reading cannot disagree.

        .PARAMETER Command
            The module command that produced the row.

        .PARAMETER Header
            What the banner says while this row is selected - Title, Root and
            DeployRoot, as Get-HDTConsoleHeader builds them.

        .PARAMETER Icon
            A glyph to show instead of the one the row's Kind would give it.
            Get-HDTConsoleIcon still chooses it - the caller asks for a named
            picture rather than writing a character here - and omitting it takes
            the Kind's own.

        .PARAMETER Collapsed
            Starts the row closed. Omitted, a row with children opens - C1 has
            one screen's worth of tree and an administrator should see it, not
            hunt for it.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Depth, Kind,
            Status, Text, Display, Detail, Command, Icon, IsExpanded, Children,
            HeaderTitle, HeaderRoot and HeaderDeployRoot.

        .EXAMPLE
            New-HDTConsoleNode -Depth 3 -Kind 'TaskSequence' -Status 'Ok' -Text 'DEMO-M4 - Deploy Windows 11' -Detail $detail -Command $command -Header $header
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a display row object; it changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 8)]
        [int] $Depth,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Root', 'Share', 'Category', 'TaskSequence', 'OperatingSystem', 'BootImage', 'Empty',
            'DriverStore', 'StepGroup', 'Step', 'MonitorRun', 'MonitorCategory')]
        [string] $Kind,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Ok', 'Error', 'Missing', 'Warning')]
        [string] $Status,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Text,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Field,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Command,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Header,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Icon = '',

        # A COLOUR TO USE INSTEAD OF THE ONE THE KIND WOULD GIVE IT, for the
        # rows whose colour is about the ROW rather than about what kind of
        # thing it is. A step that is switched off, or one that is allowed to
        # fail, is still a Step; Get-HDTConsoleIconColor answers by Kind and
        # Status and has nothing to say about either fact.
        [Parameter()]
        [AllowEmptyString()]
        [string] $IconColor = '',

        # THE SUBJECT'S OWN NAME, WHICH IS NOT ITS ROW'S TEXT. Text is prose for
        # a person - '3. Apply OS  (disabled)' - and every editing cmdlet takes
        # the bare name. Carrying it here rather than having the window peel the
        # decoration back off means the two can never drift, and a step
        # legitimately called '2. Reboot' cannot be mis-parsed into 'Reboot'.
        #
        # It defaults to Text because most rows are their own name; only the
        # editor's step rows decorate theirs.
        [Parameter()]
        [AllowEmptyString()]
        [string] $Name = '',

        # THE THING THE ROW IS ABOUT, for the rows that open something. A task
        # sequence row carries its own sequence object so a double-click can
        # hand it straight to Show-HDTSequenceEditor - which takes the OBJECT
        # and never an id, because two shares commonly hold a sequence with the
        # same id and an editor opened by id could write to the wrong one.
        #
        # A row without a subject does not open, and CanOpen says so rather than
        # leaving the window to work out which Kinds are which.
        [Parameter()]
        [AllowNull()]
        [object] $Subject = $null,

        [Parameter()]
        [switch] $Collapsed
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # ONE SOURCE, TWO READINGS. The window shows the fields; a console, a
    # Format-List and a test read Detail. Rendering Detail from the same fields
    # is what stops the two describing different things after the next edit.
    $glyph = $Icon
    if ([string]::IsNullOrEmpty($glyph)) {
        $glyph = Get-HDTConsoleIcon -Kind $Kind -Status $Status
    }

    $line = foreach ($current in @($Field)) {
        if ([string]::IsNullOrEmpty($current.Label)) {
            $current.Value
        } else {
            '{0,-20}: {1}' -f $current.Label, $current.Value
        }
    }

    return [pscustomobject] @{
        Depth            = $Depth
        Kind             = $Kind
        Status           = $Status
        Text             = $Text
        Name             = $(if ([string]::IsNullOrEmpty($Name)) { $Text } else { $Name })
        Subject          = $Subject
        CanOpen          = ($null -ne $Subject)
        Display          = ((' ' * (4 * $Depth)) + $Text)
        Field            = [pscustomobject[]] @($Field)
        Detail           = (@($line) -join [System.Environment]::NewLine)
        Command          = $Command
        Icon             = $glyph

        # THE COLOUR BESIDE THE GLYPH, so the window binds to it and decides
        # nothing. See Get-HDTConsoleIconColor for why this is a literal rather
        # than a theme resource key.
        IconColor        = $(if ([string]::IsNullOrEmpty($IconColor)) { Get-HDTConsoleIconColor -Kind $Kind -Status $Status } else { $IconColor })
        IsExpanded       = (-not $Collapsed.IsPresent)

        # WHETHER THIS ROW IS THE SELECTED ONE, carried the way IsExpanded is
        # and bound the same way. A splice rebuilds the tree from scratch, so
        # the row object that WAS selected no longer exists; without this the
        # highlight falls back to the nearest container - the step's group -
        # and the panes follow it, which is what an administrator saw after
        # ticking "Disable this step".
        #
        # It is set before the tree is handed the rows, because a PSCustomObject
        # raises no change notification: the binding takes the value it finds at
        # the moment the container is generated, and nothing afterwards.
        IsSelected       = $false

        # AN OBSERVABLE COLLECTION, NOT AN ARRAY AND NOT AN ArrayList. An array
        # would be copied on every add while the tree is being assembled,
        # leaving the bound collection behind; an ArrayList fixes that but is
        # invisible to a binding afterwards, so a row added once the tree is on
        # screen never appears. The monitoring view is refreshed while the
        # window is open (ROADMAP M8: "tailing"), and this is what lets the new
        # rows arrive.
        Children         = [System.Collections.ObjectModel.ObservableCollection[object]]::new()

        HeaderTitle      = [string] $Header.Title
        HeaderRoot       = [string] $Header.Root
        HeaderDeployRoot = [string] $Header.DeployRoot
    }
}
