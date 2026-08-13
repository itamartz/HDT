<#
    .SYNOPSIS
        Task runner for the Hephaestus Deployment Toolkit.

    .DESCRIPTION
        Runs the clean / build / lint / test / selfcheck tasks, and ci as the
        composition of all five. Every function here obeys the Verb-HDTNoun rule
        (DESIGN 15.1), which applies to build functions as much as to the engine.

        The script must work under both pwsh 7 and Windows PowerShell 5.1, because
        the engine ships into WinPE where only 5.1 exists. PSScriptAnalyzer is not
        importable under 5.1 on every machine, so 'test' never depends on 'lint'.

    .PARAMETER Task
        One or more of clean, build, lint, test, selfcheck, ci, integration, e2e.
        Defaults to test. Tasks always run in the canonical order clean -> build
        -> lint -> test -> selfcheck -> integration -> e2e regardless of the
        order given.

        integration and e2e are NOT part of ci and never will be. DESIGN 12.2.5
        puts integration on pushes to main and E2E nightly; both need an elevated
        session, a disk to write to and - for e2e - Hyper-V and the staged media,
        none of which a CI worker has.

    .PARAMETER Verbosity
        Pester output verbosity for the test task.

    .EXAMPLE
        ./build.ps1 -Task test

    .EXAMPLE
        ./build.ps1 -Task ci

    .EXAMPLE
        ./build.ps1 -Task integration

        Real DISM, a real mounted VHDX, elevated. Not part of ci.

    .EXAMPLE
        ./build.ps1 -Task e2e

        Hyper-V, elevated, on the isolated 'HDT Lab' switch only. Not part of ci.
