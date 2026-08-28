function Get-HDTConsoleFeatureChoice {
    <#
        .SYNOPSIS
            Everything on the editor's Install Roles and Features page, decided
            in a command so the window assigns and branches on nothing.

        .DESCRIPTION
            THE INSTALL ROLES AND FEATURES PAGE IS A TICK LIST, and this fills
            it. What it replaces was a row on the generic sheet reading
            '0 entries - a table, not a value', read-only: the one key the step
            refuses to run without was the one key the console could not set, so
            the step could not be made runnable from the UI at all.

            A COMMA LINE WOULD HAVE FIXED REACHABILITY AND NOT SHAPE. A
            technician would still have to know that the IIS role is spelled
            'Web-Server' rather than 'IIS', type it correctly, and find out at
            the machine if they had not. The shape this page keeps is a list of
            names you tick.

            THE CATALOGUE IS AN OFFER; THE ENGINE IS THE AUTHORITY. The step
            installs through Install-WindowsFeature and asks the TARGET for its
            own feature list first, refusing an unknown name before it installs
            anything. The console is not running on the target and frequently
            runs on a Windows client with no ServerManager module at all - so
            Get-HDTFeatureCatalog ships a table, one per operating system.

            A NAME THE DOCUMENT HAS AND THE CATALOGUE DOES NOT IS STILL SHOWN,
            TICKED, and marked as unrecognised. That is the bargain the
            Operating System page already makes with an image the share no
            longer holds: a sequence naming something unfamiliar was written
            that way on purpose - a newer Server, or a name this table simply
            omits - and hiding the entry would delete it the first time anybody
            ticked a box. Marked, because an unrecognised name that looked like
            every other row would read as a spelling that will work.

            THE PAYLOAD SOURCE IS HERE TOO. .NET Framework 3.5 has no payload in
            the image, so a sequence that installs it needs a side-by-side store
            - and 'source' was another key the generic sheet never gave a row,
            because the template writes it as a comment.

        .PARAMETER Line
            The document's lines, as read.

        .PARAMETER Path
            The document's path, for the parser's messages.

        .PARAMETER Name
            The selected step, by name.

        .PARAMETER Document
            What the host already parsed, so the editor's refresh does not turn
            the same lines back into a document once per view model.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              IsRolesStep             whether this page belongs on screen
              Feature                 one row per offer, with Name, DisplayName,
                                      Category, Note, Selected and Known
              IncludeManagementTools  the switch beside the list
              Source                  the payload store, or empty
              Note                    what is wrong with the step, or empty
              Command                 the cmdlet that produced the page

        .EXAMPLE
            Get-HDTConsoleFeatureChoice -Line $line -Path $path -Name 'Install Roles and Features'
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

        [Parameter()]
        [AllowNull()]
        [object] $Document
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -ne $Document) {
        $sequence = $Document
    } else {
        $reader = New-HDTFileSystemFromText -Path $Path -Text ($Line -join [System.Environment]::NewLine)
        $sequence = Import-HDTSequenceDocument -Path $Path -FileSystem $reader
    }

    $step = @($sequence.Step | Where-Object { $_.Name -eq $Name })

    $isRolesStep = (@($step).Count -gt 0 -and [string] $step[0].Type -eq 'InstallRoles')

    $property = $null
    if (@($step).Count -gt 0) { $property = $step[0].Property }

    # WHAT THE DOCUMENT NAMES. The step accepts a list or a single string it
    # splits on commas and semicolons, so both shapes are read the same way here
    # - a page that understood only one of them would show an empty list for a
    # document the engine runs perfectly well.
    $written = @()

    if ($null -ne $property -and $property.Contains('features')) {
        $raw = $property['features']

        if ($raw -is [string]) {
            $written = @($raw -split '[,;]')
        } else {
            $written = @($raw)
        }

        $written = @($written | ForEach-Object { ([string] $_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $row = New-Object -TypeName System.Collections.ArrayList

    # A HEADING IS A ROW, NOT A GroupStyle. WPF's grouping produced the picture
    # this page wanted and hid every tick box in it from UIAutomation: the
    # Validation list beside it exposes its six, and this one exposed NONE of its
    # ninety-nine, so a screen reader found an empty page and no automation could
    # drive it.
    #
    # THE VIEW MODEL DOES THE GROUPING INSTEAD, which is this console's rule
    # anyway - the window formats nothing and everything on screen can be
    # asserted without one. A header row carries IsHeader and no Name, and the
    # template draws it as a caption.
    $addHeader = {
        param([string] $Text)

        [void] $row.Add([pscustomobject] @{
                Name        = ''
                DisplayName = $Text
                Category    = $Text
                Note        = ''
                Selected    = $false
                Known       = $true
                IsHeader    = $true

                RowVisibility    = 'Collapsed'
                HeaderVisibility = 'Visible'
                HintVisibility   = 'Collapsed'
            })
    }

    $group = ''

    # THE CATALOGUE IN ITS OWN ORDER, which is Server Manager's: roles, then the
    # IIS parts people name separately, then features, then the tools. Sorting
    # it alphabetically would put 'AD-Certificate' beside 'ADFS-Federation' and
    # bury Web-Server in the middle of the features.
    foreach ($offer in @(Get-HDTFeatureCatalog)) {
        if ([string] $offer.Category -ne $group) {
            $group = [string] $offer.Category
            & $addHeader $group
        }

        [void] $row.Add([pscustomobject] @{
                Name        = [string] $offer.Name
                DisplayName = [string] $offer.DisplayName
                Category    = [string] $offer.Category
                Note        = [string] $offer.Note
                Selected    = ($written -contains [string] $offer.Name)
                Known       = $true
                IsHeader    = $false

                RowVisibility    = 'Visible'
                HeaderVisibility = 'Collapsed'
                HintVisibility   = $(if ([string]::IsNullOrEmpty([string] $offer.Note)) { 'Collapsed' } else { 'Visible' })
            })
    }

    # AND THEN WHATEVER ELSE THE DOCUMENT SAYS, at the end and marked. At the
    # end because it is the exception, and marked because a row that looked like
    # the others would say the catalogue had checked it.
    # AND THEN WHATEVER ELSE THE DOCUMENT SAYS. A sequence naming something this
    # table omits was written that way on purpose - a newer Server, or simply a
    # name not worth listing - and dropping the entry would delete it from the
    # document the first time anybody ticked a box.
    #
    # NO HEADING OF ITS OWN. An invented caption over one row is a section that
    # exists to explain itself; the red name and the sentence behind the ? say
    # the same thing without adding furniture to a page that has ninety-nine
    # rows already.
    $unknown = @($written | Where-Object {
            $candidate = $_
            @($row | Where-Object { [string] $_.Name -eq [string] $candidate }).Count -eq 0
        })

    if (@($unknown).Count -gt 0) { & $addHeader 'Named by this sequence' }

    foreach ($one in $unknown) {
        [void] $row.Add([pscustomobject] @{
                Name        = [string] $one
                DisplayName = [string] $one
                Category    = 'Named by this sequence'
                Note        = 'This name is not in the console''s list, so it is shown as the sequence wrote it. The target is asked whether it knows the name before anything is installed.'
                Selected    = $true
                Known       = $false
                IsHeader    = $false

                RowVisibility    = 'Visible'
                HeaderVisibility = 'Collapsed'
                HintVisibility   = 'Visible'
            })
    }

    $includeManagementTools = $false
    if ($null -ne $property -and $property.Contains('includeManagementTools')) {
        $includeManagementTools = [bool] $property['includeManagementTools']
    }

    $source = ''
    if ($null -ne $property -and $property.Contains('source')) {
        $source = [string] $property['source']
    }

    # THE REFUSAL THE ENGINE WILL MAKE, MADE WHILE THE STEP IS BEING WRITTEN.
    # Invoke-HDTInstallRolesStep fails a step that declares no features, and the
    # template ships 'features: []' - so the step a technician gets from the Add
    # menu is in exactly this state until they tick something.
    $note = ''
    if ($isRolesStep -and @($written).Count -eq 0) {
        $note = 'This step installs nothing, so it will fail when it runs. Tick at least one role or feature.'
    }

    return [pscustomobject] @{
        IsRolesStep            = $isRolesStep
        Feature                = [pscustomobject[]] @($row)
        IncludeManagementTools = $includeManagementTools
        Source                 = $source

        Note                   = $note
        HasNote                = (-not [string]::IsNullOrEmpty($note))

        Command                = ("Get-HDTConsoleFeatureChoice -Line `$line -Path `$path -Name '{0}'" -f $Name)
    }
}
