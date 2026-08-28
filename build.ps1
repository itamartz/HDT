<#
    .SYNOPSIS
        Task runner for the Hephaestus Deployment Toolkit.

    .DESCRIPTION
        Runs the clean / version / bundle / build / lint / test / selfcheck
        tasks, and ci as the composition of all seven. Every function here obeys the Verb-HDTNoun rule
        (DESIGN 15.1), which applies to build functions as much as to the engine.

        The script must work under both pwsh 7 and Windows PowerShell 5.1, because
        the engine ships into WinPE where only 5.1 exists. PSScriptAnalyzer is not
        importable under 5.1 on every machine, so 'test' never depends on 'lint'.

    .PARAMETER Task
        One or more of clean, version, bundle, build, lint, test, selfcheck, ci,
        integration, e2e. Defaults to test. Tasks always run in the canonical
        order clean -> version -> bundle -> build -> lint -> test -> selfcheck
        -> integration -> e2e regardless of the order given.

        version comes before bundle and build because it is what decides the
        number the staged artefact in out/ is named for.

        integration and e2e are NOT part of ci and never will be. DESIGN 12.2.5
        puts integration on pushes to main and E2E nightly; both need an elevated
        session, a disk to write to and - for e2e - Hyper-V and the staged media,
        none of which a CI worker has.

    .PARAMETER Verbosity
        Pester output verbosity for the test task.

    .PARAMETER Coverage
        Measure code coverage over the module bundle during the test task and write
        out/coverage/coverage.xml, plus the two shields.io badge documents in
        out/badges/ that the README renders from.

        OFF BY DEFAULT BECAUSE IT IS NOT FREE. Coverage profiles every command
        the suite executes; a developer running one file should not pay for a
        number nobody is going to read. CI asks for it once per push.

    .PARAMETER Worker
        How many child processes the test task spreads the suite across.

        0, the default, picks one per core less two, capped at eight - measured
        on this repository as the point where more workers stop buying anything,
        because by then the run is bounded by its single longest test file rather
        than by how many are in flight. 1 runs everything in this process, which
        is what to use when a failure needs reading in order.

        NOT COMPATIBLE WITH -Coverage, which measures one process and so runs
        unsharded whatever this says.

    .EXAMPLE
        ./build.ps1 -Task test

    .EXAMPLE
        ./build.ps1 -Task test -Worker 1

        One process, output in order. What to run when something failed and the
        interleaved output of eight workers is not what you want to read.

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
    [ValidateSet('clean', 'version', 'bundle', 'build', 'lint', 'test', 'selfcheck', 'ci', 'integration', 'e2e')]
    [string[]] $Task = @('test'),

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string] $Verbosity = 'Detailed',

    [switch] $Coverage,

    [ValidateRange(0, 128)]
    [int] $Worker = 0
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

function Invoke-HDTVersion {
    <#
        .SYNOPSIS
            Bumps the engine's ModuleVersion when its sources have moved since
            the last bump.

        .DESCRIPTION
            A file added or removed takes the minor; a file edited inside takes
            the patch; a tree that has not moved is left alone and the manifest
            is not written at all.

            IT RUNS BEFORE bundle AND build. Invoke-HDTBuild stages the module
            into out/<name>/<version>, and a bump after that would leave the
            staged folder named for the version before it - the one artefact
            somebody would go looking for by number.

            THE MANIFEST IS A TRACKED SOURCE FILE, so this task really does
            change the working tree. That is the point: the number moves with
            the code rather than when somebody remembers.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Import-Module -Name $script:HDTModuleManifest -Force -ErrorAction Stop

    $moduleRoot = Split-Path -Parent $script:HDTModuleManifest
    $answer = Update-HDTModuleVersion -ModuleRoot $moduleRoot

    if ($answer.Changed) {
        Write-Information ("version: {0} -> {1} ({2}, {3} file(s))" -f
            $answer.PreviousVersion, $answer.Version, $answer.Reason, $answer.FileCount)
    } else {
        Write-Information ("version: {0} unchanged ({1}, {2} file(s))" -f
            $answer.Version, $answer.Reason, $answer.FileCount)
    }
}