#>
[CmdletBinding()]
param(
    [ValidateSet('clean', 'build', 'lint', 'test', 'selfcheck', 'ci', 'integration', 'e2e')]
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

function Test-HDTElevation {
    <#
        .SYNOPSIS
            True when this session is running as Administrator.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    return ([Security.Principal.WindowsPrincipal] $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-HDTIntegrationTest {
    <#
        .SYNOPSIS
            Runs tests/integration - real DISM, a real mounted VHDX, real
            partitioning.

        .DESCRIPTION
            NOT PART OF ci, and it must not become part of it. These tests mount
            VHDXs, clear and repartition them, and apply a 4 GB Windows image;
            they need an elevated session and about 25 GB of free disk.

            Every precondition is named in a sentence here rather than left to
            fail obscurely inside a test. A suite that dies with "Access is
            denied" thirty seconds in has told the operator nothing.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
        [string] $OutputVerbosity = 'Detailed'
    )

    if (-not (Test-HDTElevation)) {
        throw "The 'integration' task needs an elevated session: it mounts VHDXs, clears disks and applies images. Start PowerShell as Administrator and run ./build.ps1 -Task integration again."
    }

    # New-VHD comes from the Hyper-V module. It is how the scratch disk these
    # tests write to is created, and it is the reason they never touch a
    # physical disk.
    if (-not (Get-Command -Name 'New-VHD' -ErrorAction SilentlyContinue)) {
        throw "The 'integration' task needs the Hyper-V PowerShell module for New-VHD, which is how it creates the scratch VHDX it writes to. Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell."
    }

    $media = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    if (-not (Test-Path -LiteralPath $media -PathType Leaf)) {
        throw ("The 'integration' task needs the staged Windows 11 media at '{0}' (PROJECT.md, 'Test media - already staged locally')." -f $media)
    }

    $path = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/integration'
    if (-not (Test-Path -Path $path -PathType Container)) {
        throw ("No integration suite found at '{0}'." -f $path)
    }

    $resultName = 'pester-integration-{0}-{1}.xml' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion
    $resultPath = Join-Path -Path (Join-Path -Path $script:HDTOutputPath -ChildPath 'testResults') -ChildPath $resultName

    $configuration = New-HDTPesterConfiguration -Path @($path) -ResultPath $resultPath -Verbosity $OutputVerbosity
    $result = Invoke-Pester -Configuration $configuration

    Write-Information ("integration: {0} passed, {1} failed, {2} skipped -> {3}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $resultPath)

    if ($result.FailedCount -gt 0) {
        throw ("{0} integration test(s) failed." -f $result.FailedCount)
    }
}

function Invoke-HDTEndToEndTest {
    <#
        .SYNOPSIS
            Runs tests/e2e - Hyper-V, on the isolated 'HDT Lab' switch only.

        .DESCRIPTION
            NOT PART OF ci. This builds a Generation 2 VM, boots it from the
            WinPE ISO and lets the engine deploy Windows 11 onto it.

            PROJECT.md's lab safety rules apply in full: HDT test VMs are named
            HDT-*, sit on the 'HDT Lab' switch, keep their files under
            C:\HDTLab\vms and stay under 12 GB combined. CM01 and DC01 are never
            touched. The helpers in tests/helpers/HDTTestTools enforce all of
            that in code; this function only checks that the run is possible at
            all.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
        [string] $OutputVerbosity = 'Detailed'
    )

    if (-not (Test-HDTElevation)) {
        throw "The 'e2e' task needs an elevated session: it creates and starts Hyper-V virtual machines and mounts VHDXs. Start PowerShell as Administrator and run ./build.ps1 -Task e2e again."
    }

    if (-not (Get-Module -Name 'Hyper-V' -ListAvailable)) {
        throw "The 'e2e' task needs the Hyper-V PowerShell module. Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell."
    }

    $iso = 'C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso'
    if (-not (Test-Path -LiteralPath $iso -PathType Leaf)) {
        throw ("The 'e2e' task needs the WinPE boot ISO at '{0}' (SPIKES.md S1/S3). Building one from code is M4's Update-HDTBootImage; until then the spike artifact is the boot vehicle." -f $iso)
    }

    $media = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    if (-not (Test-Path -LiteralPath $media -PathType Leaf)) {
        throw ("The 'e2e' task needs the staged Windows 11 media at '{0}' (PROJECT.md, 'Test media - already staged locally')." -f $media)
    }

    $path = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/e2e'
    if (-not (Test-Path -Path $path -PathType Container)) {
        throw ("No e2e suite found at '{0}'." -f $path)
    }

    $resultName = 'pester-e2e-{0}-{1}.xml' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion
    $resultPath = Join-Path -Path (Join-Path -Path $script:HDTOutputPath -ChildPath 'testResults') -ChildPath $resultName

    $configuration = New-HDTPesterConfiguration -Path @($path) -ResultPath $resultPath -Verbosity $OutputVerbosity
    $result = Invoke-Pester -Configuration $configuration

    Write-Information ("e2e: {0} passed, {1} failed, {2} skipped -> {3}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $resultPath)

    if ($result.FailedCount -gt 0) {
        throw ("{0} end-to-end test(s) failed." -f $result.FailedCount)
    }
}

function Invoke-HDTSelfCheck {
    <#
        .SYNOPSIS
            Proves the test harness itself works, by watching it catch a
            deliberately failing test.

        .DESCRIPTION
            ROADMAP M0 requires that a deliberately failing test fails CI, a
            passing one passes, and analyzer violations block. A suite nobody has
            watched go red is not a suite, so this task observes all three
            against the fixtures in tests/selfcheck and tests/fixtures/analyzer.

            Those fixtures are deliberately red and deliberately dirty. They are
            outside Invoke-HDTTest's Run.Path and outside Get-HDTSourceFile, so
            they can never turn the real suite or the lint task red.

            Four checks, each reported PASS or FAIL on its own line:

              1. The failure fixture produces FailedCount >= 1 in-process.
              2. The pass fixture produces PassedCount >= 1 and FailedCount = 0.
              3. A CHILD process running the failure fixture with Run.Exit set
                 exits non-zero. This is the exit-code path CI depends on, and
                 it cannot be observed from inside the run it is testing.
              4. PSScriptAnalyzer reports diagnostics for the bait fixture,
                 including PSUseCompatibleSyntax - which also proves the 5.1
                 target version in PSScriptAnalyzerSettings.psd1 is in force.

            Check 4 is skipped with a warning where PSScriptAnalyzer cannot be
            imported, which is the normal case for Windows PowerShell 5.1 on a
            developer machine. CI installs the analyzer for both editions, so
            both legs run it there.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $failureFixture = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/selfcheck/DeliberateFailure.Tests.ps1'
    $passFixture = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/selfcheck/DeliberatePass.Tests.ps1'
    $baitFixture = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/fixtures/analyzer/AnalyzerBait.ps1'

    foreach ($required in @($failureFixture, $passFixture, $baitFixture)) {
        if (-not (Test-Path -Path $required -PathType Leaf)) {
            throw ("selfcheck: the fixture '{0}' is missing. The harness cannot prove itself without it." -f $required)
        }
    }

    # Check 1 - a failing test fails.
    $failureResult = Invoke-Pester -Configuration (New-HDTPesterConfiguration -Path $failureFixture -Verbosity None)
    if ($failureResult.FailedCount -lt 1) {
        Write-Information 'selfcheck 1 FAIL: a deliberately failing test was not detected'
        throw 'selfcheck check 1 failed: the harness did not detect a deliberately failing test. The harness cannot be trusted.'
    }
    Write-Information ("selfcheck 1 PASS: the deliberately failing test was detected ({0} failed)" -f $failureResult.FailedCount)

    # Check 2 - a passing test passes.
    $passResult = Invoke-Pester -Configuration (New-HDTPesterConfiguration -Path $passFixture -Verbosity None)
    if ($passResult.PassedCount -lt 1 -or $passResult.FailedCount -ne 0) {
        Write-Information 'selfcheck 2 FAIL: a deliberately passing test did not pass'
        throw ("selfcheck check 2 failed: the deliberately passing test reported {0} passed and {1} failed." -f $passResult.PassedCount, $passResult.FailedCount)
    }
    Write-Information ("selfcheck 2 PASS: the deliberately passing test passed ({0} passed)" -f $passResult.PassedCount)

    # Check 3 - failure reaches the process exit code. Spawned in the same
    # PowerShell edition this build is running under, so the 5.1 leg proves 5.1.
    $hostPath = (Get-Process -Id $PID).Path
    $childCommand = "Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -Force; " +
    "`$c = New-PesterConfiguration; " +
    "`$c.Run.Path = '$failureFixture'; " +
    "`$c.Run.Exit = `$true; " +
    "`$c.Output.Verbosity = 'None'; " +
    "Invoke-Pester -Configuration `$c"

    & $hostPath -NoProfile -Command $childCommand 2>&1 | Out-Null
    $childExitCode = $LASTEXITCODE

    if ($childExitCode -eq 0) {
        Write-Information 'selfcheck 3 FAIL: a red run exited zero'
        throw 'selfcheck check 3 failed: the harness does not propagate failure to the process exit code, so CI would report green on a red suite.'
    }
    Write-Information ("selfcheck 3 PASS: a red run exits non-zero (exit code {0})" -f $childExitCode)

    # Check 4 - analyzer violations are detected.
    if (-not (Test-HDTModuleAvailable -Name PSScriptAnalyzer)) {
        Write-Warning ("selfcheck 4 SKIP: PSScriptAnalyzer cannot be imported by this edition (PowerShell {0}, {1}), so the analyzer leg was not proven here. CI installs it for both editions." -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
        Write-Information 'selfcheck: 3 of 4 checks passed, analyzer check skipped for this edition'
        return
    }

    $diagnostic = @(Invoke-ScriptAnalyzer -Path $baitFixture -Settings $script:HDTAnalyzerSettings)
    if ($diagnostic.Count -lt 1) {
        Write-Information 'selfcheck 4 FAIL: no analyzer diagnostics for the bait fixture'
        throw 'selfcheck check 4 failed: PSScriptAnalyzer reported nothing for a deliberately dirty file, so analyzer violations would not block.'
    }

    $compatibility = @($diagnostic | Where-Object { $_.RuleName -eq 'PSUseCompatibleSyntax' })
    if ($compatibility.Count -lt 1) {
        Write-Information 'selfcheck 4 FAIL: no PSUseCompatibleSyntax diagnostic for the bait fixture'
        throw ("selfcheck check 4 failed: the bait fixture contains PowerShell 7 only syntax but PSUseCompatibleSyntax did not fire. Check the TargetVersions in {0}." -f $script:HDTAnalyzerSettings)
    }

    Write-Information ("selfcheck 4 PASS: analyzer reported {0} diagnostic(s) for the bait fixture, including PSUseCompatibleSyntax" -f $diagnostic.Count)
    Write-Information 'selfcheck: 4 of 4 checks passed'
}

# WHAT ci MEANS. These five, and only these five. integration and e2e are
# accepted tasks but are deliberately absent from this list, so 'ci' never
# expands to a run that needs elevation, a disk or Hyper-V.
$canonicalOrder = @('clean', 'build', 'lint', 'test', 'selfcheck')

# WHAT CAN BE DISPATCHED. Everything above, plus the two slow tasks, in the
# order they would be run together. A task accepted by the ValidateSet but
# missing from THIS list would leave $ordered empty, the foreach would run
# nothing, and the script would print BUILD SUCCEEDED () and exit 0 - reporting
# success for a suite that never executed. The guard below makes that a failure,
# but the list is what makes it not happen.
$dispatchOrder = @($canonicalOrder + @('integration', 'e2e'))

$requested = @($Task)
if ($requested -contains 'ci') {
    $requested = @($requested + $canonicalOrder)
}
$ordered = @($dispatchOrder | Where-Object { $requested -contains $_ })

try {
    if ($ordered.Count -eq 0) {
        throw ("No task was dispatched for -Task [{0}]. A build that ran nothing is not a build that succeeded. The tasks are: {1} (and ci, which runs {2})." -f
            ($requested -join ', '), ($dispatchOrder -join ', '), ($canonicalOrder -join ', '))
    }

    Initialize-HDTBuildEnvironment

    foreach ($name in $ordered) {
        switch ($name) {
            'clean' { Clear-HDTBuildOutput -Confirm:$false }
            'build' { Invoke-HDTBuild }
            'lint' { Invoke-HDTLint }
            'test' { Invoke-HDTTest -OutputVerbosity $Verbosity }
            'selfcheck' { Invoke-HDTSelfCheck }
            'integration' { Invoke-HDTIntegrationTest -OutputVerbosity $Verbosity }
            'e2e' { Invoke-HDTEndToEndTest -OutputVerbosity $Verbosity }
        }
    }
} catch {
    [Console]::Error.WriteLine(("BUILD FAILED: {0}" -f $_.Exception.Message))
    [Console]::Error.WriteLine(($_ | Out-String))
    exit 1
}

Write-Information ("BUILD SUCCEEDED ({0}) on PowerShell {1}" -f ($ordered -join ', '), $PSVersionTable.PSVersion)
exit 0
