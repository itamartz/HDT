# The shipped sequence templates, PLANNED rather than merely parsed.
#
# THIS EXISTS BECAUSE THE SHIPPED CLIENT TEMPLATE COULD NOT PARTITION A DISK.
# 'Format and Partition Disk (UEFI)' authors its partition table inline, and an
# authored table came back with DriveLetter = '' on every row - so the step
# handed the disk service an empty letter, which is how that service is told to
# REMOVE an access path. On the first bare-metal machine that ever ran it:
#
#   disk 0 failed while lettering the System partition:
#   SetPartitionDriveLetter ... "The access path is not valid."
#
# NOTHING CAUGHT IT, through ten thousand tests and a full end-to-end VM
# deployment, because the VM sequences used a NAMED layout - uefi-standard,
# which carries S/W/R - and the shipped templates were only ever parsed and
# schema-checked. Nobody ever planned one.
#
# So this plans every DiskPartition step in every shipped template, the way the
# step does, and asserts the plan is something a disk could actually be built
# from. It covers the templates as a SET, so a template added tomorrow is
# covered on the day it appears.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name powershell-yaml -ErrorAction Stop

    $script:templateRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Templates'

    # EVERY SEQUENCE THIS REPOSITORY SHIPS, not only the ones under Templates.
    # A sample and an e2e payload are copied onto real shares and run on real
    # machines exactly as written, so a rule that judged Templates alone would
    # exempt fourteen sequences that partition disks for a living.
    $script:sequenceFile = New-Object -TypeName System.Collections.ArrayList

    foreach ($file in @(Get-ChildItem -LiteralPath $script:templateRoot -Filter '*.yaml' -File -ErrorAction SilentlyContinue)) {
        [void] $script:sequenceFile.Add($file)
    }

    foreach ($relative in @('samples/workspace/TaskSequences', 'tests/e2e/payload')) {
        $root = Join-Path -Path $script:repoRoot -ChildPath $relative
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'sequence.yaml' -File -Recurse -ErrorAction SilentlyContinue)) {
            [void] $script:sequenceFile.Add($file)
        }
    }

    # Every DiskPartition step in every shipped sequence, flattened out of the
    # group tree with the template and step name kept, so a failure says WHICH -
    # and with the condition of every group it sits inside, because a group
    # condition gates its children and Invoke-HDTTaskSequence evaluates the
    # ancestors before the step's own.
    $script:diskStep = New-Object -TypeName System.Collections.ArrayList

    $script:walk = {
        param($Node, [string] $Template, $Ancestor = @())

        foreach ($current in @($Node)) {
            if ($null -eq $current) { continue }
            if (-not ($current -is [System.Collections.IDictionary])) { continue }

            if ($current.Contains('steps')) {
                $inner = @($Ancestor)

                if ($current.Contains('condition')) {
                    $groupName = '(unnamed group)'
                    if ($current.Contains('group')) { $groupName = [string] $current['group'] }

                    $inner += [pscustomobject] @{
                        Owner     = "group '$groupName'"
                        Condition = [string] $current['condition']
                    }
                }

                & $script:walk -Node $current['steps'] -Template $Template -Ancestor $inner
            }

            if (-not $current.Contains('type')) { continue }
            if ([string] $current['type'] -ne 'DiskPartition') { continue }

            $stepName = '(unnamed)'
            if ($current.Contains('name')) { $stepName = [string] $current['name'] }

            # EVERY CONDITION THAT STANDS BETWEEN THIS STEP AND RUNNING, in the
            # order the engine tests them: the groups outermost first, the step's
            # own last.
            $gate = @($Ancestor)

            if ($current.Contains('condition')) {
                $gate += [pscustomobject] @{
                    Owner     = "the step itself"
                    Condition = [string] $current['condition']
                }
            }

            [void] $script:diskStep.Add([pscustomobject] @{
                    Template = $Template
                    Name     = $stepName
                    Step     = $current
                    Gate     = [pscustomobject[]] @($gate)
                })
        }
    }

    foreach ($file in @($script:sequenceFile)) {
        $document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($file.FullName)) -Ordered

        if ($null -eq $document) { continue }
        if (-not $document.Contains('steps')) { continue }

        # 'client.yaml' names itself; 'REF-BUILD/sequence.yaml' needs its folder
        # to, because every one of those files has the same name.
        $label = $file.Name
        if ($file.Name -eq 'sequence.yaml') { $label = '{0}/{1}' -f (Split-Path -Leaf $file.DirectoryName), $file.Name }

        & $script:walk -Node $document['steps'] -Template $label -Ancestor @()
    }

    # The style the step would resolve: an EFI row means the template wrote
    # this one for a GPT disk, which is what Resolve-HDTDiskLayoutName decides
    # from the firmware at run time.
    $script:planOf = {
        param($Step)

        $authored = $Step['partition']
        if ($null -eq $authored) { return $null }

        $style = 'MBR'
        if (@(@($authored) | Where-Object { [string] $_['type'] -eq 'EFI' }).Count -gt 0) { $style = 'GPT' }

        $layout = ConvertTo-HDTDiskLayout -Partition ([object[]] @($authored)) -Style $style

        return [pscustomobject] @{
            Layout = $layout
            Plan   = @(New-HDTDiskLayoutPlan -Layout $layout -DiskSizeByte 512110190592)
        }
    }
}

