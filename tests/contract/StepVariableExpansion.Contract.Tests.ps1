# Every step type expands %Variable% in the properties it reads.
#
# THIS IS A TEST ABOUT THE SET, NOT ABOUT THE STEP THAT WAS BROKEN. Two of the
# twenty step types - CommandLine and PowerShell - read their own properties
# straight out of the bag while the other eighteen went through
# Get-HDTStepProperty -Expand. So `command: echo %HDTOSVolume%` reached the
# process service as the literal string and `script: Scripts\%HDTScriptName%`
# failed naming a file with a percent sign in it. Nothing tested any of it.
#
# A test naming those two properties would pass for them and fail nobody after
# them, so this one is driven by ENUMERATION instead: the table below carries one
# row per step type per string property, and the last test in this file refuses
# a step type that has no row at all. A twenty-first step type turns this file
# red until somebody says what its properties are.
#
# HOW A ROW IS PROVED, and it is why the assertion is not "the log mentions the
# value". Each row is run TWICE against fakes wired to one shared journal and a
# frozen clock:
#
#   the control  the property carries the value itself - drive: 'W:'
#   the probe    the property carries '%HDTExpandProbe%', and the variable
#                HDTExpandProbe is set to that same value
#
# A step that expands cannot tell the two runs apart, so every service call and
# every log line must match. A step that does not expand hands '%HDTExpandProbe%'
# to a service or writes it to the log, and the two runs diverge - which is the
# defect, stated as a difference rather than as a string somebody grepped for.
#
# THE CONTROL MUST BE OBSERVABLE. Both runs matching proves nothing if the step
# refused before it ever read the property, so the control run has to carry the
# value into the journal or the log. That is what stops a row from passing
# because its step type was handed a catalog it could not use.
#
# A TOKEN NOBODY SET IS A SEPARATE MATTER and is NOT tested here: it is left
# standing verbatim on purpose (Expand-HDTVariableToken), so the probe value is
# always one this context resolves. The verbatim rule is covered where it is
# read, in the CommandLine and PowerShell step tests.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') `
    -Force -ErrorAction Stop

# Built at file scope: Pester 5 expands -ForEach while discovering, and a table
# built in a BeforeAll produces zero test cases.
#
# Extra carries whatever else the step needs to reach the property under test -
# a CommandLine step reads `arguments` only when it also has a `file`.
$script:HDTExpansionProbe = @(
    # AsWritten: this step logs BOTH forms on purpose - "this step's group
    # property is '%HDTDriverGroup%', which expanded to 'Win11\Contoso\...'" - so
    # a technician reading the log can see which variable chose the folder. The
    # raw token in that record is the feature, not the defect, so the row is held
    # only to "the expanded value reached the log".
    @{ Type = 'ApplyDrivers'; Key = 'group'; Value = 'Win11\Contoso\Latitude 5540'; Phase = 'WinPE'
        Extra = @{}; AsWritten = $true
    }
    @{ Type = 'ApplyDrivers'; Key = 'target'; Value = 'S:'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'ApplyImage'; Key = 'os'; Value = 'Win11-LTSC-2024'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'ApplyImage'; Key = 'target'; Value = 'S:'; Phase = 'WinPE'; Extra = @{ os = 'Win11-LTSC-2024' } }
    @{ Type = 'ApplyUnattend'; Key = 'template'; Value = 'Unattend\unattend.xml'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'BootToWinPE'; Key = 'bootImage'; Value = 'HDTPE_x64'; Phase = 'FullOS'; Extra = @{ action = 'stage' } }
    @{ Type = 'CaptureImage'; Key = 'image'; Value = 'CONTOSO-REF.wim'; Phase = 'WinPE'; Extra = @{ source = 'C:' } }
    @{ Type = 'CaptureImage'; Key = 'source'; Value = 'D:'; Phase = 'WinPE'; Extra = @{ image = 'CONTOSO-REF.wim' } }
    @{ Type = 'CommandLine'; Key = 'command'; Value = 'setup.exe /quiet'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'CommandLine'; Key = 'file'; Value = 'D:\Applications\setup.exe'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'CommandLine'; Key = 'arguments'; Value = '/quiet /norestart'; Phase = 'WinPE'
        Extra = @{ file = 'D:\Applications\setup.exe' }
    }
    @{ Type = 'CommandLine'; Key = 'workingDirectory'; Value = 'D:\Applications'; Phase = 'WinPE'
        Extra = @{ file = 'D:\Applications\setup.exe' }
    }
    @{ Type = 'ConfigureBoot'; Key = 'firmware'; Value = 'UEFI'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'DiskPartition'; Key = 'layout'; Value = 'uefi-standard'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'EnableBitLocker'; Key = 'drive'; Value = 'S:'; Phase = 'FullOS'; Extra = @{} }
    @{ Type = 'InstallApplications'; Key = 'selection'; Value = 'APP-0001'; Phase = 'FullOS'; Extra = @{} }
    @{ Type = 'InstallCertificate'; Key = 'bootstrap'; Value = 'X:\HDT\contoso-bootstrap.json'; Phase = 'FullOS'; Extra = @{} }
    @{ Type = 'InstallRoles'; Key = 'features'; Value = 'Web-Server'; Phase = 'FullOS'; Extra = @{} }
    @{ Type = 'InstallRoles'; Key = 'source'; Value = 'D:\sources\sxs'; Phase = 'FullOS'
        Extra = @{ features = 'Web-Server' }
    }
    @{ Type = 'NoOp'; Key = 'message'; Value = 'the step said this'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'PowerShell'; Key = 'script'; Value = 'Scripts\Set-ContosoBios.ps1'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'Restart'; Key = 'message'; Value = 'restarting to finish setup'; Phase = 'WinPE'; Extra = @{} }
    @{ Type = 'SetVariable'; Key = 'value'; Value = 'the assigned value'; Phase = 'WinPE'
        Extra = @{ variable = 'HDTProbeTarget' }
    }
    @{ Type = 'Sysprep'; Key = 'unattend'; Value = 'Sysprep\unattend.xml'; Phase = 'FullOS'; Extra = @{} }
    @{ Type = 'Tattoo'; Key = 'path'; Value = 'HKLM:\SOFTWARE\Contoso\Deployment'; Phase = 'FullOS'; Extra = @{} }
    @{ Type = 'Validate'; Key = 'minTpmVersion'; Value = '2.0'; Phase = 'WinPE'; Extra = @{} }
)

