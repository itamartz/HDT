# Get-HDTMedia reads Media\<id>\media.yaml the way Get-HDTApplication reads
# Applications\<id>\app.yaml: the catalog IS the directory, one document per
# item, validated before it is projected.
#
# THE MOUNTED-DRIVE TEST IS THE ONE THAT MATTERS MOST HERE. Every path in this
# file is under X:\, a drive this session has not got. Join-Path resolves the
# drive qualifier and throws DriveNotFound for one, so a line written with it
# cannot be tested at all - which is exactly the trap Get-HDTWorkspacePath's own
# header records.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:root = 'X:\Share'

    $script:mediaYaml = {
        param(
            [string] $Id = 'M1',
            [string] $Output = '',
            [string] $Extra = ''
        )

        $iso = $Output
        if ([string]::IsNullOrEmpty($iso)) {
            $iso = 'Media\{0}\HDT_{1}.iso' -f $Id, $Id
        }

        $line = @(
            '# HDT standalone media definition.'
            '# Update-HDTMediaContent builds the ISO this names.'
            'schemaVersion: 1'
            ('id: {0}' -f $Id)
            ('name: Media {0}' -f $Id)
            'selectionProfile: everything'
            ('output: {0}' -f $iso)
            'enabled: true'
        )

        if (-not [string]::IsNullOrEmpty($Extra)) { $line += $Extra }

        return (@($line) -join "`r`n")
    }

    # The manifest plan 02 writes beside the ISO. Shaped like
    # Boot\<name>.manifest.json - an artifacts.iso block with path, sizeBytes
    # and sha256 - so one reader shape serves both.
    $script:manifestJson = @'
{
  "schemaVersion": 1,
  "mediaId": "M1",
  "builtUtc": "2026-09-01T07:13:00Z",
  "artifacts": {
    "iso": {
      "path": "X:\\Share\\Media\\M1\\HDT_M1.iso",
      "sizeBytes": 6442450944,
      "sha256": "8E1C0A2B3D4E5F60718293A4B5C6D7E8F90112233445566778899AABBCCDDEEFF"
    }
  }
}
'@
}

