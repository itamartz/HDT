# The long-step progress contract (DESIGN 11.1).
#
# A STEP THAT CAN RUN FOR MINUTES MUST SAY SOMETHING BETWEEN ITS START AND ITS
# FINISH. Not because a bar is pretty - because of what the alternative looks
# like on a machine somebody is standing in front of.
#
# THREE STEPS SHIPPED SILENT, AND EACH ONE WAS FOUND THE SAME WAY: a technician
# watching a deployment that was working perfectly and could not tell.
#
#   ApplyDrivers        82 drivers, 670 seconds on a Latitude 5490. Eleven
#                       minutes of the same frame.
#   ApplyUnattend       over three minutes on LT-7FJ45S2 run-20260829-172208,
#                       running offlineServicing over 133 .inf packages.
#   InstallApplications an Acrobat MSI with a 687 MB patch, over SMB, on the
#                       same run. Four log lines for the whole step, all of them
#                       boundaries.
#
# AND IT IS WORSE THAN A STILL BAR, because the progress card's elapsed clock is
# derived from the FIRST AND LAST RECORD IN THE LOG (Get-HDTDeploymentProgress).
# A step that writes nothing does not merely fail to move its own bar - it stops
# the clock for the whole deployment. Silence is not a cosmetic defect here.
#
# SO THE RULE IS ENFORCED AGAINST THE SET, NOT AGAINST THE THREE THAT WERE
# FIXED. Every step type in the registry must be classified: either it reports,
# or it is named below with the reason it cannot. A step type that is neither
# fails this file, which is what makes the NEXT slow step somebody adds a
# decision rather than an oversight - the three above were all oversights, and
# every one of them passed its own tests.
#
# Pester 5 expands -ForEach at DISCOVERY time, so the registry is built at file
# scope rather than in a BeforeAll, which would produce zero test cases.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') `
    -Force -ErrorAction Stop

# THE STEPS THAT MUST REPORT, and what each of them has to report WITH. A step
# is on this list because it can occupy a deployment for minutes; the second
# column is the fact it already had in hand, which is why none of these needed a
# new service, a new channel or an output capture to fix.
$script:HDTReportingStep = [ordered] @{
    'ApplyImage'          = "dism.exe prints a percentage meter on stdout while it writes the image."
    'ApplyDrivers'        = "it stages drivers one at a time and knows how many there are."
    # NOT "the same meter", WHICH IS WHAT THIS LINE USED TO SAY AND WAS WRONG.
    # dism.exe prints NO percentage for /Apply-Unattend - a banner, then silence,
    # then one sentence. LT-D5M1NN3 run-20260829-223623 proved it from a boot
    # image built AFTER the meter was wired here: twenty step.progress records
    # out of ApplyImage in that run, none at all out of this step, across 153
    # seconds of real offlineServicing over 260 .inf packages. So the adapter
    # runs dism as a POLLED process and the step hands it a heartbeat, which is
    # MDT's shape - RunCommandLog polls, scrapes AND beats event 41003 for
    # exactly the case where the tool says nothing.
    'ApplyUnattend'       = "dism.exe prints no meter for /Apply-Unattend, so the adapter polls the process and the step beats a heartbeat with the elapsed time."
    'InstallApplications' = "it resolves the whole ordered plan before it starts, so it knows it is on 1 of 2."
    'EnableBitLocker'     = "it polls the volume every fifteen seconds and can say the disk is still encrypting."

    # THE CAPTURE IS THE APPLY RUN BACKWARDS, and the meter is the same one:
    # dism.exe prints a percentage on stdout for /Capture-Image exactly as it
    # does for /Apply-Image, and the adapter hands every line to the step.
    'CaptureImage'        = "dism.exe prints a percentage meter on stdout while it reads the volume into the WIM."

    # AND SYSPREP IS THE OTHER SHAPE ENTIRELY. It prints no meter, no banner and
    # no line - it is simply silent, for minutes, at the end of a reference
    # build somebody has spent a day preparing. It cannot go in the quiet list:
    # that list takes two shapes only, a step that finishes in seconds and a
    # step that hands control to an operator's own program, and this is neither.
    # So the step beats a heartbeat, which is ApplyUnattend's answer to the same
    # problem on the same evidence.
    'Sysprep'             = "sysprep.exe prints no meter and is silent for minutes, so the step writes a first frame and then beats a heartbeat with the elapsed time."

    # A CUMULATIVE UPDATE IS EIGHT TO TWELVE MINUTES PER PACKAGE, MEASURED.
    # KB5094126 into a mounted Windows 11 image took 8m35s and KB5094125 into
    # a Server one took 12m24s on 2026-09-01, and dism prints its percentage
    # meter to a pipe this step does not read - it takes the exit code and
    # then re-reads the image. But the step knows the whole ordered list
    # BEFORE it starts, so it can say it is on 1 of 3, which is
    # InstallApplications' answer to the same shape of problem.
    'ApplyUpdates'        = "it resolves the whole ordered list of updates before it starts, so it knows it is on 1 of 3 - and a single cumulative update is eight to twelve minutes."
}