# THE ONE TYPE WITH NOTHING TO EXPAND, written down rather than left out, so the
# coverage test below can tell "has no string property" from "nobody wrote a row".
# Gather reads no property at all - it runs the rule engine and publishes what it
# found - and Import-HDTSequenceDocument gives it an empty bag.
$script:HDTNoStringProperty = @('Gather')

Describe 'step property variable expansion' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        # The files a step looks for before it will do anything. The capture
        # exclusion list is the module's own and is found by module path, so it
        # is computed rather than written down.
        $script:probeFile = @{
            'C:\Deploy\OperatingSystems\Win11-LTSC-2024\os.yaml' = @(
                'schemaVersion: 1'
                'id: Win11-LTSC-2024'
                'name: Windows 11 Enterprise LTSC 2024'
                'type: wim'
                'architecture: x64'
                'sourcePath: sources\install.wim'
                "importedUtc: '2026-08-13T09:14:22.0000000Z'"
                'defaultIndex: 1'
                'images:'
                '  - index: 1'
                '    name: Windows 11 Enterprise LTSC'
                '    edition: EnterpriseS'
                '    sizeBytes: 18356832906'
                '    version: 10.0.26100.1742'
            ) -join "`n"
            'C:\Deploy\OperatingSystems\Win11-LTSC-2024\sources\install.wim' = 'wim'
            'C:\Deploy\TaskSequences\PROBE\Unattend\unattend.xml'    = '<unattend />'
            'C:\Deploy\Scripts\Set-ContosoBios.ps1'                  = '# probe'
            'C:\Deploy\Boot\HDTPE_x64.wim'                           = 'wim'
        }
        $script:probeFile[(Join-Path -Path (Split-Path -Parent (Get-Module -Name Hephaestus).Path) `
                    -ChildPath 'Templates\Capture\wimscript.ini')] = '[ExclusionList]'

        # The step type's OWN template is the starting bag, so a probe runs a step
        # shaped the way the engine would author one rather than one this file
        # invented. The template is a YAML fragment, so it goes back through
        # Import-HDTSequenceDocument - the same reader a real sequence uses.
        $script:newTemplateStep = {
            param([string] $Type)

            $row = @(Get-HDTStepType | Where-Object { $_.Type -eq $Type })[0]

            $text = New-Object -TypeName System.Collections.ArrayList
            [void] $text.Add('schemaVersion: 1')
            [void] $text.Add('id: PROBE')
            [void] $text.Add('name: Expansion probe')
            [void] $text.Add('steps:')
            foreach ($one in @(& $row.TemplateCommand.Name)) { [void] $text.Add('  ' + $one) }

            $reader = New-HDTFakeFileSystem -File @{ 'C:\probe\sequence.yaml' = ($text -join "`n") }

            return @((Import-HDTSequenceDocument -Path 'C:\probe\sequence.yaml' -FileSystem $reader).Step)[0]
        }

        # One run of one step type against nothing but fakes, reduced to the text
        # of everything it did: every service call in journal order, then every
        # log record. That text is the whole observable behaviour of the step.
        $script:invokeProbeRun = {
            param([string] $Type, [string] $Phase, [System.Collections.IDictionary] $Property,
                [System.Collections.IDictionary] $Variable)

            $journal = New-Object -TypeName System.Collections.ArrayList

            # THE MACHINE A STEP EXPECTS TO FIND, seeded identically for both
            # runs. Without it most step types refuse before they ever read the
            # property under test - and two runs that both refused for the same
            # unrelated reason would match each other while proving nothing.
            $fileSystem = New-HDTFakeFileSystem -Journal $journal -File $script:probeFile
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 1, 9, 0, 0, [System.DateTimeKind]::Utc)) -Journal $journal

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock `
                -Registry (New-HDTFakeRegistryService -Journal $journal) `
                -Lsa (New-HDTFakeLsaService -Journal $journal) `
                -Process (New-HDTFakeProcessService -Journal $journal) `
                -Power (New-HDTFakePowerService -Journal $journal) `
                -ScriptInvoker (New-HDTFakeScriptInvoker -Journal $journal) `
                -Cim (New-HDTFakeCimProvider -Journal $journal -FixturePath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim')) `
                -Environment (New-HDTFakeEnvironmentProvider -Journal $journal -Variable @{ SystemDrive = 'C:'; SystemRoot = 'C:\Windows' }) `
                -Disk (New-HDTFakeDiskService -Journal $journal -FixturePath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/disk/gen2-vm-raw-disk.json')) `
                -Image (New-HDTFakeImageService -Journal $journal) `
                -Feature (New-HDTFakeFeatureService -Journal $journal -Feature @{ 'Web-Server' = @{ Installed = $false } }) `
                -BitLocker (New-HDTFakeBitLockerService -Journal $journal) `
                -Content (New-HDTFakeContentProvider -Journal $journal)

            # Debug, because the CommandLine step keeps the full command line at
            # Debug on purpose (DESIGN 4.4.5) and that record is where an
            # unexpanded token shows up first.
            $log = New-HDTLogContext -RunId 'run-probe' -Phase $Phase -LogPath 'C:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Debug

            $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }

            # HDTOSVolume is deliberately NOT the value any probe row uses: half
            # the imaging steps fall back to it when their own target is empty,
            # so a row that shared its value would pass whether or not the step
            # read the property at all.
            $scope = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $scope['HDTOSVolume'] = 'W:'
            $scope['HDTSystemVolume'] = 'Y:'
            $scope['HDTTaskSequenceID'] = 'PROBE'
            $scope['HDTDeploymentType'] = 'NEWCOMPUTER'
            foreach ($key in @($Variable.Keys)) { $scope[[string] $key] = $Variable[$key] }

            $context = New-HDTExecutionContext -RunId 'run-probe' -Phase $Phase -WorkspaceRoot 'C:\Deploy' `
                -Variable $scope -Service $catalog -Log $log
            $context.SetStep(1, 'Expansion probe', $Type, 'C:\HDT\Logs\Steps\001-Probe.log')

            $step = [pscustomobject] @{
                Index          = 1
                Name           = 'Expansion probe'
                Type           = $Type
                TimeoutMinutes = 0
                Log            = $null
                Property       = $bag
            }

            $invoke = @(Get-HDTStepType | Where-Object { $_.Type -eq $Type })[0].InvokeCommand.Name

            $line = New-Object -TypeName System.Collections.ArrayList

            try {
                $result = & $invoke -Step $step -Context $context

                [void] $line.Add('status={0}' -f [string] $result.Status)
                [void] $line.Add('message={0}' -f [string] $result.Message)
            } catch {
                # A step that threw is still evidence: what it did before it threw
                # is in the journal, and the two runs must have thrown alike.
                [void] $line.Add('threw={0}' -f [string] $_.Exception.Message)
            }

            foreach ($entry in @($journal)) {
                # The extra parentheses are load-bearing: inside a method call's
                # argument list the commas separate ARGUMENTS, so -f would be
                # handed one operand and throw about an index it cannot find.
                [void] $line.Add(('{0}.{1}({2})' -f $entry.Service, $entry.Operation,
                        ((@($entry.Arguments) | ForEach-Object { [string] $_ }) -join '|')))
            }

            $jsonl = ''
            if ($fileSystem.File.ContainsKey('C:\HDT\Logs\HDT.jsonl')) {
                $jsonl = [string] $fileSystem.File['C:\HDT\Logs\HDT.jsonl']
            }
            foreach ($record in @($jsonl -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($record)) { [void] $line.Add('log:' + $record) }
            }

            # AN INSTANT IS NOT A BEHAVIOUR. The two runs happen one after the
            # other, and not every timestamp a step writes comes from the
            # injected clock - Tattoo stamps DeploymentEnd from the deployment's
            # own wall-clock reckoning, so the control and the probe recorded
            # 16:36:31 and 16:36:32 and the comparison failed on a second. Every
            # ISO-8601 instant is flattened to one placeholder; no probe value is
            # a timestamp, so nothing under test is hidden by this.
            return (($line -join "`n") -replace '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z', '<instant>')
        }
    }

    # THE ROW. -ForEach over the table, so adding a property adds a test.
    It 'a <Type> step expands %Var% in <Key>' -ForEach $script:HDTExpansionProbe {

        $base = & $script:newTemplateStep $Type

        $control = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $base.Property) {
            foreach ($name in @($base.Property.Keys)) { $control[[string] $name] = $base.Property[$name] }
        }
        foreach ($name in @($Extra.Keys)) { $control[[string] $name] = $Extra[$name] }

        $probe = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($control.Keys)) { $probe[[string] $name] = $control[$name] }

        $control[$Key] = $Value
        $probe[$Key] = '%HDTExpandProbe%'

        $controlText = & $script:invokeProbeRun $Type $Phase $control ([ordered] @{})
        $probeText = & $script:invokeProbeRun $Type $Phase $probe ([ordered] @{ HDTExpandProbe = $Value })

        # The control has to carry the value somewhere observable, or "the two
        # runs match" would be a statement about a step that never read it.
        $controlText | Should -Match ([regex]::Escape($Value)) -Because (
            "the control run of a $Type step must carry $Key='$Value' into the journal or the log, " +
            'or this row proves nothing about expansion')

        # A ROW THAT REPORTS BOTH FORMS CANNOT BE HELD TO EITHER RULE, because
        # naming the token AS WRITTEN is what it is for. All that is left to
        # check - and it is the thing that matters - is that the expansion
        # happened at all.
        #
        # .Contains FIRST, and it is not defensive noise: the gate runs under
        # Set-StrictMode -Version Latest, where reading a key a row does not
        # carry is a PropertyNotFoundException rather than $null. Every row but
        # one omits AsWritten, so `if ($_.AsWritten)` passed a direct run and
        # failed all 25 rows under the gate.
        if ($_.Contains('AsWritten') -and $_.AsWritten) {
            $probeText | Should -Match ([regex]::Escape($Value)) -Because (
                "$Type logs $Key both as written and as expanded; the expanded form must be there")

            return
        }

        # THE DEFECT, STATED AS A DIFFERENCE. A step that reads the bag raw sends
        # '%HDTExpandProbe%' where the control sent the value.
        $probeText | Should -Not -Match '%HDTExpandProbe%' -Because (
            "$Type reads $Key straight out of the property bag; it must go through " +
            'Get-HDTStepProperty -Expand like the other step types')

        $probeText | Should -Be $controlText -Because (
            "a $Type step whose $Key is written '%HDTExpandProbe%' must behave exactly as one written '$Value'")
    }

    # THE GUARD. A step type with no row is a step type nobody checked.
    #
    # The covered list arrives through -ForEach rather than as $script:. A
    # variable set at file scope is read during DISCOVERY; the body of an It runs
    # later, in Pester's own scope, where it is not there at all - and the guard
    # would then report every step type as missing, which is a failure about the
    # test file rather than about the engine.
    It 'every HDT step type is covered by the probe table' -ForEach @(
        @{ Covered = @(@($script:HDTExpansionProbe | ForEach-Object { $_.Type }) + $script:HDTNoStringProperty) |
                Sort-Object -Unique
        }
    ) {

        $all = @(Get-HDTStepType | Where-Object { $_.Source -eq 'Hephaestus' } |
                ForEach-Object { $_.Type }) | Sort-Object -Unique

        $missing = @($all | Where-Object { $Covered -notcontains $_ })

        $missing | Should -BeNullOrEmpty -Because (
            'a step type with no expansion probe is one nobody proved expands its own properties; ' +
            'add a row to $script:HDTExpansionProbe, or name it in $script:HDTNoStringProperty and say why')
    }
}
