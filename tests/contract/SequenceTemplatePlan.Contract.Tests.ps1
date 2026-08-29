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

    # Every DiskPartition step in every shipped template, flattened out of the
    # group tree with the template and step name kept, so a failure says WHICH.
    $script:diskStep = New-Object -TypeName System.Collections.ArrayList

    $script:walk = {
        param($Node, [string] $Template)

        foreach ($current in @($Node)) {
            if ($null -eq $current) { continue }
            if (-not ($current -is [System.Collections.IDictionary])) { continue }

            if ($current.Contains('steps')) { & $script:walk -Node $current['steps'] -Template $Template }
            if (-not $current.Contains('type')) { continue }
            if ([string] $current['type'] -ne 'DiskPartition') { continue }

            $stepName = '(unnamed)'
            if ($current.Contains('name')) { $stepName = [string] $current['name'] }

            [void] $script:diskStep.Add([pscustomobject] @{
                    Template = $Template
                    Name     = $stepName
                    Step     = $current
                })
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $script:templateRoot -Filter '*.yaml' -File -ErrorAction SilentlyContinue)) {
        $document = ConvertFrom-Yaml -Yaml ([System.IO.File]::ReadAllText($file.FullName)) -Ordered

        if ($null -eq $document) { continue }
        if (-not $document.Contains('steps')) { continue }

        & $script:walk -Node $document['steps'] -Template $file.Name
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
