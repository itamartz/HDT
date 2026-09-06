# The three guards MDT applies to a Refresh and only to a Refresh
# (ZTIValidate.wsf; M9's "Refresh-only validation"; DESIGN 3.2).
#
# THEY LIVE IN THE PRE-FLIGHT BECAUSE THE PRE-FLIGHT IS WHAT RUNS FIRST. Every
# one of them is a refusal that becomes worthless the moment the volume is
# emptied: a machine that cannot fit the image, or is about to be rolled back to
# an older Windows, or is about to have its image written to the wrong volume,
# has to be told so while its installation is still there. That is the same
# argument Invoke-HDTValidateStep already makes for the target-disk check, and
# it is why these are three more checks in that step rather than a step of their
# own - a guard in a step type an author can leave out of a sequence is a guard
# that is not there.
#
# ALL THREE ARE REFRESH-ONLY, AND MDT SAYS SO EXPLICITLY. The free-space check
# is `Case "REFRESH", "UPGRADE"`, and `Case "NEWCOMPUTER"` skips it with
# "Assuming that the drive has enough disk space (once cleaned)". A NEWCOMPUTER
# run repartitions the disk, so the volume being measured does not survive to be
# measured; and it lays Windows down on a machine that may have no Windows on it
# at all, so there is no current version to be downgraded from and no current OS
# partition to match.
#
# SO BOTH DIRECTIONS ARE PROVEN, AND OVER THE SET RATHER THAN OVER THREE NAMES.
# Get-HDTValidateCheckDefinition is the one place a check is declared and it is
# data, so each row says which deployment type it belongs to. The set tests
# below read the Refresh rows out of THAT table and assert that every one of
# them refuses on a REFRESH which fails them all, and is skipped on a
# NEWCOMPUTER - so the fourth guard added there is covered the day it lands
# rather than the day somebody remembers to add it to a list here.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:newStep = {
        param([System.Collections.IDictionary] $Property)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 1; Name = 'Validate'; Type = 'Validate'; TimeoutMinutes = 0; Log = $null; Property = $bag
        }
    }

    # A machine that is already running Windows, which is what a Refresh starts
    # from: one 128 GB disk carrying one 120 GB volume on C:.
    $script:runningMachine = {
        param([long] $VolumeSizeByte = 128849018880, [string] $Letter = 'C')

        return (New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 137438953472
                    BusType = 'SAS'; PartitionStyle = 'GPT'
                }) -Volume @(
                @{ DriveLetter = $Letter; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'
                    SizeBytes = $VolumeSizeByte; SizeRemainingBytes = 4294967296
                }))
    }

    # THE CONTEXT A REFRESH REALLY HAS. It runs in the full OS, so the catalog
    # carries an IEnvironmentProvider and SystemDrive answers C: - which is how
    # the partition check knows which volume this machine is running from
    # without touching hardware. Assert-HDTCleanVolumeTarget reads the same
    # thing from the same place, so the two cannot disagree about it.
    $script:contextFor = {
        param([object] $Disk, [System.Collections.IDictionary] $Variable, [string] $SystemDrive = 'C:',
            [string] $Phase = 'FullOS')

        $fileSystem = New-HDTFakeFileSystem
        $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 9, 5, 0, 0, 0, [System.DateTimeKind]::Utc))
        $environment = New-HDTFakeEnvironmentProvider -Variable @{ SystemDrive = $SystemDrive; ComSpec = 'cmd.exe' }

        $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock -Disk $Disk `
            -Image (New-HDTFakeImageService) -Environment $environment

        $log = New-HDTLogContext -RunId 'run-refresh-0001' -Phase $Phase -LogPath 'C:\HDT\Logs' `
            -FileSystem $fileSystem -Clock $clock -Level Debug

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $live['HDTMemory'] = 8192
        $live['HDTIsUEFI'] = $true
        $live['HDTDeploymentType'] = 'REFRESH'
        $live['HDTOSCurrentVersion'] = '10.0.26100'

        if ($null -ne $Variable) {
            foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
        }

        return (New-HDTExecutionContext -RunId 'run-refresh-0001' -Phase $Phase -WorkspaceRoot 'Z:\Deploy' `
                -Variable $live -Service $catalog -Log $log)
    }

    # The three declarations that make every Refresh guard pass, so a test that
    # changes one of them changes exactly one thing.
    $script:passingProperty = [ordered] @{
        imageVersion = '10.0.26100'
        imageSizeMB  = 5200
    }

    # THE SET COMES OUT OF THE TABLE, NOT OUT OF THIS FILE.
    # Get-HDTValidateCheckDefinition is "the one place a check is declared, and
    # it is data", so the Refresh guards are the rows that say they are - and a
    # fourth one added there is covered by every assertion below the day it
    # lands, rather than the day somebody remembers to name it here.
    # InModuleScope because the table is private, which is how every other test
    # over this set reads it (Invoke-HDTValidateStep.Tests.ps1).
    $script:refreshRowOf = {
        param([object] $Result)

        $key = @(InModuleScope Hephaestus {
                @(Get-HDTValidateCheckDefinition |
                        Where-Object { [string] $_.Scope -eq 'REFRESH' } |
                        ForEach-Object { [string] $_.Key })
            })

        # ANTI-VACUITY, AND IT HAS TO BE HERE RATHER THAN IN AN It. A set test
        # that matched nothing would pass every assertion below by matching no
        # rows at all, which is the shape this whole file exists to avoid.
        if ($key.Count -lt 3) {
            throw ("Get-HDTValidateCheckDefinition declares {0} REFRESH-scoped check(s); the three guards should be there." -f $key.Count)
        }

        return @($Result.Data.check | Where-Object { $key -contains [string] $_['key'] })
    }
}

Describe 'Invoke-HDTValidateStep, the guards a Refresh runs' {

    # MDT's ZTIValidate.wsf:138-146, failure 9808. The citation lives in this
    # comment rather than in the Context name: the no-MDT contract scans strings
    # and a test name is one.
    Context 'the downgrade refusal' {

        It 'refuses a Refresh whose image is older than the Windows already on the machine' {
            $step = & $script:newStep $script:passingProperty
            $step.Property['imageVersion'] = '10.0.19045'

            $result = Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor (& $script:runningMachine) $null)

            $result.Status | Should -BeExactly 'Failed'
        }

        It 'names what it found, what it needed and what the administrator can do' {
            $step = & $script:newStep $script:passingProperty
            $step.Property['imageVersion'] = '10.0.19045'

            $result = Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor (& $script:runningMachine) $null)

            $result.Message | Should -BeLike '*10.0.26100*' -Because 'the version it found on the machine'
            $result.Message | Should -BeLike '*10.0.19045*' -Because 'the version the sequence would have applied'
            $result.Message | Should -BeLike '*NEWCOMPUTER*' -Because 'the way out is a bare-metal deployment, which is what MDT says too'
        }

        It 'allows a Refresh onto a newer image' {
            $step = & $script:newStep $script:passingProperty
            $step.Property['imageVersion'] = '10.0.26200'

            (Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor (& $script:runningMachine) $null)).Status |
                Should -BeExactly 'Completed'
        }

        It 'allows a Refresh onto the same version' {
            $step = & $script:newStep $script:passingProperty

            (Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor (& $script:runningMachine) $null)).Status |
                Should -BeExactly 'Completed'
        }

        It 'compares the build and not only the major and minor version' {
            # A STATED DIVERGENCE FROM MDT, AND THE REASON IS THAT MDT'S CHECK IS
            # DEAD. ZTIValidate calls GetMajorMinorVersion on both sides and
            # compares 10.0 with 10.0 - and every Windows since Windows 10
            # reports 10.0, Windows 11 included. So MDT's downgrade refusal has
            # not been able to fire on a supported OS for ten years. The build is
            # the only component that moves, so the build is what HDT compares.
            $step = & $script:newStep $script:passingProperty
            $step.Property['imageVersion'] = '10.0.22631'

            (Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor (& $script:runningMachine) $null)).Status |
                Should -BeExactly 'Failed' -Because '26100 is newer than 22631 and both are 10.0'
        }

        It 'skips the check, and says so, when the sequence declares no image version' {
            # MDT'S OWN BEHAVIOUR: "ImageBuild could not be determined, assuming
            # ConfigMgr deployment", and it carries on. A sequence that does not
            # say what it is applying cannot be told the answer is wrong.
            $step = & $script:newStep ([ordered] @{ imageSizeMB = 5200 })

            $result = Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor (& $script:runningMachine) $null)

            $result.Status | Should -BeExactly 'Completed'

            $row = @($result.Data.check | Where-Object { [string] $_['key'] -eq 'imageVersion' })
            $row.Count | Should -Be 1 -Because 'a check that did not run is still reported'
            [string] $row[0]['result'] | Should -BeExactly 'skipped'
        }

        It 'refuses when the machine could not say which Windows it is running' {
            # A REFRESH THAT CANNOT READ ITS OWN VERSION CANNOT BE TOLD IT IS NOT
            # A DOWNGRADE. Silence here is the case the guard exists for.
            $step = & $script:newStep $script:passingProperty
            $context = & $script:contextFor (& $script:runningMachine) ([ordered] @{ HDTOSCurrentVersion = '' })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTOSCurrentVersion*'
        }
    }

    # MDT's ZTIValidate.wsf:151-154, failure 9809.
    Context 'the target volume refusal' {

        It 'refuses a Refresh aimed at a volume this machine is not running from' {
            $disk = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 137438953472
                    BusType = 'SAS'; PartitionStyle = 'GPT'
                }) -Volume @(
                @{ DriveLetter = 'C'; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'
                    SizeBytes = 128849018880; SizeRemainingBytes = 4294967296
                }
                @{ DriveLetter = 'D'; FileSystem = 'NTFS'; FileSystemLabel = 'Data'
                    SizeBytes = 128849018880; SizeRemainingBytes = 107374182400
                })

            $step = & $script:newStep $script:passingProperty
            $context = & $script:contextFor $disk ([ordered] @{ HDTOSVolume = 'D' })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*D:\*' -Because 'the volume it would have written to'
            $result.Message | Should -BeLike '*C:\*' -Because 'the volume this machine is running from'
            $result.Message | Should -BeLike '*allowOtherPartition*' -Because 'the override is named where the refusal is read'
        }

        It 'allows a Refresh aimed at the volume the machine is running from' {
            $step = & $script:newStep $script:passingProperty
            $context = & $script:contextFor (& $script:runningMachine) ([ordered] @{ HDTOSVolume = 'C' })

            (Invoke-HDTValidateStep -Step $step -Context $context).Status | Should -BeExactly 'Completed'
        }

        It "takes 'C', 'C:' and 'C:\' as one volume" {
            foreach ($spelling in @('C', 'C:', 'C:\')) {
                $step = & $script:newStep $script:passingProperty
                $context = & $script:contextFor (& $script:runningMachine) ([ordered] @{ HDTOSVolume = $spelling })

                (Invoke-HDTValidateStep -Step $step -Context $context).Status |
                    Should -BeExactly 'Completed' -Because ("HDTOSVolume was '{0}'" -f $spelling)
            }
        }

        It 'defaults the target to the running volume when nothing has published one' {
            # A REFRESH HAS NO DiskPartition STEP, so nothing publishes
            # HDTOSVolume before the pre-flight runs. MDT pins the destination to
            # SystemDrive for exactly this case (ZTIUtility.vbs:3586-3593), and
            # the check must not refuse a sequence for not having answered a
            # question it was never asked.
            $step = & $script:newStep $script:passingProperty

            (Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor (& $script:runningMachine) $null)).Status |
                Should -BeExactly 'Completed'
        }

        It 'lets the sequence override it deliberately, and records that it did' {
            # HDT'S SPELLING OF MDT'S DestinationOSRefresh=OKTOUSEOTHERDISKAND-
            # PARTITION. The magic string is an MDT artefact and rule 4 keeps it
            # out; the capability is real, so it survives as a declaration on the
            # step that enforces it - the same shape as DiskPartition's
            # `wipe: true`. An overridden safety rule is never silent.
            $disk = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 137438953472
                    BusType = 'SAS'; PartitionStyle = 'GPT'
                }) -Volume @(
                @{ DriveLetter = 'C'; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'
                    SizeBytes = 128849018880; SizeRemainingBytes = 4294967296
                }
                @{ DriveLetter = 'D'; FileSystem = 'NTFS'; FileSystemLabel = 'Data'
                    SizeBytes = 128849018880; SizeRemainingBytes = 107374182400
                })

            $step = & $script:newStep $script:passingProperty
            $step.Property['allowOtherPartition'] = $true
            $context = & $script:contextFor $disk ([ordered] @{ HDTOSVolume = 'D' })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Completed'
            @($result.Data.warning | Where-Object { $_ -like '*allowOtherPartition*' }).Count |
                Should -Be 1 -Because 'the override warns rather than passing in silence'
        }

        It 'does not let the override reach the other two guards' {
            # MDT'S ESCAPE HATCH COVERS ONE REFUSAL AND HDT'S COVERS THE SAME
            # ONE. A single switch that waved all three through would be a switch
            # nobody could reason about.
            $step = & $script:newStep $script:passingProperty
            $step.Property['allowOtherPartition'] = $true
            $step.Property['imageVersion'] = '10.0.19045'

            (Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor (& $script:runningMachine) $null)).Status |
                Should -BeExactly 'Failed'
        }
    }

    # MDT's ZTIValidate.wsf:231-256, failure 9807.
    Context 'the free-space refusal' {

        It 'refuses when the target volume cannot hold the image, WinPE and Setup' {
            # MDT'S ARITHMETIC: image + 150 MB for WinPE and logs + 3 GB for
            # Setup. A 6 GB volume and a 5200 MB image needs 8422 MB.
            $step = & $script:newStep $script:passingProperty
            $context = & $script:contextFor (& $script:runningMachine 6442450944) $null

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
        }

        It 'names the shortfall, the arithmetic and the way out' {
            $step = & $script:newStep $script:passingProperty
            $context = & $script:contextFor (& $script:runningMachine 6442450944) $null

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Message | Should -BeLike '*8422*' -Because '5200 + 150 + 3072 is what it needed'
            $result.Message | Should -BeLike '*6144*' -Because 'a 6 GB volume is what it found'
            $result.Message | Should -BeLike '*2278*' -Because 'the additional megabytes required, which is what MDT prints'
        }

        It 'measures the size of the volume rather than the space free on it' {
            # A DELIBERATE READING OF MDT, WRITTEN DOWN BECAUSE IT LOOKS WRONG.
            # ZTIValidate compares the drive's TOTAL size, "assuming most of the
            # drive will be cleaned off before calling setup" - and in HDT that
            # assumption is a step: CleanVolume empties the OS volume before the
            # image is applied. A check against free space would refuse every
            # machine that is full, which is every machine anybody wants to
            # refresh.
            $step = & $script:newStep $script:passingProperty
            $disk = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 137438953472
                    BusType = 'SAS'; PartitionStyle = 'GPT'
                }) -Volume @(
                @{ DriveLetter = 'C'; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'
                    SizeBytes = 128849018880; SizeRemainingBytes = 104857600
                })

            (Invoke-HDTValidateStep -Step $step -Context (& $script:contextFor $disk $null)).Status |
                Should -BeExactly 'Completed' -Because 'a 120 GB volume with 100 MB free is still a 120 GB volume'
        }

        It 'still requires room for WinPE and Setup when no image size is declared' {
            $step = & $script:newStep ([ordered] @{ imageVersion = '10.0.26100' })
            $context = & $script:contextFor (& $script:runningMachine 1073741824) $null

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*3222*' -Because '150 + 3072 is the floor even when the image size is unknown'
        }

        It 'refuses when the target volume is not there at all' {
            $step = & $script:newStep $script:passingProperty
            $context = & $script:contextFor (& $script:runningMachine 128849018880 'E') `
                ([ordered] @{ HDTOSVolume = 'C' })

            $result = Invoke-HDTValidateStep -Step $step -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*C:\*'
        }
    }

    Context 'the set, on a Refresh' {

        It 'refuses every one of them, not the first' {
            # THE PRE-FLIGHT'S OWN RULE, applied to the new checks: a technician
            # standing at a machine wants the whole list.
            $disk = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 137438953472
                    BusType = 'SAS'; PartitionStyle = 'GPT'
                }) -Volume @(
                @{ DriveLetter = 'C'; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'
                    SizeBytes = 128849018880; SizeRemainingBytes = 4294967296
                }
                @{ DriveLetter = 'D'; FileSystem = 'NTFS'; FileSystemLabel = 'Small'
                    SizeBytes = 1073741824; SizeRemainingBytes = 1073741824
                })

            $step = & $script:newStep ([ordered] @{ imageVersion = '10.0.19045'; imageSizeMB = 5200 })
            $context = & $script:contextFor $disk ([ordered] @{ HDTOSVolume = 'D' })

            $result = Invoke-HDTValidateStep -Step $step -Context $context
            $refresh = & $script:refreshRowOf $result

            $result.Status | Should -BeExactly 'Failed'

            $refresh.Count | Should -BeGreaterOrEqual 3 `
                -Because 'the Refresh guards report themselves whatever their verdict'

            @($refresh | Where-Object { [string] $_['result'] -ne 'fail' }) | Should -BeNullOrEmpty `
                -Because ('every Refresh check should have failed; the verdicts were: {0}' -f
                    ((@($refresh | ForEach-Object { '{0}={1}' -f $_['check'], $_['result'] })) -join ', '))

            @($result.Data.failedCheck).Count | Should -BeGreaterOrEqual 3
        }

        It 'gives every one of them a reason, an observation and a threshold' {
            $step = & $script:newStep ([ordered] @{ imageVersion = '10.0.19045'; imageSizeMB = 999999 })
            $context = & $script:contextFor (& $script:runningMachine) ([ordered] @{ HDTOSVolume = 'C' })

            $refresh = & $script:refreshRowOf (Invoke-HDTValidateStep -Step $step -Context $context)

            @($refresh | Where-Object { [string]::IsNullOrWhiteSpace([string] $_['observed']) }) |
                Should -BeNullOrEmpty -Because 'a refusal that does not say what it found is unactionable'
            @($refresh | Where-Object { [string]::IsNullOrWhiteSpace([string] $_['threshold']) }) |
                Should -BeNullOrEmpty -Because 'a refusal that does not say what it needed is unactionable'
        }
    }

    Context 'the set, on a NEWCOMPUTER run' {

        BeforeAll {
            # EVERY GUARD POINTED AT A FAILURE, AND NONE OF THEM MAY FIRE. An
            # older image, a volume that is not the running one, and a volume far
            # too small - on a run that starts from boot media, where the disk is
            # about to be repartitioned and there may be no Windows on it at all.
            $disk = New-HDTFakeDiskService -Disk @(
                @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 137438953472
                    BusType = 'SAS'; PartitionStyle = 'GPT'
                }) -Volume @(
                @{ DriveLetter = 'C'; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'
                    SizeBytes = 128849018880; SizeRemainingBytes = 4294967296
                }
                @{ DriveLetter = 'D'; FileSystem = 'NTFS'; FileSystemLabel = 'Small'
                    SizeBytes = 1073741824; SizeRemainingBytes = 1073741824
                })

            $step = & $script:newStep ([ordered] @{ imageVersion = '10.0.19045'; imageSizeMB = 5200 })

            # X: is the RAM disk a bare-metal run boots into, and the machine may
            # report no Windows version at all.
            $context = & $script:contextFor $disk ([ordered] @{
                    HDTDeploymentType   = 'NEWCOMPUTER'
                    HDTOSCurrentVersion = ''
                    HDTOSVolume         = 'D'
                }) 'X:' 'WinPE'

            $script:bareMetal = Invoke-HDTValidateStep -Step $step -Context $context
        }

        It 'passes the pre-flight' {
            $script:bareMetal.Status | Should -BeExactly 'Completed' `
                -Because ('the pre-flight said: {0}' -f $script:bareMetal.Message)
        }

        It 'skips every Refresh guard rather than passing it quietly' {
            $refresh = & $script:refreshRowOf $script:bareMetal

            $refresh.Count | Should -BeGreaterOrEqual 3 `
                -Because 'a check absent from the log and a check that passed look identical'

            @($refresh | Where-Object { [string] $_['result'] -ne 'skipped' }) | Should -BeNullOrEmpty `
                -Because ('the verdicts were: {0}' -f
                    ((@($refresh | ForEach-Object { '{0}={1}' -f $_['check'], $_['result'] })) -join ', '))
        }

        It 'says why each was skipped, naming the deployment type' {
            $refresh = & $script:refreshRowOf $script:bareMetal

            @($refresh | Where-Object { [string] $_['reason'] -notlike '*NEWCOMPUTER*' }) |
                Should -BeNullOrEmpty -Because 'the reader has to be able to tell a skip from a pass'
        }

        It 'raises no warning about them either' {
            @($script:bareMetal.Data.warning | Where-Object { $_ -like '*Refresh*' }) | Should -BeNullOrEmpty
        }
    }
}

# THE TARGET-DISK CHECK, ON THE MACHINE A REFRESH ACTUALLY RUNS ON.
#
# THIS IS THE DEFECT THE FIXTURES ABOVE COULD NOT SEE. Every disk row in this
# file until now was seeded WITHOUT IsBoot or IsSystem, so the target-disk
# selection passed - on a machine that had, by construction, never booted from
# anything. A real Refresh runs in the full OS of a machine that is booting from
# the disk it is about to replace, and Get-HDTTargetDiskAssessment's very first
# rule excludes that disk ABSOLUTELY and not overridably: "disk N is the disk
# this machine booted from". It is exactly the right rule for a bare-metal run,
# where the boot disk is the WinPE stick, and exactly backwards for a Refresh,
# where the boot disk IS the target.
#
# So the pre-flight refused every Refresh it would ever have been pointed at, at
# step one, with a message about a disk it was never going to use - and the whole
# feature stopped there. Found by taking the shipped refresh.yaml through the
# engine rather than by parsing it (tests/unit/RefreshTemplate.EndToEnd).
#
# THE FIX IS THE SYMMETRY THAT WAS ALREADY THERE. The three Refresh-only guards
# report 'skipped' with a reason on a NEWCOMPUTER run; the target-disk rows now
# report 'skipped' with a reason on a REFRESH, for the mirror-image cause. A
# Refresh does not choose a disk - it reuses the one Windows was booting from -
# and the check that governs its target is the partition-match guard, which is
# in this step already.

Describe 'Invoke-HDTValidateStep on the machine a Refresh runs on' {

    BeforeAll {
        # THE DISK THIS MACHINE BOOTED FROM, which is what every previous fixture
        # in this file left out.
        $script:bootedDisk = New-HDTFakeDiskService -Disk @(
            @{ Number = 0; FriendlyName = 'Virtual HD'; SizeBytes = 137438953472
                BusType = 'SAS'; PartitionStyle = 'GPT'; IsBoot = $true; IsSystem = $true
            }) -Volume @(
            @{ DriveLetter = 'C'; FileSystem = 'NTFS'; FileSystemLabel = 'Windows'
                SizeBytes = 128849018880; SizeRemainingBytes = 4294967296
            })

        # minDiskGB IS DECLARED HERE ON PURPOSE, and refresh.yaml declares none.
        # The shipped template leaves it out with a comment saying why, which
        # protects the template and nobody else: an administrator ticking
        # "Ensure minimum disk size" on the console's Validate page writes the
        # key onto a Refresh sequence, and the engine has to be right about it
        # rather than the file.
        $step = & $script:newStep $script:passingProperty
        $step.Property['minDiskGB'] = 60

        $context = & $script:contextFor $script:bootedDisk $null

        $script:onItsOwnDisk = Invoke-HDTValidateStep -Step $step -Context $context

        # THE SET COMES OUT OF THE TABLE, NOT OUT OF THIS FILE.
        # Get-HDTValidateCheckDefinition is the one place a check is declared and
        # its Scope column says which run each one belongs to, so "the checks a
        # Refresh does not make" is a QUERY - and a fourth one scoped that way is
        # covered by every assertion below the day its row lands, rather than the
        # day somebody remembers to name it here. It is the mirror of
        # $script:refreshRowOf above, which reads the REFRESH rows the same way.
        $script:diskRowOf = {
            param([object] $Result)

            $key = @(InModuleScope Hephaestus {
                    @(Get-HDTValidateCheckDefinition |
                            Where-Object { [string] $_.Scope -eq 'NEWCOMPUTER' } |
                            ForEach-Object { [string] $_.Key })
                })

            # ANTI-VACUITY, and it has to be here rather than in an It. A set
            # test that matched nothing would pass every assertion below by
            # matching no rows at all.
            if ($key.Count -lt 2) {
                throw ("Get-HDTValidateCheckDefinition declares {0} NEWCOMPUTER-scoped check(s); the disk checks should be there." -f $key.Count)
            }

            # The per-disk rows carry no key - they are one row per disk this
            # machine has rather than a check anybody can declare - so they are
            # matched by name.
            return @($Result.Data.check | Where-Object {
                    $key -contains [string] $_['key'] -or [string] $_['check'] -match '^disk \d+$'
                })
        }
    }

    It 'passes the pre-flight rather than refusing the disk it is standing on' {
        $script:onItsOwnDisk.Status | Should -BeExactly 'Completed' `
            -Because ('the pre-flight said: {0}' -f $script:onItsOwnDisk.Message)
    }

    It 'does not report the boot disk as an exclusion' {
        [string] $script:onItsOwnDisk.Message | Should -Not -Match 'booted from'
    }

    It 'reports the target-disk rows as skipped rather than passing them quietly' {
        $row = & $script:diskRowOf $script:onItsOwnDisk

        $row.Count | Should -BeGreaterThan 0 `
            -Because 'a check absent from the log and a check that passed look identical'

        @($row | Where-Object { [string] $_['result'] -ne 'skipped' }) | Should -BeNullOrEmpty `
            -Because ('the verdicts were: {0}' -f
                ((@($row | ForEach-Object { '{0}={1}' -f $_['check'], $_['result'] })) -join ', '))
    }

    It 'says why, naming REFRESH' {
        $row = & $script:diskRowOf $script:onItsOwnDisk

        @($row | Where-Object { [string] $_['reason'] -notlike '*REFRESH*' }) |
            Should -BeNullOrEmpty -Because 'the reader has to be able to tell a skip from a pass'
    }

    It 'still chooses a target disk on a NEWCOMPUTER run, boot disk excluded' {
        # THE OTHER HALF OF THE SET, so the fix cannot turn into "the check never
        # runs". A bare-metal run on this same machine still refuses: the only
        # disk is the one WinPE booted from.
        $step = & $script:newStep ([ordered] @{})
        $context = & $script:contextFor $script:bootedDisk ([ordered] @{
                HDTDeploymentType   = 'NEWCOMPUTER'
                HDTOSCurrentVersion = ''
            }) 'X:' 'WinPE'

        $result = Invoke-HDTValidateStep -Step $step -Context $context

        $result.Status | Should -BeExactly 'Failed'
        [string] $result.Message | Should -Match 'booted from'
    }
}
