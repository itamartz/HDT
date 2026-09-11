# The CleanVolume step empties the OS volume before the image is applied.
#
# DESIGN 3.2. A Refresh does not repartition and does not format - it DELETES.
# DISM /Apply-Image OVERLAYS a volume rather than emptying one, so without this
# step the previous Windows\, Program Files\, Users\ and ProgramData\ survive
# underneath the new installation and the machine looks deployed while carrying
# the last installation's files.
#
# MDT'S CleanDrive, LTIApply.wsf:1245-1317. It enumerates the root's subfolders
# at :1265, runs cmd.exe /c rd /s /q on each at :1282, retries once through
# ResetFolder's takeown/icacls at :1285-1299/:1564, then deletes the root files
# at :1308-1315. HDT does the same three things through IFileSystem, so the whole
# step is provable here against the hand-written fake (rule 5).
#
# AND IT DIVERGES ON FAILURE, DELIBERATELY. LTIApply.wsf:1297-1299 logs
# "Unable to delete " and carries on, so a locked folder survives into the new
# installation and nothing fails. HDT FAILS the step, for the reason the resume
# guard already fails rather than skips: a half-cleaned volume is a machine that
# looks deployed and is not, and a week later the cause is unreadable in a log
# that recorded it as a warning.
#
# THE ASSERTION IS THE POINT OF THE FILE. CLAUDE.md forbids building a delete
# target by enumerating a parent directory, and this step is exactly an
# enumerate-and-delete loop. What stands in for the rule it cannot satisfy
# literally is Assert-HDTCleanVolumeTarget, and every refusal it makes is
# asserted below WITH the proof that nothing was deleted when it fired.

# AT FILE SCOPE, NOT IN A BeforeAll, AND THE FIRST DRAFT PROVED WHY. Pester 5
# expands -ForEach while it DISCOVERS, and a BeforeAll runs later - so the
# preserved-set table built there was $null when the cases were generated, every
# It that walked it produced ZERO cases, and the run went green having asserted
# nothing about the set it exists to assert about.
$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') `
    -Force -ErrorAction Stop

# THE FOUR MDT DELETES BY NAME, LTIApply.wsf. They are the whole reason the step
# exists, so every arrangement below carries them.
$script:HDTOldInstallation = @('Windows', 'Program Files', 'Users', 'ProgramData')

# THE PRESERVED SET, READ OFF THE ENGINE RATHER THAN COPIED HERE. A test that
# names HDT passes for HDT and fails nobody after it; walking the set covers the
# name somebody adds next.
$script:HDTPreservedCase = @(InModuleScope Hephaestus { Get-HDTCleanVolumePreservedName } |
        ForEach-Object { @{ Name = [string] $_.Name; Reason = [string] $_.Reason } })

