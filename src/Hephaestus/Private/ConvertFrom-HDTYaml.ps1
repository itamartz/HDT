function ConvertFrom-HDTYaml {
    <#
        .SYNOPSIS
            Parses YAML text into an ordered dictionary, turning a parser
            exception into a configuration error that names the file and line.

        .DESCRIPTION
            This is the ONLY place in the engine that mentions ConvertFrom-Yaml.
            Everything else asks for a document and gets either an ordered
            dictionary or a pointed error: malformed YAML produces a pointed
            configuration error, not a crash.

            Three behaviours are deliberate:

            1. The dependency is imported lazily. powershell-yaml is NOT in the
               manifest's RequiredModules: that would make the whole module
               unimportable wherever the dependency is absent, and it would
               complicate staging into WinPE, which has no gallery. A missing
               module is reported as HDTDependencyError naming the module and
               the command that installs it.

            2. -Ordered is mandatory, not a nicety. Without it the parser returns
               a hashtable whose key order differs between Windows PowerShell 5.1
               and pwsh 7 - the same document was observed yielding two different
               orders. rules.yaml applies its set: keys in document order, so
               that difference would make variable resolution depend on which
               engine happened to be running.

            3. Nothing of the parser's own exception types escapes. A YAML syntax
               error surfaces as a MethodInvocationException wrapping a YamlDotNet
               exception which carries .Start.Line; that line is lifted into the
               message and the whole chain is dropped, so no caller can come to
               depend on a third-party exception type. The parser's own sentence
               is kept, because it is the part that says what is actually wrong.

            An empty or whitespace-only document parses to $null rather than
            throwing. "The file exists and says nothing" is a fact the validator
            reports in its own words, not a parse failure.

        .PARAMETER Yaml
            The document text, as read through an IFileSystem.

        .PARAMETER Path
            The path the text came from. Used for the error message and the
            TargetObject only - this function never reads the file itself.

        .OUTPUTS
            System.Collections.Specialized.OrderedDictionary, or $null for an
            empty document. A document whose root is a sequence returns a list;
            rejecting that is the validator's job, not the parser's.

        .EXAMPLE
            ConvertFrom-HDTYaml -Yaml $FileSystem.ReadAllText($path) -Path $path

            The canonical call: the filesystem is injected, this is pure text in
            and objects out.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
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

    if ($null -eq (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        try {
            Import-Module -Name powershell-yaml -ErrorAction Stop
        } catch {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord `
                        -Message 'the powershell-yaml module is required to read HDT configuration and could not be imported. Run: Install-Module powershell-yaml -Scope AllUsers.' `
                        -Path $Path -ErrorId 'HDTDependencyError' -Category NotInstalled))
        }
    }

    if ([string]::IsNullOrWhiteSpace($Yaml)) {
        return $null
    }

    $document = $null
    $failure = $null
    try {
        $document = ConvertFrom-Yaml -Yaml $Yaml -Ordered
    } catch {
        $failure = $_
    }

    if ($null -ne $failure) {
        $inner = $failure.Exception
        while ($null -ne $inner.InnerException) {
            $inner = $inner.InnerException
        }

        $line = 0
        if (@($inner.PSObject.Properties.Name) -contains 'Start') {
            $start = $inner.Start
            if ($null -ne $start -and @($start.PSObject.Properties.Name) -contains 'Line') {
                $line = [int] $start.Line
            }
        }

        $message = 'the YAML in this file could not be parsed. {0}' -f $inner.Message

        if ($line -gt 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Message $message -Path $Path -Line $line))
        }

        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Message $message -Path $Path))
    }

    return $document
}
