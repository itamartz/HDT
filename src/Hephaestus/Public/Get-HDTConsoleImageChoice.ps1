function Get-HDTConsoleImageChoice {
    <#
        .SYNOPSIS
            An ApplyImage step's operating system, and the ones the share offers.

        .DESCRIPTION
            MDT'S Install Operating System PAGE, where an administrator PICKS an
            image out of the share rather than typing its id and finding out at
            the machine whether they spelled it right.

            THE LIST IS THE SHARE'S OWN. Get-HDTConsoleWorkspace already reads
            OperatingSystems\<id>\os.yaml for the browser, so this window cannot
            offer an image the engine will not resolve, and importing one makes
            it appear here without anything being edited.

            WHAT THE DOCUMENT SAYS WINS, EVEN WHEN THE SHARE DOES NOT HAVE IT. A
            sequence naming an image somebody has since deleted still opens,
            still shows the name it carries, and gets a row of its own marked
            missing. A dropdown that silently selected the first row instead
            would rewrite the deployment the next time anybody pressed save -
            quietly, and in the direction of whatever happens to sort first.

            A SHARE THAT CANNOT BE READ IS NOT AN ERROR HERE. Offline, renamed
            or not yet created is exactly the moment somebody needs to look at
            the sequence; the page opens with an empty list and the document's
            own value.

        .PARAMETER Line
            The sequence document's lines.

        .PARAMETER Path
            Where those lines came from, so a parse failure can name the file.

        .PARAMETER Name
            The step to read.

        .PARAMETER Workspace
            The deployment share's root, which is where the catalog lives.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with IsImageStep, Image,
            Selected, Index, Target, TimeoutMinutes and the command formats.

        .EXAMPLE
            Get-HDTConsoleImageChoice -Line $line -Path $path -Name 'Install Operating System' -Workspace C:\HDTLab\Share
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
        [string] $Name,

        [Parameter(Mandatory = $true, Position = 3)]
        [ValidateNotNullOrEmpty()]
        [string] $Workspace,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $reader = New-HDTFileSystemFromText -Path $Path -Text ($Line -join [System.Environment]::NewLine)
    $document = Import-HDTSequenceDocument -Path $Path -FileSystem $reader

    $step = @($document.Step | Where-Object { $_.Name -eq $Name })

    $isImageStep = (@($step).Count -gt 0 -and [string] $step[0].Type -eq 'ApplyImage')

    $read = {
        param([string] $Key)

        if (@($step).Count -eq 0) { return '' }

        $property = $step[0].Property
        if ($null -eq $property) { return '' }
        if (-not $property.Contains($Key)) { return '' }

        return [string] $property[$Key]
    }

    $written = & $read 'os'
    $selected = $written
    $note = ''

    # A VARIABLE THERE IS LEGITIMATE - rules.yaml choosing an image per model is
    # a real pattern - so the page follows it to what it names rather than
    # reporting the reference as an image nobody has.
    #
    # AND THE FILE KEEPS THE VARIABLE. Resolving for display and then saving the
    # resolution would quietly delete the indirection the sequence was built on,
    # the first time somebody pressed Apply on an unrelated box.
    if ($written -match '^\s*%([^%]+)%\s*$') {
        $token = [string] $Matches[1]

        if ($null -ne $document.Variable -and $document.Variable.Contains($token)) {
            $selected = [string] $document.Variable[$token]
            $note = 'This step names the image through %{0}%, which the sequence sets to {1}. Applying keeps the variable.' -f $token, $selected
        } else {
            $note = 'This step names the image through %{0}%, which this sequence does not set - it comes from rules.yaml or the wizard.' -f $token
        }
    }

    # THE CATALOG, THROUGH THE SAME COMMAND THE BROWSER USES. A share that will
    # not read is an empty list rather than a refusal - see the description for
    # why the editor has to open anyway.
    $catalog = @()

    try {
        $catalog = @((Get-HDTConsoleWorkspace -Path $Workspace -FileSystem $FileSystem).OperatingSystem)
    } catch {
        $catalog = @()
    }

    $image = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($catalog)) {
        if ($null -eq $current) { continue }

        $id = [string] $current.Id
        $display = $id

        # THE NAME, AND THE NAME ALONE. The window shows what a person
        # recognises; the document keeps the id, which is what the engine
        # resolves and what the share is keyed on. A row reading
        # 'Windows 11 Enterprise LTSC 2024  (Win11-LTSC-2024)' says the same
        # thing twice in a list that is scanned, not read.
        #
        # THE ID IS THE FALLBACK, because a share whose os.yaml carries no name
        # leaves the folder as the only thing anybody has to go on.
        if (-not [string]::IsNullOrWhiteSpace([string] $current.Name)) {
            $display = [string] $current.Name
        }

        $rowEdition = New-Object -TypeName System.Collections.ArrayList

        foreach ($inside in @($current.Image)) {
            if ($null -eq $inside) { continue }

            [void] $rowEdition.Add([pscustomobject] @{
                    Index   = [int] $inside.Index
                    Name    = [string] $inside.Name
                    Display = ('{0}  -  {1}' -f $inside.Index, $inside.Name)
                })
        }

        [void] $image.Add([pscustomobject] @{
                Id      = $id
                Name    = [string] $current.Name
                Display = $display
                Missing = $false
                Edition = [pscustomobject[]] @($rowEdition)
            })
    }

    # AND THE ONE THE DOCUMENT NAMES, IF THE SHARE DOES NOT HAVE IT. It goes on
    # the list rather than being dropped, so the box shows what the file says.
    if (-not [string]::IsNullOrWhiteSpace($selected)) {
        $known = @($image | Where-Object { $_.Id -eq $selected })

        if (@($known).Count -eq 0) {
            [void] $image.Add([pscustomobject] @{
                    Id      = $selected
                    Name    = ''
                    Display = ('{0}  (not in this share)' -f $selected)
                    Missing = $true

                    # NO CATALOG BEHIND IT, so no editions to offer. A list
                    # borrowed from another image would put a number in the file
                    # that names something else.
                    Edition = [pscustomobject[]] @()
                })
        }
    }

    # THE EDITIONS OF THE SELECTED IMAGE. An index is a number inside a WIM and
    # nobody remembers which; os.yaml already carries the pairs, because
    # Import-HDTOperatingSystem read them off the media.
    #
    # THEY BELONG TO ONE IMAGE. An image the share does not have offers none -
    # listing another image's would put a number in the file that names
    # something else entirely.
    $indexWritten = & $read 'index'
    $index = $indexWritten

    # AN UNDECLARED INDEX IS 1 - the first image in the WIM, which is what the
    # engine applies when a step names none. A blank box beside a list of
    # editions reads as "nothing chosen" rather than "the usual one".
    if ([string]::IsNullOrWhiteSpace($index)) { $index = '1' }
    $indexNote = ''

    if ($indexWritten -match '^\s*%([^%]+)%\s*$') {
        $indexToken = [string] $Matches[1]

        if ($null -ne $document.Variable -and $document.Variable.Contains($indexToken)) {
            $index = [string] $document.Variable[$indexToken]
            $indexNote = 'The index comes through %{0}%.' -f $indexToken
        } else {
            $indexNote = 'The index comes through %{0}%, which this sequence does not set.' -f $indexToken
        }
    }

    $edition = @(@($image | Where-Object { $_.Id -eq $selected }) |
            ForEach-Object { $_.Edition } | Where-Object { $null -ne $_ })

    # WHERE THE IMAGE GOES - MDT's Destination - AND IT IS A VARIABLE. The
    # partition step publishes HDTOSVolume; that is the volume Windows lands on,
    # and naming it is what makes the page say which one rather than gesture at
    # it. It is never a guess at C:, which in WinPE is frequently the content
    # disk.
    #
    # 'primary' IS THE SAME THING SPELLED AS A WORD. Invoke-HDTApplyImageStep
    # resolves it to %HDTOSVolume% and refuses when that is unset, so the two
    # are one answer - and existing documents are full of the word. It stays on
    # the list, at the bottom, rather than leading it: a magic word that means a
    # variable teaches nobody which variable.
    $destination = New-Object -TypeName System.Collections.ArrayList

    # THE OS VOLUME LEADS, because this page is about where WINDOWS goes. The
    # map lists the system volume first - it is first on the disk - and that is
    # the wrong order for this one box.
    [void] $destination.Add('%HDTOSVolume%')

    # The engine's own, from the variable map rather than a list kept here: a
    # volume variable added to the engine appears in this box without anybody
    # remembering to add it twice.
    foreach ($known in @(Get-HDTVariableMap)) {
        if ([string] $known.Origin -ne 'step') { continue }
        if ([string] $known.HDTName -notlike '*Volume') { continue }

        [void] $destination.Add(('%{0}%' -f $known.HDTName))
    }

    # And the ones this sequence publishes itself: a partition row naming a
    # variable has created exactly the volume somebody would apply an image to.
    foreach ($other in @($document.Step)) {
        if ($null -eq $other) { continue }
        if ([string] $other.Type -ne 'DiskPartition') { continue }
        if ($null -eq $other.Property) { continue }
        if (-not $other.Property.Contains('partition')) { continue }

        foreach ($row in @($other.Property['partition'])) {
            if ($null -eq $row) { continue }
            if ($row -isnot [System.Collections.IDictionary]) { continue }
            if (-not $row.Contains('variable')) { continue }

            $published = [string] $row['variable']
            if ([string]::IsNullOrWhiteSpace($published)) { continue }

            [void] $destination.Add(('%{0}%' -f $published))
        }
    }

    [void] $destination.Add('primary')

    # SORTED BY WHAT IS ON SCREEN. A dropdown is scanned in the order it is
    # drawn, and the catalog's own order is the order the folders happened to be
    # enumerated in.
    $ordered = @($image | Sort-Object -Property Display)

    return [pscustomobject] @{
        IsImageStep        = $isImageStep
        Image              = [pscustomobject[]] @($ordered)

        Selected           = $selected

        # WHAT APPLY PUTS BACK IN THE FILE when nothing on the page was
        # changed - the author's own text, variable and all.
        Written            = $written
        Note               = $note
        Index              = $index
        IndexWritten       = $indexWritten
        IndexNote          = $indexNote
        Edition            = [pscustomobject[]] @($edition)
        Target             = (& $read 'target')

        # DISTINCT, KEEPING THE ORDER: primary first, then the engine's, then
        # this sequence's own. Sort-Object -Unique would alphabetise them and
        # bury the answer nearly everybody wants.
        Destination        = [string[]] @($destination | Select-Object -Unique)
        TimeoutMinutes     = $(
            if (@($step).Count -gt 0 -and $null -ne $step[0].TimeoutMinutes) {
                [string] $step[0].TimeoutMinutes
            } else { '' })

        OsCommandFormat    = ("Set-HDTStepProperty -Line `$line -Name '$Name' -Property 'os' -Value '{0}'")
        IndexCommandFormat = ("Set-HDTStepProperty -Line `$line -Name '$Name' -Property 'index' -Value '{0}'")

        Command            = ("Get-HDTConsoleImageChoice -Line `$line -Path `$path -Name '{0}' -Workspace `$root" -f $Name)
    }
}