function Invoke-HDTBundle {
    <#
        .SYNOPSIS
            Concatenates the module's sources into one file, so importing it
            parses one file instead of several hundred.

        .DESCRIPTION
            2.46 seconds of dot-sourcing becomes 1.37 on the lab host - measured
            in a fresh 5.1 process - and that second is what somebody watches
            nothing happen for after Start-HDTConsole -Detach.

            THE ARTEFACT IS NEVER COMMITTED, and it is the only thing
            Hephaestus.psm1 loads. This task does not have to be run: the loader
            calls Write-HDTModuleBundle itself whenever the bundle is missing or
            older than a source, so a stale one cannot run. It is here so that a
            build produces one deliberately, before build stages it and drops the
            sources it replaces.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Import-Module -Name $script:HDTModuleManifest -Force -ErrorAction Stop

    $moduleRoot = Split-Path -Parent $script:HDTModuleManifest
    $made = Write-HDTModuleBundle -ModuleRoot $moduleRoot

    Write-Information ("bundle: {0} file(s), {1:n0} KB -> {2}" -f
        $made.FileCount, ($made.Length / 1KB), $made.Path)
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

    # THE PACKAGE SHIPS THE BUNDLE AND NOT THE 375 FILES IT REPLACES. Both is
    # the same 2.6 MB of code twice, and it leaves Hephaestus.psm1 choosing
    # between two copies on a timestamp comparison - on a machine where neither
    # copy will ever be edited, and where the copy that loses is the fast one.
    #
    # Update-HDTBootImage already stages WinPE this way, for the same reason.
    # This is that decision for the Gallery.
    #
    # THE BUNDLE HAS TO BE THERE FIRST. Dropping the sources is only safe
    # because it is: a package with neither imports nothing, and the Gallery
    # keeps a published version for ever. ./build.ps1 -Task bundle is what puts
    # it there, and it runs before build in the canonical order.
    $stagedBundle = Join-Path -Path $stagePath -ChildPath 'Hephaestus.bundle.ps1'

    if (-not (Test-Path -LiteralPath $stagedBundle -PathType Leaf)) {
        throw ("the stage has no Hephaestus.bundle.ps1, so the sources cannot be dropped from it. " +
            "Run the bundle task first: ./build.ps1 -Task bundle,build.")
    }

    # BY NAME, INSIDE THE FOLDER THIS FUNCTION JUST CREATED, and nowhere near
    # the source tree - see the delete rules in CLAUDE.md.
    foreach ($replaced in @('Private', 'Public')) {
        $trim = Join-Path -Path $stagePath -ChildPath $replaced

        if (Test-Path -LiteralPath $trim) {
            Remove-Item -LiteralPath $trim -Recurse -Force
        }
    }

    Write-Information ("build: {0} {1} staged to {2} (bundled; Private\ and Public\ dropped)" -f
        $manifest.Name, $manifest.Version, $stagePath)
}

function Invoke-HDTLint {
    <#
        .SYNOPSIS
            Runs PSScriptAnalyzer over every HDT source file and the engine manifest.

        .PARAMETER Worker
            How many child processes to spread the files across. 1 analyses them
            in this process.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [ValidateRange(1, 128)]
        [int] $Worker = 1
    )

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

    # ONE PROCESS PER SHARD, BECAUSE THE ANALYZER ITSELF CANNOT BE MADE CHEAPER.
    # PSScriptAnalyzer costs a flat ~110ms per file here and almost none of that
    # is any one rule: measured over the 115 files under Private, the full rule
    # set takes 13.0s and the same run with PSUseCompatibleSyntax excluded takes
    # 12.7s. Batching the calls does not help either - it analyses the same files
    # and saves only the per-invocation setup, about 7 seconds of 78. What is
    # left is to do it on more than one core.
    #
    # THE BUNDLE IS ALREADY OUT, because Get-HDTSourceFile excludes it: the
    # suppression attributes that were valid in their own files match nothing
    # once they sit beside 364 others, and the analyzer raises a terminating
    # error rather than a diagnostic on it.
    $diagnostic = @(Invoke-HDTShardedLint -Path $file -Worker $Worker -Settings $script:HDTAnalyzerSettings)

    foreach ($item in $diagnostic) {
        Write-Information ("{0} {1} {2}:{3} {4}" -f $item.Severity, $item.RuleName, $item.ScriptPath, $item.Line, $item.Message)
    }

    if ($diagnostic.Count -gt 0) {
        throw ("PSScriptAnalyzer reported {0} diagnostic(s) across {1} file(s)." -f $diagnostic.Count, $file.Count)
    }

    Write-Information ("lint: 0 diagnostics across {0} file(s)" -f $file.Count)
}

