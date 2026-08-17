function Get-HDTConsolePartitionRow {
    <#
        .SYNOPSIS
            A DiskPartition step's table, as the editor's grid shows it.

        .DESCRIPTION
            MDT'S Format and Partition Disk GRID, answered without a window.
            The columns are the ones that dialog has - name, type, size, file
            system, and the variable the drive letter is published into - and
            each row carries the command its buttons would run.

            A STEP THAT NAMES A LAYOUT HAS NO ROWS, and that is an answer rather
            than an error: the grid shows nothing and says which layout is in
            force, because a window that drew an empty table over a step laid
            out by uefi-standard would be describing a disk nobody is building.

            THE SIZE IS SHOWN AS AUTHORED. '60%' and 'remainder' are not
            byte counts and must not be rendered as any - what they resolve to
            depends on the machine, and New-HDTDiskLayoutPlan is the only thing
            entitled to say.

            IT IS A QUERY. Nothing here writes; the commands the rows name are
            what write, and the window shows the invocation so an administrator
            can learn the automation surface by clicking.

        .PARAMETER Line
            The sequence document's lines.

        .PARAMETER Path
            Where those lines came from, so a parse failure can name the file.

        .PARAMETER Name
            The step to read.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Row, Style, Layout,
            HasTable and the command formats the grid's buttons use.

        .EXAMPLE
            (Get-HDTConsolePartitionRow -Line $line -Name 'Format and Partition').Row |
                Format-Table Name, Type, Size, FileSystem

        .EXAMPLE
            $view = Get-HDTConsolePartitionRow -Line $line -Name 'Format and Partition'
            $view.AddCommandFormat -f 'Data', 'Primary', 'remainder'
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

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # THE VALUES COME OUT OF THE PARSED DOCUMENT, not off the lines: a line
    # reader would have to learn YAML quoting to tell 60% from '60%'.
    $reader = New-HDTFileSystemFromText -Path $Path -Text ($Line -join [System.Environment]::NewLine)
    $document = Import-HDTSequenceDocument -Path $Path -FileSystem $reader

    $step = @($document.Step | Where-Object { $_.Name -eq $Name })

    $authored = @()
    $layout = ''
    $style = ''
    $disk = ''
    $wipe = $false

    # WHETHER THE PANEL BELONGS ON SCREEN AT ALL, decided here rather than by the
    # window: a Disk tab over Apply OS is a tab with nothing to say that invites
    # a click to find out. A group is selected often, and is not a step, so the
    # question has to survive not finding one.
    $isDiskStep = (@($step).Count -gt 0 -and [string] $step[0].Type -eq 'DiskPartition')

    if (@($step).Count -gt 0) {
        $property = $step[0].Property

        if ($null -ne $property) {
            if ($property.Contains('partition')) { $authored = @($property['partition']) }
            if ($property.Contains('layout')) { $layout = [string] $property['layout'] }
            if ($property.Contains('style')) { $style = [string] $property['style'] }
            if ($property.Contains('diskNumber')) { $disk = [string] $property['diskNumber'] }
            if ($property.Contains('wipe')) { $wipe = [bool] $property['wipe'] }
        }
    }

    # THE UNITS THE ENGINE READS, AND WHAT EACH ONE COMPOSES. MDT's dialog has
    # Size and Size units beside it, and a checkbox for "a percentage of
    # remaining free space"; this is the same choice as one list, because a
    # percentage IS a unit here and a separate checkbox that silently ignores
    # the units dropdown is the part of that dialog worth not copying.
    #
    # THE FORMAT COMES WITH THE UNIT so the window composes nothing. The rest of
    # the disk takes no number at all, which is what NeedsAmount says - the
    # window disables the box rather than deciding what an empty one means.
    $unitOption = [pscustomobject[]] @(
        [pscustomobject] @{ Display = 'MB'; Format = '{0}MB'; NeedsAmount = $true }
        [pscustomobject] @{ Display = 'GB'; Format = '{0}GB'; NeedsAmount = $true }
        [pscustomobject] @{ Display = 'TB'; Format = '{0}TB'; NeedsAmount = $true }
        [pscustomobject] @{ Display = '% of what is left'; Format = '{0}%'; NeedsAmount = $true }
        [pscustomobject] @{ Display = 'bytes'; Format = '{0}'; NeedsAmount = $true }
        [pscustomobject] @{ Display = 'the rest of the disk'; Format = 'remainder'; NeedsAmount = $false }
    )

    $row = New-Object -TypeName System.Collections.ArrayList
    $order = 0
    $declaredBoot = $false

    foreach ($current in @($authored)) {
        if ($null -eq $current) { continue }

        $order++

        $read = {
            param([string] $Key)

            if ($current -is [System.Collections.IDictionary]) {
                if ($current.Contains($Key)) { return [string] $current[$Key] }
                return ''
            }

            if ($null -eq $current.PSObject.Properties[$Key]) { return '' }
            return [string] $current.$Key
        }

        $partitionName = & $read 'name'

        # THE TWO CHECKBOXES, ANSWERED EVEN WHEN THE DOCUMENT IS SILENT. The
        # engine formats quick unless told otherwise and makes the FIRST row
        # bootable when no row claims it, so a dialog that showed both unticked
        # for a silent document would be describing a disk nobody is building.
        $quickFormat = $true
        $quickText = & $read 'quickFormat'
        if ($quickText -match '^(?i)(false|0|no)$') { $quickFormat = $false }

        # BOOTABLE IS DECIDED AFTER THE WHOLE TABLE IS READ. The engine's
        # positional default - the first row - applies only while NO row
        # declares one, and `bootable: false` is a declaration: it is how a
        # first partition refuses the default. Deciding it here, row by row,
        # would make row 1 look bootable in a table where row 3 claimed it.
        $bootable = $false
        $bootText = & $read 'bootable'

        if ($bootText -match '^(?i)(true|1|yes)$') {
            $bootable = $true
            $declaredBoot = $true
        } elseif ($bootText -match '^(?i)(false|0|no)$') {
            $declaredBoot = $true
        }

        # THE SIZE, TAKEN APART FOR THE TWO CONTROLS BELOW THE GRID. Selecting a
        # row fills a number and a unit, so Edit can rewrite the whole row
        # without anybody having to retype what was already there.
        #
        # THE GRID STILL SHOWS THE WHOLE STRING. This is for the boxes; the
        # column prints what the document says.
        $sizeText = & $read 'size'
        $amount = $sizeText
        $unit = 'MB'

        if ($sizeText -match '^\s*(remainder|\*)\s*$') {
            $amount = ''
            $unit = 'the rest of the disk'
        } elseif ($sizeText -match '^\s*([0-9]+)\s*%\s*$') {
            $amount = [string] $Matches[1]
            $unit = '% of what is left'
        } elseif ($sizeText -match '^\s*([0-9]+)\s*(KB|MB|GB|TB)\s*$') {
            $amount = [string] $Matches[1]
            $unit = [string] $Matches[2].ToUpperInvariant()
        } elseif ($sizeText -match '^\s*[0-9]+\s*$') {
            $unit = 'bytes'
        }

        [void] $row.Add([pscustomobject] @{
                Order         = $order
                Name          = $partitionName
                Type          = & $read 'type'

                # AS AUTHORED, NEVER AS BYTES. '60%' and 'remainder' resolve
                # against the disk in front of the machine, and only the planner
                # is entitled to say what they come to.
                Size          = $sizeText
                Amount        = $amount
                Unit          = $unit
                QuickFormat   = $quickFormat
                Bootable      = $bootable

                # THE GRID SHOWS A MARK, NOT A WORD. Two boolean columns of
                # 'yes' and 'no' are wider than the names they sit beside and
                # harder to scan than a tick; the checkboxes on the dialog are
                # where they are set.
                QuickText     = ''
                BootText      = ''

                # The document's own rows, as against a named layout's.
                FromLayout    = $false

                FileSystem    = & $read 'filesystem'
                Variable      = & $read 'variable'

                # PARENTHESISED, AND IT HAS TO BE: inside a hash literal the
                # comma of -f binds as the next entry, and the file stops
                # parsing.
                RemoveCommand = ("Remove-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}'" -f $Name, $partitionName)
                UpCommand     = ("Move-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}' -Direction Up" -f $Name, $partitionName)
                DownCommand   = ("Move-HDTStepPartition -Line `$line -Name '{0}' -Partition '{1}' -Direction Down" -f $Name, $partitionName)
            })
    }

    # WHETHER THE DOCUMENT CARRIES ITS OWN TABLE, decided before a named
    # layout's volumes are added below. HasTable governs the buttons, and the
    # buttons edit the DOCUMENT - so it has to mean "there are rows in the file",
    # not "there are rows on screen".
    $hasTable = (@($row).Count -gt 0)

    # A NAMED LAYOUT HAS VOLUMES TOO, AND THE PAGE SHOWS THEM. The step carries
    # no table, but uefi-standard is three partitions and this page's whole job
    # is showing the disk that will be built - an empty grid over it describes
    # nothing and reads as a step that does nothing.
    #
    # THEY ARE MARKED FromLayout AND THE BUTTONS STAY DARK. Editing one would
    # have to write a table into the step, which silently converts it from "the
    # standard layout, whatever that becomes" into a frozen copy of today's.
    # That is a decision to make deliberately, not by clicking Edit.
    #
    # A LAYOUT THIS ENGINE DOES NOT HAVE IS NOT AN ERROR HERE. The step refuses
    # at run time and says so; a properties page that threw could not be opened
    # to fix the name.
    if (@($row).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($layout)) {
        $resolved = $null
        try { $resolved = Get-HDTDiskLayout -Name $layout } catch { $resolved = $null }

        $order = 0

        foreach ($current in @($resolved.Partition)) {
            if ($null -eq $current) { continue }

            $order++

            [void] $row.Add([pscustomobject] @{
                    Order         = $order
                    Name          = [string] $current.Role
                    Type          = (Get-HDTConsolePartitionTypeText -Partition $current)
                    Size          = (Get-HDTConsolePartitionSizeText -Partition $current)
                    Amount        = ''
                    Unit          = ''
                    QuickFormat   = $true
                    Bootable      = ($order -eq 1)
                    QuickText     = ''
                    BootText      = ''
                    FileSystem    = [string] $current.FileSystem

                    # WHAT THE STEP WILL PUBLISH FOR THIS ROLE. A built-in
                    # layout carries no variable key - Invoke-HDTDiskPartitionStep
                    # writes HDTSystemVolume, HDTOSVolume and HDTRecoveryVolume
                    # by role - so leaving the column empty hid the one answer
                    # somebody comes to this grid for: which volume the image
                    # lands on.
                    Variable      = $(
                        switch ([string] $current.Role) {
                            'System' { 'HDTSystemVolume' }
                            'Windows' { 'HDTOSVolume' }
                            'Recovery' { 'HDTRecoveryVolume' }
                            default { '' }
                        })

                    FromLayout    = $true

                    RemoveCommand = ("Get-HDTDiskLayout -Name '{0}'" -f $layout)
                    UpCommand     = ''
                    DownCommand   = ''
                })
        }
    }

    # THE POSITIONAL DEFAULT, APPLIED ONLY IF NOBODY CLAIMED IT.
    if (-not $declaredBoot -and @($row).Count -gt 0) { $row[0].Bootable = $true }

    foreach ($current in @($row)) {
        if ($current.QuickFormat) { $current.QuickText = [char] 0x2713 }
        if ($current.Bootable) { $current.BootText = [char] 0x2713 }
    }

    # WHAT THE STYLE WILL BE IF THE STEP DOES NOT PIN IT. The step resolves it
    # from the firmware at run time; saying "follows the firmware" is honest,
    # and printing GPT here would be this build host answering for a machine
    # that has not booted yet.
    $styleText = $style
    if ([string]::IsNullOrWhiteSpace($styleText)) { $styleText = 'follows the firmware' }

    # THE SENTENCE ABOVE THE GRID, COMPOSED HERE. The window assigns it and
    # joins nothing itself, which is the same rule the condition picker's format
    # string follows.
    $summary = 'Partition style: {0}.' -f $styleText

    if (-not [string]::IsNullOrWhiteSpace($layout)) {
        $summary = ("This step uses the named layout '{0}', so it writes no table of its own. Partition style: {1}." -f
            $layout, $styleText)
    }

    return [pscustomobject] @{
        IsDiskStep        = $isDiskStep
        Summary           = $summary
        HasTable          = $hasTable
        Row               = [pscustomobject[]] @($row)
        Unit              = $unitOption

        # THE TOP OF MDT'S PAGE. Disk number and disk type sit above the volume
        # list there, and they belong to the same decision - which disk, laid
        # out how - so putting them on the Properties tab split one dialog in
        # half.
        DiskNumber        = $disk
        Wipe              = $wipe

        # FOLLOWING THE FIRMWARE IS ON THE LIST, not the absence of a choice: it
        # is what most sequences should keep, and a dropdown offering only GPT
        # and MBR would make pinning one look compulsory.
        StyleOption       = [string[]] @('follows the firmware', 'GPT', 'MBR')
        Style             = $styleText
        Layout            = $layout

        AddCommandFormat  = "Add-HDTStepPartition -Line `$line -Name '$Name' -Partition '{0}' -Type {1} -Size '{2}'"
        StyleCommandFormat = "Set-HDTStepProperty -Line `$line -Name '$Name' -Property 'style' -Value '{0}'"

        Command           = "Get-HDTConsolePartitionRow -Line `$line -Path `$path -Name '$Name'"
    }
}
