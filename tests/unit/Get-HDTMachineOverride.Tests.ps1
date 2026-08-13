# Get-HDTMachineOverride reads DESIGN 3.1 source 2: Control\machines\<UUID>.yaml,
# "the MDT-database equivalent, but file-based".
#
# Two behaviours carry the weight:
#
#   * NO FILE IS THE NORMAL CASE. Most machines have no override, so an absent
#     file returns $null rather than throwing. A malformed one, however, is a
#     configuration error naming the file - an override that silently does
#     nothing is exactly the MDT-database debugging problem HDT exists to end.
#   * IT READS THROUGH THE INJECTED IFileSystem. No Get-Content anywhere, so the
#     whole path is provable with no share and no disk (PROJECT constraint 4).

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:workspaceRoot = 'C:\HDTLab\does-not-exist\ws'
    $script:uuid = '4C4C4544-0031-3610-8052-B7C04F515A31'
    $script:overridePath = 'C:\HDTLab\does-not-exist\ws\Control\machines\4C4C4544-0031-3610-8052-B7C04F515A31.yaml'

    $script:validYaml = @'
schemaVersion: 1
variables:
  HDTComputerName: FIN-0007
  HDTTaskSequenceID: OVR-CLIENT
'@
}

Describe 'Get-HDTMachineOverride' {

    BeforeEach {
        $script:fileSystem = New-HDTFakeFileSystem -File @{ $script:overridePath = $script:validYaml }
    }

    It 'returns null when no override file exists' {
        $empty = New-HDTFakeFileSystem

        Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $empty |
            Should -BeNullOrEmpty
    }

    It 'does not throw when no override file exists' {
        $empty = New-HDTFakeFileSystem

        { Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $empty } |
            Should -Not -Throw
    }

    It 'returns null for an empty uuid without touching the filesystem' {
        $result = Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid '' -FileSystem $script:fileSystem

        $result | Should -BeNullOrEmpty
        $script:fileSystem.Operations.Count | Should -Be 0
    }

    It 'builds the path from the workspace root, Control, machines and the uuid' {
        $result = Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $script:fileSystem

        $result.Path | Should -BeExactly $script:overridePath
        $script:fileSystem.Operations[0].Arguments[0] | Should -BeExactly $script:overridePath
    }

    It 'reads the file through the injected filesystem' {
        $null = Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $script:fileSystem

        $script:fileSystem.GetOperationName() | Should -Contain 'ReadAllText'
        Test-Path -LiteralPath $script:overridePath | Should -BeFalse
    }

    It 'returns the variables as an ordered dictionary' {
        $result = Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $script:fileSystem

        $result.Variable | Should -BeOfType ([System.Collections.Specialized.OrderedDictionary])
        @($result.Variable.Keys) | Should -Be @('HDTComputerName', 'HDTTaskSequenceID')
        $result.Variable['HDTComputerName'] | Should -BeExactly 'FIN-0007'
    }

    It 'looks a variable up case-insensitively' {
        $result = Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $script:fileSystem

        $result.Variable['hdtcomputername'] | Should -BeExactly 'FIN-0007'
    }

    It 'returns the path it read' {
        $result = Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $script:fileSystem

        # Provenance names this file as the source of the value, so it has to
        # come back with the variables rather than be reconstructed by a caller.
        $result.Path | Should -BeExactly $script:overridePath
    }

    It 'throws a configuration error naming the file for malformed yaml' {
        $fs = New-HDTFakeFileSystem -File @{ $script:overridePath = "schemaVersion: 1`nvariables:`n  HDTComputerName: FIN-0007`n   HDTBad: x`n" }

        $record = $null
        try { Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $fs } catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        $record.Exception.Message | Should -BeLike '*4C4C4544-0031-3610-8052-B7C04F515A31.yaml*'
    }

    It 'throws for a missing schemaVersion' {
        $fs = New-HDTFakeFileSystem -File @{ $script:overridePath = "variables:`n  HDTComputerName: FIN-0007`n" }

        { Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $fs } |
            Should -Throw -ExpectedMessage '*schemaVersion*'
    }

    It 'throws for a schemaVersion newer than supported' {
        $fs = New-HDTFakeFileSystem -File @{ $script:overridePath = "schemaVersion: 99`nvariables:`n  HDTComputerName: FIN-0007`n" }

        { Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $fs } |
            Should -Throw -ExpectedMessage '*99*'
    }

    It 'throws for a missing variables key' {
        $fs = New-HDTFakeFileSystem -File @{ $script:overridePath = "schemaVersion: 1`n" }

        { Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $fs } |
            Should -Throw -ExpectedMessage '*variables*'
    }

    It 'throws for an empty variables mapping' {
        $fs = New-HDTFakeFileSystem -File @{ $script:overridePath = "schemaVersion: 1`nvariables: {}`n" }

        { Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $fs } |
            Should -Throw -ExpectedMessage '*variables*'
    }

    It 'throws for a variable name that does not start with HDT' {
        $fs = New-HDTFakeFileSystem -File @{ $script:overridePath = "schemaVersion: 1`nvariables:`n  ComputerName: FIN-0007`n" }

        { Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $fs } |
            Should -Throw -ExpectedMessage '*ComputerName*'
    }

    It 'throws for an engine variable' {
        $fs = New-HDTFakeFileSystem -File @{ $script:overridePath = "schemaVersion: 1`nvariables:`n  _HDTLogPath: X:\HDT\Logs`n" }

        { Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot -Uuid $script:uuid -FileSystem $fs } |
            Should -Throw -ExpectedMessage '*_HDTLogPath*'
    }

    It 'matches the uuid case-insensitively' {
        # Win32_ComputerSystemProduct reports the UUID upper case and a
        # hand-created override file may be named either way; Windows does not
        # care and neither does this.
        $result = Get-HDTMachineOverride -WorkspaceRoot $script:workspaceRoot `
            -Uuid $script:uuid.ToLowerInvariant() -FileSystem $script:fileSystem

        $result.Variable['HDTComputerName'] | Should -BeExactly 'FIN-0007'
    }

    It 'has comment-based help with a synopsis' {
        # Get-Command first: Get-Help alone answers with a stub for a command
        # that does not exist.
        $command = Get-Command -Name Get-HDTMachineOverride -Module Hephaestus -ErrorAction Stop
        $help = Get-Help -Name $command.Name -ErrorAction Stop

        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match 'Get-HDTMachineOverride \['
    }
}
