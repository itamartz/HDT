# New-HDTServiceCatalog is PROJECT constraint 4 made into one object: the single
# thing a step is handed so it can reach the outside world, and the single thing
# a test replaces to prove the step without a machine attached.
#
# EVERY PROPERTY IS DEFINED EVEN WHEN IT IS $null. Engine code runs under
# Set-StrictMode -Version Latest, where reading a property that was never defined
# throws "The property 'Process' cannot be found on this object" - an error that
# says nothing about which step wanted what. GetRequired exists to replace that
# with a sentence naming the service and the step type that asked for it.
#
# FileSystem and Clock are mandatory and nothing else is, because a NoOp sequence
# must be runnable with two services and no more.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
}

Describe 'New-HDTServiceCatalog' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::Parse('2026-08-13T00:11:02.481Z').ToUniversalTime())
    }

    It 'exposes every service property even when it was not supplied' {
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        $name = @($catalog.PSObject.Properties.Name)
        foreach ($expected in @('FileSystem', 'Clock', 'Registry', 'Lsa', 'Process', 'Power', 'ScriptInvoker', 'Cim', 'Environment')) {
            $name | Should -Contain $expected
        }

        $catalog.Process | Should -BeNullOrEmpty
        $catalog.Registry | Should -BeNullOrEmpty
    }

    It 'exposes Disk and Image even when they were not supplied' {
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        $name = @($catalog.PSObject.Properties.Name)
        $name | Should -Contain 'Disk'
        $name | Should -Contain 'Image'

        $catalog.Disk | Should -BeNullOrEmpty
        $catalog.Image | Should -BeNullOrEmpty
    }

    It 'exposes Content even when it was not supplied' {
        # The twelfth service (DESIGN 6). Defined even when null, because engine
        # code runs under Set-StrictMode -Version Latest and ApplyImage asks
        # whether the catalog carries one before it uses it.
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        @($catalog.PSObject.Properties.Name) | Should -Contain 'Content'
        $catalog.Content | Should -BeNullOrEmpty
    }

    It 'returns the content provider GetRequired was asked for' {
        $content = New-HDTFakeContentProvider -Root 'Z:\Deploy'
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Content $content

        [object]::ReferenceEquals($catalog.GetRequired('Content', 'ApplyImage'), $content) | Should -BeTrue
    }

    It 'names the step in the error when the Content service is missing' {
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        { $catalog.GetRequired('Content', 'ApplyImage') } | Should -Throw -ExpectedMessage '*Content*'
        { $catalog.GetRequired('Content', 'ApplyImage') } | Should -Throw -ExpectedMessage '*ApplyImage*'
    }

    It 'returns the disk service GetRequired was asked for' {
        $disk = New-HDTFakeDiskService
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Disk $disk

        [object]::ReferenceEquals($catalog.GetRequired('Disk', 'DiskPartition'), $disk) | Should -BeTrue
    }

    It 'returns the image service GetRequired was asked for' {
        $image = New-HDTFakeImageService
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Image $image

        [object]::ReferenceEquals($catalog.GetRequired('Image', 'ApplyImage'), $image) | Should -BeTrue
    }

    It 'names the step in the error when the Disk service is missing' {
        # The sentence an administrator reads when a run was started without the
        # one service the step it is running needs.
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        { $catalog.GetRequired('Disk', 'DiskPartition') } | Should -Throw -ExpectedMessage '*Disk*'
        { $catalog.GetRequired('Disk', 'DiskPartition') } | Should -Throw -ExpectedMessage '*DiskPartition*'
    }

    It 'still requires only a filesystem and a clock' {
        # A NoOp sequence must run on two services and no more, however many the
        # catalog grows to carry.
        { New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock } | Should -Not -Throw
    }

    # THESE ASSERT THE ATTRIBUTE, NOT THE BINDER'S REACTION TO IT, and the
    # difference is not academic. Calling the command with the parameter left
    # off asks PowerShell what it does about a missing mandatory parameter, and
    # the answer depends on the HOST: a non-interactive one throws
    # MissingMandatoryParameter, an interactive one STOPS AND PROMPTS -
    # "Supply values for the following parameters: Clock:". So the suite passed
    # in CI and hung on a prompt for anyone who ran Invoke-Pester at their own
    # console, which is where the fact was noticed.
    #
    # The fact worth asserting was never the binder's behaviour anyway. It is
    # that a catalog cannot be built without these two - PROJECT constraint 4 -
    # and that is on the parameter, where it can be read without calling
    # anything.
    It 'requires a <Parameter>' -ForEach @(
        @{ Parameter = 'FileSystem' }
        @{ Parameter = 'Clock' }
    ) {
        $declared = (Get-Command -Name 'New-HDTServiceCatalog').Parameters[$Parameter]

        $declared | Should -Not -BeNullOrEmpty

        $mandatory = @($declared.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory })

        $mandatory | Should -Contain $true
    }

    It 'returns the service GetRequired was asked for' {
        # A stand-in object rather than a fake: the catalog is deliberately
        # service-agnostic - it holds what it is given and never calls it.
        $process = [pscustomobject] @{ ServiceName = 'ProcessService' }
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock -Process $process

        $catalog.GetRequired('Process') | Should -Be $process
    }

    It 'throws naming the service when GetRequired finds nothing' {
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        { $catalog.GetRequired('Process') } | Should -Throw -ExpectedMessage '*Process*'
    }

    It 'names the caller in the GetRequired error' {
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        { $catalog.GetRequired('Process', 'CommandLine') } | Should -Throw -ExpectedMessage '*CommandLine*'
    }

    It 'throws for a service name the catalog does not carry' {
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        { $catalog.GetRequired('Teleporter') } | Should -Throw -ExpectedMessage '*Teleporter*'
    }

    It 'holds the same object it was given' {
        # Reference equality, so a test can assert on the very fake it passed in
        # rather than on a copy that records nothing.
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        [object]::ReferenceEquals($catalog.FileSystem, $script:fileSystem) | Should -BeTrue
        [object]::ReferenceEquals($catalog.Clock, $script:clock) | Should -BeTrue
    }

    It 'holds every optional service it was given' {
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock `
            -Registry (New-HDTFakeRegistryService) `
            -ScriptInvoker (New-HDTFakeScriptInvoker) `
            -Cim (New-HDTFakeCimProvider) `
            -Environment (New-HDTFakeEnvironmentProvider) `
            -Process ([pscustomobject] @{ ServiceName = 'ProcessService' }) `
            -Power ([pscustomobject] @{ ServiceName = 'PowerService' })

        foreach ($service in @('Registry', 'ScriptInvoker', 'Cim', 'Environment', 'Process', 'Power')) {
            $catalog.GetRequired($service) | Should -Not -BeNullOrEmpty
        }
    }

    It 'performs no I/O when it is built' {
        $catalog = New-HDTServiceCatalog -FileSystem $script:fileSystem -Clock $script:clock

        $catalog | Should -Not -BeNullOrEmpty
        @($script:fileSystem.Operations).Count | Should -Be 0
        @($script:clock.Operations).Count | Should -Be 0
    }

    It 'has comment-based help with a synopsis' {
        $help = Get-Help -Name New-HDTServiceCatalog -ErrorAction Stop

        $help.Name | Should -BeExactly 'New-HDTServiceCatalog'
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }
}
