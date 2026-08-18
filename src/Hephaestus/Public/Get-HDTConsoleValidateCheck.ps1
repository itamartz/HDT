function Get-HDTConsoleValidateCheck {
    <#
        .SYNOPSIS
            A Validate step's checks, as the editor's Validate page shows them.

        .DESCRIPTION
            MDT'S Validate DIALOG, answered without a window: a fixed list of
            checks, each ticked or not, each with the value it is checking
            against.

            EVERY CHECK IS OFFERED, NOT ONLY THE DECLARED ONES. A page listing
            only what the document already says is a page you cannot add a check
            on, which is the whole reason to have one. Get-HDTValidateCheckDefinition
            is that list, and it is data - a check added tomorrow appears here
            and on the page without either being edited.

            UNTICKED MEANS THE KEY IS ABSENT, NOT ZERO. 'minRamMB: 0' is a bound
            of nothing that still reads as a declared bound; removing the key is
            how a sequence says it does not care.

            IT IS A QUERY. The rows name the command each would run, and the
            window runs it - so an administrator can learn the automation
            surface by clicking.

        .PARAMETER Line
            The sequence document's lines.

        .PARAMETER Path
            Where those lines came from, so a parse failure can name the file.

        .PARAMETER Name
            The step to read.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with IsValidateStep and
            Check.

        .EXAMPLE
            (Get-HDTConsoleValidateCheck -Line $line -Path $path -Name 'Validate').Check |
                Format-Table Label, Enabled, Value, Unit
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
,

        # WHAT THE HOST ALREADY PARSED. The editor rebuilds its whole right
        # pane after every edit and four view models each turned the same lines
        # back into a document to do it - about 70ms apiece, on the UI thread,
        # while somebody waited for a checkbox to tick.
        #
        # THE HOST GUARANTEES THEY AGREE: it parses $book.Line once and hands
        # the result to all four in the same refresh. Omitted, this parses the
        # lines exactly as it always did, which is what a script or a test
        # wants.
        [Parameter()]
        [AllowNull()]
        [object] $Document
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # HANDED IN? THEN NOTHING IS RE-READ. See the -Document help above.
    if ($null -ne $Document) {
        $sequence = $Document
    } else {
        $reader = New-HDTFileSystemFromText -Path $Path -Text ($Line -join [System.Environment]::NewLine)
        $sequence = Import-HDTSequenceDocument -Path $Path -FileSystem $reader
    }

    $step = @($sequence.Step | Where-Object { $_.Name -eq $Name })

    $isValidateStep = (@($step).Count -gt 0 -and [string] $step[0].Type -eq 'Validate')

    $property = $null
    if (@($step).Count -gt 0) { $property = $step[0].Property }

    $check = New-Object -TypeName System.Collections.ArrayList

    foreach ($definition in @(Get-HDTValidateCheckDefinition | Sort-Object -Property Order)) {
        $declared = $false
        $value = ''

        if ($null -ne $property -and $property.Contains($definition.Key)) {
            $declared = $true
            $raw = $property[$definition.Key]

            # A LIST IS SHOWN AS ONE LINE. requireVariable is a YAML list, and a
            # comma-separated line is faster to read and to type than any grid
            # for the two or three names it ever holds.
            if ($definition.Kind -eq 'List') {
                $value = ((@($raw) | ForEach-Object { [string] $_ }) -join ', ')
            } else {
                $value = [string] $raw
            }
        }

        # A SWITCH THAT SAYS false IS NOT TICKED. The key is present, but what it
        # declares is "do not make this check" - which is what an unticked box
        # means, and writing false is how an author overrides a default.
        $enabled = $declared
        if ($definition.Kind -eq 'Switch' -and $value -match '^(?i)(false|0|no)$') { $enabled = $false }

        [void] $check.Add([pscustomobject] @{
                Key     = [string] $definition.Key
                Label   = [string] $definition.Label
                Kind    = [string] $definition.Kind
                Unit    = [string] $definition.Unit
                Hint    = [string] $definition.Hint

                Enabled = $enabled
                Value   = $value

                # THE BOX IS FOR A VALUE. A switch has none, and a page that
                # showed an empty one beside it would invite a number that is
                # then dropped without a word.
                HasValue = ($definition.Kind -ne 'Switch')

                # THE WORD WPF BINDS, decided here rather than by a converter in
                # markup: a Visibility converter is a decision living in a file
                # no test executes.
                ValueVisibility = $(if ($definition.Kind -eq 'Switch') { 'Collapsed' } else { 'Visible' })

                Command = ("Set-HDTStepProperty -Line `$line -Name '{0}' -Property '{1}' -Value '<value>'" -f
                    $Name, $definition.Key)
            })
    }

    return [pscustomobject] @{
        IsValidateStep = $isValidateStep
        Check          = [pscustomobject[]] @($check)

        Command        = ("Get-HDTConsoleValidateCheck -Line `$line -Path `$path -Name '{0}'" -f $Name)
    }
}
