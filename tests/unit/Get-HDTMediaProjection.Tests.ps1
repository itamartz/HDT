#requires -Version 5.1

# Get-HDTMediaProjection against a fake filesystem: no ISO, no ADK, no disk.
#
# THE CORRECTNESS HEART OF MEDIA GENERATION, AND IT IS PURE. DESIGN 6.2 says
# media generation is "a content projection plus a provider swap", and this is
# the projection half stated as a list of rows: one per thing that travels and
# one per thing refused. Nothing is copied here and nothing is created, which is
# what makes projection completeness - the thing a wrong disc costs an hour of
# rebuild to discover - provable in milliseconds.
#
# THE HEADLINE ASSERTIONS ARE THE TWO EXACT ORDERED LISTS, in
# tests/unit/Update-HDTBootImage.Tests.ps1's image (DESIGN 12.2.1: a ceremony is
# asserted by its exact ordered operation list). Every other assertion in this
# file is cheap because those two are here.
#
# THE FOUR REFUSALS EACH HAVE A TEST THAT NAMES THE ARTIFACT AND THE REASON,
# because each of them cost a rebuild on 2026-09-03 - see ROADMAP M7's
# "Exit - media" block.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # A DRIVE THIS SESSION HAS NOT MOUNTED, deliberately and for every test in
    # the file. Get-HDTWorkspacePath's header records why: Join-Path resolves the
    # drive qualifier and throws DriveNotFound for a path like this, so a root
    # that cannot be mounted is the only way to prove no line reached for one.
    $script:root = 'X:\Share'

    $script:profileYaml = @(
        'schemaVersion: 1'
        'profiles:'
        '  - id: two-vendor'
        '    name: Two vendor folders'
        '    include:'
        '      - Drivers\WinPE\Dell WinPE 11 x64'
        '      - Applications\TightVNC'
        '  - id: reversed'
        '    name: The same two, declared the other way round'
        '    include:'
        '      - Applications\TightVNC'
        '      - Drivers\WinPE\Dell WinPE 11 x64'
        '  - id: missing-folder'
        '    name: Names a folder the share has not got'
        '    include:'
        '      - Drivers\WinPE\Lenovo WinPE 11 x64'
        '  - id: empty'
        '    name: Includes nothing at all'
        '    include: []'
    ) -join "`r`n"

    # A DOCUMENT NO SHARE MAY CARRY, kept apart from the one above on purpose:
    # Get-HDTSelectionProfile validates on read, so a single illegal include
    # refuses the WHOLE document and would take every other test in this file
    # with it.
    $script:triesBootYaml = @(
        'schemaVersion: 1'
        'profiles:'
        '  - id: tries-boot'
        '    name: Tries to include the build output'
        '    include:'
        '      - Boot'
        '      - Applications\TightVNC'
    ) -join "`r`n"

    $script:workspaceYaml = @(
        'schemaVersion: 1'
        'id: HDT-LAB'
        'name: HDT lab deployment share'
        'deployRoot: \\server\HDTShare'
        'logLevel: Info'
    ) -join "`r`n"

    # THE SHARE EVERY TEST IN THIS FILE PROJECTS: every content folder, an
    # authored selection profile document, three applications with a dependency
    # chain, and all four of the artifacts a disc must refuse.
    function New-HDTTestMediaShare {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory hashtable of seed data; it changes no state.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [Parameter()]
            [AllowNull()]
            [hashtable] $ExtraFile,

            [Parameter()]
            [AllowNull()]
            [string[]] $Without
        )

        $seed = @{
            ($script:root + '\workspace.yaml')                            = $script:workspaceYaml
            ($script:root + '\rules.yaml')                                = 'schemaVersion: 1'
            ($script:root + '\bootstrap-rules.yaml')                      = 'schemaVersion: 1'
            ($script:root + '\Control\selection-profiles.yaml')           = $script:profileYaml
            ($script:root + '\Control\share-credential.json')             = '{ "username": "CONTOSO\\svc-hdt-deploy" }'
            ($script:root + '\Control\machines\PC-1234.yaml')             = 'schemaVersion: 1'
            ($script:root + '\Applications\TightVNC\app.yaml')            = 'schemaVersion: 1'
            ($script:root + '\Applications\Acrobat\app.yaml')             = 'schemaVersion: 1'
            ($script:root + '\Applications\Chrome\app.yaml')              = 'schemaVersion: 1'
            ($script:root + '\OperatingSystems\Win11\os.yaml')            = 'schemaVersion: 1'
            ($script:root + '\Drivers\WinPE\Dell WinPE 11 x64\oem0.inf')  = '[Version]'
            ($script:root + '\Drivers\Models\HP EliteBook\oem1.inf')      = '[Version]'
            ($script:root + '\TaskSequences\PNP-TEST\sequence.yaml')      = 'schemaVersion: 1'
            ($script:root + '\Scripts\UI\HDTWizard.xaml')                 = '<Window />'
            ($script:root + '\Boot\HDTPE_x64.wim')                        = 'a boot image'
            ($script:root + '\Logs\PC-9876\HDT.log')                      = 'another machine''s log'
            ($script:root + '\Captures\PC-9876.wim')                      = 'another machine''s image'
        }

        foreach ($leaf in @($Without)) {
            [void] $seed.Remove($script:root + '\' + $leaf)
        }

        if ($null -ne $ExtraFile) {
            foreach ($key in @($ExtraFile.Keys)) { $seed[[string] $key] = $ExtraFile[$key] }
        }

        return $seed
    }

    function New-HDTTestMediaFileSystem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory test double; it changes no state.')]
        [CmdletBinding()]
        param(
            [Parameter()]
            [AllowNull()]
            [hashtable] $ExtraFile,

            [Parameter()]
            [AllowNull()]
            [string[]] $Without,

            [Parameter()]
            [AllowNull()]
            [object] $Journal
        )

        $splat = @{ File = (New-HDTTestMediaShare -ExtraFile $ExtraFile -Without $Without) }
        if ($null -ne $Journal) { $splat['Journal'] = $Journal }

        return (New-HDTFakeFileSystem @splat)
    }

    # IT IS PRIVATE, so every call runs inside InModuleScope. Wrapped once
    # rather than at nineteen call sites, so the file reads as assertions about
    # a projection rather than as assertions about Pester.
    function Get-HDTMediaTestProjection {
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory = $true)]
            [string] $WorkspaceRoot,

            [Parameter(Mandatory = $true)]
            [string] $SelectionProfile,

            [Parameter(Mandatory = $true)]
            [object] $FileSystem
        )

        return [pscustomobject[]] @(InModuleScope Hephaestus -Parameters @{
                Root = $WorkspaceRoot; ProfileId = $SelectionProfile; Fs = $FileSystem
            } {
                param($Root, $ProfileId, $Fs)

                Get-HDTMediaProjection -WorkspaceRoot $Root -SelectionProfile $ProfileId -FileSystem $Fs
            })
    }

    # The projection as a list a person can read, which is also the shape the
    # two headline assertions compare element by element.
    function ConvertTo-HDTTestMediaRowName {
        [CmdletBinding()]
        [OutputType([string[]])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]] $Row
        )

        return [string[]] @($Row | ForEach-Object { '{0}:{1}' -f [string] $_.Kind, [string] $_.Source })
    }
}

