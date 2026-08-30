# DESIGN 9.3: read the sysprepped reference machine into a WIM the share can
# deploy. ApplyImage run backwards - the same service, the same dism meter, the
# same throttling - and the inverse mistakes.
#
# THE ARGUMENT ORDER IS THE WHOLE CONTRACT. capturePath is READ and imagePath is
# WRITTEN; both are paths and both are strings, and a step that swapped them
# would overwrite the machine it was asked to capture. Nothing but the fake's
# recorded argument list catches that.
#
# AND THREE REFUSALS THAT COST NOTHING HERE AND HOURS ON A MACHINE.
#
#   Captures\ IS VERIFIED FIRST. It is one of only two folders the deployment
#   account may write (DESIGN 2.1), and discovering it cannot at the END of a
#   capture is discovering it after the reference build has already been
#   generalized and can no longer be picked up where it left off.
#
#   THE Local PROVIDER IS REFUSED OUTRIGHT. The deploy root is a read-only disc,
#   Captures\ cannot be written at all, and there is no correction a technician
#   standing at the machine could make (DESIGN 9.3 note 6).
#
#   AND NO CAPTURE EVER RUNS WITHOUT AN EXCLUSION LIST. Without /ConfigFile: a
#   capture swallows pagefile.sys, hiberfil.sys and - because HDT put them there
#   - the resume agent at <osvolume>\HDT and one machine's deployment log. An
#   image carrying those re-runs somebody else's deployment state on every
#   machine built from it (DESIGN 9.3 note 7).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'Z:\Deploy'
    # THE PATH THE STEP WILL BUILD, BUILT THE SAME WAY. The fallback is the
    # module's own shipped list, which travels into every boot image with the
    # rest of Templates\ - so on a real machine it is on the disk beside the
    # engine, and the fake stands for that disk.
    $script:moduleBase = (Get-Module -Name Hephaestus).ModuleBase
    $script:moduleConfig = [System.IO.Path]::Combine($script:moduleBase, 'Templates', 'Capture', 'wimscript.ini')

    # And the real file, so the seeded copy is the one this module ships rather
    # than a stub that could disagree with it.
    $script:moduleConfigText = [string] (Get-Content -LiteralPath $script:moduleConfig -Raw)

    # THE PROBE'S NAME IS DERIVED FROM THE RUN ID AND NOT FROM A GUID, so a test
    # can seed the one path that must refuse to be written. A random name would
    # make "the account cannot write Captures\" unprovable against a fake.
    $script:probePath = 'Z:\Deploy\Captures\.hdt-write-probe-run-0001.tmp'

    # A REAL dism /Capture-Image METER. The same shape /Apply-Image prints, which
    # is why the step reuses ApplyImage's parser and its five-point stride.
    $script:meter = @(
        'Deployment Image Servicing and Management tool'
        'Version: 10.0.26100.1'
        ''
        '[                           1.0%                           ] '
        '[=====                      10.0%                          ] '
        '[===========                22.0%                          ] '
        '[================           33.0%                          ] '
        '[=====================      45.0%                          ] '
        '[==========================100.0%==========================] '
        'The operation completed successfully.'
    )

    $script:newStep = {
        param([System.Collections.IDictionary] $Property, [int] $TimeoutMinute = 0)

        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Property) {
            foreach ($key in @($Property.Keys)) { $bag[[string] $key] = $Property[$key] }
        }

        return [pscustomobject] @{
            Index = 11; Name = 'Capture the reference image'; Type = 'CaptureImage'
            TimeoutMinutes = $TimeoutMinute; Log = $null; Property = $bag
        }
    }
}