function Invoke-HDTShardedLint {
    <#
        .SYNOPSIS
            Analyses a file list across child processes and returns every
            diagnostic they found.

        .DESCRIPTION
            One worker is the ordinary in-process loop, so nothing about a
            single-core machine, or -Worker 1, goes through the process
            machinery.

            EVERY WORKER MUST REPORT. A shard whose file is missing died before
            writing it, and its files therefore went unanalysed - reporting the
            surviving shards' diagnostics would be a lint that passed by not
            looking, which is worse than a lint that failed.

            THE BUCKETS ARE EVEN BY COUNT, not by cost: analyzer time per file
            varies far less than test time per file does, and there is no
            previous run to take timings from.

        .PARAMETER Path
            The files to analyse.

        .PARAMETER Worker
            How many child processes to use.

        .PARAMETER Settings
            The PSScriptAnalyzer settings file every worker uses.

        .OUTPUTS
            The diagnostics, flattened to Severity, RuleName, ScriptPath, Line
            and Message.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts child processes and writes into the build output directory, which is the task it was asked to run.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 128)]
        [int] $Worker,

        [Parameter(Mandatory = $true)]
        [string] $Settings
    )

    if ($Worker -le 1) {
        return @($Path | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Settings $Settings })
    }

    # PER PROCESS, for the reason Invoke-HDTShardedTest spells out: a second
    # build running at the same time must not share these files.
    $shardDirectory = Join-Path -Path (Join-Path -Path $script:HDTOutputPath -ChildPath 'lintShards') -ChildPath $PID
    if (Test-Path -LiteralPath $shardDirectory -PathType Container) {
        Get-ChildItem -Path $shardDirectory -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } else {
        $null = New-Item -Path $shardDirectory -ItemType Directory -Force
    }

    $bucket = @(Split-HDTTestBucket -Path $Path -Worker $Worker)
    $shardScript = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTLintShard.ps1'
    $hostPath = (Get-Process -Id $PID).Path

    Write-Information ("lint: {0} file(s) across {1} worker(s)" -f @($Path).Count, $bucket.Count)

    $shard = @()
    for ($i = 0; $i -lt $bucket.Count; $i++) {
        $listPath = Join-Path -Path $shardDirectory -ChildPath ('list-{0}.txt' -f $i)
        Set-Content -LiteralPath $listPath -Value $bucket[$i] -Encoding UTF8

        $diagnosticPath = Join-Path -Path $shardDirectory -ChildPath ('diagnostic-{0}.clixml' -f $i)

        $argument = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $shardScript,
            '-ListPath', $listPath,
            '-DiagnosticPath', $diagnosticPath,
            '-SettingsPath', $Settings
        )

        $errorPath = Join-Path -Path $shardDirectory -ChildPath ('err-{0}.log' -f $i)

        $process = Start-Process -FilePath $hostPath -ArgumentList $argument -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path -Path $shardDirectory -ChildPath ('out-{0}.log' -f $i)) `
            -RedirectStandardError $errorPath

        if ($null -eq $process) {
            throw ("Lint worker {0} of {1} could not be started ({2}), so its {3} file(s) would not have been analysed." -f
                ($i + 1), $bucket.Count, $hostPath, @($bucket[$i]).Count)
        }

        $shard += [pscustomobject] @{
            Process        = $process
            DiagnosticPath = $diagnosticPath
            ErrorPath      = $errorPath
            FileCount      = @($bucket[$i]).Count
        }
    }

    try {
        $null = $shard | ForEach-Object { $_.Process } | Wait-Process
    } finally {
        foreach ($item in $shard) {
            if (-not $item.Process.HasExited) {
                Stop-Process -Id $item.Process.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $diagnostic = @()
    for ($i = 0; $i -lt $shard.Count; $i++) {
        if (-not (Test-Path -LiteralPath $shard[$i].DiagnosticPath -PathType Leaf)) {
            # THE EXIT CODE BELONGS NEXT TO THE LOG. This read its err-N.log from
            # the start, which is more than the test half did, but an analyzer
            # worker killed for memory writes nothing at all - and an empty
            # reason here reads as no reason.
            $exitCode = $null
            try {
                $exitCode = $shard[$i].Process.ExitCode
            } catch {
                $exitCode = $null
            }

            throw ("lint worker {0} of {1} died without reporting, so its {2} file(s) were not analysed. {3}" -f
                ($i + 1), $shard.Count, $shard[$i].FileCount,
                (Get-HDTShardFailureReason -ErrorPath $shard[$i].ErrorPath -ExitCode $exitCode))
        }

        $diagnostic += @((Import-Clixml -LiteralPath $shard[$i].DiagnosticPath).Diagnostic)
    }

    return @($diagnostic)
}

function Invoke-HDTTest {
    <#
        .SYNOPSIS
            Runs the unit and contract suites and fails the build on any failure.

        .DESCRIPTION
            With -Coverage it also profiles the module bundle - the one file
            Hephaestus.psm1 loads - writes JaCoCo to
            out/coverage/coverage.xml and emits the two badge documents the
            README renders. See the -Coverage help on build.ps1 itself.

        .PARAMETER OutputVerbosity
            Pester output verbosity.

        .PARAMETER Coverage
            Measure coverage and write the badges.

        .PARAMETER Worker
            How many child processes to spread the suite across. 1 runs it in
            this process, exactly as it always did.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
        [string] $OutputVerbosity = 'Detailed',

        [Parameter()]
        [switch] $Coverage,

        [Parameter()]
        [ValidateRange(1, 128)]
        [int] $Worker = 1
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

    $coverageArgument = @{}
    if ($Coverage) {
        # THE BUNDLE, BECAUSE THE BUNDLE IS WHAT RUNS.
        #
        # Hephaestus.psm1 loads Hephaestus.bundle.ps1 and nothing else, so the
        # scriptblocks Pester traces belong to that file. Profiling the folder
        # instead would measure the bundle correctly AND score all 377 sources
        # at nought for never having executed - halving the number on the front
        # page while nothing about the tests changed.
        #
        # WHICH SOURCE A COVERED LINE CAME FROM IS STILL RECOVERABLE, from the
        # '# ---- source: ... ----' markers in the bundle: Resolve-HDTBundleLine
        # maps a line in out/coverage/coverage.xml back to Public\Foo.ps1 and a
        # line in it. The JaCoCo document is a nightly artefact somebody opens
        # by hand, not an input to anything, so it is left as Pester wrote it.
        #
        # NOT THE TESTS AND NOT THE HELPERS, either way. Coverage of a test file
        # is a tautology - it ran, or it did not - and coverage of the fakes
        # measures the harness rather than the product.
        Import-Module -Name $script:HDTModuleManifest -Force -ErrorAction Stop

        $bundlePath = Join-Path -Path (Split-Path -Parent $script:HDTModuleManifest) -ChildPath 'Hephaestus.bundle.ps1'

        # IMPORTING IT IS WHAT BUILDS IT - the loader writes the bundle whenever
        # a source is newer - so by here it exists. Saying so out loud rather
        # than measuring an empty path and reporting 0%.
        if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
            throw ("there is no bundle at '{0}' to measure coverage over. ./build.ps1 -Task bundle is what writes it." -f $bundlePath)
        }

        $coverageArgument['CoveragePath'] = $bundlePath
        $coverageArgument['CoverageResultPath'] = Join-Path -Path (Join-Path -Path $script:HDTOutputPath -ChildPath 'coverage') -ChildPath 'coverage.xml'
    }

    # MORE THAN ONE WORKER MEANS CHILD PROCESSES, and coverage cannot come with
    # them: Pester's profiler is per-process and JaCoCo documents do not merge by
    # concatenation, so -Coverage stays on the single-process path. Saying so
    # rather than silently producing a coverage badge measured over one eighth of
    # the suite.
    if ($Worker -gt 1 -and $Coverage) {
        Write-Warning 'test: -Coverage measures one process, so this run is not sharded. Drop -Coverage to use -Worker.'
    }

    if ($Worker -gt 1 -and -not $Coverage) {
        $result = Invoke-HDTShardedTest -Path $path -Worker $Worker -ResultPath $resultPath -OutputVerbosity $OutputVerbosity
    } else {
        $configuration = New-HDTPesterConfiguration -Path $path -ResultPath $resultPath -Verbosity $OutputVerbosity @coverageArgument
        $result = Invoke-Pester -Configuration $configuration
    }

    # THE PATH IT NAMES HAS TO BE ONE THAT EXISTS. A sharded run never writes
    # $resultPath - each worker writes a sibling of it - so printing it would
    # send whoever reads the log to a file that is not there.
    $written = $resultPath
    if ($Worker -gt 1 -and -not $Coverage) {
        $written = '{0}-shard*of*.xml' -f (Join-Path -Path (Split-Path -Parent $resultPath) -ChildPath ([IO.Path]::GetFileNameWithoutExtension($resultPath)))
    }

    Write-Information ("test: {0} passed, {1} failed, {2} skipped -> {3}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $written)

    # BEFORE THE JUDGEMENT, DELIBERATELY. A red run still writes its badges, and
    # they say so - a badge that only exists when the build is green is a badge
    # that always reads green.
    #
    # ALWAYS, NOT ONLY WITH -Coverage. Counting tests is free; measuring
    # coverage is not, and the two badges refresh on different clocks because of
    # it - tests on every push, coverage nightly. Write-HDTBuildBadge writes the
    # coverage document only when the run actually produced one.
    Write-HDTBuildBadge -Result $result

    Assert-HDTPesterResult -Result $result -Suite 'test'
}

function Invoke-HDTShardedTest {
    <#
        .SYNOPSIS
            Runs the suite across several child processes and returns one result.

        .DESCRIPTION
            WHY PROCESSES AND NOT RUNSPACES. The engine targets Windows
            PowerShell 5.1, which has no ForEach-Object -Parallel, and Pester 5
            keeps enough module-scoped state that sharing a session between
            concurrent runs is not something it promises. Processes also give
            the isolation the suite already assumes - two test files that both
            reach for the same scratch directory cannot see each other's
            $env: or current location.

            THE CHILD IS THE SAME EDITION THIS BUILD IS RUNNING UNDER, resolved
            off $PID rather than by hunting for powershell.exe: a 5.1 leg that
            silently shells out to pwsh proves nothing about 5.1, which is the
            whole point of running both legs.

            BALANCE IS THE LEVER, NOT THE WORKER COUNT. A sharded run cannot
            finish before its longest bucket, so the previous run's per-file
            seconds are fed to Split-HDTTestBucket to pack longest-first. The
            durations live in out/testResults, which -Task clean deletes; the
            first run after a clean is merely unbalanced, never wrong.

            EVERY WORKER WRITES ITS OWN NUnit XML. Nothing merges them because
            nothing needs to: both CI workflows collect out/testResults/*.xml as
            a glob, and the verdict comes from the summaries, not the documents.

        .PARAMETER Path
            The suite directories to run.

        .PARAMETER Worker
            How many child processes to start.

        .PARAMETER ResultPath
            The NUnit path the single-process run would have used. Each worker
            writes a sibling of it, suffixed with its shard number.

        .PARAMETER OutputVerbosity
            Pester output verbosity, passed to every worker.

        .OUTPUTS
            The merged result, shaped as Write-HDTBuildBadge and
            Assert-HDTPesterResult expect.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts child processes and writes into the build output directory, which is the task it was asked to run.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateRange(2, 128)]
        [int] $Worker,

        [Parameter(Mandatory = $true)]
        [string] $ResultPath,

        [Parameter(Mandatory = $true)]
        [string] $OutputVerbosity
    )

    $file = @(Get-ChildItem -Path $Path -Filter '*.Tests.ps1' -File -Recurse | ForEach-Object { $_.FullName })

    if ($file.Count -eq 0) {
        throw ("No test file was found under {0}. A build that ran nothing is not a build that succeeded." -f ($Path -join ', '))
    }

    $resultDirectory = Split-Path -Parent $ResultPath

    # PER PROCESS, NOT ONE SHARED FOLDER. Two builds running at once - a second
    # shell, another agent, a watch task - would otherwise overwrite each other's
    # list-N.txt between the write and the worker reading it, and each would run
    # the other's files while deleting the logs the other was still writing.
    # Observed as "the process cannot access the file 'err-2.log'" from clean.
    $shardDirectory = Join-Path -Path (Join-Path -Path $script:HDTOutputPath -ChildPath 'testShards') -ChildPath $PID

    # AND THE TIMINGS OUTSIDE IT, BECAUSE THE NEXT BUILD HAS A DIFFERENT PID.
    # The per-process isolation above is right for the volatile files - the
    # lists, the logs, the summaries - and was silently fatal for the durations,
    # which are the one thing here that is meant to outlive the run. Read from
    # the per-PID directory they were always read from a folder created seconds
    # earlier, so $duration was always empty, so Split-HDTTestBucket priced every
    # file at its 1.0 default and the longest-first pack degraded to plain
    # round-robin. Measured across the eight buckets that produced: 50.8s to
    # 91.8s, which is the whole imbalance the packer exists to remove.
    $timingDirectory = Join-Path -Path (Join-Path -Path $script:HDTOutputPath -ChildPath 'testShards') -ChildPath 'timing'

    foreach ($directory in @($resultDirectory, $shardDirectory, $timingDirectory)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -Path $directory -ItemType Directory -Force
        }
    }

    # THE PREVIOUS RUN'S TIMINGS, IF THERE ARE ANY. A hint and nothing more: a
    # file with no entry is priced at the mean, and -Task clean deletes the lot.
    $duration = @{}
    foreach ($csv in @(Get-ChildItem -Path $timingDirectory -Filter 'duration-*.csv' -File -ErrorAction SilentlyContinue)) {
        foreach ($row in @(Import-Csv -LiteralPath $csv.FullName)) {
            $duration[[string] $row.Path] = [double] $row.Seconds
        }
    }

    # THE FILES THAT USE A TestRegistry GO IN ONE BUCKET, so exactly one worker
    # ever creates a key under HKCU:\Software\Pester. Found by reading the files
    # rather than by keeping a list: a list is a thing to forget.
    $registryFile = @($file | Where-Object {
            (Get-Content -LiteralPath $_ -Raw -ErrorAction SilentlyContinue) -match 'TestRegistry'
        })

    $bucket = @(Split-HDTTestBucket -Path $file -Worker $Worker -Duration $duration `
            -RegistryPath $registryFile)

    Get-ChildItem -Path $shardDirectory -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # BUILD THE BUNDLE HERE, IN ONE PROCESS, BEFORE ANY WORKER STARTS.
    # Hephaestus.psm1 rebuilds Hephaestus.bundle.ps1 whenever a source is newer
    # than it, and every worker imports the engine. Left to themselves, eight
    # processes that all find a stale bundle all try to write the same file and
    # seven of them die on "because it is being used by another process" -
    # observed, not theorised, the first time a source file was saved while the
    # suite was running.
    #
    # IMPORTING IS WHAT BUILDS IT, so this line is the rebuild. It costs the
    # 1.37s the bundle exists to save and it happens once.
    #
    # A SOURCE SAVED AFTER THIS POINT can still race. Closing that properly means
    # an atomic write inside Write-HDTModuleBundle - temp file plus move - rather
    # than a wider window here.
    Import-Module -Name $script:HDTModuleManifest -Force -ErrorAction Stop

    $shardScript = Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'tests/helpers/HDTTestShard.ps1'
    $hostPath = (Get-Process -Id $PID).Path

    Write-Information ("test: {0} file(s) across {1} worker(s) of {2}" -f $file.Count, $bucket.Count, $hostPath)

    $shard = @()
    for ($i = 0; $i -lt $bucket.Count; $i++) {
        $listPath = Join-Path -Path $shardDirectory -ChildPath ('list-{0}.txt' -f $i)
        Set-Content -LiteralPath $listPath -Value $bucket[$i] -Encoding UTF8

        $summaryPath = Join-Path -Path $shardDirectory -ChildPath ('summary-{0}.clixml' -f $i)
        $shardResult = Join-Path -Path $resultDirectory -ChildPath (
            '{0}-shard{1}of{2}.xml' -f [IO.Path]::GetFileNameWithoutExtension($ResultPath), ($i + 1), $bucket.Count)

        $argument = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $shardScript,
            '-ListPath', $listPath,
            '-SummaryPath', $summaryPath,
            '-DurationPath', (Join-Path -Path $shardDirectory -ChildPath ('duration-{0}.csv' -f $i)),
            '-ResultPath', $shardResult,
            '-Verbosity', $OutputVerbosity
        )

        $errorPath = Join-Path -Path $shardDirectory -ChildPath ('err-{0}.log' -f $i)

        $process = Start-Process -FilePath $hostPath -ArgumentList $argument -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path -Path $shardDirectory -ChildPath ('out-{0}.log' -f $i)) `
            -RedirectStandardError $errorPath

        # -PassThru RETURNING NOTHING IS ITS OWN DEFECT. Stored unchecked it
        # reaches Wait-Process as a null InputObject, which is terminating under
        # $ErrorActionPreference = 'Stop' and names neither the shard nor the
        # cause - and leaves the workers that DID start running detached.
        if ($null -eq $process) {
            throw ("Worker {0} of {1} could not be started ({2}), so its {3} file(s) would not have run." -f
                ($i + 1), $bucket.Count, $hostPath, @($bucket[$i]).Count)
        }

        $shard += [pscustomobject] @{
            Process     = $process
            SummaryPath = $summaryPath
            ErrorPath   = $errorPath
            ListPath    = $listPath
            FileCount   = @($bucket[$i]).Count
        }
    }

    # NO WORKER OUTLIVES THE BUILD THAT STARTED IT. Start-Process children are
    # in no job object, so a throw between here and the end of the wait would
    # leave up to eight suites running detached - writing into out/ and into the
    # scratch paths the NEXT build is about to clear, which is a machine for
    # manufacturing exactly the "died mid-write" symptom being diagnosed.
    try {
        $null = $shard | ForEach-Object { $_.Process } | Wait-Process
    } finally {
        foreach ($item in $shard) {
            if (-not $item.Process.HasExited) {
                Stop-Process -Id $item.Process.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # A MISSING SUMMARY IS PASSED THROUGH AS $null ON PURPOSE.
    # Merge-HDTPesterSummary is what turns that into a failure, so that the
    # decision lives next to the counts it would otherwise have been folded into.
    #
    # AND THE REASON TRAVELS WITH IT. The stderr of a dead worker was captured
    # and never read: eight workers died on one Import-Module, every err-N.log
    # said so in plain English, and the build printed "worker 1 of 8 did not
    # report a result". Invoke-HDTShardedLint has read its logs from the start;
    # this is the half that was missing.
    $summary = @()
    $reason = @()

    foreach ($item in $shard) {
        # .ExitCode THROWS on a process that has not exited, and a worker this
        # function had to stop in the finally above may not have done so yet.
        # An unknown code is a fact the reason can state; an exception here
        # would replace the diagnosis with itself.
        $exitCode = $null
        try {
            $exitCode = $item.Process.ExitCode
        } catch {
            $exitCode = $null
        }

        $result = $null
        $failure = ''

        if (Test-Path -LiteralPath $item.SummaryPath -PathType Leaf) {
            # TEST-PATH IS NOT READABILITY. A worker killed part way through
            # Export-Clixml leaves a truncated document, and an unguarded import
            # throws raw XML out of build.ps1 instead of the sentence the merge
            # exists to produce. Both cases funnel into the same named path.
            try {
                $result = Import-Clixml -LiteralPath $item.SummaryPath
            } catch {
                $result = $null
                $failure = "its summary '{0}' could not be read ({1}), so it was killed part way through writing it. {2}" -f
                $item.SummaryPath, $_.Exception.Message, (Get-HDTShardFailureReason -ErrorPath $item.ErrorPath -ExitCode $exitCode)
            }
        } else {
            # WHAT IT WAS GIVEN FIRST, WHAT IT SAID LAST. The stderr quote is
            # several lines and ends the sentence; anything appended after it
            # runs into the last line of a stack trace.
            $failure = 'it was given {0} file(s), listed in ''{1}''. {2}' -f
            $item.FileCount, $item.ListPath, (Get-HDTShardFailureReason -ErrorPath $item.ErrorPath -ExitCode $exitCode)
        }

        $summary += , $result
        $reason += $failure
    }

    # THE TIMINGS SURVIVE THE RUN. Copied rather than written here directly, so
    # a second build racing this one can only ever replace a whole file with
    # another whole file - and the worst a mixed pair costs is a slightly worse
    # pack next time.
    foreach ($csv in @(Get-ChildItem -Path $shardDirectory -Filter 'duration-*.csv' -File -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $csv.FullName -Destination (Join-Path -Path $timingDirectory -ChildPath $csv.Name) `
            -Force -ErrorAction SilentlyContinue
    }

    return Merge-HDTPesterSummary -Summary $summary -Reason $reason
}

