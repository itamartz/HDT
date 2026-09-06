# THE SHIPPED REFRESH TEMPLATE, RUN RATHER THAN READ.
#
# THIS FILE EXISTS BECAUSE THE SHIPPED CLIENT TEMPLATE COULD NOT PARTITION A
# DISK. client.yaml authored its partition table inline, every row came back with
# no drive letter, and the first bare-metal machine that ever ran it died at the
# partitioner. Ten thousand tests and a full end-to-end VM deployment missed it,
# because the VM sequences used a NAMED layout and the shipped template was only
# ever PARSED and schema-checked. Nobody ever planned one.
#
# SequenceTemplatePlan.Contract.Tests.ps1 closed that for DiskPartition. A
# Refresh has no DiskPartition step at all, so it contributes nothing to that
# file and would be covered by nothing - which is the same hole in a different
# shape. So this takes refresh.yaml through the engine itself, on BOTH of its
# legs, against nothing but hand-written fakes, and asserts the ORDERED LIST OF
# OPERATIONS it performs on a machine.
#
# THE TWO CLAIMS THAT ARE WORTH THE WHOLE FILE:
#
#   1. THE SUSPEND LANDS AHEAD OF THE ARM. Arming a one-shot ramdisk boot entry
#      changes what the TPM measured. Suspend afterwards and the machine has
#      already been told to boot into a configuration BitLocker will refuse, so
#      the next boot asks for a recovery key on a machine nobody is standing in
#      front of. The order is the feature; the steps existing is not.
#
#   2. THE VOLUME IS EMPTIED BEFORE THE IMAGE IS APPLIED, AND THE RUN'S OWN
#      STATE SURVIVES IT. DISM overlays a volume rather than emptying one, and
#      <volume>\HDT carries the state document this leg resumed from, the WinPE
#      it is running out of, and its logs. Delete either half of that pair in the
#      wrong order and the machine is a Windows nobody can finish deploying.
#
# AND THE SECOND LEG IS RESUMED, NOT MERELY SECOND. Invoke-HDTTaskSequence
# -Resumed is what refuses the destructive step types, and a Refresh's WinPE leg
# is the one leg in HDT that needs an EXCEPTION carved out of that refusal -
# ApplyImage, on a REFRESH, and nothing else. A test that ran the second leg
# without -Resumed would prove the sequence works against a guard it never met.

