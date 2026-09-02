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
    Context 'what it says while it is running' {

        # THE DEFECT THIS CONTEXT EXISTS FOR, FOUND BY READING A REAL LOG.
        # HDT-UPD-01 run-20260902-004953 step 7 was EIGHT MINUTES of one
        # cumulative update and wrote TWO step.progress records for the whole of
        # it - "considering 1 update(s)" and "applying KB5094126 (1 of 1)". The
        # bar in front of whoever was standing at the machine did not move once,
        # and a motionless bar is indistinguishable from a hung machine.
        #
        # THE NUMBER WAS THERE ALL ALONG. dism /Add-Package prints the same
        # percentage meter /Apply-Image does - measured on this machine on
        # 2026-09-02, 58 bar lines out of 124 for one WinPE-NetFx.cab - and the
        # adapter was collecting it into a string array the step threw away.

        BeforeEach {
            $script:meter = [string[]] [System.IO.File]::ReadAllLines(
                (Join-Path -Path $script:repoRoot -ChildPath 'tests/fixtures/image/dism-add-package-output.txt'))

            $script:progressHost = New-HDTFakeProgressHost

            $script:newProgressContext = {
                param([object] $Image, [hashtable] $Variable = @{ HDTOSVolume = 'W' })

                $fileSystem = New-HDTFakeFileSystem -File (& $script:newFile)
                $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 1, 12, 0, 0, [System.DateTimeKind]::Utc)) `
                    -TickMillisecond 500

                $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Image $Image `
                    -Progress $script:progressHost

                $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                    -FileSystem $fileSystem -Clock $clock

                $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($key in @($Variable.Keys)) { $bag[$key] = $Variable[$key] }

                return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:share `
                        -Variable $bag -Service $catalog -Log $log)
            }

            # A FIELD THAT IS ABSENT BY DESIGN, READ THE ONLY WAY STRICT MODE
            # ALLOWS. A step.progress from the pass opening carries no kb, and
            # a record that is not this step's carries no Data at all - so a
            # bare $_.Data.kb in a Where-Object over the whole log THROWS under
            # Set-StrictMode -Version Latest. It passes in a direct
            # Invoke-Pester run and fails the gate, which is the gate being
            # right. PSObject.Properties answers 'absent' instead of raising.
            $script:fieldOf = {
                param([object] $Record, [string] $Name)

                if ($null -eq $Record.PSObject.Properties['Data'] -or $null -eq $Record.Data) { return $null }

                $property = $Record.Data.PSObject.Properties[$Name]
                if ($null -eq $property) { return $null }

                return $property.Value
            }

            $script:percentOf = {
                param([object] $Context)

                return @(Get-HDTRunLogRecord -Context $Context.Log |
                        Where-Object { $_.Event -eq 'step.progress' -and $null -ne (& $script:fieldOf $_ 'percent') } |
                        ForEach-Object { [int] (& $script:fieldOf $_ 'percent') })
            }
        }

        It 'streams the meter rather than writing one record for the whole package' {
            # THE ASSERTION THAT WOULD HAVE FAILED THE SHIPPED STEP. Two records
            # for eight minutes was what a technician watched; anything that
            # tracks the tool has to be an order of magnitude more than that.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ Output = $script:meter } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newProgressContext $image
            $result = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $percent = & $script:percentOf $context

            $percent.Count | Should -BeGreaterThan 12
            $percent[-1] | Should -Be 100
        }

        It 'never lets the number go backwards' {
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ Output = $script:meter } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newProgressContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $percent = & $script:percentOf $context

            for ($i = 1; $i -lt $percent.Count; $i++) {
                $percent[$i] | Should -BeGreaterOrEqual $percent[$i - 1]
            }
        }

        It 'scales each package meter into its own slice of the step' {
            # PACKAGE PROGRESS IS NOT STEP PROGRESS. Three cumulative updates
            # each reporting their own 0-100 would send the bar back to zero
            # twice, and a bar that restarts reads as a deployment that
            # restarted. The step's number is the position of this package in
            # the set plus this package's own share of one slice.
            $image = New-HDTFakeImageService `
                -PackageResult @{
                    $script:clientPackage = @{ Output = $script:meter }
                    $script:serverPackage = @{ Output = $script:meter }
                } `
                -PackageInstalls @{
                    $script:clientPackage = @($script:clientInstalled)
                    $script:serverPackage = @('Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.32995.1.21')
                }

            $context = & $script:newProgressContext $image
            $result = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep) -Context $context

            $result.Status | Should -BeExactly 'Completed'

            $percent = & $script:percentOf $context

            # TWO PACKAGES IS TWO HALVES. The first one cannot reach past the
            # halfway mark however far dism gets through it, and the second one
            # has to finish the bar.
            @($percent | Where-Object { $_ -gt 50 }).Count | Should -BeGreaterThan 5
            $percent[-1] | Should -Be 100

            $record = @(Get-HDTRunLogRecord -Context $context.Log |
                    Where-Object { $_.Event -eq 'step.progress' -and [string] (& $script:fieldOf $_ 'kb') -eq 'KB5094126' })

            @($record | ForEach-Object { [int] $_.Data.percent } | Sort-Object -Descending)[0] |
                Should -BeLessOrEqual 50
        }

        It 'names the package, its place in the set and its own percentage' {
            # THE MESSAGE IS THE PACKAGE'S OWN NUMBER AND THE DATA IS THE STEP'S.
            # A reader with dism.log open beside this one matches on the number
            # dism printed; the bar reads data.percent, which belongs to the step.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ Output = $script:meter } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newProgressContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $record = @(Get-HDTRunLogRecord -Context $context.Log |
                    Where-Object { $_.Event -eq 'step.progress' -and $null -ne (& $script:fieldOf $_ 'packagePercent') })

            $record.Count | Should -BeGreaterThan 12
            [string] $record[0].Message | Should -Match 'KB5094126 \(1 of 1\): \d+%'
            [string] $record[0].Data.kb | Should -BeExactly 'KB5094126'
            [int] $record[0].Data.total | Should -Be 1
        }

        It 'writes nothing extra when dism prints no meter at all' {
            # A record per line of output would be a bar driven by how chatty a
            # tool is. Only the boundary records survive: the pass opening and
            # the package announcing itself.
            $image = New-HDTFakeImageService `
                -PackageResult @{
                    $script:clientPackage = @{
                        Output = @('Deployment Image Servicing and Management tool', 'Version: 10.0.26100.8521',
                            '', 'The operation completed successfully.')
                    }
                } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newProgressContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            @(Get-HDTRunLogRecord -Context $context.Log |
                    Where-Object { $_.Event -eq 'step.progress' -and $null -ne (& $script:fieldOf $_ 'packagePercent') }) |
                Should -BeNullOrEmpty
        }

        It 'keeps the progress it made when the package then fails' {
            # A PACKAGE THAT DIED AT 60% DIED SOMEWHERE DIFFERENT from one that
            # never started, and the log is the only place to tell them apart.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ Output = $script:meter[0..60] } } `
                -Failure @{ AddPackage = 'Error: 0x8007000E - Not enough memory.' }

            $context = & $script:newProgressContext $image
            $result = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $result.Status | Should -BeExactly 'Failed'

            $percent = & $script:percentOf $context

            $percent.Count | Should -BeGreaterThan 5
            $percent[-1] | Should -BeLessThan 100
        }

        It 'drives the progress display while the package is still being applied' {
            # THE HALF THAT WAS MISSING FROM ApplyDrivers: the record reached the
            # jsonl and nothing told the window to read it back, so a step
            # reported into a file nobody was reading.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ Output = $script:meter } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newProgressContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            # THE DISPLAY THE STEP ACTUALLY DROVE, read off the context rather
            # than off a variable a test believes is the same object.
            # IProgressHost's fake records operation NAMES, not objects.
            $display = $context.Service.Progress
            $update = @($display.Operations | Where-Object { $_ -eq 'Update' })

            $update.Count | Should -BeGreaterThan 12 -Because 'a display updated twice in eight minutes is the bar that never moves'
            [int] $display.LastProgress.StepPercent | Should -Be 100
        }

        It 'still asks the service for exactly the same apply' {
            # The progress channel is an addition, not a change: what the step
            # asks for is what it always asked for.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ Output = $script:meter } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newProgressContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $added = @($image.Operations | Where-Object { $_.Operation -eq 'AddPackage' })

            $added.Count | Should -Be 1
            @($added[0].Arguments).Count | Should -Be 2
            [string] $added[0].Arguments[1] | Should -BeExactly $script:clientPackage
        }

        It 'still judges the apply by the image and not by the exit code' {
            # THE VERDICT IS NOT WHAT CHANGED. dism exited 0xC0000409 after an
            # apply that had plainly worked; adding a meter must not quietly turn
            # the number back into the judge.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ ExitCode = -1073740791; Output = $script:meter } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newProgressContext $image
            $result = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $result.Status | Should -BeExactly 'Completed'
            $result.Data['applied'] | Should -Be 1
        }
    }

    Context 'what a reader at three in the morning needs' {

        # THE WHOLE STEP LOG FOR AN EIGHT-MINUTE PASS WAS FIVE LINES, and none of
        # them said which updates were passed over or why. CLAUDE.md's rule is
        # write too much, never too little: a pass that skipped nineteen of
        # twenty imported updates has to say so by name.

        It 'says by name which imported updates it passed over, and why' {
            $image = New-HDTFakeImageService `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $record = @(Get-HDTRunLogRecord -Context $context.Log |
                    Where-Object { [string] (& $script:fieldOf $_ 'kb') -eq 'KB5094125' -and
                        [string] (& $script:fieldOf $_ 'selected') -eq 'False' })

            $record.Count | Should -Be 1
            [string] $record[0].Message | Should -Match 'WS2025'
            [string] $record[0].Message | Should -Match 'Win11-24H2'
        }

        It 'names the build each package takes the image from and to' {
            # "IT PATCHED" IS NOT AN ANSWER AT 3AM. 26100.1742 -> 26100.8655 is,
            # and it is the number a technician compares winver against.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ ExitCode = 0 } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $record = @(Get-HDTRunLogRecord -Context $context.Log |
                    Where-Object { $_.Event -eq 'update.apply' -and [string] $_.Data.kb -eq 'KB5094126' })[0]

            [string] $record.Data.targetVersion | Should -BeExactly '10.0.26100.8655'
            [string] $record.Data.baselineVersion | Should -BeExactly '10.0.26100.1742'
            [string] $record.Data.target | Should -BeExactly 'W:\'
        }

        It 'spells the exit code the way dism does' {
            # 0xC0000409 IS SEARCHABLE AND -1073740791 IS NOT. A technician with
            # dism.log open is looking for the hex.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $script:clientPackage = @{ ExitCode = -1073740791 } } `
                -PackageInstalls @{ $script:clientPackage = @($script:clientInstalled) }

            $context = & $script:newContext $image
            $null = Invoke-HDTApplyUpdatesStep -Step (& $script:newStep @{ release = 'Win11-24H2' }) -Context $context

            $record = @(Get-HDTRunLogRecord -Context $context.Log |
                    Where-Object { $_.Event -eq 'update.apply' -and [string] $_.Data.kb -eq 'KB5094126' })[0]

            [string] $record.Data.exitCodeHex | Should -BeExactly '0xC0000409'
        }
    }
}
