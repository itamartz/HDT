function Test-HDTModuleAvailable {
    <#
        .SYNOPSIS
            Reports whether a PowerShell module can actually be imported by the
            current engine.

        .DESCRIPTION
            Get-Module -ListAvailable is not a sufficient availability test. On
            Windows PowerShell 5.1 a module can be listed because it appears
            inside another module's RequiredModules tree and still refuse to
            import - PSScriptAnalyzer does exactly that on the HDT development
            machine. Anything that gates an analyzer step on -ListAvailable alone
            reports the analyzer as present under 5.1 and then fails on import.

            This helper answers the only question callers care about: will
            Import-Module succeed. An already-imported module is available
            without a second import; otherwise the import is attempted and any
            failure is swallowed and reported as $false.

            The import is a deliberate side effect. Callers that get $true can
            use the module's commands immediately.

        .PARAMETER Name
            Name of the module to test.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTModuleAvailable -Name PSScriptAnalyzer

            Returns $true under pwsh 7 and $false under Windows PowerShell 5.1 on
            a machine where the analyzer is listed but not importable.

        .EXAMPLE
            It 'lints cleanly' -Skip:(-not (Test-HDTModuleAvailable -Name PSScriptAnalyzer)) { }

            The correct way to skip an analyzer assertion.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Name
    )

    if (Get-Module -Name $Name) {
        return $true
    }

    if (-not (Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        Import-Module -Name $Name -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}