# THE STEPS THAT DO NOT, EACH WITH THE REASON IT CANNOT RATHER THAN A BLANK
# EXEMPTION. Two shapes only: a step that finishes in seconds has nothing to
# report, and a step that hands control to somebody else's program cannot know
# how far through it is. Anything that is neither of those does not belong here.
$script:HDTQuietStep = [ordered] @{
    'CommandLine'        = "it runs an operator's own command line, and the engine cannot know how far through somebody else's program it is. A number invented from elapsed time would be a bar that lied."
    'PowerShell'         = "the same: an operator's script, whose progress is theirs to report and not the engine's to guess."
    'InstallRoles'       = "one Install-WindowsFeature call for the whole set, and that cmdlet reports on PowerShell's progress STREAM, which is a console bar and not data - the same reason New-HDTImageService shells dism.exe rather than calling Expand-WindowsImage. Reporting would mean a new output channel on IFeatureService."
    'ConfigureBoot'      = "bcdboot and bcdedit, and both return in seconds."

    # THE HONEST ANSWER IS "IT CANNOT", AND IT IS NOT THE SECONDS SHAPE.
    # Two of its three actions are bcdedit and return at once, but the third
    # copies a ~500 MB boot image off the share and that is a minute or two
    # of real time. It stays quiet for InstallRoles' reason rather than for
    # ConfigureBoot's: IFileSystem.CopyItem is one call that returns when it
    # is done and says nothing while it runs, so reporting would mean a new
    # output channel on the file system service - and a percentage invented
    # from elapsed time would be a bar that lied.
    'BootToWinPE'        = "two of its actions are bcdedit and return at once; the third is one IFileSystem.CopyItem, which reports nothing while it runs. A bar would mean a new output channel on IFileSystem."
    'DiskPartition'      = "partitioning and a quick format, seconds on any disk this deploys to."
    'Gather'             = "reads CIM and the rules, in seconds."
    'InstallCertificate' = "writes a certificate to a store; effectively instant."

    # ONE NetJoinDomain CALL, AND IT IS BOUNDED BY THE CALL ITSELF. A join that
    # is slow is a DNS lookup or a controller that is not answering, and the
    # cmdlet gives up on its own rather than sitting there - so there is no
    # window in which this step is working and silent for minutes. The step's
    # own retry: is the engine's, and the engine logs each attempt.
    'JoinDomain'         = "one in-process join call, bounded by the call itself; a slow one is a name lookup timing out, not work in progress."
    'NoOp'               = "does nothing, at length."
    'Restart'            = "it arms a reboot and returns; the machine is gone before there is anything to report."
    'SetVariable'        = "assigns a variable; effectively instant."
    'Tattoo'             = "writes a handful of registry values; effectively instant."
    'Validate'           = "reads the machine's facts and checks them, in seconds."
}

$script:HDTStepProgressCase = @(Get-HDTStepType |
        Where-Object { $_.Source -eq 'Hephaestus' } |
        ForEach-Object {
            @{
                Type        = [string] $_.Type
                InvokeName  = [string] $_.InvokeCommand.Name
                MustReport  = $script:HDTReportingStep.Contains([string] $_.Type)
                IsClassified = ($script:HDTReportingStep.Contains([string] $_.Type) -or
                    $script:HDTQuietStep.Contains([string] $_.Type))
            }
        })

$script:HDTMustReportCase = @($script:HDTStepProgressCase | Where-Object { $_.MustReport })

# THE STALE-NAME CHECK, ALSO EXPANDED AT DISCOVERY. It used to read the lists
# above from inside an It body, where the file's script scope is not visible:
# Pester's run phase does not share a scope with discovery, so under
# Set-StrictMode -Version Latest the read threw and the assertion NEVER RAN
# ONCE. Its siblings passed because -ForEach is evaluated while discovering,
# which is the same phase the lists are built in - so this check is fed the
# same way, one case per classified name.
$script:HDTKnownStepType = @($script:HDTStepProgressCase | ForEach-Object { $_.Type })

$script:HDTClassifiedNameCase = @(
    @($script:HDTReportingStep.Keys) + @($script:HDTQuietStep.Keys) |
        ForEach-Object {
            @{
                ClassifiedType = [string] $_
                IsKnown        = $script:HDTKnownStepType -contains [string] $_
            }
        })

