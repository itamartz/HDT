function Import-HDTRuleDocument {
    <#
        .SYNOPSIS
            Reads, parses, validates and normalises a rules.yaml.

        .DESCRIPTION
            The public front door to rules.yaml. It reads the file
            through an injected IFileSystem - never Get-Content - so the whole
            authoring path is provable under Pester with no share, no media and
            no disk.

            Four steps, and a failure at any of them is a terminating
            HDTConfigurationError naming the file:

              1. read through IFileSystem;
              2. parse with ConvertFrom-HDTYaml, which turns a parser exception
                 into an error naming the file and the LINE;
              3. validate with Assert-HDTRuleDocument, which names the file and
                 the RULE;
              4. normalise.

            Step 4 is load-bearing rather than cosmetic. Rule resolution applies
            set: in document order and looks names up case-insensitively, so
            every When and Set is re-materialised into an OrderedDictionary built
            with StringComparer::OrdinalIgnoreCase. The caller then never has to
            care what the YAML parser handed back, and a hand-written rules.yaml
            may spell HDTmodel however it likes.

        .PARAMETER Path
            The rules.yaml to read. Interpreted by the filesystem service, so it
            may be a share path, a media path or a fake's in-memory path.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production,
            New-HDTFakeFileSystem in a test.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Path          the path it was given
              SchemaVersion [int]
              Rule          one [pscustomobject] per rule, in document order:
                            Index (1-based), Name, When, Set, SetFrom

            When is an empty ordered dictionary for a rule with no conditions;
            Set is $null for a setFrom rule and SetFrom is $null for a set rule.

        .EXAMPLE
            $document = Import-HDTRuleDocument -Path 'X:\Deploy\rules.yaml' -FileSystem (New-HDTFileSystem)
            $document.Rule | Format-Table Index, Name, SetFrom

        .EXAMPLE
            $fs = New-HDTFakeFileSystem -File @{ 'C:\ws\rules.yaml' = $text }
            Import-HDTRuleDocument -Path 'C:\ws\rules.yaml' -FileSystem $fs

            The same call in a test, with no file on disk anywhere.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $FileSystem.TestPath($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the rules file does not exist. Every workspace declares one at its root.' `
                    -Category ObjectNotFound))
    }

    $text = $FileSystem.ReadAllText($Path)

    return ConvertFrom-HDTRuleYaml -Yaml ([string] $text) -Path $Path
}
