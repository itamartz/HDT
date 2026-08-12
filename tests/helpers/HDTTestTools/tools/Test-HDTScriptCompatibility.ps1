function Test-HDTScriptCompatibility {
    <#
        .SYNOPSIS
            Tests whether a PowerShell file can run on Windows PowerShell 5.1.

        .DESCRIPTION
            Returns $true when Get-HDTScriptCompatibilityViolation finds nothing in
            the file and $false otherwise. The rule itself lives there; this is the
            boolean face of it.

        .PARAMETER Path
            The PowerShell file to test.

        .OUTPUTS
            System.Boolean

        .EXAMPLE
            Test-HDTScriptCompatibility -Path ./build.ps1

            Returns $true: build.ps1 runs on both engines.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    process {
        return (@(Get-HDTScriptCompatibilityViolation -Path $Path).Count -eq 0)
    }
}
