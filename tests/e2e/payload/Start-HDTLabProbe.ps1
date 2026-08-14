<#
    .SYNOPSIS
        The WinPE smoke check: does the engine load and work inside WinPE at
        all?

    .DESCRIPTION
        RUN BEFORE THE DEPLOYMENT, DELIBERATELY. Everything phase 04 built is
        asserted against fakes on a developer machine running pwsh 7. This
        script is the first time any of it executes inside WinPE, and it answers
        five questions that the deployment depends on but does not isolate:

          1. What PowerShell is in this WinPE? (SPIKES S1 said 5.1.26100.1.)
          2. DOES powershell-yaml LOAD? This is the one most likely to fail and
             the most damaging if it does. ConvertFrom-HDTYaml imports it lazily
             and reports HDTDependencyError when it is absent, so a WinPE that
             cannot load the parser cannot read a sequence, and ROADMAP M3's
             exit criterion - "a VM boots into Windows FROM A SEQUENCE RUN" -
             cannot be met at all. Its lib\ carries net47 and netstandard2.1
             flavours; under 5.1 it loads net47, which needs .NET Framework
             4.7+, and SPIKES S1's image carries WinPE-NetFx (4.8). Expected to
             work. Expected is not verified.
          3. Does Get-HDTMachineFact work against the REAL CIM provider,
             registry and environment - phase 02's gatherer, in its actual home?
          4. What does Get-Disk report for a Generation 2 VM's virgin disk?
             SPIKES S6 recorded BusType SAS and PartitionStyle RAW from a hand
             run; tests/fixtures/disk/gen2-vm-raw-disk.json has been DERIVED
             from that note rather than captured, and this closes the debt.
          5. Do Import-HDTSequenceDocument and Import-HDTRuleDocument actually
             return documents? Loading the parser module is necessary but not
             sufficient, and proving the sufficient thing costs two more lines.
          6. ADDED IN 05-06: is shutdown.exe here at all, and does
             New-HDTPowerService work? ROADMAP M2 deferred "does WinPE need
             wpeutil reboot rather than shutdown.exe" to phase 05 and five plans
             went by with New-HDTPowerService never once executed anywhere. This
             machine is a WinPE that is about to power itself off; there is no
             cheaper place to run the one adapter in HDT that ends machines.

        Everything is written to PROBE.json on the content disk, and the machine
        shuts down - so the harness reads a file rather than a screenshot.

        HOW IT ENDS, AND WHY THAT IS AN ASSERTION. The machine is powered off BY
        New-HDTPowerService, not by a wpeutil line of its own. A direct call is
        kept as a bounded fallback so a broken adapter produces a fast, readable
        failure instead of a fifteen-minute timeout - and the fallback WRITES
        FALLBACK.txt BEFORE it fires. The harness asserts that file is ABSENT,
        which is what makes "the service did it" a fact rather than a
        coincidence of a machine that was going to power off anyway.

        NOTHING HERE IS DESTRUCTIVE. It reads. The smoke VM is given exactly one
        small disk so there is nothing on it that could be mistaken for a
        deployment target even if something did try.

    .PARAMETER ContentRoot
        The content disk. Found by scanning when omitted.

    .EXAMPLE
        powershell -ExecutionPolicy Bypass -File D:\HDT\Start-HDTLabProbe.ps1
