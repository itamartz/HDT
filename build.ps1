<#
    .SYNOPSIS
        Task runner for the Hephaestus Deployment Toolkit.

    .DESCRIPTION
        Runs the clean / build / lint / test tasks, and ci as the composition of
        all four. Every function here obeys the Verb-HDTNoun rule (DESIGN 15.1),
        which applies to build functions as much as to the engine.

        The script must work under both pwsh 7 and Windows PowerShell 5.1, because
        the engine ships into WinPE where only 5.1 exists. PSScriptAnalyzer is not
        importable under 5.1 on every machine, so 'test' never depends on 'lint'.

    .PARAMETER Task
        One or more of clean, build, lint, test, ci. Defaults to test. Tasks always
        run in the canonical order clean -> build -> lint -> test regardless of the
        order given.

    .PARAMETER Verbosity
        Pester output verbosity for the test task.

    .EXAMPLE
        ./build.ps1 -Task test

    .EXAMPLE
        ./build.ps1 -Task ci
#>
[CmdletBinding()]
param(
    [ValidateSet('clean', 'build', 'lint', 'test', 'ci')]
    [string[]] $Task = @('test'),

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string] $Verbosity = 'Detailed'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Initialize-HDTBuildEnvironment {
    <#
        .SYNOPSIS
            Resolves repository paths and imports the modules the build depends on.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $script:HDTRepositoryRoot = $PSScriptRoot
    $script:HDTOutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'out'
    $script:HDTModuleManifest = Join-Path -Path $PSScriptRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'
    $script:HDTAnalyzerSettings = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'

    # Pester 6.0.0 is installed on some machines and wins a bare import under
    # Windows PowerShell 5.1. The 5.x pin is mandatory, not cosmetic.
    try {
        Import-Module -Name Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force -ErrorAction Stop
    } catch {
        throw ("Pester 5 is required and could not be imported. Run: Install-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Scope CurrentUser -Force. Underlying error: {0}" -f $_.Exception.Message)
    }

    $helperManifest = Join-Path -Path $PSScriptRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1'
    if (-not (Test-Path -Path $helperManifest -PathType Leaf)) {
        throw "The HDTTestTools helper module is missing at '$helperManifest'."
    }
    Import-Module -Name $helperManifest -Force -ErrorAction Stop
}

function Clear-HDTBuildOutput {
    <#
        .SYNOPSIS
            Removes the out directory.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param()

    if (Test-Path -Path $script:HDTOutputPath) {
        if ($PSCmdlet.ShouldProcess($script:HDTOutputPath, 'Remove build output')) {
            Remove-Item -Path $script:HDTOutputPath -Recurse -Force
        }
        Write-Information ("clean: removed {0}" -f $script:HDTOutputPath)
    } else {
        Write-Information 'clean: nothing to remove'
    }
}