# IMPORTED AT DISCOVERY AS WELL AS IN BeforeAll, which is what every other file
# in tests/unit does and this one did not. A -ForEach is evaluated while Pester
# is DISCOVERING tests, before any BeforeAll has run, and the preserved-name
# case below asks the module for its set - so on its own this file died at
# discovery with "No modules named 'Hephaestus' are currently loaded". It
# survived the full suite only because some earlier file had already imported
# the module, which is a dependency on discovery ORDER rather than on anything
# this file says.
$script:HDTRefreshTemplateRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module -Name (Join-Path -Path $script:HDTRefreshTemplateRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # THE SHIPPED FILE, READ OFF DISK. Nothing here is a copy of it: a fixture
    # that drifted from the template would go green about a file nobody ships.
    $script:templatePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates/refresh.yaml'
    $script:templateYaml = Get-Content -LiteralPath $script:templatePath -Raw

    $script:runId = 'run-refresh-0001'
    $script:workspaceRoot = '\\srv\HDTShare'
    $script:sequencePath = '\\srv\HDTShare\TaskSequences\REFRESH\sequence.yaml'

    # THE FOUR MDT DELETES BY NAME, LTIApply.wsf:1265-1282, plus the run's own
    # state directory which must survive them.
    $script:oldInstallation = @('Windows', 'Program Files', 'Users', 'ProgramData')

    # -- one machine, seeded as a Refresh finds it -------------------------
    #
    # C: IS A REAL WINDOWS WITH REAL THINGS ON IT, because a Refresh runs on a
    # machine somebody has been using. An empty volume would let CleanVolume
    # complete having deleted nothing, which is the shape of pass this file
    # exists to refuse.
    $script:newMachine = {
        $directory = New-Object -TypeName System.Collections.ArrayList
        [void] $directory.Add('C:\')
        foreach ($name in @($script:oldInstallation)) {
            [void] $directory.Add([IO.Path]::Combine('C:\', $name))
        }
        foreach ($row in @(InModuleScope Hephaestus { Get-HDTCleanVolumePreservedName })) {
            [void] $directory.Add([IO.Path]::Combine('C:\', [string] $row.Name))
        }
        [void] $directory.Add('C:\HDT\Boot')
        [void] $directory.Add('\\srv\HDTShare\Boot')

        $file = @{
            $script:sequencePath                                     = $script:templateYaml
            '\\srv\HDTShare\Boot\HDTPE_x64.wim'                               = 'wim'
            # THE RAMDISK DESCRIPTOR EVERY WINDOWS INSTALLATION CARRIES, and the
            # staging step refuses without it: a machine without one cannot boot
            # a ramdisk image at all. On a Refresh it comes off the installation
            # being replaced, which is the last thing that installation does.
            'C:\Windows\Boot\DVD\PCAT\boot.sdi'                      = 'sdi'
            '\\srv\HDTShare\TaskSequences\REFRESH\unattend.xml'      = '<unattend />'
            '\\srv\HDTShare\OperatingSystems\Win11-LTSC-2024\sources\install.wim' = 'wim'
            '\\srv\HDTShare\OperatingSystems\Win11-LTSC-2024\os.yaml'         = @(
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
            'C:\Windows\explorer.exe'                                = 'MZ'
            'C:\Users\bob\ntuser.dat'                                = 'REG'
            'C:\HDT\state.json'                                      = '{}'
            'C:\HDT\Boot\HDTPE_x64.wim'                              = 'wim'
        }

        return (New-HDTFakeFileSystem -Directory ([string[]] @($directory)) -File $file)
    }

    # A DISK WITH A WINDOWS ALREADY ON IT, which is what distinguishes the
    # machine a Refresh runs on from the raw one client.yaml's fixtures use. It
    # is GPT, it is the boot and system disk, and it is NOT going to be
    # repartitioned - the template carries no step that could.
    $script:diskRow = @(
        [pscustomobject] @{
            Number = 0; FriendlyName = 'Msft Virtual Disk'; SerialNumber = ''
            SizeBytes = 68719476736; BusType = 'SAS'; PartitionStyle = 'GPT'
            IsBoot = $true; IsSystem = $true; IsReadOnly = $false; IsOffline = $false
            OperationalStatus = 'Online'
        }
    )

    # THE VOLUME ROW THE FREE-SPACE GUARD MEASURES. 68 GB, comfortably past the
    # 20000 MB image plus 150 MB plus 3 GB the template declares - so the guard
    # PASSES on evidence rather than on an absent row.
    $script:volumeRow = @(
        [pscustomobject] @{
            DriveLetter = 'C'; FileSystemLabel = 'Windows'; SizeBytes = 68719476736
            SizeRemainingBytes = 4294967296; FileSystem = 'NTFS'; DriveType = 'Fixed'
        }

        # THE ESP THE TEMPLATE NAMES AS HDTSystemVolume, lettered - which is what
        # a machine HDT itself deployed looks like (uefi-standard lays out S/W/R).
        # A machine partitioned by Windows setup has an ESP with no letter at
        # all, and that limitation is written into the template beside the value.
        [pscustomobject] @{
            DriveLetter = 'S'; FileSystemLabel = 'System'; SizeBytes = 272629760
            SizeRemainingBytes = 209715200; FileSystem = 'FAT32'; DriveType = 'Fixed'
        }
    )

    # -- a leg -------------------------------------------------------------

    $script:runLeg = {
        param([string] $Phase, [object] $FileSystem, [object] $BitLocker, [object] $State,
            [System.Collections.IDictionary] $Variable, [switch] $Resumed)

        $journal = [System.Collections.ArrayList]::new()

        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 6, 9, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 250

        # SystemDrive IS C: ON BOTH LEGS OF THIS TEST, and that is a deliberate
        # simplification with a limit written down. A real resumed leg reports
        # X:, and Assert-HDTCleanVolumeTarget refuses to empty the volume the
        # engine is running from - so C: on the second leg would refuse. The
        # WinPE leg below therefore reports X:, which is what a RAM disk does.
        $environment = New-HDTFakeEnvironmentProvider -Variable @{
            ComSpec = 'cmd.exe'; SystemDrive = $(if ($Phase -eq 'WinPE') { 'X:' } else { 'C:' })
            SystemRoot = 'C:\Windows'
        }

        $registry = New-HDTFakeRegistryService
        $lsa = New-HDTFakeLsaService
        $power = New-HDTFakePowerService
        $process = New-HDTFakeProcessService
        $invoker = New-HDTFakeScriptInvoker
        $cim = New-HDTFakeCimProvider -FixturePath (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/cim')
        $disk = New-HDTFakeDiskService -Disk $script:diskRow -Volume $script:volumeRow
        $image = New-HDTFakeImageService
        $feature = New-HDTFakeFeatureService
        $domain = New-HDTFakeDomainService
        $content = New-HDTFakeContentProvider

        $catalog = New-HDTServiceCatalog -FileSystem $FileSystem -Clock $clock -Registry $registry `
            -Lsa $lsa -Process $process -Power $power -ScriptInvoker $invoker -Cim $cim `
            -Environment $environment -Disk $disk -Image $image -Feature $feature `
            -BitLocker $BitLocker -Domain $domain -Content $content

        $sequence = Import-HDTSequenceDocument -Path $script:sequencePath -FileSystem $FileSystem

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($sequence.Variable.Keys)) { $live[[string] $name] = $sequence.Variable[$name] }
        $live['HDTAdminPassword'] = 'Refresh-P@ssw0rd'
        if ($null -ne $Variable) {
            foreach ($name in @($Variable.Keys)) { $live[[string] $name] = $Variable[$name] }
        }

        $logPath = 'C:\HDT\Logs'
        if ($Phase -eq 'WinPE') { $logPath = 'X:\HDT\Logs' }

        $log = New-HDTLogContext -RunId $script:runId -Phase $Phase -LogPath $logPath `
            -FileSystem $FileSystem -Clock $clock -Level Debug -ThreadId 1

        $runState = $State
        if ($null -eq $runState) {
            $runState = New-HDTRunState -SequenceId $sequence.Id -RunId $script:runId -Phase $Phase `
                -Clock $clock -Variable $live -Step $sequence.Step
        }

        $context = New-HDTExecutionContext -RunId $script:runId -Phase $Phase `
            -WorkspaceRoot $script:workspaceRoot -Variable $live -Service $catalog -Log $log -State $runState

        # THE JOURNAL GOES ON LAST, after every seed, so its first entry is the
        # first thing the ENGINE did.
        foreach ($fake in @($FileSystem, $clock, $registry, $lsa, $process, $power, $invoker,
                $cim, $environment, $disk, $image, $BitLocker, $domain, $content)) {

            if ($null -ne $fake) { $fake.Journal = $journal }
        }

        $argument = @{ Sequence = $sequence; Context = $context; State = $runState }
        if ($Resumed) { $argument['Resumed'] = $true }

        $result = Invoke-HDTTaskSequence @argument

        return [pscustomobject] @{
            Result   = $result
            Journal  = $journal
            State    = $runState
            Sequence = $sequence
            Variable = $live
        }
    }

    # THE ORDERED OPERATION LIST, filtered to the operations that are SIDE
    # EFFECTS ON A MACHINE. Log writes dominate the journal by volume - thousands
    # of AppendAllText calls - so an unfiltered list would break on every added
    # log line, which makes it a list nobody maintains and therefore nobody
    # trusts. The filesystem is asserted separately and by path.
    $script:operationOf = {
        param([object] $Run)

        return [string[]] @($Run.Journal |
                Where-Object { $_.Service -ne 'FileSystem' -and $_.Service -ne 'Clock' } |
                ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation })
    }

    # ONE SAFE WAY TO READ AN ARGUMENT OFF A JOURNAL ENTRY, because there is no
    # safe unsafe way.
    #
    # A journal entry records whatever arguments its operation took, and plenty
    # of operations take NONE - GetDisk, GetVolume, Restart, GetOperationName.
    # Indexing past the end of an array is TERMINATING under
    # Set-StrictMode -Version Latest, so a projection over the WHOLE journal dies
    # on the first argument-less entry with an IndexOutOfRangeException that
    # reads like a broken test rather than a broken projection. The projections
    # that survive it today survive only because they filter to RemoveItem or
    # CopyItem first - an operation that happens always to carry one - which is a
    # guarantee no filter states and nothing enforces.
    $script:argumentAt = {
        param([object] $Entry, [int] $Index)

        $argument = @($Entry.Arguments)
        if ($Index -lt 0 -or $Index -ge $argument.Count) { return '' }

        return [string] $argument[$Index]
    }

    $script:indexOf = {
        param([string[]] $List, [string] $Operation)

        return [array]::IndexOf($List, $Operation)
    }

    $script:stepNamed = {
        param([object] $Run, [string] $Name)

        return @($Run.Result.Result | Where-Object { [string] $_.Name -eq $Name })[0]
    }
}

Describe 'The shipped Refresh template' {

    Context 'the full-OS leg, which is where the run starts' {

        BeforeAll {
            $script:fs = & $script:newMachine

            # AN ENCRYPTED MACHINE, which is what a Refresh runs on in any estate
            # with a BitLocker policy. The whole point of the first leg is the
            # step that deals with this.
            $script:bitLocker = New-HDTFakeBitLockerService -Volume @{
                'C:' = @{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On' }
            }

            $script:first = & $script:runLeg 'FullOS' $script:fs $script:bitLocker $null $null
            $script:firstOps = & $script:operationOf $script:first
        }

        It 'is a REFRESH, derived from the phase it started in' {
            [string] $script:first.State.deploymentType | Should -BeExactly 'REFRESH'
        }

        It 'gets as far as the restart and asks for one' {
            $script:first.Result.Status | Should -BeExactly 'RebootPending'
        }

        It 'runs every step it reached without failing one' {
            $failed = @($script:first.Result.Result | Where-Object { $_.Status -eq 'Failed' } |
                    ForEach-Object { '{0}: {1}' -f $_.Name, $_.Message })

            ($failed -join ' | ') | Should -BeNullOrEmpty
        }

        It 'suspends BitLocker' {
            $script:firstOps | Should -Contain 'BitLockerService.Suspend'
        }

        # THE CLAIM THIS FILE IS FOR. MDT runs its Disable BDE Protectors step
        # immediately before it stages the transport (Client.xml:85-90); reversed,
        # the machine has been told to boot a configuration BitLocker will refuse
        # before anybody turned the protectors off.
        It 'suspends BitLocker BEFORE it adds the ramdisk boot entry' {
            $suspend = & $script:indexOf $script:firstOps 'BitLockerService.Suspend'
            $add = & $script:indexOf $script:firstOps 'ImageService.AddRamdiskBootEntry'

            $suspend | Should -BeGreaterThan -1
            $add | Should -BeGreaterThan -1
            $suspend | Should -BeLessThan $add
        }

        It 'suspends BitLocker BEFORE it arms the one-shot boot' {
            $suspend = & $script:indexOf $script:firstOps 'BitLockerService.Suspend'
            $arm = & $script:indexOf $script:firstOps 'ImageService.SetBootSequenceOnce'

            $suspend | Should -BeGreaterThan -1
            $arm | Should -BeGreaterThan -1
            $suspend | Should -BeLessThan $arm
        }

        It 'arms the one-shot boot BEFORE it asks for the restart' {
            $arm = & $script:indexOf $script:firstOps 'ImageService.SetBootSequenceOnce'
            $restart = & $script:indexOf $script:firstOps 'PowerService.Restart'

            $arm | Should -BeGreaterThan -1
            $restart | Should -BeGreaterThan -1
            $arm | Should -BeLessThan $restart
        }

        # NOTHING IS SEALED UNTIL WE KNOW IT CAN COME BACK - reference.yaml's
        # rule, and on a production machine it is the difference between a
        # retry and a laptop nobody can boot.
        It 'stages the WinPE onto the machine before it arms a boot into it' {
            $copied = @($script:first.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'CopyItem' } |
                    ForEach-Object { & $script:argumentAt $_ 1 })

            ($copied -join ' | ') | Should -Match 'C:\\HDT\\Boot'
        }

        It 'partitions nothing: a Refresh reuses the table Windows was booting from' {
            $partitioning = @($script:firstOps | Where-Object { $_ -like 'DiskService.New*' -or $_ -like 'DiskService.Clear*' -or $_ -like 'DiskService.Format*' })

            ($partitioning -join ', ') | Should -BeNullOrEmpty
        }

        It 'deletes nothing on the leg it is still running from' {
            # CleanVolume is on the WinPE leg for a reason MDT states outright:
            # you cannot delete the Windows you are running.
            $removed = @($script:first.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'RemoveItem' } |
                    ForEach-Object { & $script:argumentAt $_ 0 })

            @($removed | Where-Object { $_ -eq 'C:\Windows' }) | Should -BeNullOrEmpty
        }

        It 'leaves the volume as encrypted as it found it: this is a suspend, not a decrypt' {
            [string] $script:bitLocker.GetVolume('C:').VolumeStatus | Should -BeExactly 'FullyEncrypted'
        }
    }

    Context 'the resumed WinPE leg, which is the leg that replaces the installation' {

        BeforeAll {
            $script:fs2 = & $script:newMachine

            $script:bitLocker2 = New-HDTFakeBitLockerService -Volume @{
                'C:' = @{ VolumeStatus = 'FullyEncrypted'; ProtectionStatus = 'On' }
            }

            $leg1 = & $script:runLeg 'FullOS' $script:fs2 $script:bitLocker2 $null $null

            # THE SAME STATE OBJECT THE FIRST LEG CHECKPOINTED, carried across
            # the reboot the way the machine carries it - and the leg number
            # moves, because this is a different leg of one run.
            $state = $leg1.Result.State
            $state.leg = [int] $state.leg + 1

            $script:second = & $script:runLeg 'WinPE' $script:fs2 $script:bitLocker2 $state $null -Resumed
            $script:secondOps = & $script:operationOf $script:second

            $script:secondRemoved = [string[]] @($script:second.Journal |
                    Where-Object { $_.Service -eq 'FileSystem' -and $_.Operation -eq 'RemoveItem' } |
                    ForEach-Object { & $script:argumentAt $_ 0 })
        }

        It 'carries the REFRESH the first leg derived across the reboot' {
            [string] $script:second.State.deploymentType | Should -BeExactly 'REFRESH'
        }

        It 'fails no step it reached' {
            $failed = @($script:second.Result.Result | Where-Object { $_.Status -eq 'Failed' } |
                    ForEach-Object { '{0}: {1}' -f $_.Name, $_.Message })

            ($failed -join ' | ') | Should -BeNullOrEmpty
        }

        # THE EXCEPTION THE WHOLE GUARD WAS RESHAPED FOR. ApplyImage is forbidden
        # on a resumed leg; a Refresh's is the step the leg exists to run.
        It 'applies the image, which no other resumed leg in HDT may do' {
            (& $script:stepNamed $script:second 'Install Operating System').Status |
                Should -BeExactly 'Completed'
        }

        It 'empties the volume of the last installation, by name' -ForEach @(
            @{ Name = 'Windows' }, @{ Name = 'Program Files' }, @{ Name = 'Users' }, @{ Name = 'ProgramData' }
        ) {
            $script:secondRemoved | Should -Contain ([IO.Path]::Combine('C:\', $Name))
        }

        # THE ONE DIRECTORY THAT MUST SURVIVE, and it is asserted against the SET
        # the engine declares rather than against the name HDT happens to use -
        # so a name added to the preserved list tomorrow is covered on the day
        # it lands.
        It 'keeps the run''s own state directory: <Name>' -ForEach @(
            @(InModuleScope Hephaestus { Get-HDTCleanVolumePreservedName } |
                    ForEach-Object { @{ Name = [string] $_.Name } })
        ) {
            $script:secondRemoved | Should -Not -Contain ([IO.Path]::Combine('C:\', $Name))
        }

        It 'empties the volume BEFORE it applies the image over it' {
            # DISM OVERLAYS A VOLUME; IT DOES NOT EMPTY ONE. Reversed, the
            # previous Windows\, Program Files\ and Users\ survive underneath the
            # new installation and the machine looks deployed while carrying the
            # last build's files.
            # BOTH POSITIONS COME OUT OF THE SAME UNFILTERED PASS, so the two
            # indexes are comparable: an ordering claim made across two
            # differently filtered lists compares positions in different
            # coordinate systems and proves nothing. The first argument is read
            # through $script:argumentAt because most entries here have none -
            # PowerService.Restart, ImageService.RemoveBootEntry, every GetVolume
            # the run makes - and indexing an empty array is terminating under
            # Set-StrictMode -Version Latest.
            $entry = [string[]] @($script:second.Journal | ForEach-Object {
                    '{0}.{1}' -f $_.Service, $_.Operation
                })
            $entryWithTarget = [string[]] @($script:second.Journal | ForEach-Object {
                    '{0}.{1}({2})' -f $_.Service, $_.Operation, (& $script:argumentAt $_ 0)
                })

            $clean = [array]::IndexOf($entryWithTarget, 'FileSystem.RemoveItem(C:\Windows)')
            $apply = [array]::IndexOf($entry, 'ImageService.ApplyImage')

            $applyList = & $script:operationOf $script:second

            $clean | Should -BeGreaterThan -1
            $apply | Should -BeGreaterThan -1
            $clean | Should -BeLessThan $apply
            $applyList | Should -Contain 'ImageService.ApplyImage'
        }

        It 'injects drivers before it applies the answer file' {
            # offlineServicing runs the moment the answer file is applied to the
            # offline image, so the drivers have to be on the volume first. The
            # reverse order cost 0.10.1 a rebuild.
            $driver = @($script:second.Result.Result | Where-Object { $_.Name -eq 'Inject Drivers' })[0]
            $unattend = @($script:second.Result.Result | Where-Object { $_.Name -eq 'Apply Windows Settings' })[0]

            $driver.Index | Should -BeLessThan $unattend.Index
        }

        It 'tears the transport down before it leaves WinPE' {
            $remove = & $script:indexOf $script:secondOps 'ImageService.RemoveBootEntry'
            $restart = & $script:indexOf $script:secondOps 'PowerService.Restart'

            $remove | Should -BeGreaterThan -1
            $restart | Should -BeGreaterThan -1
            $remove | Should -BeLessThan $restart
        }

        It 'does not suspend BitLocker again on a leg where there is nothing to suspend' {
            $script:secondOps | Should -Not -Contain 'BitLockerService.Suspend'
        }

        It 'asks for the restart into the new installation' {
            $script:second.Result.Status | Should -BeExactly 'RebootPending'
        }
    }

    Context 'what a Refresh template may and may not carry' {

        BeforeAll {
            $script:refreshDocument = Import-HDTSequenceDocument -Path $script:sequencePath `
                -FileSystem (& $script:newMachine)

            $script:refreshType = [string[]] @($script:refreshDocument.Step | ForEach-Object { [string] $_.Type })
        }

        # ASSERTED AGAINST THE SET, so a destructive step type added next year is
        # covered by construction rather than by somebody remembering this file.
        It 'carries no step type a resumed leg refuses outright' {
            $forbidden = @(InModuleScope Hephaestus { Get-HDTResumeForbiddenStepType })
            $permitted = @(InModuleScope Hephaestus { Get-HDTResumePermittedStepType -DeploymentType 'REFRESH' })

            $offending = @($script:refreshType | Where-Object {
                    $forbidden -contains $_ -and $permitted -notcontains $_
                })

            ($offending -join ', ') | Should -BeNullOrEmpty -Because (
                'a Refresh sequence carrying one of these would fail at the machine on its resumed leg')
        }

        It 'empties the volume from WinPE and never from the Windows it started in' {
            $clean = @($script:refreshDocument.Step | Where-Object { $_.Type -eq 'CleanVolume' })

            @($clean).Count | Should -Be 1
            [string] $clean[0].RunIn | Should -BeExactly 'WinPE'
        }

        It 'suspends BitLocker from the full OS, which is the only place it can' {
            $suspend = @($script:refreshDocument.Step | Where-Object { $_.Type -eq 'SuspendBitLocker' })

            @($suspend).Count | Should -Be 1
            [string] $suspend[0].RunIn | Should -BeExactly 'FullOS'
        }
    }
}

Describe 'Shipped sequence templates: only a run that starts in the full OS suspends BitLocker' {

    # AGAINST THE SET, NOT AGAINST refresh.yaml. A NEWCOMPUTER run has nothing to
    # suspend - a bare machine has no protectors - and a template that suspended
    # anyway would fail on every one of them. The rule is structural: the step
    # can only appear on a leg that runs in the full OS, and a template whose
    # first group is WinPE is a bare-metal deployment.

    BeforeAll {
        $script:root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:root -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:root -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        $script:templateRoot = Join-Path -Path $script:root -ChildPath 'src/Hephaestus/Templates'

        $script:suspendRow = New-Object -TypeName System.Collections.ArrayList

        foreach ($file in @(Get-ChildItem -LiteralPath $script:templateRoot -Filter '*.yaml' -File -ErrorAction SilentlyContinue)) {
            $reader = New-HDTFakeFileSystem -File @{
                'C:\t\sequence.yaml' = [System.IO.File]::ReadAllText($file.FullName)
            }

            $document = Import-HDTSequenceDocument -Path 'C:\t\sequence.yaml' -FileSystem $reader

            foreach ($step in @($document.Step | Where-Object { $_.Type -eq 'SuspendBitLocker' })) {
                [void] $script:suspendRow.Add([pscustomobject] @{
                        Template = $file.Name
                        Name     = [string] $step.Name
                        RunIn    = [string] $step.RunIn
                    })
            }
        }
    }

    It 'finds the SuspendBitLocker steps to check' {
        # A guard on the guard: an empty list passes the assertion below.
        $script:suspendRow.Count | Should -BeGreaterThan 0
    }

    It 'declares FullOS on every SuspendBitLocker step in every shipped template' {
        $wrong = @($script:suspendRow | Where-Object { $_.RunIn -ne 'FullOS' } |
                ForEach-Object { '{0} / {1}: runIn {2}' -f $_.Template, $_.Name, $_.RunIn })

        ($wrong -join ' | ') | Should -BeNullOrEmpty
    }
}