function Write-HDTBuildBadge {
    <#
        .SYNOPSIS
            Writes the two shields.io badge documents the README renders.

        .DESCRIPTION
            THE NUMBERS COME FROM THE RUN THAT PRODUCED THEM. out/badges/ holds
            tests.json and coverage.json; CI pushes them to the orphan `badges`
            branch and the README points shields.io at their raw URL. Nothing
            signs up for a coverage service and no token is stored.

            IT IS HERE RATHER THAN IN THE WORKFLOW because CI must never grow
            its own private build logic (DESIGN 12.2.5): `./build.ps1 -Task ci
            -Coverage` produces exactly what the runner uploads, so the badges
            can be reproduced locally by running the same line.

        .PARAMETER Result
            The object Invoke-Pester -PassThru returned.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes two files into the build output directory. New-HDTBadgeFile, which does the writing, carries ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Result
    )

    $badgeDirectory = Join-Path -Path $script:HDTOutputPath -ChildPath 'badges'

    # A FILE THAT COULD NOT BE DISCOVERED COUNTS AS A FAILURE HERE TOO, for the
    # reason Assert-HDTPesterResult spells out: no test failing is not the same
    # as every test passing.
    $failed = [int] $Result.FailedCount + [int] $Result.FailedContainersCount

    if ($failed -gt 0) {
        $testMessage = '{0} failed, {1} passed' -f $failed, $Result.PassedCount
        $testColor = 'red'
    } else {
        $testMessage = '{0} passed' -f $Result.PassedCount
        $testColor = 'brightgreen'
    }

    New-HDTBadgeFile -Path (Join-Path -Path $badgeDirectory -ChildPath 'tests.json') `
        -Label 'tests' -Message $testMessage -Color $testColor

    # Pester reports CoveragePercent only when coverage actually ran; a suite
    # that died in discovery has no coverage object at all.
    $percent = $null
    if ($null -ne $Result.CodeCoverage) {
        $percent = [double] $Result.CodeCoverage.CoveragePercent
    }

    # NO COVERAGE DOCUMENT WHEN NO COVERAGE RAN, and specifically not a grey
    # "unknown" one: the badges branch already carries a real number from the
    # nightly run, and overwriting it with "unknown" on every push would make
    # the front page report the LAST run rather than the last measurement.
    if ($null -eq $percent) {
        Write-Information 'badge: tests only - this run measured no coverage, so the coverage badge is left as it was'
        return
    }

    $rounded = [math]::Round($percent, 1)

    New-HDTBadgeFile -Path (Join-Path -Path $badgeDirectory -ChildPath 'coverage.json') `
        -Label 'coverage' -Message ('{0}%' -f $rounded) -Color (Get-HDTBadgeColor -Percent $percent)

    Write-Information ("coverage: {0}% of {1} command(s) in src/Hephaestus -> {2}" -f
        $rounded, $Result.CodeCoverage.CommandsAnalyzedCount, (Join-Path -Path $script:HDTOutputPath -ChildPath 'coverage/coverage.xml'))
}

