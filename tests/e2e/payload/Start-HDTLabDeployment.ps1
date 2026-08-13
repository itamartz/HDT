<#
    .SYNOPSIS
        Starts a task sequence inside WinPE from a locally attached content
        disk, and shuts the machine down when it ends.

    .DESCRIPTION
        THE PHASE-04 STAND-IN FOR PHASE 05's Start-HDTDeployment.ps1, and
        nothing more. It wires the real service adapters, resolves variables,
        builds a context and calls Invoke-HDTTaskSequence ONCE.

        IT CONTAINS NO DEPLOYMENT LOGIC, AND THAT IS THE POINT. ROADMAP M3's
        exit criterion is "a VM boots into Windows from a sequence run
        end-to-end". A launcher that partitioned a disk itself, or applied an
        image itself, would make that claim a lie - so
        tests/unit/StartHDTLabDeploymentPayload.Tests.ps1 parses this file and
        asserts that it names no Storage cmdlet, no DISM cmdlet, no bcdboot,
        bcdedit, reagentc or diskpart, and calls Invoke-HDTTaskSequence exactly
        once.

        WHY A CONTENT DISK RATHER THAN A SHARE. PROJECT.md requires the isolated
        'HDT Lab' switch, and SPIKES S6 records that a VM on an isolated switch
        cannot reach a share on the host. A locally attached disk removes SMB,
        DHCP and the host firewall from the exit criterion, so a failure means
        the imaging code failed. It is also DESIGN 6.2's Local provider shape.

        SIX THINGS, IN THIS ORDER:

          1. Find the content drive - WinPE's letter assignment is not
             guaranteed - put its Modules folder on PSModulePath, and import
             powershell-yaml AND Hephaestus, LOGGING THE VERSION OF EACH. That
             logging is the WinPE dependency proof: ConvertFrom-HDTYaml goes
             through powershell-yaml, so a WinPE that cannot load it cannot read
             a sequence at all.
          2. Build the real adapters.
          3. Get-HDTMachineFact -> Resolve-HDTVariable against the workspace's
             rules.yaml and the sequence's own defaults.
          4. New-HDTLogContext, New-HDTRunState, New-HDTExecutionContext.
          5. ONE call to Invoke-HDTTaskSequence, with -LogDestination pointing
             into the content disk so the whole log survives the shutdown.
          6. Write RESULT.json and shut down with wpeutil, which is how the
             harness knows the run ended rather than guessing at a duration.

        EVERY FAILURE STILL WRITES RESULT.json AND STILL SHUTS DOWN. A VM left
        sitting at a WinPE prompt tells the harness nothing except that its
        timeout expired.

    .PARAMETER ContentRoot
        The root of the content disk. Found by scanning for HDT\Modules when
        omitted, because WinPE does not guarantee drive letters.

    .PARAMETER SequenceId
        The task sequence to run.

    .PARAMETER LogRoot
        Where the live log goes. X:\ is WinPE's RAM disk, which is fast and
        disappears - the log is copied to the content disk at the end through
        -LogDestination.

    .EXAMPLE
        powershell -ExecutionPolicy Bypass -File D:\HDT\Start-HDTLabDeployment.ps1

        What the harness types at the WinPE prompt.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [AllowEmptyString()]
    [string] $ContentRoot = '',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $SequenceId = 'DEMO-M3',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $LogRoot = 'X:\HDT\Logs'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Visible at the WinPE console without Write-Host, which the analyzer refuses.
# Write-Information renders to the host under 5.1 when the preference says so.
$InformationPreference = 'Continue'

$runId = 'run-{0:yyyyMMdd-HHmmss}' -f (Get-Date)
$started = Get-Date
$transcript = New-Object -TypeName System.Collections.ArrayList

$say = {
    param([string] $Message)

    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    [void] $transcript.Add($line)
    Write-Information $line
}

# -- 1. the content disk, and the two modules ---------------------------------
#
# WinPE assigns letters in an order nothing here may assume, so the disk is
# found by looking for what is on it.