function Invoke-HDTBuild {
    <#
        .SYNOPSIS
            Validates the engine manifest and stages the module into out/.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $manifest = Test-ModuleManifest -Path $script:HDTModuleManifest -ErrorAction Stop
    $data = Import-PowerShellDataFile -Path $script:HDTModuleManifest

    Import-Module -Name $script:HDTModuleManifest -Force -ErrorAction Stop

    $declared = @($data.FunctionsToExport) | Sort-Object
    $exported = @((Get-Module -Name $manifest.Name).ExportedFunctions.Keys) | Sort-Object

    if (($declared -join ',') -ne ($exported -join ',')) {
        throw ("Exported functions do not match the manifest. Manifest: [{0}]. Module: [{1}]." -f ($declared -join ', '), ($exported -join ', '))
    }

    $stagePath = Join-Path -Path $script:HDTOutputPath -ChildPath ("{0}/{1}" -f $manifest.Name, $manifest.Version)
    if (Test-Path -Path $stagePath) {
        Remove-Item -Path $stagePath -Recurse -Force
    }
    New-Item -Path $stagePath -ItemType Directory -Force | Out-Null

    $sourcePath = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/*'
    Copy-Item -Path $sourcePath -Destination $stagePath -Recurse -Force

    Write-Information ("build: {0} {1} staged to {2}" -f $manifest.Name, $manifest.Version, $stagePath)
}

function Invoke-HDTLint {
    <#
        .SYNOPSIS
            Runs PSScriptAnalyzer over every HDT source file and the engine manifest.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    # Being listed by Get-Module -ListAvailable is not enough: on Windows
    # PowerShell 5.1 the analyzer can show up inside another module's
    # RequiredModules tree yet still refuse to import. Test-HDTModuleAvailable
    # holds that distinction so the lint task, the selfcheck task and the tests
    # all agree on what "available" means.
    if (-not (Test-HDTModuleAvailable -Name PSScriptAnalyzer)) {
        throw ("PSScriptAnalyzer is not available to this PowerShell edition (PowerShell {0}, {1}). Run: Install-Module PSScriptAnalyzer -Scope CurrentUser. The 'test' task does not require it." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    }

    $file = @(Get-HDTSourceFile -RepositoryRoot $script:HDTRepositoryRoot)
    $file += $script:HDTModuleManifest

    $diagnostic = @()
    foreach ($path in $file) {
        $diagnostic += @(Invoke-ScriptAnalyzer -Path $path -Settings $script:HDTAnalyzerSettings)
    }

    foreach ($item in $diagnostic) {
        Write-Information ("{0} {1} {2}:{3} {4}" -f $item.Severity, $item.RuleName, $item.ScriptPath, $item.Line, $item.Message)
    }

    if ($diagnostic.Count -gt 0) {
        throw ("PSScriptAnalyzer reported {0} diagnostic(s) across {1} file(s)." -f $diagnostic.Count, $file.Count)
    }

    Write-Information ("lint: 0 diagnostics across {0} file(s)" -f $file.Count)
}

function Invoke-HDTTest {
    <#
        .SYNOPSIS
            Runs the unit and contract suites and fails the build on any failure.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
        [string] $OutputVerbosity = 'Detailed'
    )

    # tests/fixtures and tests/selfcheck are never in Run.Path.
    $candidate = @('tests/unit', 'tests/contract')
    $path = @()
    foreach ($item in $candidate) {
        $full = Join-Path -Path $script:HDTRepositoryRoot -ChildPath $item
        if (Test-Path -Path $full -PathType Container) {
            $path += $full
        }
    }

    if ($path.Count -eq 0) {
        throw ("No test suites found. Expected at least one of: {0}." -f ($candidate -join ', '))
    }

    $resultName = 'pester-{0}-{1}.xml' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion
    $resultPath = Join-Path -Path (Join-Path -Path $script:HDTOutputPath -ChildPath 'testResults') -ChildPath $resultName

    $configuration = New-HDTPesterConfiguration -Path $path -ResultPath $resultPath -Verbosity $OutputVerbosity
    $result = Invoke-Pester -Configuration $configuration

    Write-Information ("test: {0} passed, {1} failed, {2} skipped -> {3}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $resultPath)

    if ($result.FailedCount -gt 0) {
        throw ("{0} test(s) failed." -f $result.FailedCount)
    }
}

$canonicalOrder = @('clean', 'build', 'lint', 'test')
$requested = @($Task)
if ($requested -contains 'ci') {
    $requested = $canonicalOrder
}
$ordered = @($canonicalOrder | Where-Object { $requested -contains $_ })

try {
    Initialize-HDTBuildEnvironment

    foreach ($name in $ordered) {
        switch ($name) {
            'clean' { Clear-HDTBuildOutput -Confirm:$false }
            'build' { Invoke-HDTBuild }
            'lint' { Invoke-HDTLint }
            'test' { Invoke-HDTTest -OutputVerbosity $Verbosity }
        }
    }
} catch {
    [Console]::Error.WriteLine(("BUILD FAILED: {0}" -f $_.Exception.Message))
    [Console]::Error.WriteLine(($_ | Out-String))
    exit 1
}

Write-Information ("BUILD SUCCEEDED ({0}) on PowerShell {1}" -f ($ordered -join ', '), $PSVersionTable.PSVersion)
exit 0
