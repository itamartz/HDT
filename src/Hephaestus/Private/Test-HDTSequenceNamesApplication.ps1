function Test-HDTSequenceNamesApplication {
    <#
        .SYNOPSIS
            Whether a task sequence document installs a given application.

        .DESCRIPTION
            WHAT Remove-HDTApplication HAS TO KNOW before it deletes anything,
            and it is not a text search. An id that appears in a comment, in a
            step's name or in a command line is not this sequence installing it:
            it is the selection of an InstallApplications step, and nothing else.

            IT WALKS THE TREE, because a sequence of any size is one - the
            sample sequence in this repository has six groups, and a scan of the
            top level would miss nearly every step in the share.

            A SELECTION THAT IS A VARIABLE IS NOT A MATCH. `selection:
            '%HDTApplications%'` is resolved from the rules at run time, so what
            it will install cannot be read from the document. Answering yes for
            those would name every such sequence for every application, which
            makes the report useless; answering no is what the document says.

        .PARAMETER Document
            The parsed sequence, as ConvertFrom-HDTYaml returns it.

        .PARAMETER Id
            The application's id.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTSequenceNamesApplication -Document $parsed -Id '7Zip-24.09'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Document -or -not ($Document -is [System.Collections.IDictionary])) { return $false }

    $wanted = $Id.Trim()

    $names = {
        param($Step)

        foreach ($current in @($Step)) {
            if ($null -eq $current -or -not ($current -is [System.Collections.IDictionary])) { continue }

            # A GROUP HOLDS STEPS, and its own type is not InstallApplications -
            # so the walk happens whatever this step turns out to be.
            if ($current.Contains('steps')) {
                if (& $names $current['steps']) { return $true }
            }

            $type = ''
            if ($current.Contains('type')) { $type = [string] $current['type'] }

            if ($type -ne 'InstallApplications') { continue }
            if (-not $current.Contains('selection')) { continue }

            $selection = $current['selection']
            $part = @()

            if ($selection -is [string]) {
                # ONE STRING IS A LIST WRITTEN THE OTHER WAY, which is how the
                # step's own reader treats it - and a variable in it is not
                # something this can resolve.
                if ([string] $selection -match '%') { continue }

                $part = @(([string] $selection) -split ',')
            } else {
                $part = @(@($selection) | ForEach-Object { [string] $_ })
            }

            foreach ($one in @($part)) {
                if ([string]::Equals(([string] $one).Trim(), $wanted, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
        }

        return $false
    }

    if (-not $Document.Contains('steps')) { return $false }

    return [bool] (& $names $Document['steps'])
}