Describe 'Shipped sequence template plan contract' {

    It 'finds the DiskPartition steps to check' {
        # A guard on the guard: an empty list passes every assertion below.
        $script:diskStep.Count | Should -BeGreaterThan 0
    }

    It 'gates every DiskPartition step on the deployment type, in every shipped sequence' {
        # MDT'S OWN SHAPE. Client.xml wraps Validate and both partition steps in
        # a group called "New Computer only", conditioned on DeploymentType, and
        # leaves the firmware test on the step. HDT does the same thing with the
        # same two levels, because its condition grammar is a single comparison -
        # there is no '-and', so a step already carrying '$HDTIsUEFI -eq $true'
        # has nowhere to put a second test and the group is where it goes.
        #
        # THIS IS DEFENCE IN DEPTH, NOT THE GUARANTEE. The engine already refuses
        # DiskPartition on any resumed leg outright, under every deployment type
        # (Get-HDTResumeForbiddenStepType), and it FAILS rather than skips. A
        # condition is evaluated against the variable bag, which on a resumed leg
        # is rehydrated from state.json - the same trust as the value the resume
        # refusal reads, no more. What it adds is that an administrator opening
        # the template can SEE that a Refresh does not repartition, instead of
        # having to know a rule in the engine.
        #
        # TESTED BY EVALUATING IT, NOT BY MATCHING TEXT. '%HDTDeploymentType%'
        # and '$HDTDeploymentType' are the same token to the engine, and '!=' and
        # '-ne' the same operator, so a spelling test would pass the wrong things
        # and fail the right ones. A condition qualifies when the real evaluator
        # says true for NEWCOMPUTER and false for REFRESH, with nothing else set -
        # which is exactly what the step needs and no other condition can fake.
        # The firmware conditions compare an unresolved '%HDTIsUEFI%' to 'True'
        # in both bags, so they answer false twice and are never mistaken for it.
        $ungated = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:diskStep) {
            $found = $false

            foreach ($clause in @($current.Gate)) {
                $onNew = Test-HDTStepCondition -Condition $clause.Condition -Variable @{ HDTDeploymentType = 'NEWCOMPUTER' }
                $onRefresh = Test-HDTStepCondition -Condition $clause.Condition -Variable @{ HDTDeploymentType = 'REFRESH' }

                if ($onNew -and -not $onRefresh) {
                    $found = $true
                    break
                }
            }

            if (-not $found) {
                [void] $ungated.Add(('{0} / {1}: nothing between it and running says the deployment type is not REFRESH ({2})' -f
                        $current.Template, $current.Name,
                        $(if (@($current.Gate).Count -eq 0) { 'it carries no condition at all' } else { (@($current.Gate) | ForEach-Object { $_.Condition }) -join ' ; ' })))
            }
        }

        # THE WHOLE LIST, NOT THE FIRST ONE. A template added without the gate is
        # usually a template copied from one that had it and lost a level.
        ($ungated -join ' | ') | Should -BeNullOrEmpty
    }

    It 'ships no DiskPartition step in refresh.yaml at all' {
        # THE OTHER HALF OF THE SAME DECISION, PINNED RATHER THAN LEFT TRUE BY
        # HABIT. A Refresh empties the volume by deletion and keeps the partition
        # table it found; refresh.yaml says so in a comment ("THERE IS NO
        # DiskPartition STEP IN THIS FILE, AND ITS ABSENCE IS THE DESIGN") and a
        # comment stops nobody. The condition above would gate a DiskPartition
        # step added here into never running, which is the quiet failure - a step
        # in the file that an administrator reads as part of a Refresh and that
        # is skipped on every run. It does not belong in the file.
        @($script:sequenceFile | Where-Object { $_.Name -eq 'refresh.yaml' }).Count |
            Should -Be 1 -Because 'the assertion below is vacuous if the file was never read'

        @($script:diskStep | Where-Object { $_.Template -eq 'refresh.yaml' } | ForEach-Object { $_.Name }) -join ', ' |
            Should -BeNullOrEmpty
    }

    It 'gives every partition a drive letter, in every shipped template' {
        # THE REGRESSION, at the level it shipped from. A blank letter here is
        # a bare-metal deployment that dies at the partitioner.
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:diskStep) {
            try {
                $answer = & $script:planOf -Step $current.Step
                if ($null -eq $answer) { continue }

                foreach ($row in $answer.Plan) {
                    if ([string]::IsNullOrWhiteSpace([string] $row.DriveLetter)) {
                        [void] $broken.Add(('{0} / {1}: {2} has no drive letter' -f $current.Template, $current.Name, $row.Role))
                    }
                }
            } catch {
                [void] $broken.Add(('{0} / {1}: {2}' -f $current.Template, $current.Name, [string] $_.Exception.Message))
            }
        }

        # THE WHOLE LIST, NOT THE FIRST ONE. A template bug is usually a habit.
        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'publishes a Windows volume for the steps that follow, in every shipped template' {
        # HDTOSVolume IS READ OFF THIS PLAN. Empty, every step downstream of the
        # partitioner is handed a blank target - ApplyImage included - and the
        # first thing to complain is not the partitioner.
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:diskStep) {
            $answer = & $script:planOf -Step $current.Step
            if ($null -eq $answer) { continue }

            $windows = @($answer.Plan | Where-Object { $_.Role -eq 'Windows' })

            if ($windows.Count -ne 1) {
                [void] $broken.Add(('{0} / {1}: {2} Windows partitions' -f $current.Template, $current.Name, $windows.Count))
                continue
            }

            if ([string]::IsNullOrWhiteSpace([string] $windows[0].DriveLetter)) {
                [void] $broken.Add(('{0} / {1}: the Windows partition has no drive letter' -f $current.Template, $current.Name))
            }
        }

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'creates only the last partition with UseMaximumSize, in every shipped template' {
        # THE SECOND WAY THE SHIPPED TEMPLATE COULD NOT PARTITION A DISK.
        # New-Partition -UseMaximumSize takes everything left, so a row carrying
        # it with anything authored after it starves every one of them:
        #
        #   disk 0 failed while creating the Recovery partition:
        #   NewPartition ... "Not enough available capacity"
        #
        # Both named layouts put the flag on the last row - uefi-standard on
        # Recovery, bios-standard on Windows - so the trailing alignment slack
        # lands in a partition instead of unallocated at the end of the disk.
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:diskStep) {
            $answer = & $script:planOf -Step $current.Step
            if ($null -eq $answer) { continue }

            $row = @($answer.Layout.Partition)
            $greedy = @(0..($row.Count - 1) | Where-Object { $row[$_].UseMaximumSize })

            if ($greedy.Count -ne 1) {
                [void] $broken.Add(('{0} / {1}: {2} rows take the maximum' -f $current.Template, $current.Name, $greedy.Count))
                continue
            }

            if ($greedy[0] -ne ($row.Count - 1)) {
                [void] $broken.Add(('{0} / {1}: {2} takes the maximum with {3} partition(s) after it' -f
                        $current.Template, $current.Name, $row[$greedy[0]].Label, ($row.Count - 1 - $greedy[0])))
            }
        }

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }

    It 'hands out no letter twice, in every shipped template' {
        # Two rows on one letter is one volume formatted twice, and the second
        # format destroys what the first one held.
        $broken = New-Object -TypeName System.Collections.ArrayList

        foreach ($current in $script:diskStep) {
            $answer = & $script:planOf -Step $current.Step
            if ($null -eq $answer) { continue }

            $letter = @($answer.Layout.Partition | ForEach-Object { [string] $_.DriveLetter })

            if (@($letter | Sort-Object -Unique).Count -ne $letter.Count) {
                [void] $broken.Add(('{0} / {1}: {2}' -f $current.Template, $current.Name, ($letter -join ',')))
            }
        }

        ($broken -join ' | ') | Should -BeNullOrEmpty
    }
}

