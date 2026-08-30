# The step contract (DESIGN 4.2, DESIGN 12.2.1, PROJECT constraint 4).
#
# Every step type ever added - by this repository or by a third party dropping a
# module into a workspace's Modules\ - is held to the same bar, and the bar is
# enforced by ENUMERATION rather than by a list somebody has to remember to
# extend:
#
#   -ForEach (Get-HDTStepType) at DISCOVERY time.
#
# Pester 5 expands -ForEach while discovering, so the registry is built here at
# file scope rather than in a BeforeAll, which would produce zero test cases.
#
# The last test in this file is the important one. PROJECT constraint 4 - "steps
# never touch hardware directly" - is a rule nobody can enforce by reading, so it
# is made mechanical: the file behind every HDT step type is parsed and refused
# if it names a filesystem, registry, CIM or process cmdlet. That is what keeps a
# future step author honest after everyone who wrote this design has moved on.

$script:HDTRepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module -Name (Join-Path -Path $script:HDTRepositoryRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') `
    -Force -ErrorAction Stop

$script:HDTStepTypeCase = @(Get-HDTStepType | ForEach-Object {
        @{
            Type        = $_.Type
            InvokeName  = $_.InvokeCommand.Name
            HasTest     = ($null -ne $_.TestCommand)
            TestName    = $(if ($null -ne $_.TestCommand) { $_.TestCommand.Name } else { '' })
            Source      = $_.Source
        }
    })

# HDT's own types only: a third party's file is not ours to hold to a layout, and
# Get-HDTStepType may be showing a module created in memory by another test file.
$script:HDTOwnStepTypeCase = @($script:HDTStepTypeCase | Where-Object { $_.Source -eq 'Hephaestus' })

# THE HAND-WRITTEN LIST. See 'the registry itself' at the foot of this file for
# why it is written out rather than enumerated, and for the assertion that stops
# it rotting. It lives at file scope because -ForEach binds during discovery.
$script:HDTExpectedStepType = @(
    'NoOp', 'SetVariable', 'PowerShell', 'CommandLine', 'Restart',
    'Validate', 'DiskPartition', 'ApplyImage', 'ApplyUnattend', 'ApplyDrivers',
    'ConfigureBoot', 'InstallApplications', 'InstallRoles', 'InstallCertificate',
    'EnableBitLocker', 'Tattoo', 'Gather', 'Sysprep', 'CaptureImage'
)

Describe 'the step contract' {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

        $script:stepFileRoot = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Steps'

        # PROJECT constraint 4 made mechanical. A step reaches the outside world
        # through the injected catalog or not at all. Defined in BeforeAll rather
        # than at discovery scope, so it is certainly in scope where it is read.
        $script:forbiddenCall = @(
            'Get-CimInstance',
            'Get-Content',
            'Set-Content',
            'Add-Content',
            'Out-File',
            'Test-Path',
            'Start-Process',
            'Restart-Computer',
            'Stop-Computer',
            'New-ItemProperty',
            'Set-ItemProperty',
            'Get-ItemProperty',
            'Invoke-WebRequest',
            'Invoke-RestMethod'
        )

        # The minimal valid step and a catalog of nothing but fakes: every step
        # type must survive being handed one, whatever it decides to do about it.
        $script:newMinimalStep = {
            param([string] $Type)

            return [pscustomobject] @{
                Index          = 1
                Name           = 'A step'
                Type           = $Type
                TimeoutMinutes = 0
                Log            = $null
                Property       = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        $script:newContext = {
            $fileSystem = New-HDTFakeFileSystem
            $clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 13, 0, 11, 2, [System.DateTimeKind]::Utc))

            # AN EMPTY FAKE DISK SERVICE IS THE RIGHT THING TO HAND A MINIMAL
            # STEP. A machine that reports no disk at all is a REFUSAL - a Failed
            # result naming the missing storage driver - not an exception, so the
            # imaging steps satisfy the closed-set contract on it. Handing them a
            # catalog with no disk service would prove only that they cope with a
            # misconfigured catalog, which is not the case the contract is about.
            $catalog = New-HDTServiceCatalog -FileSystem $fileSystem -Clock $clock `
                -Registry (New-HDTFakeRegistryService) `
                -Process (New-HDTFakeProcessService) `
                -Power (New-HDTFakePowerService) `
                -ScriptInvoker (New-HDTFakeScriptInvoker) `
                -Cim (New-HDTFakeCimProvider) `
                -Environment (New-HDTFakeEnvironmentProvider) `
                -Disk (New-HDTFakeDiskService) `
                -Image (New-HDTFakeImageService)

            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE -LogPath 'X:\HDT\Logs' `
                -FileSystem $fileSystem -Clock $clock

            $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

            return (New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE -WorkspaceRoot 'X:\Deploy' `
                    -Variable $variable -Service $catalog -Log $log)
        }
    }

    Context 'every discovered type' -ForEach $script:HDTStepTypeCase {

        It '<Type> exposes an invoke command' {
            Get-Command -Name $InvokeName -CommandType Function -ErrorAction Stop | Should -Not -BeNullOrEmpty
        }

        It '<Type> takes a -Step parameter' {
            @((Get-Command -Name $InvokeName).Parameters.Keys) | Should -Contain 'Step'
        }

        It '<Type> takes a -Context parameter' {
            @((Get-Command -Name $InvokeName).Parameters.Keys) | Should -Contain 'Context'
        }

        It '<Type> has no other mandatory parameter' {
            # A step type the loop cannot call with exactly -Step and -Context is
            # not a step type, whatever else it does.
            $command = Get-Command -Name $InvokeName
            $mandatory = @($command.Parameters.Values |
                    Where-Object { @($_.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0 } |
                    ForEach-Object { $_.Name })

            @($mandatory | Where-Object { @('Step', 'Context') -notcontains $_ }) | Should -BeNullOrEmpty
        }

        It '<Type> returns a description' {
            $step = & $script:newMinimalStep $Type

            Get-HDTStepDescription -Step $step | Should -Not -BeNullOrEmpty
        }

        It '<Type> reports applicability as a boolean' {
            $step = & $script:newMinimalStep $Type
            $context = & $script:newContext

            Test-HDTStepApplicable -Step $step -Context $context | Should -BeOfType ([bool])
        }

        It '<Type> returns a result with a Status from the closed set' {
            $step = & $script:newMinimalStep $Type
            $context = & $script:newContext

            $result = Invoke-HDTStep -Step $step -Context $context

            $result | Should -Not -BeNullOrEmpty
            @('Completed', 'Failed', 'RebootRequested') | Should -Contain $result.Status
        }

        It '<Type> returns a result carrying ExitCode, Message and Data' {
            $step = & $script:newMinimalStep $Type
            $context = & $script:newContext

            $name = @((Invoke-HDTStep -Step $step -Context $context).PSObject.Properties.Name)

            foreach ($expected in @('Status', 'ExitCode', 'Message', 'Data')) {
                $name | Should -Contain $expected
            }
        }
    }

    Context "this module's own types" -ForEach $script:HDTOwnStepTypeCase {

        It '<Type> is defined in a file under Public/Steps' {
            $path = Join-Path -Path $script:stepFileRoot -ChildPath ('{0}.ps1' -f $InvokeName)

            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        }

        It '<Type> mentions no forbidden direct call' {
            # PROJECT constraint 4, made mechanical: a step reaches the outside
            # world through the injected service catalog or not at all. A grep is
            # crude, but it makes the constraint permanent instead of relying on
            # every future author remembering it.
            $path = Join-Path -Path $script:stepFileRoot -ChildPath ('{0}.ps1' -f $InvokeName)
            $text = Get-Content -LiteralPath $path -Raw

            $hit = @($script:forbiddenCall | Where-Object { $text -match ('\b{0}\b' -f [regex]::Escape($_)) })

            $hit | Should -BeNullOrEmpty -Because ("{0} must reach the outside world only through the injected service catalog" -f $InvokeName)
        }

        It '<Type> declares comment-based help with a synopsis' {
            $help = Get-Help -Name $InvokeName -ErrorAction Stop

            $help.Name | Should -BeExactly $InvokeName
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the registry itself' {

        # THE ONE ASSERTION IN THIS FILE THAT IS NOT AN ENUMERATION, and it is
        # hand-maintained on purpose: everything above holds whatever
        # Get-HDTStepType happens to return, so a type that quietly stopped being
        # discovered would take its own tests with it and nothing would go red.
        # This list is what notices.
        It 'discovered <_>' -ForEach $script:HDTExpectedStepType {

            @(Get-HDTStepType -Name $_).Count | Should -Be 1
        }

        # AND THIS IS THE TRIPWIRE ON THE TRIPWIRE. A hand-written list rots:
        # this one named fourteen types while Public\Steps held seventeen, so
        # ApplyDrivers, Gather and InstallCertificate could have stopped being
        # discovered and every assertion in this file would still have been
        # green. A list nobody is made to update is not a tripwire.
        #
        # IT COMPARES AGAINST THE FILES ON DISK, NOT AGAINST Get-HDTStepType.
        # Deriving the other side from the registry would check the list against
        # the very thing the list exists to check, and pass for ever. The step
        # files are an independent witness: one per type, named for it.
        #
        # SET EQUALITY, NOT A COUNT, AND BOTH DIRECTIONS. A count says a number
        # is wrong; this names the type and says which way it went - a new step
        # file nobody listed, or a listed type whose file was deleted.
        #
        # The list arrives through -ForEach rather than being read off the script
        # scope, for the reason the $forbiddenCall comment above gives: a
        # variable set at discovery scope is not certainly in scope at run time.
        It 'names exactly the step files under Public/Steps' -ForEach @(@{ Expected = $script:HDTExpectedStepType }) {

            $onDisk = @(Get-ChildItem -LiteralPath $script:stepFileRoot -Filter 'Invoke-HDT*Step.ps1' -File |
                    ForEach-Object { $_.BaseName -replace '^Invoke-HDT', '' -replace 'Step$', '' })

            @($onDisk | Where-Object { $Expected -notcontains $_ }) |
                Should -BeNullOrEmpty -Because 'a step file with no entry in the list above is a step type nothing in this file is watching'

            @($Expected | Where-Object { $onDisk -notcontains $_ }) |
                Should -BeNullOrEmpty -Because 'the list above names a step type with no file under Public/Steps'
        }
    }
}
