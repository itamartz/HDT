function ConvertFrom-HDTRuleYaml {
    <#
        .SYNOPSIS
            Turns the text of a rules document into the object the engine walks.

        .DESCRIPTION
            LIFTED OUT OF Import-HDTRuleDocument, WHICH NOW CALLS IT, so that
            something holding the text rather than the file can build the same
            object - the console's Rules tab, judging what an administrator has
            typed before offering to save it, and the Bootstrap tab doing the
            same against a smaller vocabulary.

            The alternative was a second parser for the same grammar, which is
            how a window comes to accept a document the engine refuses.

        .PARAMETER Yaml
            The document text.

        .PARAMETER Path
            Where it came from. Used in every refusal, and carried on the result.

        .OUTPUTS
            System.Management.Automation.PSCustomObject - Path, SchemaVersion,
            Rule[] of Index, Name, When, Set, SetFrom.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Yaml,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $document = ConvertFrom-HDTYaml -Yaml $Yaml -Path $Path
    Assert-HDTRuleDocument -Document $document -Path $Path

    $rule = New-Object -TypeName System.Collections.ArrayList
    $index = 0

    foreach ($current in @($document['rules'])) {
        $index++

        $when = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($current.Contains('when')) {
            foreach ($key in @($current['when'].Keys)) {
                $when[[string] $key] = $current['when'][$key]
            }
        }

        $set = $null
        if ($current.Contains('set')) {
            $set = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($key in @($current['set'].Keys)) {
                $set[[string] $key] = $current['set'][$key]
            }
        }

        $setFrom = $null
        if ($current.Contains('setFrom')) {
            $setFrom = [string] $current['setFrom']
        }

        [void] $rule.Add([pscustomobject] @{
                Index   = $index
                Name    = [string] $current['name']
                When    = $when
                Set     = $set
                SetFrom = $setFrom
            })
    }

    return [pscustomobject] @{
        Path          = $Path
        SchemaVersion = [int] $document['schemaVersion']
        Rule          = [object[]] @($rule)
    }
}