# THE GREP ABOVE IS NOT A MEASUREMENT, AND ApplyUpdates PROVED IT.
# HDT-UPD-01 run-20260902-004953 step 7 was EIGHT MINUTES of one cumulative
# update and wrote TWO step.progress records for the whole of it - "considering
# 1 update(s)" and "applying KB5094126 (1 of 1)". Both strings this file greps
# for were present in the step's source; the step passed every test in here
# while showing a technician a bar that did not move once. A text search can
# only ever prove that somebody typed the words.
#
# SO THE STEPS ARE RUN. Each entry below builds that step's fakes, seeds them
# with ONE unit of work that takes a long time - one image, one package, one
# application, one volume, one driver pack - executes the step and hands back
# the context, so the It can read the records the step really wrote. One long
# unit is the case the grep cannot see: a step given ten fast ones emits ten
# boundary records and looks healthy while the eight-minute one emits two.
#
# THE FAKE SHAPES ARE LIFTED FROM EACH STEP'S OWN UNIT TESTS rather than
# invented here, so a fake that drifts from its adapter breaks the unit test
# that owns it rather than being quietly re-guessed in a second place.
#
# At file scope, and for the reason the header already gives: -ForEach is
# expanded while Pester DISCOVERS, so a table built in a BeforeAll yields zero
# test cases and a green run that asserted nothing.
$script:HDTProgressDriveCase = @(

    @{
        Type  = 'ApplyImage'
        Drive = {
            param([string] $RepositoryRoot)

            # 18 GB over SMB, the step MDT users watch for nine minutes. The
            # meter is the real /Apply-Image transcript, replayed by the fake to
            # the same callback the adapter hands the real dism's stdout to.
            $meter = [string[]] [System.IO.File]::ReadAllLines(
                [IO.Path]::Combine($RepositoryRoot, 'tests', 'fixtures', 'image', 'dism-apply-image-output.txt'))

            $catalogPath = 'Z:\Deploy\OperatingSystems\Win11-LTSC-2024\os.yaml'
            $catalogYaml = @(
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

            $fileSystem = New-HDTFakeFileSystem -File @{ $catalogPath = $catalogYaml }
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 9, 26, [System.DateTimeKind]::Utc)) -TickMillisecond 500

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock `
                -Disk (New-HDTFakeDiskService) -Image (New-HDTFakeImageService -ApplyOutput $meter) `
                -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                -Variable $live -Service $catalog -Log $log

            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $property['os'] = 'Win11-LTSC-2024'
            $property['index'] = 1

            $null = Invoke-HDTApplyImageStep -Context $context -Step ([pscustomobject] @{
                    Index = 3; Name = 'Apply OS'; Type = 'ApplyImage'; TimeoutMinutes = 60; Log = $null
                    Property = $property
                })

            return $context
        }
    }

    @{
        Type  = 'CaptureImage'
        Drive = {
            param([string] $RepositoryRoot)

            # THE APPLY RUN BACKWARDS, AND THE SAME METER. The fixture is the
            # apply transcript deliberately: dism prints the identical bar for
            # /Capture-Image, and the step reuses ApplyImage's parser - so the
            # fixture that proves one drives the other with nothing invented.
            $meter = [string[]] [System.IO.File]::ReadAllLines(
                [IO.Path]::Combine($RepositoryRoot, 'tests', 'fixtures', 'image', 'dism-apply-image-output.txt'))

            # The shipped exclusion list, read off the module the way the step
            # will build the path to it.
            $moduleConfig = [IO.Path]::Combine((Get-Module -Name Hephaestus).ModuleBase, 'Templates', 'Capture', 'wimscript.ini')

            $fileSystem = New-HDTFakeFileSystem -File @{
                $moduleConfig = [string] (Get-Content -LiteralPath $moduleConfig -Raw)
            }
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 31, 11, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 500

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock `
                -Image (New-HDTFakeImageService -CaptureOutput $meter) `
                -Content (New-HDTFakeContentProvider -Root 'Z:\Deploy' -Kind Smb) `
                -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                -Variable $live -Service $catalog -Log $log

            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $property['image'] = 'REF-WIN11.wim'

            $null = Invoke-HDTCaptureImageStep -Context $context -Step ([pscustomobject] @{
                    Index = 11; Name = 'Capture the reference image'; Type = 'CaptureImage'
                    TimeoutMinutes = 0; Log = $null; Property = $property
                })

            return $context
        }
    }

    @{
        Type  = 'ApplyUnattend'
        Drive = {
            param([string] $RepositoryRoot)

            # NO METER EXISTS FOR THIS VERB, so there is nothing to replay and
            # the heartbeat is the whole mechanism. UnattendTick stands for the
            # half-second slices a polled dism spends saying nothing;
            # TickMillisecond 16000 makes each of them cross the fifteen-second
            # ration, which is what a 153-second offlineServicing pass over 260
            # .inf packages looked like on LT-D5M1NN3 run-20260829-223623.
            $templatePath = 'Z:\Deploy\TaskSequences\DEMO-M3\unattend.xml'

            $fileSystem = New-HDTFakeFileSystem -File @{
                $templatePath = [System.IO.File]::ReadAllText(
                    [IO.Path]::Combine($RepositoryRoot, 'src', 'Hephaestus', 'Templates', 'unattend.xml'))
            }
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 29, 1, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 16000

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock `
                -Image (New-HDTFakeImageService -UnattendTick 15) -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTComputerName'] = 'HDT-M3-01'
            $live['HDTTaskSequenceID'] = 'DEMO-M3'
            $live['HDTAdminPassword'] = 'Fixture-P@ssw0rd'

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                -Variable $live -Service $catalog -Log $log

            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $property['template'] = 'unattend.xml'

            $null = Invoke-HDTApplyUnattendStep -Context $context -Step ([pscustomobject] @{
                    Index = 4; Name = 'Apply Unattend'; Type = 'ApplyUnattend'; TimeoutMinutes = 0
                    Log = $null; Property = $property
                })

            return $context
        }
    }

    @{
        Type  = 'InstallApplications'
        Drive = {
            param([string] $RepositoryRoot)

            # ONE APPLICATION, AND THE SLOW ONE. The Acrobat MSI with a 687 MB
            # patch over SMB is what wrote four log lines for a whole step on
            # LT-7FJ45S2 run-20260829-190105, all of them boundaries. TickCount
            # is how long the fake process takes to return.
            $appYaml = @(
                'schemaVersion: 1'
                'id: Corp-Baseline'
                'name: Corporate baseline'
                'install: baseline.cmd'
            ) -join "`n"

            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\Deploy\Applications\Corp-Baseline\app.yaml' = $appYaml
            }
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 16, 9, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 20000

            $process = New-HDTFakeProcessService -Result @{
                'cmd.exe /c baseline.cmd' = @{ ExitCode = 0; TickCount = 20 }
            }

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Process $process `
                -Environment (New-HDTFakeEnvironmentProvider -Variable @{ ComSpec = 'cmd.exe' }) `
                -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Info

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
                -Variable $live -Service $catalog -Log $log
            $context.SetStep(1, 'Install applications', 'InstallApplications', 'C:\HDT\Logs\Steps\001-Install.log')

            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $property['selection'] = @('Corp-Baseline')

            $null = Invoke-HDTInstallApplicationsStep -Context $context -Step ([pscustomobject] @{
                    Index = 1; Name = 'Install applications'; Type = 'InstallApplications'
                    TimeoutMinutes = 0; Log = $null; Property = $property
                })

            return $context
        }
    }

    @{
        Type  = 'EnableBitLocker'
        Drive = {
            param([string] $RepositoryRoot)

            # ONE VOLUME, ENCRYPTING FOR TWENTY MINUTES, which is an ordinary
            # figure for a laptop disk. The fake never reaches FullyEncrypted,
            # so the step polls its fifteen seconds until the bounded wait gives
            # up - and every one of those polls has to say the disk is alive.
            # The step FAILS here, deliberately: what is under test is what it
            # said while it waited, and a technician staring at the timeout is
            # exactly who needed those records.
            $fileSystem = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 16, 9, 0, 0, [System.DateTimeKind]::Utc))

            $bitlocker = New-HDTFakeBitLockerService -Volume @{
                'C:' = @{ VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off' }
            }

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -BitLocker $bitlocker `
                -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Info

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'C:\Deploy' `
                -Variable $live -Service $catalog -Log $log
            $context.SetStep(1, 'Enable BitLocker', 'EnableBitLocker', 'C:\HDT\Logs\Steps\001-BitLocker.log')

            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $property['drive'] = 'C:'
            $property['escrow'] = 'none'
            $property['wait'] = $true

            $null = Invoke-HDTEnableBitLockerStep -Context $context -Step ([pscustomobject] @{
                    Index = 1; Name = 'Enable BitLocker'; Type = 'EnableBitLocker'; TimeoutMinutes = 20
                    Log = $null; Property = $property
                })

            return $context
        }
    }

    @{
        Type  = 'Sysprep'
        Drive = {
            param([string] $RepositoryRoot)

            # SILENT FOR MINUTES AT THE END OF A DAY'S WORK. sysprep prints no
            # meter and no banner, so the heartbeat is all there is; TickCount
            # is how many polls the fake spends before the tool returns.
            $fileSystem = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 31, 10, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 20000

            $sysprepCommand = 'C:\Windows\system32\sysprep\sysprep.exe /quiet /generalize /oobe /quit'

            $process = New-HDTFakeProcessService -Result @{
                $sysprepCommand = @{ ExitCode = 0; StandardOutput = ''; TickCount = 20 }
            }

            $registry = New-HDTFakeRegistryService -Value @{
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' = @{
                    ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'
                }
            }

            # DomainRole 2 is Standalone Server, the only kind sysprep will
            # generalize; a member machine is refused before the tool runs.
            $cim = New-HDTFakeCimProvider -Instance @{
                'Win32_ComputerSystem' = @([pscustomobject] @{
                        Name = 'REF-BUILD-01'; Domain = 'WORKGROUP'; DomainRole = 2; PartOfDomain = $false
                    })
            }

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Registry $registry `
                -Process $process -Cim $cim -Lsa (New-HDTFakeLsaService) `
                -Environment (New-HDTFakeEnvironmentProvider -Variable @{ SystemRoot = 'C:\Windows' }) `
                -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase FullOS -LogPath 'C:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase FullOS -WorkspaceRoot 'Z:\Deploy' `
                -Variable $live -Service $catalog -Log $log

            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            $null = Invoke-HDTSysprepStep -Context $context -Step ([pscustomobject] @{
                    Index = 9; Name = 'Sysprep'; Type = 'Sysprep'; TimeoutMinutes = 60
                    Log = $null; Property = $property
                })

            return $context
        }
    }

    @{
        Type  = 'ApplyUpdates'
        Drive = {
            param([string] $RepositoryRoot)

            # THE RUN THIS WHOLE CONTEXT EXISTS FOR. One cumulative update,
            # eight minutes and thirty-five seconds measured on 2026-09-01, two
            # step.progress records in the shipped step. The fixture is a real
            # dism /Add-Package transcript captured on this machine - 124 lines,
            # 58 of them the bar - replayed to the third argument of AddPackage.
            $meter = [string[]] [System.IO.File]::ReadAllLines(
                [IO.Path]::Combine($RepositoryRoot, 'tests', 'fixtures', 'image', 'dism-add-package-output.txt'))

            $updateYaml = @(
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

            $packagePath = 'C:\Deploy\WindowsUpdates\KB5094126-x64\windows11.0-kb5094126-x64.msu'

            $fileSystem = New-HDTFakeFileSystem -File @{
                'C:\Deploy\WindowsUpdates\KB5094126-x64\update.yaml' = $updateYaml
                $packagePath                                        = 'msu'
            }
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 1, 12, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 500

            # DISM's SPELLING OF THE IDENTITY, WITH THE PUBLISHER KEY, because
            # the step believes the image rather than the exit code and would
            # otherwise call a good apply a failure.
            $image = New-HDTFakeImageService `
                -PackageResult @{ $packagePath = @{ Output = $meter } } `
                -PackageInstalls @{ $packagePath = @('Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.8655.1.20') }

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Image $image `
                -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'C:\Deploy' `
                -Variable $live -Service $catalog -Log $log

            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $property['release'] = 'Win11-24H2'

            $null = Invoke-HDTApplyUpdatesStep -Context $context -Step ([pscustomobject] @{
                    Index = 7; Name = 'Apply Windows Updates'; Type = 'ApplyUpdates'; TimeoutMinutes = 0
                    Log = $null; Property = $property
                })

            return $context
        }
    }

    @{
        Type  = 'ApplyDrivers'
        Case  = 'ApplyDrivers, the group path'
        Drive = {
            param([string] $RepositoryRoot)

            # ONE PACK, AND THE PACK IS THE UNIT OF WORK. A Latitude 5490 pack
            # took 670 seconds - eleven minutes of the same frame - and the
            # group path stages the folder WHOLE, so the only thing that can
            # move a bar inside it is the file count. Sixty files stands for the
            # eighty-two-driver pack that surfaced the defect; a pack seeded
            # with the two .inf files the unit tests use would emit a handful of
            # records and prove nothing about eleven minutes.
            $groupPath = 'Z:\Deploy\Drivers\Win11\Dell inc\Dell Pro 3 16 P316265'

            $inf = @(
                '[version]'
                'Signature   = "$Windows NT$"'
                'Class       = Net'
                'ClassGUID   = {4d36e972-e325-11ce-bfc1-08002be10318}'
                'Provider    = %Realtek%'
                'DriverVer   = 11/28/2024,10.74.1128.2024'
                ''
                '[Manufacturer]'
                '%Realtek% = Realtek, NTamd64.10.0'
                ''
                '[Realtek.NTamd64.10.0]'
                '%RTL8168.DeviceDesc% = RTL8168.ndi, PCI\VEN_10EC&DEV_8168&SUBSYS_393917AA&REV_15'
                ''
                '[Strings]'
                'Realtek = "Realtek"'
                'RTL8168.DeviceDesc = "Realtek PCIe GbE Family Controller"'
            ) -join "`r`n"

            $file = @{ ('{0}\net-realtek.inf' -f $groupPath) = $inf }

            # The payload beside the .inf: a driver is the .inf plus the .sys,
            # .cat and .dll below it, and it is the whole set that gets copied.
            foreach ($i in 1..59) {
                $file[('{0}\payload{1:d2}.sys' -f $groupPath, $i)] = ('binary payload {0}' -f $i)
            }

            $fileSystem = New-HDTFakeFileSystem -File $file
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 27, 9, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 250

            $deviceText = [System.IO.File]::ReadAllText(
                [IO.Path]::Combine($RepositoryRoot, 'tests', 'fixtures', 'cim', 'Win32_PnPEntity.json'))
            $captured = ConvertFrom-Json -InputObject $deviceText

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock `
                -Image (New-HDTFakeImageService) `
                -Cim (New-HDTFakeCimProvider -Instance @{ Win32_PnPEntity = [object[]] @($captured) }) `
                -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            $live['HDTMake'] = 'Dell inc'
            $live['HDTModel'] = 'Dell Pro 3 16 P316265'

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                -Variable $live -Service $catalog -Log $log

            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $property['group'] = 'Win11\%HDTMake%\%HDTModel%'

            $null = Invoke-HDTApplyDriversStep -Context $context -Step ([pscustomobject] @{
                    Index = 5; Name = 'Inject Drivers'; Type = 'ApplyDrivers'; TimeoutMinutes = 30
                    Log = $null; Property = $property
                })

            return $context
        }
    }

    @{
        Type  = 'ApplyDrivers'
        Case  = 'ApplyDrivers, the PnP fallback'
        Drive = {
            param([string] $RepositoryRoot)

            # THE SECOND PATH, AND UNTIL NOW THE UNDRIVEN ONE. ApplyDrivers has
            # two, they report by different mechanisms, and only the group path
            # above was ever executed here - so the fallback's counter was
            # covered by a text match for the words "step.progress" and by
            # nothing that counted what it wrote. It scored twenty on the group
            # seed and nobody had asked what the other half did.
            #
            # AND IT IS THE HALF WITH THE ARITHMETIC IN IT. One package is the
            # only case in which a package's own meter and the step's are the
            # same number; the fallback stages a SET, and writing each package's
            # own 0-100% as the step's number gave the measured sequence
            # 4 9 ... 100, 33, 4 9 ... 100, 66, 4 9 ... 100 - a bar that ran to
            # the end and restarted, twice. Three matching folders is the
            # smallest seed in which that is visible at all.
            $inf = @(
                '[version]'
                'Signature   = "$Windows NT$"'
                'Class       = Net'
                'ClassGUID   = {4d36e972-e325-11ce-bfc1-08002be10318}'
                'Provider    = %Realtek%'
                'DriverVer   = 11/28/2024,10.74.1128.2024'
                ''
                '[Manufacturer]'
                '%Realtek% = Realtek, NTamd64.10.0'
                ''
                '[Realtek.NTamd64.10.0]'
                '%RTL8168.DeviceDesc% = RTL8168.ndi, PCI\VEN_10EC&DEV_8168&SUBSYS_393917AA&REV_15'
                ''
                '[Strings]'
                'Realtek = "Realtek"'
                'RTL8168.DeviceDesc = "Realtek PCIe GbE Family Controller"'
            ) -join "`r`n"

            $file = @{}
            foreach ($n in 1..3) {
                $vendor = 'Z:\Deploy\Drivers\Win11\Vendor{0}' -f $n
                $file[('{0}\net{1}.inf' -f $vendor, $n)] = $inf

                # The payload beside the .inf: a driver is the .inf plus the
                # .sys, .cat and .dll below it, and it is the whole set that
                # gets copied.
                foreach ($i in 1..20) {
                    $file[('{0}\pay{1}{2:d2}.sys' -f $vendor, $n, $i)] = ('binary payload {0}' -f $i)
                }
            }

            $fileSystem = New-HDTFakeFileSystem -File $file
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 27, 9, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 250

            $deviceText = [System.IO.File]::ReadAllText(
                [IO.Path]::Combine($RepositoryRoot, 'tests', 'fixtures', 'cim', 'Win32_PnPEntity.json'))
            $captured = ConvertFrom-Json -InputObject $deviceText

            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock `
                -Image (New-HDTFakeImageService) `
                -Cim (New-HDTFakeCimProvider -Instance @{ Win32_PnPEntity = [object[]] @($captured) }) `
                -Progress (New-HDTFakeProgressHost)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'Z:\Deploy' `
                -Variable $live -Service $catalog -Log $log

            # A GROUP NOBODY WROTE, WHICH IS WHAT PUTS THE STEP ON THE FALLBACK.
            $property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $property['group'] = 'Win11\Acme\Nonesuch'

            $null = Invoke-HDTApplyDriversStep -Context $context -Step ([pscustomobject] @{
                    Index = 5; Name = 'Inject Drivers'; Type = 'ApplyDrivers'; TimeoutMinutes = 30
                    Log = $null; Property = $property
                })

            return $context
        }
    }
)

# AND THE SET IS WHAT IS CHECKED, NOT THE ONE THAT WAS JUST ADDED. A reporting
# step with no driver here is a step whose records nothing counts, which is the
# state ApplyUpdates shipped in.
# A NAME PER DRIVEN CASE, BECAUSE ONE STEP TYPE CAN HAVE TWO PATHS. ApplyDrivers
# has a group path and a PnP fallback, they report by different mechanisms, and
# two tests both called 'ApplyDrivers writes more than a token record' say
# nothing about which of them moved. Every other step is one path and says
# nothing extra.
foreach ($one in $script:HDTProgressDriveCase) {
    if (-not $one.ContainsKey('Case')) { $one['Case'] = [string] $one.Type }
}

$script:HDTDrivenType = @($script:HDTProgressDriveCase | ForEach-Object { [string] $_.Type })

$script:HDTDriveCoverageCase = @($script:HDTMustReportCase | ForEach-Object {
        @{
            Type      = [string] $_.Type
            IsDriven  = $script:HDTDrivenType -contains [string] $_.Type
        }
    })

Describe 'the long-step progress contract' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:stepFileRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Steps'
    }

    Context 'every step type is classified' {

        # THE TEST THAT CATCHES THE NEXT ONE. A step type added without a
        # decision about whether it can run for minutes fails here, by name,
        # before anybody deploys with it.
        It 'classifies <Type> as either reporting or quiet, with a reason' -ForEach $script:HDTStepProgressCase {
            $IsClassified | Should -BeTrue -Because (
                "every step type must be listed in this file as one that reports progress or one that cannot, " +
                "with the reason. '$Type' is in neither list, so nobody has decided whether it can occupy a " +
                'deployment for minutes in silence.')
        }

        # A name left behind after a step type was renamed or removed would
        # exempt nothing and look like it exempted something.
        It 'classifies <ClassifiedType>, which the registry still has' -ForEach $script:HDTClassifiedNameCase {
            $IsKnown | Should -BeTrue -Because (
                "'$ClassifiedType' is classified in this file as reporting or quiet, but it is not a step type " +
                'this module exports. A name left behind by a rename or a removal exempts nothing and looks ' +
                'like it exempted something.')
        }
    }

    Context 'a step that can run for minutes reports while it runs' {

        # PARSED RATHER THAN EXECUTED, and deliberately: running these for real
        # would need an image, a disk and an encrypting volume. What is asserted
        # is that the two lines exist in the step's own file - the record, and
        # the nudge that makes the window read it. Each step's UNIT tests then
        # prove the records come out in the right order and at the right stride
        # against the fakes; this file's job is to prove nobody FORGOT.
        It '<Type> writes a step.progress record' -ForEach $script:HDTMustReportCase {
            $path = Join-Path -Path $script:stepFileRoot -ChildPath ('{0}.ps1' -f $InvokeName)
            $text = [System.IO.File]::ReadAllText($path)

            $text | Should -Match "step\.progress" -Because (
                "$Type can occupy a deployment for minutes. Without a record between its start and its finish " +
                'the progress card shows the same frame throughout AND its elapsed clock stops, because elapsed ' +
                'is derived from the first and last record in the log.')
        }

        It '<Type> asks the display to re-read the log' -ForEach $script:HDTMustReportCase {
            $path = Join-Path -Path $script:stepFileRoot -ChildPath ('{0}.ps1' -f $InvokeName)
            $text = [System.IO.File]::ReadAllText($path)

            # THE RECORD ALONE IS NOT ENOUGH, and this is the half that was
            # missing for ApplyDrivers: the line was written to the JSONL and
            # nothing told the window to look, so the step reported into a file
            # nobody was reading.
            $text | Should -Match "Update-HDTProgressDisplay" -Because (
                "$Type writes a step.progress, but a record nothing reads back is a record that draws nothing.")
        }

        It '<Type> reports through the log rather than through a channel of its own' -ForEach $script:HDTMustReportCase {
            $path = Join-Path -Path $script:stepFileRoot -ChildPath ('{0}.ps1' -f $InvokeName)
            $text = [System.IO.File]::ReadAllText($path)

            # DESIGN 11.1: "there is exactly one source of truth for what the
            # deployment is doing, so the screen and the log can never
            # disagree". A step calling the progress host directly would be a
            # second truth, and the first thing it would do is drift on a
            # resume.
            $text | Should -Not -Match "Service\.Progress" -Because (
                "$Type must report by writing a record and asking the display to re-read it, never by pushing " +
                'to the progress host itself (DESIGN 11.1).')
        }
    }

    Context 'a step that can run for minutes reports MORE THAN TWICE while it runs' {

        # WHAT THE GREPS ABOVE CANNOT SEE, AND THE RUN THAT PROVED THEY CANNOT.
        # ApplyUpdates carried both strings the context above searches for and
        # passed every test in this file while emitting TWO step.progress
        # records across an eight-minute step - HDT-UPD-01 run-20260902-004953,
        # step 7. "Reporting" as a text match means somebody typed the words;
        # what a technician in front of the machine needs is a number that keeps
        # arriving, and only running the step can tell the two apart.
        #
        # SO EVERY REPORTING STEP IS EXECUTED HERE against hand-written fakes,
        # seeded with ONE unit of work that takes a long time. One long unit is
        # the case that catches a token record: a step handed ten fast units
        # emits ten boundary records and looks perfectly healthy while the
        # eight-minute one emits two.

        BeforeAll {
            Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') `
                -Force -ErrorAction Stop

            # THE FLOOR, AND WHY IT IS TEN. The heartbeat rations itself to one
            # record every fifteen seconds and the meter steps report every five
            # points, so ten records is the two-and-a-half minutes of coverage
            # BOTH mechanisms produce at their slowest. Every step driven here
            # runs far longer than that on real hardware - eight minutes for one
            # cumulative update, eleven for a driver pack, twenty for a disk -
            # so ten is generous to the step and still an order of magnitude
            # above the two records that shipped.
            $script:progressFloor = 10

            # A RECORD'S SIGNATURE, SO "NUMEROUS" CAN BE TOLD FROM "MOVING".
            # Fifty copies of "applying KB5094126 (1 of 1)" would clear a count
            # and leave the bar exactly as still as two would. The message plus
            # whichever of the moving fields the record carries is what a reader
            # actually distinguishes one frame from the next by.
            #
            # PROPERTY LOOKUPS GO THROUGH PSObject.Properties and never straight
            # at the name: these are ConvertFrom-Json objects, the fields are
            # present on some records and absent on others by design - a
            # heartbeat carries no percent precisely so it cannot drag a bar
            # backwards - and a bare $_.data.percent throws under StrictMode.
            $script:progressSignature = {
                param([object] $Record)

                $part = New-Object -TypeName System.Collections.ArrayList
                [void] $part.Add([string] $Record.message)

                if ($null -ne $Record.PSObject.Properties['data'] -and $null -ne $Record.data) {
                    foreach ($name in @('percent', 'packagePercent', 'elapsedSecond', 'elapsedMinute')) {
                        $property = $Record.data.PSObject.Properties[$name]
                        if ($null -ne $property) {
                            [void] $part.Add(('{0}={1}' -f $name, [string] $property.Value))
                        }
                    }
                }

                return ($part -join '|')
            }

            $script:progressRecordOf = {
                param([object] $Context)

                return @(Get-HDTRunLogRecord -Context $Context.Log |
                        Where-Object { [string] $_.event -eq 'step.progress' })
            }
        }

        # THE STEP THAT IS CLASSIFIED AS REPORTING AND DRIVEN BY NOBODY. Without
        # this, a new reporting step is covered by the greps above and by
        # nothing that counts its records - which is the exact state
        # ApplyUpdates shipped in.
        It 'drives <Type> against fakes, rather than only reading its source' -ForEach $script:HDTDriveCoverageCase {
            $IsDriven | Should -BeTrue -Because (
                "'$Type' is classified in this file as a step that reports progress, but no entry in " +
                'HDTProgressDriveCase executes it - so nothing here counts what it actually writes, and a ' +
                'text match for the word step.progress is all that stands behind the claim.')
        }

        It '<Case> writes more than a token record through one long unit of work' -ForEach $script:HDTProgressDriveCase {
            $context = & $Drive $script:repoRoot
            $progress = @(& $script:progressRecordOf $context)

            $progress.Count | Should -BeGreaterOrEqual $script:progressFloor -Because (
                "$Type was driven with ONE unit of work that takes minutes on real hardware and wrote " +
                "$($progress.Count) step.progress record(s). Fewer than $script:progressFloor is the shipped " +
                'ApplyUpdates defect: both strings this file greps for present, and a bar that did not move ' +
                'once in eight minutes.')
        }


        # A MEASUREMENT OR A SIGN OF LIFE, AND THE RECORD HAS TO SAY WHICH.
        #
        # step.progress carries both kinds deliberately - New-HDTStepHeartbeat
        # spells out why it adds no second event name - and
        # Get-HDTDeploymentProgress reads `percent` CONDITIONALLY so that a
        # liveness record leaves the bar where the last real measurement put it
        # rather than dragging it back to zero.
        #
        # BUT THE ABSENCE OF A FIELD IS NOT SOMETHING A FILTER CAN SAY OUT LOUD.
        # A reader separating "how far through" from "still alive" has nothing to
        # test against on a record that carries neither, so `heartbeat = $true`
        # is the mark that makes the second kind readable. EnableBitLocker's
        # fifteen-second poll and the line Sysprep writes before it starts
        # generalizing both shipped carrying neither, which put two liveness
        # records into the measurement stream with no way to tell them apart.
        It '<Case> marks every record as a measurement or as a sign of life' -ForEach $script:HDTProgressDriveCase {
            $context = & $Drive $script:repoRoot
            $progress = @(& $script:progressRecordOf $context)

            $unmarked = @($progress | Where-Object {
                    $data = $null
                    if ($null -ne $_.PSObject.Properties['data']) { $data = $_.data }

                    $hasPercent = ($null -ne $data -and $null -ne $data.PSObject.Properties['percent'])
                    $hasHeartbeat = ($null -ne $data -and $null -ne $data.PSObject.Properties['heartbeat'])

                    return (-not $hasPercent -and -not $hasHeartbeat)
                })

            # NAMED BEFORE THE ASSERTION, NEVER INSIDE -Because. The reason
            # string is built whether or not the assertion fails, so reaching
            # into an empty collection there throws on the PASSING case - which
            # is the shape that passes in a direct run and fails the gate.
            $first = ''
            if ($unmarked.Count -gt 0) { $first = [string] $unmarked[0].message }

            $unmarked.Count | Should -Be 0 -Because (
                ("$Type wrote {0} step.progress record(s) carrying neither a percent nor heartbeat = true, " -f $unmarked.Count) +
                ('the first being "{0}". A reader filtering on heartbeat to tell liveness from measurement ' -f $first) +
                'cannot see them at all, and the absence of a percent is not something a filter can test for.')
        }

        It '<Case> writes records a reader can tell apart, not the same frame repeated' -ForEach $script:HDTProgressDriveCase {
            $context = & $Drive $script:repoRoot
            $progress = @(& $script:progressRecordOf $context)

            $distinct = @($progress | ForEach-Object { & $script:progressSignature $_ } | Sort-Object -Unique)

            $distinct.Count | Should -BeGreaterOrEqual $script:progressFloor -Because (
                "$Type wrote $($progress.Count) step.progress record(s) but only $($distinct.Count) of them say " +
                'anything different. A count alone is satisfiable by repeating one frame, which leaves the ' +
                'screen exactly as still as silence does - what has to move is the percentage, or the elapsed ' +
                'time on a step that honestly has no percentage to report.')
        }
    }
}