if ([string]::IsNullOrWhiteSpace($ContentRoot)) {
    foreach ($letter in @('C', 'D', 'E', 'F', 'G', 'H')) {
        if (Test-Path -LiteralPath ('{0}:\HDT\Modules\Hephaestus' -f $letter)) {
            $ContentRoot = '{0}:\' -f $letter
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ContentRoot)) {
    & $say 'FATAL: no content disk carrying HDT\Modules\Hephaestus was found.'
    Start-Sleep -Seconds 5
    & "$env:SystemRoot\System32\wpeutil.exe" shutdown
    exit 1
}

& $say ("content root: {0}" -f $ContentRoot)

$modulePath = Join-Path -Path $ContentRoot -ChildPath 'HDT\Modules'
$env:PSModulePath = '{0};{1}' -f $modulePath, $env:PSModulePath

$workspaceRoot = Join-Path -Path $ContentRoot -ChildPath 'Share'
$shareLogRoot = Join-Path -Path $workspaceRoot -ChildPath 'Logs'

$result = [ordered] @{
    runId        = $runId
    sequenceId   = $SequenceId
    status       = 'Failed'
    failedStep   = ''
    message      = ''
    computerName = ''
    yamlVersion  = ''
    yamlLoaded   = $false
    psVersion    = [string] $PSVersionTable.PSVersion
    contentRoot  = $ContentRoot
    engineVersion = ''
    elapsedSecond = 0
    diskBefore    = @()
}

try {
    # POWERSHELL-YAML FIRST. ConvertFrom-HDTYaml imports it lazily and reports
    # HDTDependencyError when it is absent, so the engine cannot read a single
    # YAML document without it. Whether it loads inside WinPE had never been
    # tested before this run.
    Import-Module -Name 'powershell-yaml' -Force -ErrorAction Stop
    $yaml = @(Get-Module -Name 'powershell-yaml')[0]
    $result['yamlLoaded'] = $true
    $result['yamlVersion'] = [string] $yaml.Version
    & $say ("powershell-yaml {0} loaded from {1}" -f $yaml.Version, $yaml.ModuleBase)

    Import-Module -Name 'Hephaestus' -Force -ErrorAction Stop
    $engine = @(Get-Module -Name 'Hephaestus')[0]
    $result['engineVersion'] = [string] $engine.Version
    & $say ("Hephaestus {0} loaded from {1}" -f $engine.Version, $engine.ModuleBase)

    # -- 2. the real adapters -------------------------------------------------
    #
    # A fake never appears in this file. This is the one place the real ones are
    # built, which is the whole point of the injection.

    $fileSystem = New-HDTFileSystem
    $clock = New-HDTClock
    $diskService = New-HDTDiskService
    $imageService = New-HDTImageService
    $registry = New-HDTRegistryService
    $environment = New-HDTEnvironmentProvider
    $cim = New-HDTCimProvider
    $processService = New-HDTProcessService
    $power = New-HDTPowerService
    $scriptInvoker = New-HDTScriptInvoker -Root $workspaceRoot

    $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Registry $registry `
        -Process $processService -Power $power -ScriptInvoker $scriptInvoker -Cim $cim `
        -Environment $environment -Disk $diskService -Image $imageService

    # THE DISKS AS THIS MACHINE HAD THEM BEFORE HDT TOUCHED ANYTHING, read
    # through IDiskService - which is exactly the eleven-property projection
    # tests/fixtures/disk/*.json use. This is the honest capture that replaces
    # the derived gen2-vm-raw-disk.json: a Generation 2 VM's virgin 64 GB disk,
    # taken by HDT's own adapter, a moment before the deployment repartitions
    # it. It is a READ; the launcher still performs no deployment work.
    $result['diskBefore'] = @($diskService.GetDisk())
    foreach ($row in @($result['diskBefore'])) {
        & $say ("  disk {0} {1} {2} bytes bus={3} style={4} boot={5} system={6}" -f
            $row.Number, $row.FriendlyName, $row.SizeBytes, $row.BusType,
            $row.PartitionStyle, $row.IsBoot, $row.IsSystem)
    }

    # -- 3. facts, then rules -------------------------------------------------

    & $say 'gathering machine facts'
    $fact = Get-HDTMachineFact -CimProvider $cim -RegistryService $registry -EnvironmentProvider $environment
    & $say ("{0} facts gathered; model '{1}', UEFI {2}, memory {3} MB" -f
        $fact.Count, [string] $fact['HDTModel'], [string] $fact['HDTIsUEFI'], [string] $fact['HDTMemory'])

    $sequencePath = Get-HDTWorkspacePath -Root $workspaceRoot -Kind TaskSequences -ChildPath $SequenceId, 'sequence.yaml'
    $sequence = Import-HDTSequenceDocument -Path $sequencePath -FileSystem $fileSystem
    & $say ("sequence '{0}' imported: {1} step(s)" -f $sequence.Id, @($sequence.Step).Count)

    $rulePath = Join-Path -Path $workspaceRoot -ChildPath 'rules.yaml'
    $ruleDocument = $null
    if ($fileSystem.TestPath($rulePath)) {
        $ruleDocument = Import-HDTRuleDocument -Path $rulePath -FileSystem $fileSystem
        & $say ("rules.yaml imported: {0} rule(s)" -f @($ruleDocument.Rule).Count)
    }

    $sequenceDefault = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($sequence.Variable.Keys)) {
        $sequenceDefault[[string] $name] = $sequence.Variable[$name]
    }

    $resolved = Resolve-HDTVariable -RuleDocument $ruleDocument -Fact $fact `
        -SequenceDefault $sequenceDefault -ScriptInvoker $scriptInvoker

    $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($resolved.Variable.Keys)) {
        $variable[[string] $name] = $resolved.Variable[$name]
    }

    $result['computerName'] = [string] $variable['HDTComputerName']
    & $say ("HDTComputerName resolved to '{0}'" -f $result['computerName'])

    # -- 4. the context -------------------------------------------------------

    $fileSystem.CreateDirectory($LogRoot)
    $fileSystem.CreateDirectory($shareLogRoot)

    $log = New-HDTLogContext -RunId $runId -Phase WinPE -LogPath $LogRoot `
        -FileSystem $fileSystem -Clock $clock -Level Debug

    $state = New-HDTRunState -SequenceId $sequence.Id -RunId $runId -Phase WinPE `
        -Clock $clock -Variable $variable -Step $sequence.Step

    $context = New-HDTExecutionContext -RunId $runId -Phase WinPE -WorkspaceRoot $workspaceRoot `
        -Variable $variable -Service $catalog -Log $log -State $state

    # -- 5. ONE call to the engine -------------------------------------------

    # -LogDestination IS THE LOG ROOT, NOT THE RUN FOLDER. Copy-HDTLog appends
    # <ComputerName>-<RunId> itself, from HDTComputerName - so passing a folder
    # that already carries it would nest one inside another, and the harness
    # would go looking for HDT.jsonl in the wrong place.
    & $say 'running the task sequence'
    $run = Invoke-HDTTaskSequence -Sequence $sequence -Context $context -State $state `
        -StatePath (Join-Path -Path $LogRoot -ChildPath 'state.json') `
        -LogDestination $shareLogRoot

    $result['status'] = [string] $run.Status
    & $say ("sequence finished: {0}" -f $run.Status)

    foreach ($step in @($run.Result)) {
        & $say ("  step {0} {1}: {2}" -f $step.Index, $step.Name, $step.Status)

        if ([string] $step.Status -eq 'Failed' -and [string]::IsNullOrEmpty([string] $result['failedStep'])) {
            $result['failedStep'] = [string] $step.Name
            $result['message'] = [string] $step.Message
        }
    }
} catch {
    $result['status'] = 'Failed'
    $result['message'] = [string] $_.Exception.Message
    & $say ("FATAL: {0}" -f $_.Exception.Message)
    & $say ([string] ($_ | Out-String))
}

