function Get-HDTSelectionProfileFromLine {
    <#
        .SYNOPSIS
            The profiles a selection profile document declares, read from lines
            rather than from a share.

        .DESCRIPTION
            ONE PARSER FOR THE READER AND THE EDITOR. Get-HDTSelectionProfile
            reads a share and calls this; the console's profile window holds the
            document as LINES it is splicing and calls the same thing after every
            edit. Two projections would be two answers to "what does this
            document say", and the one that mattered would be whichever ran last.

            IT ALWAYS INCLUDES THE BUILT-INS, because they are part of what a
            share offers whether or not anything is written down - and because a
            window that showed them only before the first edit would lose them
            the moment somebody pressed New.

            IT VALIDATES BEFORE IT PROJECTS. A document that would not load is a
            terminating error naming the file, not a half-built list.

        .PARAMETER Line
            The document as lines. Empty means a share with no document, which
            answers with the built-ins alone.

        .PARAMETER Path
            The file the lines came from, for any message. Nothing is read.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject per profile, in name
            order, with Id, Name, Include, IsBuiltIn and Path.

        .EXAMPLE
            Get-HDTSelectionProfileFromLine -Line $line -Path 'C:\HDTLab\Share\Control\selection-profiles.yaml'

        .EXAMPLE
            @(Get-HDTSelectionProfileFromLine -Line @() -Path $path | ForEach-Object { $_.Id })

            all-drivers, everything, nothing - what a share with no document has.

        .LINK
            Get-HDTSelectionProfile
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $all = New-Object -TypeName System.Collections.ArrayList

    foreach ($current in @(Get-HDTSelectionProfileBuiltIn)) {
        [void] $all.Add([pscustomobject] @{
                Id        = [string] $current.Id
                Name      = [string] $current.Name
                Include   = [string[]] @($current.Include)
                IsBuiltIn = $true
                Path      = ''
            })
    }

    $text = (@($Line) -join [Environment]::NewLine)

    if (-not [string]::IsNullOrWhiteSpace($text)) {
        $document = ConvertFrom-HDTYaml -Yaml $text -Path $Path
        Assert-HDTSelectionProfileDocument -Document $document -Path $Path

        # The validator has already refused anything this loop could trip over,
        # so it is a projection and not a second set of rules.
        if (($null -ne $document) -and $document.Contains('profiles') -and ($null -ne $document['profiles'])) {
            foreach ($entry in @($document['profiles'])) {
                $include = @()
                if ($null -ne $entry['include']) { $include = @($entry['include']) }

                [void] $all.Add([pscustomobject] @{
                        Id        = [string] $entry['id']
                        Name      = [string] $entry['name']
                        Include   = [string[]] @($include | ForEach-Object { [string] $_ })
                        IsBuiltIn = $false
                        Path      = [string] $Path
                    })
            }
        }
    }

    # IN NAME ORDER, for the reason Get-HDTDriverGroup sorts: a list somebody
    # scans for a name they half remember has to be somewhere predictable.
    return [pscustomobject[]] @($all | Sort-Object -Property Name)
}