# THE EVENT FAMILY, READ OFF Write-HDTLog RATHER THAN LISTED HERE, for the same
# reason. DESIGN 4.4.2's vocabulary is closed and cross-checked against the
# document in both directions, so a volume.* name that reaches the ValidateSet
# without an emitter is a name the report renderer and the console can filter on
# and never see - and a test that names volume.delete passes for volume.delete
# and fails nobody after it.
$script:HDTVolumeEvent = @((Get-Command -Name Write-HDTLog).Parameters['Event'].Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
        ForEach-Object { $_.ValidValues } |
        Where-Object { $_ -like 'volume.*' } |
        Sort-Object)

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # THE FOUR MDT DELETES BY NAME, LTIApply.wsf. They are the whole reason the
    # step exists, so every arrangement below carries them.
    $script:oldInstallation = @('Windows', 'Program Files', 'Users', 'ProgramData')

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 3; Name = 'Clean the OS volume'; Type = 'CleanVolume'
            TimeoutMinutes = 0; Log = $null; Property = $bag
        }
    }

    # A WinPE leg standing on C: - which is what a Refresh is. SystemDrive is
    # X: because the engine is running from the RAM disk, and C: is the volume
    # the full OS was on and the one the run staged its own state onto.
    $script:newContext = {
        param($FileSystem, [hashtable] $Variable, [string] $SystemDrive)

        $drive = $SystemDrive
        if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'X:' }

        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 5, 9, 0, 0, [System.DateTimeKind]::Utc))

        $catalog = New-HDTServiceCatalog -FileSystem $FileSystem -Clock $clock `
            -Environment (New-HDTFakeEnvironmentProvider -Variable @{ SystemDrive = $drive })

        $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $FileSystem -Clock $clock -Level Debug

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
        }

        return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot '\\srv\HDTShare' `
                -Variable $live -Service $catalog -Log $log)
    }

    # THE PRESERVED SET, READ OFF THE ENGINE RATHER THAN COPIED HERE. A test
    # that names HDT\ passes for HDT\ and fails nobody after it; walking the set
    # covers the name somebody adds next.
    $script:preserved = @(InModuleScope Hephaestus { Get-HDTCleanVolumePreservedName })

    # A volume laid out like the one a Refresh stands on: the last
    # installation, the run's own state directory, and the two directories
    # Windows owns and nobody may delete.
    $script:newVolume = {
        param([string[]] $Extra, [hashtable] $RemoveFailure, [hashtable] $RemoveFailureCount)

        $directory = New-Object -TypeName System.Collections.ArrayList
        [void] $directory.Add('C:\')

        foreach ($name in @($script:oldInstallation)) {
            [void] $directory.Add([IO.Path]::Combine('C:\', $name))
        }

        foreach ($row in @($script:preserved)) {
            [void] $directory.Add([IO.Path]::Combine('C:\', [string] $row.Name))
        }

        foreach ($name in @($Extra)) { [void] $directory.Add([IO.Path]::Combine('C:\', $name)) }

        $argument = @{
            Directory = [string[]] @($directory)
            File      = @{
                # The run's own state and its staged transport, both under
                # C:\HDT - deleting them kills the leg mid-flight.
                'C:\HDT\state.json'      = '{}'
                'C:\HDT\Boot\boot.wim'   = 'WIM'
                'C:\Windows\explorer.exe' = 'MZ'
                'C:\Users\bob\ntuser.dat' = 'REG'
            }
        }

        if ($null -ne $RemoveFailure) { $argument['RemoveFailure'] = $RemoveFailure }
        if ($null -ne $RemoveFailureCount) { $argument['RemoveFailureCount'] = $RemoveFailureCount }

        return (New-HDTFakeFileSystem @argument)
    }

    # Every path this step asked to have removed, in the order it asked.
    $script:removed = {
        param($FileSystem)

        return [string[]] @($FileSystem.Operations |
                Where-Object { $_.Operation -eq 'RemoveItem' } |
                ForEach-Object { [string] $_.Arguments[0] })
    }

    $script:jsonlRecord = {
        param($FileSystem)

        $path = 'X:\HDT\Logs\HDT.jsonl'
        if (-not $FileSystem.TestPath($path)) { return @() }

        return @(($FileSystem.ReadAllText($path) -split "`r?`n") |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'Invoke-HDTCleanVolumeStep' {

    Context 'the preserved set is a set, not an example' {

        # THE ASSERTION THE ROADMAP ASKS FOR, WRITTEN OVER THE SET. Deleting
        # C:\HDT\ kills the run in the one place it cannot record why, so its
        # survival must not be the one example somebody happened to write.
        It 'leaves <Name> standing' -ForEach $script:HDTPreservedCase {

            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $result.Status | Should -BeExactly 'Completed'
            $fs.TestPath([IO.Path]::Combine('C:\', $Name)) | Should -BeTrue -Because (
                "the step preserves '$Name' because $Reason")
        }

        It 'says why <Name> was preserved, in the log' -ForEach $script:HDTPreservedCase {

            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            # FILTERED ON THE EVENT, NOT ON THE COMPONENT. A component tells a
            # reader which step wrote a line; the event is what the report
            # renderer and the console select on, and a record filed under the
            # `message` default is invisible to both however good its prose is.
            $said = @(& $script:jsonlRecord $fs | Where-Object {
                    [string] $_.event -eq 'volume.preserve' -and [string] $_.message -match ('^keeping .*{0}' -f [regex]::Escape($Name)) })

            @($said).Count | Should -BeGreaterThan 0
            [string] $said[0].message | Should -Not -BeNullOrEmpty
            [string] $said[0].data.reason | Should -Not -BeNullOrEmpty -Because (
                'the reason travels in the record, not only in the sentence')
        }

        It 'gives every preserved name a reason' {
            foreach ($row in @($script:preserved)) {
                [string] $row.Name | Should -Not -BeNullOrEmpty
                [string] $row.Reason | Should -Not -BeNullOrEmpty -Because (
                    'a name with no reason is an exemption nobody can review')
            }
        }

        It 'carries the run state directory, whatever else it carries' {
            @($script:preserved | ForEach-Object { [string] $_.Name }) | Should -Contain 'HDT'
        }

        It 'matches a preserved name however it is cased' {
            # A volume laid down by a previous run may carry 'hdt' or 'Hdt';
            # Windows does not distinguish them and neither may this.
            $fs = & $script:newVolume -Extra @('hdt')
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $fs.TestPath('C:\hdt') | Should -BeTrue
        }
    }

    Context 'the old installation' {

        It 'deletes <_>' -ForEach $script:HDTOldInstallation {
            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $fs.TestPath([IO.Path]::Combine('C:\', $_)) | Should -BeFalse
        }

        It 'deletes each folder whole rather than a file at a time' {
            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $recursive = @($fs.Operations | Where-Object {
                    $_.Operation -eq 'RemoveItem' -and [string] $_.Arguments[0] -eq 'C:\Windows' })

            @($recursive).Count | Should -Be 1
            $recursive[0].Arguments[1] | Should -BeTrue -Because 'rd /s /q takes the tree, not the folder'
        }

        # LTIApply.wsf:1308-1315. A root file is not in any subfolder, so the
        # subfolder loop never reaches it and a bootmgr or a pagefile from the
        # last installation would survive the clean.
        It 'deletes the files sitting in the root too' {
            $fs = & $script:newVolume
            $fs.SeedFile('C:\bootmgr', 'BM')
            $fs.SeedFile('C:\pagefile.sys', 'PF')

            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $fs.TestPath('C:\bootmgr') | Should -BeFalse
            $fs.TestPath('C:\pagefile.sys') | Should -BeFalse
        }

        It 'names every folder it deleted, in the log' {
            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $said = @(& $script:jsonlRecord $fs | Where-Object { [string] $_.event -eq 'volume.delete' })

            foreach ($name in @($script:oldInstallation)) {
                @($said | Where-Object { [string] $_.message -match [regex]::Escape($name) }).Count |
                    Should -BeGreaterThan 0 -Because (
                        "an administrator reading this a week later has to be able to see that $name went")
            }
        }

        It 'reports what it deleted and what it kept' {
            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            @($result.Data['deleted']) | Should -Contain 'C:\Windows'
            @($result.Data['preserved']) | Should -Contain 'C:\HDT'
        }
    }

    Context 'the target it refuses to guess' {

        # EACH ROW IS A TARGET THE STEP MUST NOT ACT ON, AND THE PROOF IS THAT
        # NOTHING WAS DELETED. A refusal that fired after the first rd is not a
        # refusal.
        It 'refuses <Case> and deletes nothing' -ForEach @(
            @{
                Case     = 'a step naming no volume on a run that published none'
                Property = @{}
                Variable = @{}
                Drive    = 'X:'
                Extra    = @()
            }
            @{
                Case     = 'a directory rather than a volume'
                Property = @{ volume = 'C:\Users\bob' }
                Variable = @{ HDTOSVolume = 'C' }
                Drive    = 'X:'
                Extra    = @()
            }
            @{
                Case     = 'a share rather than a volume'
                Property = @{ volume = '\\srv\HDTShare' }
                Variable = @{ HDTOSVolume = 'C' }
                Drive    = 'X:'
                Extra    = @()
            }
            @{
                Case     = 'a volume that is not there'
                Property = @{ volume = 'Q' }
                Variable = @{ HDTOSVolume = 'C' }
                Drive    = 'X:'
                Extra    = @()
            }
            @{
                Case     = 'the volume the engine is running from'
                Property = @{ volume = 'C' }
                Variable = @{ HDTOSVolume = 'C' }
                Drive    = 'C:'
                Extra    = @()
            }
        ) {
            $fs = & $script:newVolume -Extra $Extra
            $context = & $script:newContext $fs $Variable $Drive

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep $Property) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Data['errorId'] | Should -Not -BeNullOrEmpty
            @(& $script:removed $fs) | Should -BeNullOrEmpty -Because (
                'a refusal that fired after the first delete is not a refusal')
        }

        # THE ONE THAT SAYS WHICH VOLUME THE RUN IS STANDING ON. A volume with
        # no HDT\ on it is not the volume this run staged its state, its logs
        # and its boot image onto - so it is not the volume this run identified,
        # and the step will not empty it on the strength of a drive letter.
        It 'refuses a volume that does not carry the run own state directory' {
            $fs = New-HDTFakeFileSystem -Directory @('C:\', 'C:\Windows', 'C:\Users')
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            @(& $script:removed $fs) | Should -BeNullOrEmpty
            [string] $result.Message | Should -Match 'HDT'
        }

        It 'takes the volume the run published when the step names primary' {
            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep @{ volume = 'primary' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'
            [string] $result.Data['volume'] | Should -BeExactly 'C:\'
        }

        It 'expands a variable an author wrote into the volume' {
            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep @{ volume = '%HDTOSVolume%' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'
            [string] $result.Data['volume'] | Should -BeExactly 'C:\'
        }
    }

    Context 'the destructive-step guards' {

        It 'declares SupportsShouldProcess' {
            $command = Get-Command -Name 'Invoke-HDTCleanVolumeStep'

            $command.Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'deletes nothing under WhatIf and says what it would have deleted' {
            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context -WhatIf

            $result.Status | Should -BeExactly 'Completed'
            @(& $script:removed $fs) | Should -BeNullOrEmpty
            $fs.TestPath('C:\Windows') | Should -BeTrue
            @($result.Data['deleted']) | Should -Contain 'C:\Windows'
        }
    }

    Context 'a folder that will not go' {

        # MDT RETRIES ONCE THROUGH takeown/icacls, ResetFolder at
        # LTIApply.wsf:1564. IFileSystem carries the icacls half - GrantAccess -
        # and takeown is a file-only method on the adapter, so the reset here is
        # the grant.
        It 'resets the ACL and tries once more' {
            $fs = & $script:newVolume `
                -RemoveFailure @{ 'C:\Windows' = 'Access to the path is denied.' } `
                -RemoveFailureCount @{ 'C:\Windows' = 1 }

            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $onWindows = @($fs.Operations |
                    Where-Object { [string] $_.Arguments[0] -eq 'C:\Windows' } |
                    ForEach-Object { [string] $_.Operation })

            # OWNERSHIP FIRST, THEN THE GRANT, AND THAT ORDER IS THE WHOLE FIX.
            #
            # icacls /grant cannot change an ACL on something the caller does not
            # own, and it is called with /C - "carry on past errors" - so it
            # fails on each TrustedInstaller-owned child and still exits 0. The
            # grant looked like it worked and changed nothing.
            #
            # WATCHED ON THE FIRST REAL REFRESH, 2026-09-10: the retry granted
            # Administrators Modify over C:\Program Files, deleted nothing, and
            # the step reported "Access to the path 'C:\Program Files\Internet
            # Explorer\images' is denied ... the volume is only half cleaned".
            # A Windows installation is owned by TrustedInstaller from the root
            # down, so the take has to come first and has to be recursive.
            $onWindows | Should -Be @('RemoveItem', 'TakeOwnership', 'GrantAccess', 'RemoveItem')
            $fs.TestPath('C:\Windows') | Should -BeFalse
        }

        It 'says what the retry was for' {
            $fs = & $script:newVolume `
                -RemoveFailure @{ 'C:\Windows' = 'Access to the path is denied.' } `
                -RemoveFailureCount @{ 'C:\Windows' = 1 }

            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }
            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $said = @(& $script:jsonlRecord $fs | Where-Object {
                    [string] $_.event -eq 'volume.retry' -and [string] $_.level -eq 'Warning' })

            @($said).Count | Should -BeGreaterThan 0
            [string] $said[0].message | Should -Match 'C:\\Windows'
        }

        # THE DIVERGENCE FROM MDT, WHICH ONLY WARNS. A half-cleaned volume is a
        # machine that looks deployed and is not.
        It 'fails the step where MDT would have warned and carried on' {
            $fs = & $script:newVolume -RemoveFailure @{ 'C:\Windows' = 'Access to the path is denied.' }
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $result = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            [string] $result.Data['errorId'] | Should -Not -BeNullOrEmpty
        }

        It 'records the exception type, the path and the innermost message' {
            $fs = & $script:newVolume -RemoveFailure @{ 'C:\Windows' = 'Access to the path is denied.' }
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $said = @(& $script:jsonlRecord $fs |
                    Where-Object { [string] $_.level -eq 'Error' -and [string] $_.component -eq 'CleanVolume' })

            @($said).Count | Should -BeGreaterThan 0

            $text = ($said | ForEach-Object { [string] $_.message }) -join "`n"

            $text | Should -Match 'UnauthorizedAccessException'
            $text | Should -Match 'C:\\Windows'
            $text | Should -Match 'Access to the path is denied'
        }
    }

    # DESIGN 4.4.2's `event` is a controlled vocabulary, and the reason this step
    # needed a family of its own is the reason ApplyDrivers did: a volume that
    # came back carrying somebody's old Program Files is a question about a
    # DECISION - which entries went, which stayed and why - and that question is
    # answered by filtering the log rather than by reading it. A step whose every
    # record lands under `message` is a step whose log can only be grepped.
    Context 'the event family it writes under' {

        BeforeAll {
            # THREE ARRANGEMENTS, BECAUSE ONE RUN DOES NOT EXERCISE THE FAMILY.
            # A clean that works never retries, and a clean that retries
            # successfully never fails - so the set below is collected across a
            # plain clean, a clean whose first delete refuses once, and a clean
            # whose delete refuses twice.
            $script:writtenEvent = {
                $seen = New-Object -TypeName System.Collections.ArrayList

                $arrangement = @(
                    @{}
                    @{ RemoveFailure = @{ 'C:\Windows' = 'Access to the path is denied.' }
                        RemoveFailureCount = @{ 'C:\Windows' = 1 } }
                    @{ RemoveFailure = @{ 'C:\Windows' = 'Access to the path is denied.' } }
                )

                foreach ($one in $arrangement) {
                    $fs = & $script:newVolume @one
                    $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

                    $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

                    foreach ($record in @(& $script:jsonlRecord $fs)) {
                        if ([string] $record.component -ne 'CleanVolume') { continue }
                        [void] $seen.Add([string] $record.event)
                    }
                }

                return [string[]] @($seen)
            }

            $script:cleanVolumeEvent = @(& $script:writtenEvent)
        }

        # THE SET TEST. A volume.* name that reaches the ValidateSet with nothing
        # emitting it is a filter the console offers and the log never satisfies,
        # and this walks the family off Write-HDTLog rather than off a list kept
        # here - so the name somebody adds next is covered the day it lands.
        It 'emits <_>' -ForEach $script:HDTVolumeEvent {
            $script:cleanVolumeEvent | Should -Contain $_
        }

        # THE GUARD UNDER THE -ForEach ABOVE, AND IT HAD TO READ THE VALIDATESET
        # AGAIN RATHER THAN $script:HDTVolumeEvent. An empty -ForEach generates
        # NO cases and the file goes green having asserted nothing - which is the
        # trap this file's header already records - and the obvious guard walked
        # into a second one: a $script: variable set at DISCOVERY is $null inside
        # an It at RUN time, and @($null).Count is 1, so the guard passed while
        # the family did not exist.
        It 'has a family to emit at all' {
            $family = @((Get-Command -Name Write-HDTLog).Parameters['Event'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                    ForEach-Object { $_.ValidValues } |
                    Where-Object { $_ -like 'volume.*' })

            $family.Count | Should -BeGreaterThan 0 -Because (
                'DESIGN 4.4.2 has to carry a volume.* family for this step to file its records under')
        }

        It 'files nothing under the message default' {
            # The default is what a call naming no event writes (DESIGN 4.4.4).
            # Every record this step writes is one of its own decisions, so none
            # of them belongs there.
            $script:cleanVolumeEvent | Should -Not -Contain 'message' -Because (
                'a record under the default is one the report renderer and the console cannot select')
        }

        It 'files every record under a volume.* name or step.fail' {
            $stray = @($script:cleanVolumeEvent |
                    Where-Object { $_ -notlike 'volume.*' -and $_ -ne 'step.fail' } |
                    Select-Object -Unique)

            $stray | Should -BeNullOrEmpty -Because ('these are neither: {0}' -f ($stray -join ', '))
        }

        # THE FAILURE KEEPS step.fail RATHER THAN GETTING A SIXTH NAME. It is the
        # same claim every other step's failure makes - this step did not finish -
        # and DESIGN 4.4.2's var.resolve reasoning is that one claim gets one
        # name: a consumer asking "what failed" filters step.fail once, not once
        # per step type that invented its own.
        It 'still fails under step.fail, the name every step failure carries' {
            $fs = & $script:newVolume -RemoveFailure @{ 'C:\Windows' = 'Access to the path is denied.' }
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            @(& $script:jsonlRecord $fs | Where-Object {
                    [string] $_.event -eq 'step.fail' -and [string] $_.component -eq 'CleanVolume' }).Count |
                Should -BeGreaterThan 0
        }

        It 'names the volume it established, under an event of its own' {
            $fs = & $script:newVolume
            $context = & $script:newContext $fs @{ HDTOSVolume = 'C' }

            $null = Invoke-HDTCleanVolumeStep -Step (& $script:newStep) -Context $context

            $said = @(& $script:jsonlRecord $fs | Where-Object { [string] $_.event -eq 'volume.target' })

            @($said).Count | Should -Be 1 -Because 'a clean establishes exactly one target'
            [string] $said[0].data.volume | Should -BeExactly 'C:\'
            [string] $said[0].data.systemDrive | Should -Not -BeNullOrEmpty -Because (
                'which volume the engine is running FROM is half of why this one is safe to empty')
        }
    }
}

Describe 'Get-HDTCleanVolumeStepTemplate' {

    It 'writes a step an author can run as it stands' {
        $line = @(Get-HDTCleanVolumeStepTemplate)

        @($line | Where-Object { $_ -match '^\s*-\s*name:' }).Count | Should -Be 1
        @($line | Where-Object { $_ -match '^\s*type:\s*CleanVolume\s*$' }).Count | Should -Be 1
    }
}

Describe 'Get-HDTCleanVolumeStepDescription' {

    It 'says which volume it empties' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['volume'] = 'C'

        $step = [pscustomobject] @{ Index = 3; Name = 'Clean'; Type = 'CleanVolume'; Property = $bag }

        Get-HDTCleanVolumeStepDescription -Step $step | Should -Match 'C'
    }

    It 'names the published volume when the step names none' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $step = [pscustomobject] @{ Index = 3; Name = 'Clean'; Type = 'CleanVolume'; Property = $bag }

        Get-HDTCleanVolumeStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}