Describe 'Invoke-HDTCaptureImageStep' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:moduleConfig = $script:moduleConfigText }
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 31, 11, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 500
        $script:image = New-HDTFakeImageService
        $script:content = New-HDTFakeContentProvider -Root $script:workspaceRoot -Kind Smb

        $script:newContext = {
            param([System.Collections.IDictionary] $Variable, [object] $ContentProvider)

            $provider = $ContentProvider
            if ($null -eq $provider) { $provider = $script:content }

            $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
                -Image $script:image -Content $provider

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock -Level Debug

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'
            if ($null -ne $Variable) {
                foreach ($key in @($Variable.Keys)) { $live[[string] $key] = $Variable[$key] }
            }

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                    -Variable $live -Service $catalog -Log $log)
        }

        $script:context = & $script:newContext $null $null
    }

    Context 'what it reads and what it writes' {

        It 'captures the OS volume root, not a folder that merely holds an OS tree' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF-WIN11.wim' })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            @($capture).Count | Should -Be 1
            [string] $capture[0].Arguments[0] | Should -BeExactly 'W:\'
        }

        It 'writes into Captures\, which is where the share expects it' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF-WIN11.wim' })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[1] | Should -BeExactly 'Z:\Deploy\Captures\REF-WIN11.wim'
        }

        It 'gives the WIM a .wim extension when the author left it off' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF-WIN11' })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[1] | Should -BeExactly 'Z:\Deploy\Captures\REF-WIN11.wim'
        }

        It 'takes a rooted destination as written, for a capture onto a second disk' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'D:\Captures\REF.wim' })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[1] | Should -BeExactly 'D:\Captures\REF.wim'
        }

        It 'names the image and describes it' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{
                            image = 'REF-WIN11.wim'; name = 'Windows 11 reference'; description = 'built 2026-08-31'
                        })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[2] | Should -BeExactly 'Windows 11 reference'
            [string] $capture[0].Arguments[3] | Should -BeExactly 'built 2026-08-31'
        }

        It 'names it after the file when the author named nothing' {
            # AN UNNAMED IMAGE IS UNSELECTABLE. Resolve-HDTImageIndex matches on
            # Name, and a WIM whose only index is called '' cannot be asked for.
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF-WIN11.wim' })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[2] | Should -BeExactly 'REF-WIN11'
        }

        It 'expands a variable in the destination, so one sequence names one build' {
            $context = & $script:newContext ([ordered] @{ HDTTaskSequenceID = 'REF-WIN11' }) $null

            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = '%HDTTaskSequenceID%.wim' })) -Context $context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[1] | Should -BeExactly 'Z:\Deploy\Captures\REF-WIN11.wim'
        }

        It 'takes a source of its own when the sequence names one' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{
                            image = 'REF.wim'; source = 'V'
                        })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[0] | Should -BeExactly 'V:\'
        }

        It 'reports Completed and publishes where it put the image' {
            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF-WIN11.wim' })) -Context $script:context

            $result.Status | Should -BeExactly 'Completed'
            [string] $script:context.Variable['HDTCapturePath'] | Should -BeExactly 'Z:\Deploy\Captures\REF-WIN11.wim'
        }
    }

    Context 'compression' {

        It 'compresses max by default, because a reference image is stored and copied for years' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[4] | Should -BeExactly 'max'
        }

        It 'takes <Compress> when the sequence asks for it' -ForEach @(
            @{ Compress = 'none' }
            @{ Compress = 'fast' }
            @{ Compress = 'max' }
        ) {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim'; compress = $Compress })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[4] | Should -BeExactly $Compress
        }

        It 'refuses a compression dism does not have, before it captures anything' {
            # THE CONSOLE OFFERS THREE AND THE STEP ACCEPTS THREE, from one list.
            # A fourth would be four hours of capture ending in dism's own
            # complaint about a switch the console had just offered.
            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim'; compress = 'ultra' })) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*ultra*'
            @($script:image.GetOperationName()) | Should -BeNullOrEmpty
        }
    }

    Context 'the exclusion list' {

        It "falls back to the module's list when the share carries none" {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[6] | Should -BeExactly $script:moduleConfig
        }

        It "prefers the share's Control\wimscript.ini when there is one" {
            # A SHARE CREATED BEFORE THIS EXISTED STILL CAPTURES CORRECTLY, and a
            # shop that has to exclude its own folder edits one file on the share
            # rather than the module every machine boots.
            $script:fileSystem.WriteAllText('Z:\Deploy\Control\wimscript.ini', "[ExclusionList]`r`n\pagefile.sys`r`n\HDT")
            $context = & $script:newContext $null $null

            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[6] | Should -BeExactly 'Z:\Deploy\Control\wimscript.ini'
        }

        It 'takes one the sequence names' {
            $script:fileSystem.WriteAllText('Z:\Deploy\Control\server.ini', '[ExclusionList]')
            $context = & $script:newContext $null $null

            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{
                            image = 'REF.wim'; configFile = 'Z:\Deploy\Control\server.ini'
                        })) -Context $context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            [string] $capture[0].Arguments[6] | Should -BeExactly 'Z:\Deploy\Control\server.ini'
        }

        It 'refuses a named list that is not there, rather than capturing without exclusions' {
            # THE SILENT FAILURE THIS EXISTS TO STOP. dism warns about a missing
            # /ConfigFile: and captures the whole volume anyway, exit code zero -
            # so the reference image is wrong and the run is green.
            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{
                        image = 'REF.wim'; configFile = 'Z:\Deploy\Control\missing.ini'
                    })) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*missing.ini*'
            @($script:image.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'the list it falls back to is one this module actually ships' {
            # A FALLBACK NOBODY SHIPPED IS THE MISSING-FILE FAILURE ABOVE, on
            # every capture, on every share.
            Test-Path -LiteralPath $script:moduleConfig -PathType Leaf | Should -BeTrue
        }

        It 'the shipped list excludes what HDT itself put on the volume' {
            $text = [string] (Get-Content -LiteralPath $script:moduleConfig -Raw)

            $text | Should -BeLike '*\HDT*'
            $text | Should -BeLike '*pagefile.sys*'
        }
    }

    Context 'the scratch directory' {

        It 'puts scratch on the volume being captured, never on the WinPE RAM disk' {
            # X: IS A RAM DISK AND dism RUNS OUT OF ROOM ON IT. The same reason
            # ApplyUnattend builds <osvolume>\HDT\Scratch rather than letting
            # dism expand into TEMP.
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context)

            $capture = @($script:image.Operations | Where-Object { $_.Operation -eq 'CaptureImage' })
            $scratch = [string] $capture[0].Arguments[5]

            $scratch | Should -Not -BeLike 'X:*'
            $scratch | Should -BeLike 'W:*'
        }
    }

    Context 'verifying the write before it is needed' {

        It 'probes Captures\ before it captures anything' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context)

            $written = @($script:fileSystem.Operations |
                    Where-Object { $_.Operation -eq 'WriteAllText' -and [string] $_.Arguments[0] -like 'Z:\Deploy\Captures\*' })

            @($written).Count | Should -BeGreaterThan 0
        }

        It 'removes its own probe rather than leaving litter in Captures\' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context)

            $script:fileSystem.TestPath($script:probePath) | Should -BeFalse
        }

        It 'fails naming Captures\ when the account cannot write there' {
            $failing = New-HDTFakeFileSystem -File @{ $script:moduleConfig = $script:moduleConfigText } `
                -WriteFailure @{ $script:probePath = 'Access to the path is denied.' }

            $catalog = New-HDTServiceCatalog -FileSystem $failing -Clock $script:clock `
                -Image $script:image -Content $script:content

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock

            $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            $live['HDTOSVolume'] = 'W'

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot $script:workspaceRoot `
                -Variable $live -Service $catalog -Log $log

            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Captures*'
            @($script:image.GetOperationName()) | Should -BeNullOrEmpty
        }
    }

    Context 'on media' {

        It 'refuses under the Local provider' {
            # DESIGN 9.3 note 6: the deploy root is a read-only disc, Captures\
            # cannot be written at all, and there is no correction a technician
            # could make. Attempting the write would report the symptom and none
            # of the cause.
            $media = New-HDTFakeContentProvider -Root 'D:\Deploy' -Kind Local
            $context = & $script:newContext $null $media

            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*media*'
            @($script:image.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'refuses before it probes, because there is nothing to probe' {
            $media = New-HDTFakeContentProvider -Root 'D:\Deploy' -Kind Local
            $context = & $script:newContext $null $media

            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $context)

            @($script:fileSystem.Operations | Where-Object { $_.Operation -eq 'WriteAllText' }) |
                Should -BeNullOrEmpty
        }

        It 'captures under the Smb provider, which is the ordinary case' {
            (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context).Status |
                Should -BeExactly 'Completed'
        }
    }

    Context 'a target that resolved to nothing' {

        It 'refuses rather than guessing at C:' {
            # THE MIRROR OF ApplyImage'S REFUSAL. A capture of C:\ in WinPE is a
            # capture of the boot media or of nothing; a capture of C:\ in the
            # full OS is a capture of a machine nobody asked about.
            $context = & $script:newContext ([ordered] @{ HDTOSVolume = '' }) $null

            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*HDTOSVolume*'
            @($script:image.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'refuses a source that is not one drive letter' {
            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{
                        image = 'REF.wim'; source = 'the big disk'
                    })) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            @($script:image.GetOperationName()) | Should -BeNullOrEmpty
        }

        It 'refuses a step that names no destination at all' {
            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep $null) -Context $script:context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*image*'
        }
    }

    Context 'the meter' {

        BeforeEach {
            $script:image = New-HDTFakeImageService -CaptureOutput $script:meter
            $script:context = & $script:newContext $null $null
        }

        It 'writes a step.progress record as dism counts up' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context)

            @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress') |
                Should -Not -BeNullOrEmpty
        }

        It 'reports every five points and not every line' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context)

            $percent = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                    ForEach-Object { [int] $_.data.percent })

            $percent | Should -Be @(10, 22, 33, 45, 100)
        }

        It 'always says a hundred, so the last word about a capture is that it finished' {
            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context)

            $percent = @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress' |
                    ForEach-Object { [int] $_.data.percent })

            $percent[-1] | Should -Be 100
        }

        It 'writes nothing when dism prints no meter at all' {
            $script:image = New-HDTFakeImageService
            $context = & $script:newContext $null $null

            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $context)

            @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress') |
                Should -BeNullOrEmpty
        }

        It 'does not let a failed log write fail the capture' {
            # A BAR DOES NOT GET TO FAIL A DEPLOYMENT, and this one runs on a
            # machine part-way through reading a day's work into a WIM.
            (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $script:context).Status |
                Should -BeExactly 'Completed'
        }
    }

    Context 'a capture that failed' {

        It 'fails with what dism said, rather than with a status' {
            $script:image = New-HDTFakeImageService -Failure @{ CaptureImage = 'Error: 0x8007000D' } `
                -CaptureOutput $script:meter
            $context = & $script:newContext $null $null

            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*0x8007000D*'
        }

        It 'keeps the progress it had already logged' {
            # A CAPTURE THAT DIED AT 45% DIED SOMEWHERE DIFFERENT from one that
            # never started, on a step that runs for a quarter of an hour.
            $script:image = New-HDTFakeImageService -Failure @{ CaptureImage = 'Error: 0x8007000D' } `
                -CaptureOutput $script:meter
            $context = & $script:newContext $null $null

            [void] (Invoke-HDTCaptureImageStep -Step (& $script:newStep ([ordered] @{ image = 'REF.wim' })) -Context $context)

            @(Get-HDTLogRecord -FileSystem $script:fileSystem -Path 'X:\HDT\Logs\HDT.jsonl' -Event 'step.progress') |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'a step with nothing configured and bare fakes' {

        It 'fails rather than throwing' {
            $catalog = New-HDTServiceCatalog -FileSystem (New-HDTFakeFileSystem) -Clock $script:clock `
                -Image (New-HDTFakeImageService)


            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $script:fileSystem -Clock $script:clock

            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'X:\Deploy' `
                -Variable ([System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)) `
                -Service $catalog -Log $log

            $result = Invoke-HDTCaptureImageStep -Step (& $script:newStep $null) -Context $context

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Get-HDTCaptureImageStepDescription' {

    It 'names the image it will write' {
        $bag = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        $bag['image'] = 'REF-WIN11.wim'

        $step = [pscustomobject] @{
            Index = 1; Name = 'Capture'; Type = 'CaptureImage'; TimeoutMinutes = 0; Log = $null; Property = $bag
        }

        Get-HDTCaptureImageStepDescription -Step $step | Should -BeLike '*REF-WIN11.wim*'
    }

    It 'says something useful even when nothing is configured' {
        $step = [pscustomobject] @{
            Index = 1; Name = 'Capture'; Type = 'CaptureImage'; TimeoutMinutes = 0; Log = $null
            Property = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        }

        Get-HDTCaptureImageStepDescription -Step $step | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-HDTCaptureImageStepTemplate' {

    It 'declares the type, so the console can offer it' {
        ((@(Get-HDTCaptureImageStepTemplate)) -join "`n") | Should -BeLike '*type: CaptureImage*'
    }

    It 'writes the destination out, because it is the one thing that cannot be guessed' {
        ((@(Get-HDTCaptureImageStepTemplate)) -join "`n") | Should -BeLike '*image:*'
    }

    It 'runs in WinPE, which is the only place a generalized machine can be read' {
        # A CAPTURE FROM THE RUNNING OS IS A CAPTURE OF A VOLUME IN USE. The
        # machine was sysprepped and restarted precisely so this runs from the
        # boot media instead.
        ((@(Get-HDTCaptureImageStepTemplate)) -join "`n") | Should -BeLike '*runIn: WinPE*'
    }
}
