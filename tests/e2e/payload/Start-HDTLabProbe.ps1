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

        Everything is written to PROBE.json on the content disk, and the machine
        shuts down - so the harness reads a file rather than a screenshot.

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

$probe = [ordered] @{
    psVersion       = [string] $PSVersionTable.PSVersion
    psEdition       = [string] $PSVersionTable.PSEdition
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
Write-Host ("content root: {0}" -f $ContentRoot)

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

Write-Host ("powershell-yaml loaded: {0} {1}" -f $probe['yamlLoaded'], $probe['yamlVersion'])

try {
    Import-Module -Name 'Hephaestus' -Force -ErrorAction Stop
    $engine = @(Get-Module -Name 'Hephaestus')[0]
    $probe['engineLoaded'] = $true
    $probe['engineVersion'] = [string] $engine.Version
} catch {
    $probe['engineError'] = [string] $_.Exception.Message
}

Write-Host ("Hephaestus loaded: {0} {1}" -f $probe['engineLoaded'], $probe['engineVersion'])

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

Write-Host ("facts: {0}" -f $probe['factCount'])

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

Write-Host ("sequence: '{0}' with {1} step(s)" -f $probe['sequenceId'], $probe['sequenceStep'])
Write-Host ("rules: {0}" -f $probe['ruleCount'])

# -- the answer, on the content disk ------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($ContentRoot)) {
    try {
        $out = Join-Path -Path $ContentRoot -ChildPath 'PROBE.json'

        # UTF-8 without a BOM (SPIKES S6's third finding).
        $utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($out, (ConvertTo-Json -InputObject $probe -Depth 6), $utf8)

        Write-Host ("wrote {0}" -f $out)
    } catch {
        Write-Host ("could not write PROBE.json: {0}" -f $_.Exception.Message)
    }
}

Start-Sleep -Seconds 5

& "$env:SystemRoot\System32\wpeutil.exe" shutdown

exit 0
