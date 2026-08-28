function Get-HDTConsoleApplicationChoice {
    <#
        .SYNOPSIS
            An InstallApplications step's selection, and the applications the
            share offers.

        .DESCRIPTION
            What an InstallApplications step has selected, and every application
            the share can offer it, so the console's page lets an administrator
            PICK what a step installs rather than typing ids and finding out at
            the machine whether they spelled them right.

            THE STEP TYPE THAT HAD NO PAGE. Until this existed an
            InstallApplications step fell through to the generic Properties tab,
            where `selection` was a text box - so the ids were typed from memory,
            and a typo was not found until a deployment ran and
            Resolve-HDTApplicationOrder refused the WHOLE plan, on the machine in
            front of somebody. That is the same argument that put an
            application's Depends On behind a picker
            (Get-HDTConsoleDependencyChoice), and this is the other half of it.

            THERE ARE TWO ANSWERS, AND THE PAGE ASKS WHICH. A step either
            installs what the technician chose, reading a variable - the mode
            MDT calls "Install multiple applications" - or a fixed list the
            sequence names. The template writes `selection: '%HDTApplications%'`
            for the first, on purpose, because that is what a wizard answer or a
            rule fills. So this reports WHICH of the two the document is, and a
            page that only offered ticks would delete the indirection the
            sequence was built on the first time anybody pressed Apply.

            A STEP THAT DECLARES NO SELECTION IS THE VARIABLE. That is not a
            guess: Invoke-HDTInstallApplicationsStep reads HDTApplications
            directly when the step names nothing, so a page reporting "nothing
            selected" would contradict the step it is editing.

            THE LIST IS THE SHARE'S OWN, through Get-HDTConsoleWorkspace - the
            command the browser already uses - so this window cannot offer an
            application the engine will not resolve, and importing one makes it
            appear here without anything being edited.

            AN APPLICATION THE SHARE DOES NOT HOLD IS SHOWN, TICKED, AND MARKED.
            A sequence naming one somebody has since deleted still opens and
            still says what it carries; a list that silently forgot it would
            rewrite the deployment the next time anybody pressed Apply.

            AN APPLICATION WHOSE DOCUMENT WILL NOT READ IS NOT OFFERED. Its id is
            the folder name and nothing else, so ticking it would write an id
            that may not be what app.yaml says.

            A SHARE THAT CANNOT BE READ IS NOT AN ERROR HERE. Offline, renamed or
            not yet created is exactly the moment somebody needs to look at the
            sequence; the page opens with an empty list and the document's own
            value.

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

        .PARAMETER Catalog
            The share's application rows, as Get-HDTConsoleWorkspace returns
            them. Handed in by the editor, which reads the share once when it
            opens: re-reading it on every keystroke froze the window. Omitted,
            this reads the share itself, which is what a script or a test wants.

        .PARAMETER Document
            What the host already parsed. The editor rebuilds its whole right
            pane after every edit, and a view model that re-parsed the same lines
            cost about 70ms of it. Omitted, this parses the lines itself.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with IsApplicationStep,
            Application, FromVariable, Variable, Written, Note, HasCatalog and
            the command format.

        .EXAMPLE
            (Get-HDTConsoleApplicationChoice -Line $line -Path $path -Name 'Install Applications' -Workspace C:\HDTLab\Share).Application |
                Format-Table Display, Selected, Missing

        .LINK
            Invoke-HDTInstallApplicationsStep

        .LINK
            Get-HDTConsoleDependencyChoice
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
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object[]] $Catalog,

        [Parameter()]
        [AllowNull()]
        [object] $Document
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # THE VARIABLE MDT'S "install multiple applications" READS, and the one
    # Invoke-HDTInstallApplicationsStep falls back to. Named once here rather
    # than typed into three strings below.
    $fallbackVariable = 'HDTApplications'

    # HANDED IN? THEN NOTHING IS RE-PARSED. See the -Document help above.
    if ($null -ne $Document) {
        $sequence = $Document
    } else {
        $reader = New-HDTFileSystemFromText -Path $Path -Text ($Line -join [System.Environment]::NewLine)
        $sequence = Import-HDTSequenceDocument -Path $Path -FileSystem $reader
    }

    $step = @($sequence.Step | Where-Object { $_.Name -eq $Name })

    $isApplicationStep = (@($step).Count -gt 0 -and [string] $step[0].Type -eq 'InstallApplications')

    # -- what the document says -------------------------------------------

    $raw = $null

    if (@($step).Count -gt 0 -and $null -ne $step[0].Property -and $step[0].Property.Contains('selection')) {
        $raw = $step[0].Property['selection']
    }

    # BOTH FORMS ARE ONE LIST, which is what the step's own reader does: a YAML
    # list stays a list, and one string is a list written the other way.
    $chosen = @()
    $written = ''

    if ($raw -is [System.Collections.IList] -and -not ($raw -is [string])) {
        $chosen = @(@($raw) | ForEach-Object { ([string] $_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $written = ($chosen -join ', ')
    } elseif ($null -ne $raw) {
        $written = ([string] $raw).Trim()

        $chosen = @(@($written -split '[,;]') | ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    # -- which of the two answers it is ------------------------------------

    $fromVariable = $false
    $variable = $fallbackVariable
    $note = ''

    if ([string]::IsNullOrWhiteSpace($written)) {
        # NO SELECTION IS THE VARIABLE, because that is what the step reads.
        $fromVariable = $true
        $note = 'This step names nothing, so it installs whatever %{0}% holds - what the wizard or a rule chose.' -f $fallbackVariable
    } elseif ($written -match '^\s*%([^%]+)%\s*$') {
        $fromVariable = $true
        $variable = [string] $Matches[1]
        $chosen = @()

        # WHAT IT WILL HOLD IS NOT KNOWN HERE, and guessing is worse than saying
        # so - the step logs the plan it resolves, once it has one.
        $note = 'This step installs whatever %{0}% holds - what the wizard or a rule chose, which cannot be read from this document.' -f $variable
    }

    # -- the share ---------------------------------------------------------

    $known = @()

    if ($null -ne $Catalog) {
        $known = @($Catalog)
    } else {
        try {
            $known = @((Get-HDTConsoleWorkspace -Path $Workspace -FileSystem $FileSystem).Application)
        } catch {
            # See the description: the editor opens on a share that will not read.
            $known = @()
        }
    }

    $readable = @(@($known) | Where-Object { $null -ne $_ -and [string] $_.Status -ne 'Error' })

    $offer = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @($readable)) {
        $id = [string] $current.Id

        [void] $offer.Add([pscustomobject] @{
                Id       = $id
                Display  = Get-HDTConsoleApplicationLabel -Name ([string] $current.Name) `
                    -Version ([string] $current.Version) -Id $id
                Selected = [bool] (@($chosen | Where-Object {
                            [string]::Equals($_, $id, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
                Missing  = $false
            })
    }

    # NAME ORDER, so the list does not reshuffle as the share grows.
    $row = New-Object -TypeName System.Collections.ArrayList
    foreach ($current in @(@($offer) | Sort-Object -Property Display)) { [void] $row.Add($current) }

    # AND THE ONES THE DOCUMENT NAMES THAT THE SHARE DOES NOT HAVE, at the end,
    # ticked. See the description for why they are not dropped.
    foreach ($one in @($chosen)) {
        $seen = @(@($row) | Where-Object {
                [string]::Equals([string] $_.Id, $one, [System.StringComparison]::OrdinalIgnoreCase) })

        if (@($seen).Count -gt 0) { continue }

        [void] $row.Add([pscustomobject] @{
                Id       = [string] $one
                Display  = ('{0}  (not in this share)' -f $one)
                Selected = $true
                Missing  = $true
            })
    }

    return [pscustomobject] @{
        IsApplicationStep = $isApplicationStep
        Application       = [pscustomobject[]] @($row)

        FromVariable      = $fromVariable
        Variable          = [string] $variable
        Written           = [string] $written
        Note              = [string] $note

        # THE EMPTY SHARE SAYS SO. A list control with nothing in it reads as a
        # page that failed to load; an administrator who has imported no
        # applications needs to be told that is what happened.
        HasCatalog        = (@($readable).Count -gt 0)

        Command           = ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property 'selection' -Value '<applications>'" -f $Name)
    }
}
