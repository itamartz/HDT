function Get-HDTConsoleBootImageSetting {
    <#
        .SYNOPSIS
            Everything the WinPE window shows, worked out without a window.

        .DESCRIPTION
            HDTBootImage.xaml is four tabs over one YAML block. This is the
            question those tabs ask, answered once: what is in the General
            boxes, which optional components are ticked and which may not be
            unticked, what content and start commands the document declares, and
            THE CALL EACH CONTROL WOULD RUN.

            IT EXISTS SO THE ADAPTER STAYS AN ADAPTER. New-HDTConsoleHost is
            exempt from TDD as a thin wrapper over WPF, and the price of that
            exemption is that it stays branch-free - "because it is not unit
            tested". Deciding which rows are ticked, which are locked, what a
            size reads as and what a button would invoke is all decision, so it
            is here, where Pester reaches it with no display.

            THE ADK IS A PARAMETER, NOT A READ. Get-HDTAdkComponent needs an
            installed ADK and a registry hive; taking its output means the whole
            Features tab is testable on a machine with neither, and means the
            window can re-ask for a different architecture without this command
            knowing how.

            EVERY ROW CARRIES ITS OWN INVOCATION, which is DESIGN 12's rule:
            "the console may not do anything the cmdlets can't", and it shows
            the invocation so an administrator learns the automation surface by
            clicking. Where the value is typed at click time - a driver group, a
            content pair - the object carries a FORMAT rather than a finished
            string, and the adapter's whole contribution is -f.

            A DOCUMENT THAT WILL NOT PARSE THROWS. The browser's row already
            says so; a window that opened anyway would offer to Save over it.

        .PARAMETER Line
            The workspace.yaml lines, as read from disk. Nothing here writes;
            the editing commands splice these same lines.

        .PARAMETER Path
            The document the lines came from, for the banner. Read by nothing.

        .PARAMETER Component
            What Get-HDTAdkComponent returned for the architecture being shown.
            An empty list is legal and means the Features tab has no rows -
            which is what a build host with no ADK actually offers.

        .PARAMETER DriverGroup
            What Get-HDTDriverGroup returned for this share. An empty list is
            legal and means the only choice is "no drivers" - which is what a
            share with nothing imported yet honestly offers.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Title,
            DocumentPath, General, Component, SelectedSizeText, Driver, Content,
            StartCommand and the Add* formats.

        .EXAMPLE
            $line = Get-Content -LiteralPath 'C:\HDTLab\Share\workspace.yaml'
            Get-HDTConsoleBootImageSetting -Line $line -Path 'C:\HDTLab\Share\workspace.yaml' `
                -Component (Get-HDTAdkComponent -Architecture amd64)

        .EXAMPLE
            (Get-HDTConsoleBootImageSetting -Line $line -Path $path -Component $adk).Component |
                Where-Object { $_.Declared } | Format-Table Name, SizeText

            The whole Features tab, on a console, with no window.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Component = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $DriverGroup = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Throws on a document that will not parse. See the header: that is the
    # answer, not something to recover from.
    $workspace = ConvertFrom-HDTWorkspaceLine -Line $Line
    $bootImage = $workspace.BootImage

    # -- the Features tab ----------------------------------------------------
    #
    # DECLARED IS "the document asks for it OR the engine always applies it".
    # Get-HDTAdkComponent's Required marks the six every image gets; they are
    # shown ticked and disabled rather than hidden, because an administrator
    # looking for WinPE-PowerShell in this list has to FIND it and see that it
    # is already there.

    $declaredName = @($bootImage.OptionalComponent | ForEach-Object { [string] $_ })

    $componentRow = New-Object -TypeName System.Collections.ArrayList
    $selectedBytes = [long] 0
    $selectedCount = 0

    foreach ($current in @($Component)) {
        $isRequired = [bool] $current.Required
        $isDeclared = $isRequired -or ($declaredName -contains [string] $current.Name)

        if ($isDeclared) {
            $selectedBytes += [long] $current.SizeBytes
            $selectedCount++
        }

        # WHAT IT NEEDS BESIDE IT, ON THE ROW. WinPE-PowerShell without
        # WinPE-WMI is a build that fails two and a half minutes in; saying so
        # where the tick is costs nothing.
        $requiresText = ''
        if (@($current.Requires).Count -gt 0) {
            $requiresText = 'needs {0}' -f (@($current.Requires) -join ', ')
        }
        if ($isRequired) {
            $requiresText = ('always applied. {0}' -f $requiresText).Trim()
        }

        # WHAT IT DOES, THEN WHAT IT COSTS YOU TO TICK IT, IN ONE COLUMN. The
        # description answers "what is this", the suffix answers "and what else
        # comes with it" - and they are read together, in that order, by
        # somebody deciding. Two columns would put the answer to the second
        # question off the right-hand edge on a narrow window.
        $description = [string] $current.Description
        $detailText = $description

        if (-not [string]::IsNullOrWhiteSpace($requiresText)) {
            if ([string]::IsNullOrWhiteSpace($detailText)) {
                $detailText = $requiresText
            } else {
                $detailText = '{0}  ({1})' -f $description, $requiresText
            }
        }

        [void] $componentRow.Add([pscustomobject] @{
                Name          = [string] $current.Name
                Declared      = $isDeclared
                CanChange     = (-not $isRequired)
                SizeText      = '{0:N1} MB' -f ([double] $current.SizeBytes / 1MB)
                Description   = $description
                DetailText    = $detailText
                RequiresText  = $requiresText
                AddCommand    = "Add-HDTBootImageComponent -Line `$line -Name '{0}'" -f [string] $current.Name
                RemoveCommand = "Remove-HDTBootImageComponent -Line `$line -Name '{0}'" -f [string] $current.Name
            })
    }

    # THE TOTAL, BECAUSE THE COST OF THAT TAB IS THE THING IT HIDES. Every tick
    # is megabytes in a WIM transferred to every machine that PXE boots, and a
    # list gives no sense of that one row at a time.
    $selectedSizeText = '{0} of {1} components selected, {2:N1} MB of cabs before compression.' -f
        $selectedCount, @($Component).Count, ([double] $selectedBytes / 1MB)

    # -- the Customisations tab ----------------------------------------------

    $contentRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($bootImage.ExtraContent)) {
        [void] $contentRow.Add([pscustomobject] @{
                Source        = [string] $current.Source
                Destination   = [string] $current.Destination

                # KEYED ON THE DESTINATION, which is what Remove takes: it is
                # what makes a row unique inside the image, and two sources can
                # land in one place.
                RemoveCommand = "Remove-HDTBootImageContent -Line `$line -Destination '{0}'" -f [string] $current.Destination
            })
    }

    $startCommandRow = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($bootImage.StartCommand)) {
        # THE LINE AS THE DOCUMENT HOLDS IT, AND NOTHING ELSE. This view model
        # describes workspace.yaml; startnet.cmd is a different file, generated
        # from it at build time and carrying `call` in front of a batch file so
        # cmd.exe returns. An earlier version also published that generated
        # line here, and the window showed it - which put text on screen that
        # appears in no file this window can save. Get-HDTStartnetScript is
        # where that translation belongs, and it is the only caller of
        # ConvertTo-HDTStartnetCommandLine again.
        [void] $startCommandRow.Add([pscustomobject] @{
                Text          = [string] $current
                RemoveCommand = "Remove-HDTBootImageStartCommand -Line `$line -Command '{0}'" -f [string] $current
            })
    }

    # -- the General tab, and the calls Save runs ----------------------------

    $general = [pscustomobject] @{
        Name                  = [string] $bootImage.Name
        Architecture          = [string] $bootImage.Architecture
        Language              = [string] $bootImage.Language

        # AS TEXT, because the combo matches on its Tag and SelectedValuePath
        # compares strings. An int here selects nothing, and the box comes up
        # blank on a document that set it.
        ScratchSpaceMB        = [string] $bootImage.ScratchSpaceMB
        Unattend              = [string] $bootImage.Unattend
        Background            = [string] $bootImage.Background

        Command               = "Set-HDTWorkspaceProperty -Line `$line -BootImageName '{0}' -Architecture '{1}' -Language '{2}' -ScratchSpaceMB {3}" -f
        [string] $bootImage.Name, [string] $bootImage.Architecture,
        [string] $bootImage.Language, [string] $bootImage.ScratchSpaceMB

        UnattendCommandFormat = 'Set-HDTBootImageUnattend -Line $line -Path ''{0}'''
        UnattendClearCommand  = 'Set-HDTBootImageUnattend -Line $line -Clear'

        BackgroundCommandFormat = 'Set-HDTBootImageBackground -Line $line -Path ''{0}'''
        BackgroundClearCommand  = 'Set-HDTBootImageBackground -Line $line -Clear'
    }

    # -- the Drivers tab -----------------------------------------------------
    #
    # A LIST, NOT A BOX YOU TYPE INTO. A group is a folder under Drivers\ on the
    # share, so the set of legal answers is knowable - and a typed one that is
    # wrong produces a boot image with no drivers in it, warned about at build
    # time and discovered on a bench.
    #
    # THE EMPTY ANSWER IS AN ENTRY IN THE LIST. "No drivers" is a real choice,
    # not the absence of one, and a list whose only way to say it was to clear a
    # selection would be a list you cannot say it in.
    $driverChoice = New-Object -TypeName System.Collections.ArrayList

    [void] $driverChoice.Add([pscustomobject] @{
            Name    = ''
            Display = '(none - WinPE uses the drivers Microsoft ships)'
        })

    foreach ($current in @($DriverGroup)) {
        [void] $driverChoice.Add([pscustomobject] @{
                Name    = [string] $current.Name
                Display = [string] $current.Name
            })
    }

    # THE DOCUMENT'S OWN ANSWER, EVEN WHEN THE FOLDER IS GONE. A share whose
    # driver group was renamed still has to show what the document says, or the
    # window silently reads as "no drivers" and a Save makes that true.
    $declaredGroup = [string] $bootImage.Drivers

    if (-not [string]::IsNullOrWhiteSpace($declaredGroup) -and
        @($driverChoice | Where-Object { $_.Name -eq $declaredGroup }).Count -eq 0) {

        [void] $driverChoice.Add([pscustomobject] @{
                Name    = $declaredGroup
                Display = '{0}  (not on the share)' -f $declaredGroup
            })
    }

    $driver = [pscustomobject] @{
        Group              = $declaredGroup
        Choice             = [pscustomobject[]] @($driverChoice)
        ApplyCommandFormat = 'Set-HDTBootImageDriver -Line $line -Name ''{0}'''
        ClearCommand       = 'Set-HDTBootImageDriver -Line $line -Clear'
    }

    return [pscustomobject] @{
        Title                     = 'Windows PE  -  {0}' -f [string] $bootImage.Name
        DocumentPath              = $Path

        General                   = $general
        Component                 = [pscustomobject[]] @($componentRow)

        # WHAT THE DOCUMENT CURRENTLY DECLARES, so a window can tell a real tick
        # from one WPF raised while building a row. A TabControl does not realise
        # an unselected tab's content, so every checkbox on the Features tab is
        # created - and raises Checked - the first time an administrator clicks
        # that tab. No timing guard can cover that; comparing against this can.
        DeclaredName              = [string[]] @($declaredName)
        SelectedSizeText          = $selectedSizeText
        Driver                    = $driver
        Content                   = [pscustomobject[]] @($contentRow)
        StartCommand              = [pscustomobject[]] @($startCommandRow)

        AddContentCommandFormat   = 'Add-HDTBootImageContent -Line $line -Source ''{0}'' -Destination ''{1}'''
        AddStartCommandFormat     = 'Add-HDTBootImageStartCommand -Line $line -Command ''{0}'''
        AddStartCommandFirstFormat = 'Add-HDTBootImageStartCommand -Line $line -Command ''{0}'' -First'

        Command                   = "Get-HDTConsoleBootImageSetting -Line `$line -Path '{0}'" -f $Path
    }
}