#>
[CmdletBinding()]
param(
    [Parameter()]
    [AllowEmptyString()]
    [string] $ContentRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# Visible at the WinPE console without Write-Host, which the analyzer refuses
# and which is not needed: Write-Information renders to the host under 5.1 when
# the preference says so, and the console is the only place anyone is watching.
$InformationPreference = 'Continue'

$probe = [ordered] @{
    psVersion       = [string] $PSVersionTable.PSVersion
    psEdition       = [string] $PSVersionTable.PSEdition

    # THE GUEST'S OWN STATEMENT ABOUT WHO STARTED IT. startnet.cmd sets
    # HDT_LAUNCHED_BY=startnet before it launches anything; a human typing the
    # command at the WinPE prompt does not. This is what makes "nothing types"
    # an assertion about the machine rather than about the harness source.
    launchedBy      = [string] $env:HDT_LAUNCHED_BY

    contentRoot     = ''
    yamlLoaded      = $false
    yamlVersion     = ''
    yamlBase        = ''
    yamlError       = ''
    engineLoaded    = $false
    engineVersion   = ''
    engineError     = ''
    factCount       = 0
    fact            = @{}
    factError       = ''
    disk            = @()
    diskError       = ''
    sequenceId      = ''
    sequenceStep    = 0
    sequenceError   = ''
    ruleCount       = -1
    ruleError       = ''
    osCatalogId     = ''
    osCatalogError  = ''
    shutdownExe     = $false
    wpeutilExe      = $false
    powerEnvironment = ''
    powerCommand    = ''
    powerArgument   = ''
    powerError      = ''
}

if ([string]::IsNullOrWhiteSpace($ContentRoot)) {
    foreach ($letter in @('C', 'D', 'E', 'F', 'G', 'H')) {
        if (Test-Path -LiteralPath ('{0}:\HDT\Modules\Hephaestus' -f $letter)) {
            $ContentRoot = '{0}:\' -f $letter
            break
        }
    }
}

$probe['contentRoot'] = $ContentRoot
Write-Information ("content root: {0}" -f $ContentRoot)

if (-not [string]::IsNullOrWhiteSpace($ContentRoot)) {
    $env:PSModulePath = '{0};{1}' -f (Join-Path -Path $ContentRoot -ChildPath 'HDT\Modules'), $env:PSModulePath
}

# -- 2. the question that matters ---------------------------------------------

try {
    Import-Module -Name 'powershell-yaml' -Force -ErrorAction Stop
    $yaml = @(Get-Module -Name 'powershell-yaml')[0]
    $probe['yamlLoaded'] = $true
    $probe['yamlVersion'] = [string] $yaml.Version
    $probe['yamlBase'] = [string] $yaml.ModuleBase
} catch {
    $probe['yamlError'] = [string] $_.Exception.Message
}

Write-Information ("powershell-yaml loaded: {0} {1}" -f $probe['yamlLoaded'], $probe['yamlVersion'])

try {
    Import-Module -Name 'Hephaestus' -Force -ErrorAction Stop
    $engine = @(Get-Module -Name 'Hephaestus')[0]
    $probe['engineLoaded'] = $true
    $probe['engineVersion'] = [string] $engine.Version
} catch {
    $probe['engineError'] = [string] $_.Exception.Message
}

Write-Information ("Hephaestus loaded: {0} {1}" -f $probe['engineLoaded'], $probe['engineVersion'])

# -- 3. phase 02's gatherer, in its actual home -------------------------------

if ($probe['engineLoaded']) {
    try {
        $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
            -RegistryService (New-HDTRegistryService) `
            -EnvironmentProvider (New-HDTEnvironmentProvider)

        $probe['factCount'] = @($fact.Keys).Count

        $flat = @{}
        foreach ($name in @($fact.Keys)) {
            $value = $fact[$name]
            if ($value -is [array]) { $value = ($value -join ',') }
            $flat[[string] $name] = [string] $value
        }
        $probe['fact'] = $flat
    } catch {
        $probe['factError'] = [string] $_.Exception.Message
    }
}

Write-Information ("facts: {0}" -f $probe['factCount'])

# -- 4. the disk row this repository has only ever derived --------------------

try {
    # The eleven documented GetDisk properties, in the projection
    # tests/fixtures/disk/host-nvme-disk.json uses.
    $probe['disk'] = @(Get-Disk | Select-Object Number, FriendlyName,
        @{ n = 'SerialNumber'; e = { 'FIXTURE-SERIAL-0001' } },
        @{ n = 'SizeBytes'; e = { [long] $_.Size } },
        BusType, PartitionStyle, IsBoot, IsSystem, IsReadOnly, IsOffline, OperationalStatus)
} catch {
    $probe['diskError'] = [string] $_.Exception.Message
}

# -- 5. documents actually coming back ---------------------------------------

if ($probe['engineLoaded'] -and -not [string]::IsNullOrWhiteSpace($ContentRoot)) {
    $workspaceRoot = Join-Path -Path $ContentRoot -ChildPath 'Share'
    $fileSystem = New-HDTFileSystem

    try {
        $sequencePath = Get-HDTWorkspacePath -Root $workspaceRoot -Kind TaskSequences -ChildPath 'DEMO-M3', 'sequence.yaml'
        $sequence = Import-HDTSequenceDocument -Path $sequencePath -FileSystem $fileSystem
        $probe['sequenceId'] = [string] $sequence.Id
        $probe['sequenceStep'] = @($sequence.Step).Count
    } catch {
        $probe['sequenceError'] = [string] $_.Exception.Message
    }

    try {
        $rule = Import-HDTRuleDocument -Path (Join-Path -Path $workspaceRoot -ChildPath 'rules.yaml') -FileSystem $fileSystem
        $probe['ruleCount'] = @($rule.Rule).Count
    } catch {
        $probe['ruleError'] = [string] $_.Exception.Message
    }

    try {
        $os = Get-HDTOperatingSystem -WorkspaceRoot $workspaceRoot -Id 'Win11-LTSC-2024' -FileSystem $fileSystem
        $probe['osCatalogId'] = [string] $os.Id
    } catch {
        $probe['osCatalogError'] = [string] $_.Exception.Message
    }
}

Write-Information ("sequence: '{0}' with {1} step(s)" -f $probe['sequenceId'], $probe['sequenceStep'])
Write-Information ("rules: {0}" -f $probe['ruleCount'])

# -- 6. what this WinPE has to end itself with (05-06) ------------------------
#
# MEASURED FROM INSIDE A RUNNING WinPE, which is a better witness than a mounted
# image: tests/integration/WinPeContent.Integration.Tests.ps1 reads the WIM, and
# this reads the machine that WIM became.

$system32 = Join-Path -Path $env:SystemRoot -ChildPath 'System32'
$probe['shutdownExe'] = Test-Path -LiteralPath (Join-Path -Path $system32 -ChildPath 'shutdown.exe') -PathType Leaf
$probe['wpeutilExe'] = Test-Path -LiteralPath (Join-Path -Path $system32 -ChildPath 'wpeutil.exe') -PathType Leaf

Write-Information ("shutdown.exe present: {0}   wpeutil.exe present: {1}" -f $probe['shutdownExe'], $probe['wpeutilExe'])

# The service that will end this machine, built here rather than at the bottom
# so its construction is recorded even if the call goes wrong.
$power = $null

if ($probe['engineLoaded']) {
    try {
        $power = New-HDTPowerService -Environment WinPE
        $probe['powerEnvironment'] = [string] $power.Environment

        # What it is about to run, so PROBE.json says it BEFORE the machine goes.
        # Reached through the module because the decision is private.
        $engineModule = @(Get-Module -Name 'Hephaestus')[0]
        $plan = & $engineModule { Get-HDTPowerCommand -Environment WinPE -Operation Stop -DelaySecond 0 }
        $probe['powerCommand'] = [string] $plan.Command
        $probe['powerArgument'] = (@($plan.Argument) -join ' ')
    } catch {
        $probe['powerError'] = [string] $_.Exception.Message
    }
} else {
    $probe['powerError'] = 'the engine did not load, so there was no power service to build'
}

Write-Information ("power service: {0} {1} ({2})" -f $probe['powerCommand'], $probe['powerArgument'], $probe['powerError'])

# -- the answer, on the content disk ------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($ContentRoot)) {
    try {
        $out = Join-Path -Path $ContentRoot -ChildPath 'PROBE.json'

        # UTF-8 without a BOM (SPIKES S6's third finding).
        $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($out, (ConvertTo-Json -InputObject $probe -Depth 6), $utf8)

        Write-Information ("wrote {0}" -f $out)
    } catch {
        Write-Information ("could not write PROBE.json: {0}" -f $_.Exception.Message)
    }
}

Start-Sleep -Seconds 5

# -- the machine ends, and the service is what ends it ------------------------
#
# THE FIRST EXECUTION OF New-HDTPowerService ANYWHERE. Everything else this
# repository knows about IPowerService comes from a fake; the real adapter's
# contract row is skipped permanently because a contract test may not reboot the
# machine running it. A WinPE VM that is about to power off is the one place the
# call is free.

if ($null -ne $power) {
    try {
        $power.Stop(0)
    } catch {
        # Recorded where a human will see it: PROBE.json is already written.
        Write-Information ("the power service threw: {0}" -f $_.Exception.Message)
    }
}

# THE FALLBACK, AND THE MARKER THAT MAKES IT VISIBLE. wpeutil shutdown takes
# effect in seconds, so reaching this line at all means the service did not end
# the machine. The harness asserts FALLBACK.txt is ABSENT - without it, "the VM
# powered off" would be satisfied by this line and would prove nothing about the
# adapter.
Start-Sleep -Seconds 120

if (-not [string]::IsNullOrWhiteSpace($ContentRoot)) {
    try {
        [System.IO.File]::WriteAllText(
            (Join-Path -Path $ContentRoot -ChildPath 'FALLBACK.txt'),
            ("New-HDTPowerService did not end this machine within 120s; wpeutil was called directly. powerCommand='{0}' powerError='{1}'" -f
                $probe['powerCommand'], $probe['powerError']))
    } catch {
        Write-Information 'could not write FALLBACK.txt'
    }
}

& "$env:SystemRoot\System32\wpeutil.exe" shutdown

exit 0
