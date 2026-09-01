# Applying imported Windows updates to the applied OS volume, offline.
#
# THE ASSERTIONS THAT MATTER HERE ARE ABOUT WHAT DECIDES SUCCESS, because the
# obvious answer is wrong and was measured to be wrong. dism exited 0xC0000409 -
# a stack buffer overrun - after a Windows 11 apply that had plainly worked, and
# exited 0 after the equivalent Server apply. A step that believed the exit code
# would have failed a good deployment on one machine and passed on the next.
#
# So the step re-reads the image and believes THAT, and the two tests named
# 'trusts the image over the exit code' and 'refuses an apply that dism called
# successful but did not land' are the pair that hold it in place.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:share = 'C:\Deploy'
    $script:osRoot = 'W:\'

    # THE TWO REAL PACKAGES, as Import-HDTWindowsUpdate really wrote them on
    # 2026-09-01. The package identities are the ones the packages' own CompDBs
    # declare - without the publisher key, which is the spelling DISM does NOT
    # use and the reason Test-HDTUpdatePackageMatch exists.
    $script:clientYaml = @(
        'schemaVersion: 1'
        'id: KB5094126-x64'
        'kb: KB5094126'
        'name: KB5094126 for Windows 11 24H2'
        'release: Win11-24H2'
        'kind: CumulativeUpdate'
        'architecture: x64'
        'fileName: windows11.0-kb5094126-x64.msu'
        'sizeBytes: 5111500010'
        'baselineVersion: 10.0.26100.1742'
        'targetVersion: 10.0.26100.8655'
        'build: 26100'
        'revision: 8655'
        'packageId: Package_for_RollupFix~~amd64~~26100.8655.1.20'
        'enabled: true'
    ) -join "`n"

    $script:serverYaml = @(
        'schemaVersion: 1'
        'id: KB5094125-x64'
        'kb: KB5094125'
        'name: KB5094125 for Windows Server 2025'
        'release: WS2025'
        'kind: CumulativeUpdate'
        'architecture: x64'
        'fileName: windows11.0-kb5094125-x64.msu'
        'targetVersion: 10.0.26100.32995'
        'build: 26100'
        'revision: 32995'
        'packageId: Package_for_RollupFix~~amd64~~26100.32995.1.21'
        'enabled: true'
    ) -join "`n"

    $script:clientPackage = 'C:\Deploy\WindowsUpdates\KB5094126-x64\windows11.0-kb5094126-x64.msu'
    $script:serverPackage = 'C:\Deploy\WindowsUpdates\KB5094125-x64\windows11.0-kb5094125-x64.msu'

    # DISM's SPELLING, WITH THE PUBLISHER KEY. Not the document's.
    $script:clientInstalled = 'Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8655.1.20'

    $script:newFile = {
        return @{
            'C:\Deploy\WindowsUpdates\KB5094126-x64\update.yaml' = $script:clientYaml
            'C:\Deploy\WindowsUpdates\KB5094125-x64\update.yaml' = $script:serverYaml
            $script:clientPackage                                = 'msu'
            $script:serverPackage                                = 'msu'
        }
    }

    $script:newStep = {
        param([hashtable] $Property = @{})

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($Property.Keys)) { $bag[$key] = $Property[$key] }

        return [pscustomobject] @{
            Index = 1; Name = 'Apply Windows Updates'; Type = 'ApplyUpdates'
            TimeoutMinutes = 0; Log = $null; Property = $bag
        }
    }

    $script:newContext = {
        param([object] $Image, [hashtable] $Variable = @{ HDTOSVolume = 'W' })

        $fileSystem = New-HDTFakeFileSystem -File (& $script:newFile)
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 1, 12, 0, 0, [System.DateTimeKind]::Utc))

        $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Image $Image

        $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
            -FileSystem $fileSystem -Clock $clock

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($Variable.Keys)) { $bag[$key] = $Variable[$key] }

        return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:share `
                -Variable $bag -Service $catalog -Log $log)
    }
}

Describe 'Invoke-HDTApplyUpdatesStep' {

    Context 'what it applies' {

        It 'applies only the updates filed under the step''s release' {
            $image = New-HDTFakeImageService `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $result = Invoke-HDTApplyUpdatesStep `
                -Step (& $script:newStep @{ release = 'Win11-24H2' }) `
                -Context (& $script:newContext $image)

            $result.Status | Should -BeExactly 'Completed'

            $added = @($image.Operations | Where-Object { $_.Operation -eq 'AddPackage' })
            $added.Count | Should -Be 1
            $added[0].Arguments[1] | Should -BeExactly $script:clientPackage
        }

        It 'applies every imported update when the step names no release' {
            $image = New-HDTFakeImageService

            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep) -Context (& $script:newContext $image)

            @($image.Operations | Where-Object { $_.Operation -eq 'AddPackage' }).Count | Should -Be 2
        }

        It 'injects into the volume the partition step published' {
            $image = New-HDTFakeImageService

            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep) -Context (& $script:newContext $image)

            @($image.Operations | Where-Object { $_.Operation -eq 'AddPackage' })[0].Arguments[0] |
                Should -BeExactly $script:osRoot
        }

        It 'refuses rather than guessing a volume when HDTOSVolume is not set' {
            $image = New-HDTFakeImageService

            $result = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep) `
                -Context (& $script:newContext $image @{})

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Match 'will not guess'
            @($image.Operations | Where-Object { $_.Operation -eq 'AddPackage' }).Count | Should -Be 0
        }

        It 'completes without applying anything when nothing is imported for the release' {
            # A SEQUENCE BUILT BEFORE ITS CONTENT EXISTS IS NOT A FAILURE.
            $image = New-HDTFakeImageService

            $result = Invoke-HDTApplyUpdatesStep `
                -Step (& $script:newStep @{ release = 'Win11-26H2' }) `
                -Context (& $script:newContext $image)

            $result.Status | Should -BeExactly 'Completed'
            $result.Data['considered'] | Should -Be 0
            @($image.Operations | Where-Object { $_.Operation -eq 'AddPackage' }).Count | Should -Be 0
        }
    }

    Context 'what decides success' {

        It 'trusts the image over the exit code' {
            # THE 0xC0000409 CASE, MEASURED ON 2026-09-01. dism crashed on its way
            # out of a Windows 11 apply that had plainly worked - the image went
            # 26100.1742 -> 26100.8655 and its package count 85 -> 159. A step
            # that read the exit code would have failed that deployment.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ ExitCode = -1073740791 } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $result = Invoke-HDTApplyUpdatesStep `
                -Step (& $script:newStep @{ release = 'Win11-24H2' }) `
                -Context (& $script:newContext $image)

            $result.Status | Should -BeExactly 'Completed'
            $result.Data['applied'] | Should -Be 1
        }

        It 'refuses an apply that dism called successful but did not land' {
            # THE OTHER DIRECTION, AND THE ONE A NAIVE STEP GETS WRONG SILENTLY:
            # exit 0, nothing on the image. Believing the number here ships an
            # unpatched machine and reports a green deployment.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ ExitCode = 0 } }

            $result = Invoke-HDTApplyUpdatesStep `
                -Step (& $script:newStep @{ release = 'Win11-24H2' }) `
                -Context (& $script:newContext $image)

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Match 'KB5094126'
        }

        It 'matches the package identity across the two spellings the tools use' {
            # The document says Package_for_RollupFix~~amd64~~26100.8655.1.20 and
            # DISM says Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8655.1.20.
            # If these did not match, every successful apply would read as a failure.
            $image = New-HDTFakeImageService `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            (Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) `
                    -Context (& $script:newContext $image)).Data['applied'] | Should -Be 1
        }

        It 'counts a package already in the image as present rather than applying it again' {
            $image = New-HDTFakeImageService `
                -ImagePackage @{ $script:osRoot = @([pscustomobject] @{ Name = $script:clientInstalled; State = 'Installed' }) }

            $result = Invoke-HDTApplyUpdatesStep `
                -Step (& $script:newStep @{ release = 'Win11-24H2' }) `
                -Context (& $script:newContext $image)

            $result.Status | Should -BeExactly 'Completed'
            $result.Data['alreadyPresent'] | Should -Be 1
            @($image.Operations | Where-Object { $_.Operation -eq 'AddPackage' }).Count | Should -Be 0
        }
    }

    Context 'one bad package among several' {

        It 'applies the rest rather than stopping at the first failure' {
            # MDT'S HALF THAT IS RIGHT. ZTIPatches never stops at a bad package;
            # what it also never does is report one, which is the half below.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ ExitCode = 50 } } `
                -PackageInstalls @{ $script:serverPackage = @('Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.32995.1.21') }

            $result = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep) -Context (& $script:newContext $image)

            @($image.Operations | Where-Object { $_.Operation -eq 'AddPackage' }).Count | Should -Be 2
            $result.Data['applied'] | Should -Be 1
        }

        It 'fails the step and names every package that failed' {
            # MDT'S HALF THAT IS WRONG. ZTIPatches logs a non-zero DISM return and
            # still returns Success, so a deployment that patched nothing looks
            # green. This one reports.
            $image = New-HDTFakeImageService `
                -PackageResult @{
                    $script:clientPackage = @{ ExitCode = 50 }
                    $script:serverPackage = @{ ExitCode = 50 }
                }

            $result = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep) -Context (& $script:newContext $image)

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Match 'KB5094126'
            $result.Message | Should -Match 'KB5094125'
        }

        It 'does not fail the step for a package that is simply not applicable' {
            # 0x800F081E is the ORDINARY result of importing a broad set. Treating
            # it as failure would make the feature unusable for its own workflow.
            $image = New-HDTFakeImageService `
                -PackageResult @{
                    $script:clientPackage = @{ ExitCode = -2146498530 }
                    $script:serverPackage = @{ ExitCode = -2146498530 }
                }

            $result = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep) -Context (& $script:newContext $image)

            $result.Status | Should -BeExactly 'Completed'
            $result.Data['notApplicable'] | Should -Be 2
            $result.Data['failed'] | Should -Be 0
        }
    }

    Context 'what it writes to the log' {

        It 'writes one update.apply record per package, not one summary for the pass' {
            # CLAUDE.md's logging rule. Twenty updates is twenty questions asked
            # afterwards, and a single summary answers none of them.
            $image = New-HDTFakeImageService `
                -PackageInstalls @{
                    $script:clientPackage = @($script:clientInstalled)
                    $script:serverPackage = @('Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.32995.1.21')
                }

            $context = & $script:newContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep) -Context $context

            $record = @(Get-HDTRunLogRecord -Context $context.Log |
                    Where-Object { $_.Event -eq 'update.apply' })

            @($record | Where-Object { $_.Data.kb -eq 'KB5094126' }).Count | Should -Be 1
            @($record | Where-Object { $_.Data.kb -eq 'KB5094125' }).Count | Should -Be 1
        }

        It 'records the outcome and the release on every package record' {
            $image = New-HDTFakeImageService `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $record = @(Get-HDTRunLogRecord -Context $context.Log |
                    Where-Object { $_.Event -eq 'update.apply' -and $_.Data.kb -eq 'KB5094126' })[0]

            $record.Data.outcome | Should -BeExactly 'Applied'
            $record.Data.release | Should -BeExactly 'Win11-24H2'
        }
    }
}
