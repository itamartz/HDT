function Get-HDTConsoleSelectionProfileSetting {
    <#
        .SYNOPSIS
            Everything the Selection Profiles window shows, worked out without a
            window.

        .DESCRIPTION
            HDTSelectionProfile.xaml is a list of profiles beside a tick box tree
            of the share. This is the question it asks, answered once: which
            profiles there are, which of them may be renamed or deleted, what the
            selected one has ticked, and THE CALL EACH BUTTON WOULD RUN.

            IT EXISTS SO THE ADAPTER STAYS AN ADAPTER, which is the same bargain
            Get-HDTConsoleBootImageSetting is here for: New-HDTConsoleHost is
            exempt from TDD as a thin wrapper over WPF, and the price is that it
            stays branch-free. Deciding tick state, which buttons are live and
            what Save would invoke is all decision, so it is here, where Pester
            reaches it with no display.

            THE PROFILES AND THE FOLDERS ARE PARAMETERS, NOT READS. Both need an
            IFileSystem - Get-HDTSelectionProfile parses a document,
            Get-HDTShareContentFolder walks the share - and taking them means
            this whole window is testable on a machine with neither.

            A BUILT-IN CANNOT BE EDITED AND THE WINDOW LEARNS THAT HERE, before
            it enables a button, rather than after Set-HDTSelectionProfile
            refuses. all-drivers, everything and nothing are answered by the
            engine and have no lines in any document.

            NOTHING SELECTED IS THE FIRST-RUN CASE, NOT AN ERROR. The window
            opens before anybody has clicked a row, and an empty tree is the
            honest picture of "no profile chosen" - a tree drawn against nothing
            would show five unticked folders that mean nothing.

        .PARAMETER Root
            The deployment share root, for the banner and the echoed commands.

        .PARAMETER SelectionProfile
            What Get-HDTSelectionProfile returned for this share.

        .PARAMETER Folder
            What Get-HDTShareContentFolder returned for this share.

        .PARAMETER SelectedId
            The profile the list has selected. Empty for none.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Title,
            DocumentPath, Profile, Tree, CanEdit, Summary and the command
            formats.

        .EXAMPLE
            Get-HDTConsoleSelectionProfileSetting -Root 'C:\HDTLab\Share' `
                -SelectionProfile (Get-HDTSelectionProfile -Root 'C:\HDTLab\Share') `
                -Folder (Get-HDTShareContentFolder -Root 'C:\HDTLab\Share') -SelectedId 'boot-critical'

        .EXAMPLE
            (Get-HDTConsoleSelectionProfileSetting -Root $r -SelectionProfile $p -Folder $f -SelectedId 'everything').CanEdit

            $false - a built-in has no lines to edit.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $SelectionProfile = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Folder = @(),

        [Parameter()]
        [AllowEmptyString()]
        [string] $SelectedId = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $documentPath = Get-HDTWorkspacePath -Root $Root -Kind Control -ChildPath 'selection-profiles.yaml'

    # -- the list on the left -------------------------------------------------

    $row = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($SelectionProfile)) {
        $count = @($current.Include).Count

        # WHAT IT CARRIES, UNDER ITS NAME. A list of names alone makes an
        # administrator click each one to find out which is the empty one they
        # started on Tuesday.
        if ([bool] $current.IsBuiltIn) {
            $detail = 'built in'
        } elseif ($count -eq 0) {
            $detail = 'nothing included yet'
        } elseif ($count -eq 1) {
            $detail = '1 path'
        } else {
            $detail = '{0} paths' -f $count
        }

        [void] $row.Add([pscustomobject] @{
                Id        = [string] $current.Id
                Name      = [string] $current.Name
                Detail    = $detail
                IsBuiltIn = [bool] $current.IsBuiltIn
                Include   = [string[]] @($current.Include)
            })
    }

    # -- the tree on the right ------------------------------------------------

    $selected = @($row | Where-Object { $_.Id -eq $SelectedId })

    $tree = [pscustomobject[]] @()
    $canEdit = $false
    $summary = 'Choose a profile on the left, or press New.'
    $label = 'Included folders'

    if (@($selected).Count -gt 0) {
        $one = @($selected)[0]

        $tree = [pscustomobject[]] @(Get-HDTConsoleSelectionProfileTree -Folder $Folder -Include $one.Include)
        $canEdit = (-not $one.IsBuiltIn)
        $label = 'Included folders  -  {0}' -f $one.Name

        if ($one.IsBuiltIn) {
            $summary = 'A built-in profile. It is answered by the engine, has no lines in any document, and cannot be renamed, edited or deleted.'
        } elseif (@($one.Include).Count -eq 0) {
            $summary = 'Nothing included yet, so this profile injects no drivers.'
        } else {
            $summary = '{0} included {1}.' -f @($one.Include).Count,
            (& { if (@($one.Include).Count -eq 1) { 'path' } else { 'paths' } })
        }
    }

    return [pscustomobject] @{
        Title             = 'Selection profiles'
        Root              = $Root
        DocumentPath      = $documentPath
        Profile           = [pscustomobject[]] @($row)
        Tree              = $tree
        CanEdit           = $canEdit
        IncludeLabel      = $label
        Summary           = $summary

        # EVERY BUTTON SHOWS THE CALL IT WOULD MAKE, which is DESIGN 12's rule -
        # "the console may not do anything the cmdlets can't" - and how an
        # administrator learns the automation surface by clicking.
        SaveCommandFormat = 'Set-HDTSelectionProfile -Line $line -Id ''{0}'' -Include {1}'
        NewCommandFormat  = 'New-HDTSelectionProfile -Line $line -Id ''{0}'' -Name ''{1}'''
        RenameCommandFormat = 'Set-HDTSelectionProfile -Line $line -Id ''{0}'' -Name ''{1}'''
        RemoveCommandFormat = 'Remove-HDTSelectionProfile -Line $line -Id ''{0}'''
        SaveDocumentFormat  = 'Save-HDTSelectionProfileDocument -Path ''{0}'' -Line $line'
    }
}