Describe 'Get-HDTMedia' {

    Context 'reading' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTMedia' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }

        It 'lists every media definition on the share, in folder order' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1')
                'X:\Share\Media\M2\media.yaml' = (& $script:mediaYaml -Id 'M2')
            }

            $media = @(Get-HDTMedia -WorkspaceRoot $script:root -FileSystem $fs)

            @($media).Count | Should -Be 2
            @($media | ForEach-Object { $_.Id }) | Should -Be @('M1', 'M2')
        }

        It 'returns nothing for a share with a Media folder and nothing in it' {
            $fs = New-HDTFakeFileSystem -Directory @('X:\Share\Media')

            @(Get-HDTMedia -WorkspaceRoot $script:root -FileSystem $fs) | Should -BeNullOrEmpty
        }

        It 'returns nothing for a share with no Media folder at all' {
            $fs = New-HDTFakeFileSystem -Directory @('X:\Share')

            @(Get-HDTMedia -WorkspaceRoot $script:root -FileSystem $fs) | Should -BeNullOrEmpty
        }

        It 'skips a folder under Media that holds no media.yaml, rather than failing the listing' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1')
                'X:\Share\Media\scratch\notes.txt' = 'somebody staged something here'
            }

            $media = @(Get-HDTMedia -WorkspaceRoot $script:root -FileSystem $fs)

            @($media).Count | Should -Be 1
            $media[0].Id | Should -BeExactly 'M1'
        }

        It 'reads one by id' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1')
                'X:\Share\Media\M2\media.yaml' = (& $script:mediaYaml -Id 'M2')
            }

            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M2' -FileSystem $fs

            $media.Id | Should -BeExactly 'M2'
            $media.Name | Should -BeExactly 'Media M2'
        }

        It 'refuses an id the share does not have, naming what a media definition is' {
            $fs = New-HDTFakeFileSystem -Directory @('X:\Share\Media')

            { Get-HDTMedia -WorkspaceRoot $script:root -Id 'M9' -FileSystem $fs } |
                Should -Throw -ExpectedMessage '*media.yaml*'
        }

        It 'validates every document it reads, so a broken one is reported and not projected' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1' -Extra 'mediaPath: D:\somewhere')
            }

            { Get-HDTMedia -WorkspaceRoot $script:root -FileSystem $fs } |
                Should -Throw -ExpectedMessage "*'mediaPath'*"
        }

        It 'reports a document whose id disagrees with its folder' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'SOMETHING-ELSE')
            }

            { Get-HDTMedia -WorkspaceRoot $script:root -FileSystem $fs } |
                Should -Throw -ExpectedMessage '*M1*'
        }

        It 'carries WorkspaceRoot on every object, so a pipeline into Set- and Remove- binds' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1')
                'X:\Share\Media\M2\media.yaml' = (& $script:mediaYaml -Id 'M2')
            }

            foreach ($item in @(Get-HDTMedia -WorkspaceRoot $script:root -FileSystem $fs)) {
                $item.WorkspaceRoot | Should -BeExactly $script:root
            }
        }

        It 'reports the folder and the document it read' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1')
            }

            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $fs

            $media.Folder | Should -BeExactly 'X:\Share\Media\M1'
            $media.DocumentPath | Should -BeExactly 'X:\Share\Media\M1\media.yaml'
        }
    }

    Context 'the output path' {

        It 'resolves a relative output against the workspace root' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1')
            }

            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $fs

            $media.Output | Should -BeExactly 'Media\M1\HDT_M1.iso'
            $media.OutputPath | Should -BeExactly 'X:\Share\Media\M1\HDT_M1.iso'
        }

        It 'leaves a rooted output alone' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1' -Output 'D:\Builds\field.iso')
            }

            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $fs

            $media.OutputPath | Should -BeExactly 'D:\Builds\field.iso'
        }

        It 'leaves a UNC output alone' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1' -Output '\\fileserver\builds\field.iso')
            }

            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $fs

            $media.OutputPath | Should -BeExactly '\\fileserver\builds\field.iso'
        }

        It 'uses [IO.Path]::Combine, so it answers for a share on a drive this session has not mounted' {
            # X: does not exist here. Join-Path throws DriveNotFound for it, so a
            # line written with Join-Path cannot answer at all - which is the
            # whole reason this file's paths are X:\ and not the scratch dir.
            Test-Path -LiteralPath 'X:\' | Should -BeFalse -Because 'the trap is only closed while X: is absent'

            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1')
            }

            { Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $fs } | Should -Not -Throw
        }
    }

    Context 'the last build' {

        It 'reports LastBuildUtc empty when no manifest is beside the media' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml' = (& $script:mediaYaml -Id 'M1')
            }

            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $fs

            $media.LastBuildUtc | Should -BeNullOrEmpty
            $media.IsoPath | Should -BeNullOrEmpty
            $media.IsoSizeBytes | Should -Be 0
            $media.IsoSha256 | Should -BeNullOrEmpty
        }

        It 'reads LastBuildUtc, IsoPath, IsoSizeBytes and IsoSha256 from media.manifest.json when there is one' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml'          = (& $script:mediaYaml -Id 'M1')
                'X:\Share\Media\M1\media.manifest.json' = $script:manifestJson
            }

            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $fs

            $media.LastBuildUtc | Should -Not -BeNullOrEmpty
            $media.LastBuildUtc.Kind | Should -Be ([System.DateTimeKind]::Utc)
            $media.LastBuildUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -BeExactly '2026-09-01T07:13:00Z'
            $media.IsoPath | Should -BeExactly 'X:\Share\Media\M1\HDT_M1.iso'
            $media.IsoSizeBytes | Should -Be 6442450944
            $media.IsoSha256 | Should -BeExactly '8E1C0A2B3D4E5F60718293A4B5C6D7E8F90112233445566778899AABBCCDDEEFF'
        }

        It 'does not fail the read when the manifest will not parse - a broken manifest is not a broken media' {
            $fs = New-HDTFakeFileSystem -File @{
                'X:\Share\Media\M1\media.yaml'          = (& $script:mediaYaml -Id 'M1')
                'X:\Share\Media\M1\media.manifest.json' = '{ this is not json'
            }

            # Called straight rather than inside a Should -Not -Throw
            # scriptblock: an assignment in there lands in the scriptblock's own
            # scope, so the assertions below would read $null however the read
            # went. A throw fails this test on its own.
            $media = Get-HDTMedia -WorkspaceRoot $script:root -Id 'M1' -FileSystem $fs

            $media.Id | Should -BeExactly 'M1'
            $media.LastBuildUtc | Should -BeNullOrEmpty
        }
    }
}
