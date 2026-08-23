function Import-HDTStepModule {
    <#
        .SYNOPSIS
            Imports the step-type modules a workspace ships in its Modules
            directory.

        .DESCRIPTION
            Third-party step types can be dropped into Modules\.
            This is the drop-in half; Get-HDTStepType is the discovery half, and
            the two are deliberately separate so discovery can be proven against
            a module created in memory with no file written anywhere.

            A THIN, BRANCH-FREE ADAPTER over Import-Module, and therefore not
            unit tested beyond "it imports what it is given"
            (tests/helpers/README.md section 10). It enumerates
            the .psd1 and .psm1 files directly under -Path and imports each. A
            missing directory yields nothing, because a workspace without
            third-party steps is the normal case, not an error.

        .PARAMETER Path
            The workspace's Modules directory.

        .OUTPUTS
            System.Management.Automation.PSModuleInfo, one per module imported.

        .EXAMPLE
            Import-HDTStepModule -Path 'C:\HDTLab\Share\Modules'
            @(Get-HDTStepType | Where-Object { $_.Source -ne 'Hephaestus' })

            Loads third-party step types off the share. This is the extension point:
            a module there declaring Invoke-HDTContosoStep gets run by the engine
            without anything in this module listing it.

        .EXAMPLE
            @(Get-HDTStepType).Count

            Every type the engine can now dispatch, the built-in ones included.

    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $manifest = @(Get-ChildItem -LiteralPath $Path -Include '*.psd1', '*.psm1' -File -Recurse -Depth 1 -ErrorAction SilentlyContinue)

    foreach ($item in $manifest) {
        Import-Module -Name $item.FullName -Force -Global -PassThru -ErrorAction Stop
    }
}