Describe 'Shipped sequence templates: drivers are staged before the answer file is applied' {

    # THE DRIVERS HAVE TO BE ON THE VOLUME BEFORE offlineServicing LOOKS FOR THEM.
    #
    # unattend.xml carries Microsoft-Windows-PnpCustomizationsNonWinPE with
    # DriverPaths pointing at \Drivers, in the offlineServicing pass - which is
    # processed the moment the answer file is APPLIED TO THE OFFLINE IMAGE. That
    # is what ApplyUnattend does, and its own log line says so: "applied the
    # unattend to the offline image at W:\, which runs its offlineServicing
    # pass".
    #
    # client.yaml shipped ApplyUnattend BEFORE ApplyDrivers, so that pass scanned
    # a \Drivers folder that did not exist yet and injected nothing. Every driver
    # was left to be found by PnP after first boot instead - which does happen,
    # asynchronously, which is why a real Latitude came up with ten devices
    # yellow in Device Manager that resolved themselves a few minutes later while
    # nobody touched it. The feature looked like it worked and never once ran.
    #
    # AGAINST THE SET, so a template added tomorrow cannot reintroduce the order.

    BeforeAll {
        $script:orderRoot = Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'src/Hephaestus/Templates'

        $script:typeOrder = New-Object -TypeName System.Collections.ArrayList

        $script:orderWalk = {
            param($Node, [string] $Template)

            foreach ($current in @($Node)) {
                if ($null -eq $current) { continue }
                if (-not ($current -is [System.Collections.IDictionary])) { continue }

                if ($current.Contains('steps')) { & $script:orderWalk -Node $current['steps'] -Template $Template }
                if (-not $current.Contains('type')) { continue }

                [void] $script:typeOrder.Add([pscustomobject] @{
                        Template = $Template
                        Type     = [string] $current['type']
                    })
            }
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $script:orderRoot -Filter '*.yaml' -File -ErrorAction SilentlyContinue)) {
            $document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($file.FullName)) -Ordered

            if ($null -eq $document) { continue }
            if (-not $document.Contains('steps')) { continue }

            & $script:orderWalk -Node $document['steps'] -Template $file.Name
        }
    }

    It 'puts ApplyDrivers before ApplyUnattend in every template that has both' {
        $offender = @()

        foreach ($template in @($script:typeOrder | ForEach-Object { $_.Template } | Sort-Object -Unique)) {
            $ordered = @($script:typeOrder | Where-Object { $_.Template -eq $template } | ForEach-Object { $_.Type })

            $driverAt = [array]::IndexOf($ordered, 'ApplyDrivers')
            $unattendAt = [array]::IndexOf($ordered, 'ApplyUnattend')

            if ($driverAt -lt 0 -or $unattendAt -lt 0) { continue }

            if ($driverAt -gt $unattendAt) {
                $offender += ('{0} (ApplyDrivers at {1}, ApplyUnattend at {2})' -f $template, $driverAt, $unattendAt)
            }
        }

        ($offender -join '; ') | Should -BeExactly ''
    }
}
