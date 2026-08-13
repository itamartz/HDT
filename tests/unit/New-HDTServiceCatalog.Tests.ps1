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
        $script:clock = New-HDTFakeClock
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

    It 'requires a filesystem' {
        $record = $null
        try { New-HDTServiceCatalog -Clock $script:clock } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike '*ParameterBindingException*'
    }

    It 'requires a clock' {
        $record = $null
        try { New-HDTServiceCatalog -FileSystem $script:fileSystem } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike '*ParameterBindingException*'
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
