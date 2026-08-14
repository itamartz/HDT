# AN ADAPTER THAT DESTROYS THINGS MAY NOT RELY ON AN AMBIENT PREFERENCE TO
# NOTICE THAT IT FAILED.
#
# Every Storage cmdlet in New-HDTDiskService was written without -ErrorAction.
# That works while $ErrorActionPreference is 'Stop' - which the module sets, and
# which engine code is required to set (CLAUDE.md rule 7) - and it means
# something completely different the moment it is not: Clear-Disk writes a
# non-terminating error, the method RETURNS NORMALLY, and the step that called it
# reports success over a disk it did not clear.
#
# THAT IS NOT HYPOTHETICAL. 05-06's ./build.ps1 -Task integration run, on BOTH
# engines:
#
#   The disk has not been initialized.
#   [-] IDiskService against a scratch VHDX.clear and initialise.refuses to
#       clear a disk that has never been initialised
#       Expected an exception ... but no exception was thrown.
#
# Clear-Disk DID fail - its message is right there in the log - and ClearDisk
# returned as though it had not. The disk was RAW, asserted one line earlier in
# the same test.
#
# WHY the preference was not 'Stop' in that scope was NOT ESTABLISHED, and the
# repository will not pretend otherwise: the failure reproduces only in the full
# seven-file run and passes in every subset tried (the file alone; with
# DiskPartition; with BootImage; with BootImage and DiskPartition; with the four
# files that follow it). SPIKES S13.6 records that honestly.
#
# What IS established is that the question should never have been able to arise.
# -ErrorAction Stop on the call makes the behaviour a property of the code rather
# than of whatever the caller's scope happened to hold. This file is what keeps
# it there, and it is deliberately about the DESTRUCTIVE half: a Get- that
# returns nothing is a legitimate answer, and DESIGN 9.1's refusals are built on
# that.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:sourcePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/New-HDTDiskService.ps1'

    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:sourcePath, [ref] $null, [ref] $null)

    # The Storage cmdlets that CHANGE something. Get-Disk, Get-Partition and
    # Get-Volume are deliberately absent.
    $script:destructive = @(
        'Clear-Disk', 'Initialize-Disk', 'New-Partition', 'Set-Partition',
        'Remove-Partition', 'Format-Volume',
        'Add-PartitionAccessPath', 'Remove-PartitionAccessPath', 'Set-Disk'
    )

    $script:call = @($script:ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true) |
            Where-Object { $script:destructive -contains [string] $_.GetCommandName() })
}

Describe 'New-HDTDiskService and the preference it must not depend on' {

    It 'found the destructive Storage calls' {
        # Against a floor. A scan that matched nothing would make the assertion
        # below true over an empty set (SPIKES S9.15b).
        @($script:call).Count | Should -BeGreaterOrEqual 6
    }

    It 'passes -ErrorAction Stop to every one of them' {
        foreach ($node in $script:call) {
            $element = @($node.CommandElements | ForEach-Object { [string] $_.Extent.Text })

            # A splatted call carries it in the hashtable instead - New-Partition
            # is the only one, because -Size and -UseMaximumSize are mutually
            # exclusive and the arguments have to be built. Same requirement,
            # different spelling, so the assertion reads the whole method.
            $splatted = @($element | Where-Object { $_ -like '@*' })

            if (@($splatted).Count -gt 0) {
                $scope = $node.Parent
                while ($null -ne $scope -and -not ($scope -is [System.Management.Automation.Language.ScriptBlockAst])) {
                    $scope = $scope.Parent
                }

                [string] $scope.Extent.Text |
                    Should -Match "ErrorAction\s*=\s*'Stop'" -Because (
                    "{0} on line {1} is splatted, so its splat must carry ErrorAction = 'Stop'" -f
                    $node.GetCommandName(), $node.Extent.StartLineNumber)

                continue
            }

            $index = [array]::IndexOf($element, '-ErrorAction')

            $index | Should -BeGreaterThan 0 -Because (
                "{0} on line {1} changes the disk and must not depend on the caller's ErrorActionPreference to report a failure" -f
                $node.GetCommandName(), $node.Extent.StartLineNumber)

            $element[$index + 1] | Should -BeExactly 'Stop' -Because (
                "{0} on line {1} must stop, not continue" -f $node.GetCommandName(), $node.Extent.StartLineNumber)
        }
    }

    It 'leaves the read-only calls alone' {
        # The converse, so the rule above cannot quietly grow into "put
        # -ErrorAction Stop on everything". Get-Disk returning nothing is how
        # AssertDisk and DESIGN 9.1's refusal to guess a target both work.
        $reader = @($script:ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    @('Get-Disk', 'Get-Partition', 'Get-Volume') -contains [string] $node.GetCommandName()
                }, $true))

        @($reader).Count | Should -BeGreaterOrEqual 3

        foreach ($node in $reader) {
            @($node.CommandElements | ForEach-Object { [string] $_.Extent.Text }) |
                Should -Not -Contain '-ErrorAction'
        }
    }
}