function Assert-HDTPesterResult {
    <#
        .SYNOPSIS
            Throws unless a Pester run both ran and passed.

        .DESCRIPTION
            FailedCount IS NOT ENOUGH, and 05-06 found out the expensive way.

            A file whose DISCOVERY fails - the commonest cause being SPIKES
            S9.15's trap, a `-Skip:` reading a variable that only BeforeAll sets,
            which throws under the StrictMode this script sets - is not run at
            all. Pester drops the tests it could not discover and reports:

                Result Failed   FailedCount 0   FailedContainersCount 1

            FailedCount is zero because no test failed. No test failed because
            most of the file was never discovered. Judged by FailedCount alone
            the build prints BUILD SUCCEEDED over a suite whose assertions never
            ran, which is the same class of defect as the empty dispatch the
            header of tests/unit/BuildScript.Tests.ps1 describes: a build that
            ran nothing is not a build that succeeded.

            IT NAMES THE FILE. "1 container failed" without a path sends the
            operator to read three suites; the error record Pester attaches to
            the container is the only thing that says where and why.

        .PARAMETER Result
            The object Invoke-Pester -PassThru returned.

        .PARAMETER Suite
            test, integration or e2e - what the message calls the run.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Result,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Suite
    )

    if ($Result.FailedContainersCount -gt 0) {
        $detail = @($Result.Containers |
                Where-Object { @($_.ErrorRecord).Count -gt 0 } |
                ForEach-Object {
                    '{0}: {1}' -f $_.Item, (@($_.ErrorRecord | ForEach-Object { [string] $_ }) -join '; ')
                })

        throw ("{0} {1} file(s) could not be run at all - a discovery or setup failure means their assertions never executed, and no test failing is not the same as every test passing. {2}" -f
            $Result.FailedContainersCount, $Suite, ($detail -join ' | '))
    }

    if ($Result.FailedCount -gt 0) {
        throw ("{0} {1} test(s) failed." -f $Result.FailedCount, $Suite)
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

function Test-HDTAdkAvailable {
    <#
        .SYNOPSIS
            True when a Windows ADK with the Windows PE add-on resolves on this
            machine.

        .DESCRIPTION
            Asked through Get-HDTAdkPath rather than by testing a literal path,
            because PROJECT.md's rule is that the ADK layout has moved between
            releases and is resolved at runtime. Both the integration task and the
            e2e task ask it: the first to warn that the boot image file will skip
            itself, the second to decide whether the suite can build its own boot
            vehicle or needs a prebuilt ISO.

            It answers false rather than throwing, because "no ADK" is a fact
            about the machine and both callers have something to say about it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        Import-Module -Name $script:HDTModuleManifest -Force -ErrorAction Stop

        [void] (Get-HDTAdkPath -Asset Oscdimg -ErrorAction Stop)
        [void] (Get-HDTAdkPath -Asset WinPeWim -ErrorAction Stop)

        return $true
    } catch {
        return $false
    }
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

    # THE STAGED MEDIA IS A PRECONDITION OF SOME FILES IN THIS SUITE, NOT OF THE
    # TASK. It was a throw until 05-02, which added an SMB provider file needing
    # a folder and a share and no Windows image at all - and on a machine with no
    # staged media the throw meant the whole task refused to start, so the files
    # that skip themselves correctly never ran either. Every slow file
    # recomputes its own skip condition inside BeforeAll (SPIKES S9.15), so this
    # names what is missing and lets them decide.
    $media = 'C:\HDTLab\media\Win11-LTSC-2024\sources\install.wim'
    if (-not (Test-Path -LiteralPath $media -PathType Leaf)) {
        Write-Warning ("The staged Windows 11 media is not at '{0}' (PROJECT.md, 'Test media - already staged locally'), so the files that apply an image will skip themselves. The rest of tests/integration still runs." -f $media)
    }

    # THE ADK IS A PRECONDITION OF ONE FILE, NOT OF THE TASK, and it is named
    # here for the same reason the media is: BootImage.Integration.Tests.ps1
    # builds a real boot image and skips itself without an ADK, and a suite that
    # skipped silently would be SPIKES S9.15's defect in another costume. A warn
    # rather than a throw, so the disk-only files still run on a machine that has
    # no ADK.
    if (-not (Test-HDTAdkAvailable)) {
        Write-Warning "The Windows ADK (Deployment Tools + Windows PE add-on) does not resolve on this machine, so tests/integration/BootImage.Integration.Tests.ps1 will skip itself. Install it, or run Get-HDTAdkPath -All to see which assets are missing. The rest of tests/integration still runs."
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

    Assert-HDTPesterResult -Result $result -Suite 'integration'
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
            C:\HDTLab\vms and stay under 12 GB combined. No VM outside that
            prefix is touched. The helpers in tests/helpers/HDTTestTools enforce all of
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

    # EITHER ROUTE TO A BOOT VEHICLE IS ENOUGH, and until 05-04 only one of them
    # existed. This precondition used to REQUIRE SPIKES S1/S3's hand-built ISO,
    # and its own error message called a boot image built from code a future
    # milestone. That is no longer true - Update-HDTBootImage exists, the e2e
    # suite can build its own boot vehicle with it, and a task that refused to
    # start unless a spike artifact was present would make the code that replaced
    # the spike unrunnable. BuildScript.Tests.ps1 asserts, by parsing this
    # function, that the old sentence has not come back.
    $iso = 'C:\HDTLab\scratch\pe\HDTPE_x64_uefi.iso'
    if (-not (Test-HDTAdkAvailable) -and -not (Test-Path -LiteralPath $iso -PathType Leaf)) {
        throw ("The 'e2e' task needs a WinPE boot vehicle and has neither route to one. Either install the Windows ADK with the Windows PE add-on, so the suite can build a boot image with Update-HDTBootImage (check with Get-HDTAdkPath -All), or put a prebuilt ISO at '{0}' (SPIKES.md S1/S3)." -f $iso)
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

    Assert-HDTPesterResult -Result $result -Suite 'end-to-end'
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

# WHAT ci MEANS. These seven, and only these seven. integration and e2e are
# accepted tasks but are deliberately absent from this list, so 'ci' never
# expands to a run that needs elevation, a disk or Hyper-V.
$canonicalOrder = @('clean', 'version', 'bundle', 'build', 'lint', 'test', 'selfcheck')

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
            'version' { Invoke-HDTVersion }
            'bundle' { Invoke-HDTBundle }
            'build' { Invoke-HDTBuild }
            'lint' { Invoke-HDTLint -Worker (Get-HDTWorkerCount -Requested $Worker) }
            'test' { Invoke-HDTTest -OutputVerbosity $Verbosity -Coverage:$Coverage -Worker (Get-HDTWorkerCount -Requested $Worker) }
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
