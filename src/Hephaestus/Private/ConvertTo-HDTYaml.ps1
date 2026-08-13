function ConvertTo-HDTYaml {
    <#
        .SYNOPSIS
            Serialises an ordered dictionary to YAML text.

        .DESCRIPTION
            The mirror of ConvertFrom-HDTYaml, and for the same reason: this is
            the ONLY place in the engine that mentions ConvertTo-Yaml. Everything
            else hands over a document and gets text or a pointed error.

            The dependency is imported lazily and a missing module is reported as
            HDTDependencyError naming the module and the command that installs
            it. powershell-yaml is NOT in the manifest's RequiredModules: that
            would make the whole module unimportable wherever the dependency is
            absent, and it would complicate staging into WinPE, which has no
            gallery.

            THE INPUT MUST BE AN ORDERED DICTIONARY. Key order is the difference
            between a diff a human reads and a diff a human re-reads, and a
            hashtable's order differs between Windows PowerShell 5.1 and pwsh 7 -
            the same trap ConvertFrom-HDTYaml documents for its -Ordered switch.

        .PARAMETER Document
            The document to serialise.

        .PARAMETER Path
            The file the text is destined for. Used for the error message only -
            this function writes nothing.

        .OUTPUTS
            System.String

        .EXAMPLE
            $FileSystem.WriteAllText($path, (ConvertTo-HDTYaml -Document $document -Path $path))
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq (Get-Command -Name ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        try {
            Import-Module -Name powershell-yaml -ErrorAction Stop
        } catch {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message 'the powershell-yaml module is required to write HDT configuration and could not be imported. Run: Install-Module powershell-yaml -Scope AllUsers.' `
                        -Path $Path -ErrorId 'HDTDependencyError' -Category NotInstalled))
        }
    }

    return [string] (ConvertTo-Yaml -Data $Document)
}