Describe 'Get-HDTMediaProjection' {

    Context 'the documents that travel whatever the profile says' {

        BeforeAll {
            $script:everything = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root `
                    -SelectionProfile 'everything' -FileSystem (New-HDTTestMediaFileSystem))
        }

        It 'projects rules.yaml, because it is the content marker Resolve-HDTDeployRoot hunts for' {
            $row = @($script:everything | Where-Object { $_.Source -eq 'rules.yaml' })

            @($row).Count | Should -Be 1
            $row[0].Kind | Should -BeExactly 'Marker'
            $row[0].Present | Should -BeTrue
        }

        It 'projects rules.yaml even for a profile that includes nothing at all' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'empty' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Source -eq 'rules.yaml' })

            @($row).Count | Should -Be 1
            $row[0].Kind | Should -BeExactly 'Marker'
        }

        It 'projects workspace.yaml, and marks it Rewritten' {
            $row = @($script:everything | Where-Object { $_.Source -eq 'workspace.yaml' })

            @($row).Count | Should -Be 1
            $row[0].Kind | Should -BeExactly 'Document'
            $row[0].Rewritten | Should -BeTrue
        }

        It 'marks nothing else Rewritten, because workspace.yaml is the one file media edits' {
            @($script:everything | Where-Object { $_.Rewritten -and $_.Source -ne 'workspace.yaml' }) |
                Should -BeNullOrEmpty
        }

        It 'projects Control, which carries selection-profiles.yaml and Control machines' {
            $row = @($script:everything | Where-Object { $_.Kind -eq 'Control' })

            @($row).Count | Should -Be 1
            $row[0].Source | Should -BeExactly 'Control'
            $row[0].Present | Should -BeTrue
        }

        It 'projects the three of them before any content, so the log reads in build order' {
            $name = ConvertTo-HDTTestMediaRowName -Row $script:everything
            $firstContent = [array]::IndexOf($name, ($name | Where-Object { $_ -like 'Content:*' } | Select-Object -First 1))

            foreach ($kind in @('Marker:rules.yaml', 'Document:workspace.yaml', 'Control:Control')) {
                $at = [array]::IndexOf($name, $kind)

                $at | Should -BeGreaterThan -1
                $at | Should -BeLessThan $firstContent
            }
        }

        It 'names the marker as the reason rules.yaml is there, not that it is a document' {
            $row = @($script:everything | Where-Object { $_.Source -eq 'rules.yaml' })[0]

            $row.Reason | Should -Match 'marker'
            $row.Reason | Should -Match 'Resolve-HDTDeployRoot|found'
        }

        It 'sends each of them to a destination under \Share' {
            foreach ($row in @($script:everything | Where-Object { $_.Kind -in @('Marker', 'Document', 'Control') })) {
                $row.Destination | Should -BeLike '\Share\*'
            }
        }
    }

    Context 'what the profile governs' {

        It 'projects exactly the folders the profile names, in the order it names them' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'two-vendor' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -eq 'Content' })

            @($row | ForEach-Object { $_.Source }) |
                Should -Be @('Drivers\WinPE\Dell WinPE 11 x64', 'Applications\TightVNC')
        }

        It 'projects the everything built-in as the five content folders and nothing else' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'everything' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -eq 'Content' })

            @($row | ForEach-Object { $_.Source }) |
                Should -Be @('Applications', 'OperatingSystems', 'Drivers', 'TaskSequences', 'Scripts')
        }

        It 'projects the all-drivers built-in as Drivers alone' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'all-drivers' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -eq 'Content' })

            @($row | ForEach-Object { $_.Source }) | Should -Be @('Drivers')
        }

        It 'projects an authored profile naming two vendor folders as those two folders' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'two-vendor' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -eq 'Content' })

            @($row).Count | Should -Be 2
        }

        It 'projects nothing extra for a profile that includes nothing' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'empty' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -eq 'Content' })

            @($row) | Should -BeNullOrEmpty
        }

        It 'keeps the declared order rather than sorting it' {
            # Driver injection order is the author's, and the same two folders
            # declared the other way round must come back the other way round.
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'reversed' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -eq 'Content' })

            @($row | ForEach-Object { $_.Source }) |
                Should -Be @('Applications\TightVNC', 'Drivers\WinPE\Dell WinPE 11 x64')
        }

        It 'sends a content folder to the same relative place under \Share' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'two-vendor' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -eq 'Content' })

            $row[0].Destination | Should -BeExactly '\Share\Drivers\WinPE\Dell WinPE 11 x64'
        }
    }

    Context 'a folder that is not there' {

        BeforeAll {
            $script:missing = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root `
                    -SelectionProfile 'missing-folder' -FileSystem (New-HDTTestMediaFileSystem))
        }

        It 'returns a row with Present false for a folder the profile names and the share has not got' {
            $row = @($script:missing | Where-Object { $_.Kind -eq 'Content' })

            @($row).Count | Should -Be 1
            $row[0].Present | Should -BeFalse
        }

        It 'does not drop it silently, which is how a disc ships without one vendor drivers' {
            @($script:missing | Where-Object { $_.Kind -eq 'Content' }) | Should -Not -BeNullOrEmpty
        }

        It 'names the folder in the row, so the warning can name it' {
            $row = @($script:missing | Where-Object { $_.Kind -eq 'Content' })[0]

            $row.Source | Should -BeExactly 'Drivers\WinPE\Lenovo WinPE 11 x64'
        }
    }

    Context 'the four refusals a real disc taught us' {

        BeforeAll {
            $script:refusal = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root `
                    -SelectionProfile 'everything' -FileSystem (New-HDTTestMediaFileSystem) |
                    Where-Object { $_.Kind -eq 'Excluded' })
        }

        It 'refuses bootstrap-rules.yaml, because it is injected into the boot image and its rules choose a share by gateway' {
            $row = @($script:refusal | Where-Object { $_.Source -eq 'bootstrap-rules.yaml' })

            @($row).Count | Should -Be 1
            $row[0].Reason | Should -Match 'boot image'
            $row[0].Destination | Should -BeNullOrEmpty
        }

        It 'refuses Control share-credential.json, because a Local image authenticates to nothing' {
            $row = @($script:refusal | Where-Object { $_.Source -eq 'Control\share-credential.json' })

            @($row).Count | Should -Be 1
            $row[0].Reason | Should -Match 'credential|authenticat'
        }

        It 'refuses Boot, because the boot wim belongs at sources boot.wim and a second copy doubles it' {
            $row = @($script:refusal | Where-Object { $_.Source -eq 'Boot' })

            @($row).Count | Should -Be 1
            $row[0].Reason | Should -Match 'boot.wim'
        }

        It 'refuses Logs and Captures, which hold other machines logs and images' {
            @($script:refusal | Where-Object { $_.Source -eq 'Logs' }).Count | Should -Be 1
            @($script:refusal | Where-Object { $_.Source -eq 'Captures' }).Count | Should -Be 1
        }

        It 'gives every refusal a reason a person can read, not a category name' {
            foreach ($row in @($script:refusal)) {
                [string]::IsNullOrWhiteSpace($row.Reason) | Should -BeFalse
                ([string] $row.Reason).Split(' ').Count | Should -BeGreaterThan 5
            }
        }

        # A PROFILE CANNOT NAME ONE OF THESE, AND THE REFUSAL IS UPSTREAM.
        # Assert-HDTSelectionProfileDocument allows only
        # Get-HDTSelectionProfileContentFolder's five as a first segment, and
        # Get-HDTSelectionProfile validates on READ - so a share carrying such a
        # profile is refused by name before any projection happens. That is why
        # Get-HDTMediaProjection does NOT repeat the check: a second filter for a
        # case that cannot arrive would be a branch no test could reach.
        It 'never has to overrule a profile, because a profile naming Boot is refused by name on read' {
            $fs = New-HDTTestMediaFileSystem -ExtraFile @{
                ($script:root + '\Control\selection-profiles.yaml') = $script:triesBootYaml
            }

            { Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'tries-boot' `
                    -FileSystem $fs } | Should -Throw -ExpectedMessage '*Boot*not a folder a profile may include from*'
        }

        It 'refuses Boot whatever the profile is, so the row is there for the built-ins too' {
            foreach ($id in @('everything', 'all-drivers', 'empty')) {
                $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile $id `
                        -FileSystem (New-HDTTestMediaFileSystem))

                @($row | Where-Object { $_.Kind -eq 'Content' -and $_.Source -eq 'Boot' }) | Should -BeNullOrEmpty
                @($row | Where-Object { $_.Kind -eq 'Excluded' -and $_.Source -eq 'Boot' }).Count | Should -Be 1
            }
        }

        It 'records a refusal for an artifact the share has not got, so the log says it was considered' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'everything' `
                    -FileSystem (New-HDTTestMediaFileSystem -Without @('bootstrap-rules.yaml')) |
                    Where-Object { $_.Kind -eq 'Excluded' -and $_.Source -eq 'bootstrap-rules.yaml' })

            @($row).Count | Should -Be 1
            $row[0].Present | Should -BeFalse
        }
    }

    Context 'the exact ordered list' {

        # DESIGN 12.2.1's benchmark shape applied to the projection. Read a
        # failure against DESIGN 6.2: it is a list a human can check.
        It 'produces exactly this list of rows for the everything profile on a full share' {
            $name = ConvertTo-HDTTestMediaRowName -Row @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root `
                    -SelectionProfile 'everything' -FileSystem (New-HDTTestMediaFileSystem))

            $name | Should -Be @(
                'Marker:rules.yaml'
                'Document:workspace.yaml'
                'Control:Control'
                'Excluded:Control\share-credential.json'
                'Content:Applications'
                'Content:OperatingSystems'
                'Content:Drivers'
                'Content:TaskSequences'
                'Content:Scripts'
                'Excluded:bootstrap-rules.yaml'
                'Excluded:Boot'
                'Excluded:Logs'
                'Excluded:Captures'
            ) -Because ('the projection produced:' + [System.Environment]::NewLine +
                (($name | ForEach-Object { '  ' + $_ }) -join [System.Environment]::NewLine))
        }

        It 'produces exactly this list of rows for an authored profile naming two folders' {
            $name = ConvertTo-HDTTestMediaRowName -Row @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root `
                    -SelectionProfile 'two-vendor' -FileSystem (New-HDTTestMediaFileSystem))

            $name | Should -Be @(
                'Marker:rules.yaml'
                'Document:workspace.yaml'
                'Control:Control'
                'Excluded:Control\share-credential.json'
                'Content:Drivers\WinPE\Dell WinPE 11 x64'
                'Content:Applications\TightVNC'
                'Excluded:bootstrap-rules.yaml'
                'Excluded:Boot'
                'Excluded:Logs'
                'Excluded:Captures'
            ) -Because ('the projection produced:' + [System.Environment]::NewLine +
                (($name | ForEach-Object { '  ' + $_ }) -join [System.Environment]::NewLine))
        }
    }

    Context 'it computes and does not copy' {

        BeforeAll {
            $script:pureJournal = [System.Collections.ArrayList]::new()

            [void] @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'everything' `
                    -FileSystem (New-HDTTestMediaFileSystem -Journal $script:pureJournal))
        }

        It 'creates no directory' {
            @($script:pureJournal | Where-Object { $_.Operation -eq 'CreateDirectory' }) | Should -BeNullOrEmpty
        }

        It 'copies no file' {
            @($script:pureJournal | Where-Object { $_.Operation -in @('CopyItem', 'MoveItem') }) |
                Should -BeNullOrEmpty
        }

        It 'writes nothing at all - the fake journal is empty of writes' {
            # THE ASSERTION THAT KEEPS THIS FUNCTION PURE, and therefore keeps
            # projection completeness provable without a disk.
            @($script:pureJournal | Where-Object {
                    $_.Operation -in @('WriteAllText', 'AppendAllText', 'RemoveItem',
                        'CreateDirectory', 'CopyItem', 'MoveItem', 'TakeOwnership', 'GrantAccess')
                }) | Should -BeNullOrEmpty
        }
    }

    Context 'paths' {

        It 'answers for a share on a drive this session has not mounted' {
            # X: is not mounted here and every other test in this file already
            # depends on that; this one says so out loud, because the day a
            # Join-Path creeps in it is the assertion that names the cause.
            (Test-Path -LiteralPath 'X:\') | Should -BeFalse

            { Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'everything' `
                    -FileSystem (New-HDTTestMediaFileSystem) } | Should -Not -Throw
        }

        It 'destinations are relative to \Share, so nothing carries the building machine letter' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'everything' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -ne 'Excluded' })

            foreach ($current in $row) {
                $current.Destination | Should -BeLike '\Share\*'
                $current.Destination | Should -Not -BeLike 'X:*'
            }
        }

        It 'carries the full source path so the caller need not rebuild it' {
            $row = @(Get-HDTMediaTestProjection -WorkspaceRoot $script:root -SelectionProfile 'two-vendor' `
                    -FileSystem (New-HDTTestMediaFileSystem) | Where-Object { $_.Kind -eq 'Content' })

            $row[0].FullPath | Should -BeExactly ($script:root + '\Drivers\WinPE\Dell WinPE 11 x64')
        }
    }
}