# -- 6. the result, and the shutdown that tells the harness it ended ----------

$result['elapsedSecond'] = [int] ((Get-Date) - $started).TotalSeconds

try {
    # AT THE ROOT OF Logs\, one file, whatever happened. The engine's own log
    # folder is named after a computer name this run may never have resolved -
    # a run that died before Resolve-HDTVariable has no such name - and the
    # harness must always know where to look.
    $destination = $shareLogRoot
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        New-Item -Path $destination -ItemType Directory -Force | Out-Null
    }

    # UTF-8 WITHOUT A BOM, EXPLICITLY. SPIKES S6's third finding: Tee-Object
    # defaults to UTF-16 under 5.1, producing logs half the tooling cannot read.
    $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

    [System.IO.File]::WriteAllText((Join-Path -Path $destination -ChildPath 'RESULT.json'),
        (ConvertTo-Json -InputObject $result -Depth 4), $utf8)

    [System.IO.File]::WriteAllLines((Join-Path -Path $destination -ChildPath 'LAUNCHER.log'),
        [string[]] @($transcript), $utf8)
} catch {
    Write-Information ("could not write RESULT.json: {0}" -f $_.Exception.Message)
}

Start-Sleep -Seconds 5

# HOW THE HARNESS KNOWS THE RUN ENDED. Whatever happened above, the machine goes
# off, and Wait-HDTLabVmState -State Off returns.
& "$env:SystemRoot\System32\wpeutil.exe" shutdown

exit 0
