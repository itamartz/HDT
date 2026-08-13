# WHICH DRIVE IS THE CONTENT ON?
#
# This is the difference between a boot image that deploys and a boot image that
# sits there. SPIKES S9.1: WinPE assigned the CONTENT DISK C: and the RAM disk
# X:, so a deployRoot baked into bootstrap.json at build time cannot know what
# letter the machine it has never met will hand out. Phase 04's launcher scanned
# 'C', 'D', 'E', 'F', 'G', 'H' for exactly that reason; this function may not
# write a letter down at all.
#
# THE ENUMERATION IS DELIBERATELY NOT ITS JOB. The caller hands it candidates,
# which is the same split Select-HDTTargetDisk already uses: the service
# enumerates, the function decides. That is what keeps this whole decision
# provable on a machine with one disk.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # THE TOPOLOGY SPIKES S9.1 MEASURED, as a fixture: three ready volumes, the
    # workspace on the second of them, and nothing in the bootstrap that says so.
    $script:candidate = @('C:\', 'D:\', 'E:\')

    $script:errorOf = {
        param([scriptblock] $Action)

        $record = $null
        try { & $Action } catch { $record = $_ }

        return $record
    }

    # A Write-Warning raised by a cmdlet is captured with -WarningVariable; these
    # helpers keep the two-line dance in one place.
    $script:resolveWithWarning = {
        param([hashtable] $Argument)

        $warning = @()
        $value = Resolve-HDTDeployRoot @Argument -WarningVariable warning -WarningAction SilentlyContinue

        return [pscustomobject] @{ Value = $value; Warning = @($warning) }
    }
}

Describe 'Resolve-HDTDeployRoot' {

    Context 'rule 1: an Smb root needs no volume' {

        It 'returns a UNC root unchanged for Smb' {
            $fs = New-HDTFakeFileSystem

            $row = Resolve-HDTDeployRoot -DeployRoot '\\HDTSRV01\HdtShare' -Provider Smb -FileSystem $fs

            $row.Path | Should -BeExactly '\\HDTSRV01\HdtShare'
            $row.Source | Should -BeExactly 'Configured'
        }

        It 'asks the filesystem nothing for an Smb root' {
            # The share is not reachable until the provider maps it, so probing
            # for a marker here would fail on every correct configuration.
            $fs = New-HDTFakeFileSystem

            $null = Resolve-HDTDeployRoot -DeployRoot '\\HDTSRV01\HdtShare' -Provider Smb -FileSystem $fs

            @($fs.GetOperationName()) | Should -BeNullOrEmpty
        }
    }

    Context 'rule 2: a rooted Local root that is there' {

        It 'returns a rooted Local root unchanged when the marker is under it' {
            $fs = New-HDTFakeFileSystem -File @{ 'D:\Share\rules.yaml' = 'schemaVersion: 1' }

            $row = Resolve-HDTDeployRoot -DeployRoot 'D:\Share' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs

            $row.Path | Should -BeExactly 'D:\Share'
            $row.Source | Should -BeExactly 'Configured'
            $row.Marker | Should -BeExactly 'rules.yaml'
        }
    }

    Context 'rule 3: a volume-relative Local root is discovered' {

        It 'finds the volume WinPE actually assigned' {
            # SPIKES S9.1 AS AN ASSERTION. The image says \Share; the machine
            # says D:. Nothing wrote D down.
            $fs = New-HDTFakeFileSystem -File @{ 'D:\Share\rules.yaml' = 'schemaVersion: 1' }

            $row = Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs

            $row.Path | Should -BeExactly 'D:\Share'
            $row.Source | Should -BeExactly 'Discovered'
        }

        It 'joins the candidate and the root without doubling the separator' {
            # 'D:\' plus '\Share' is 'D:\Share', not 'D:\\Share'. The leading
            # separator is trimmed before [IO.Path]::Combine sees it.
            $fs = New-HDTFakeFileSystem -File @{ 'D:\Share\rules.yaml' = 'schemaVersion: 1' }

            $null = Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs

            @($fs.Operations | ForEach-Object { [string] $_.Arguments[0] }) |
                Should -Not -Contain 'D:\\Share\rules.yaml'
        }

        It 'searches the candidates in the order it was given' {
            $fs = New-HDTFakeFileSystem -File @{ 'E:\Share\rules.yaml' = 'schemaVersion: 1' }

            $null = Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs

            $probed = @($fs.Operations |
                    Where-Object { $_.Operation -eq 'TestPath' } |
                    ForEach-Object { [string] $_.Arguments[0] })

            $probed[0] | Should -BeExactly 'C:\Share\rules.yaml'
            $probed[1] | Should -BeExactly 'D:\Share\rules.yaml'
            $probed[2] | Should -BeExactly 'E:\Share\rules.yaml'
        }

        It 'reads through the injected filesystem' {
            $fs = New-HDTFakeFileSystem -File @{ 'D:\Share\rules.yaml' = 'schemaVersion: 1' }

            $null = Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs

            @($fs.GetOperationName() | Select-Object -Unique) | Should -Be @('TestPath')
        }

        It 'honours a non-default marker' {
            $fs = New-HDTFakeFileSystem -File @{ 'E:\Share\workspace.yaml' = 'schemaVersion: 1' }

            $row = Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                -CandidateRoot $script:candidate -Marker 'workspace.yaml' -FileSystem $fs

            $row.Path | Should -BeExactly 'E:\Share'
            $row.Marker | Should -BeExactly 'workspace.yaml'
        }

        It 'accepts a deployRoot of a single separator, which is the volume root' {
            $fs = New-HDTFakeFileSystem -File @{ 'D:\rules.yaml' = 'schemaVersion: 1' }

            $row = Resolve-HDTDeployRoot -DeployRoot '\' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs

            $row.Path | Should -BeExactly 'D:\'
            $row.Source | Should -BeExactly 'Discovered'
        }
    }

    Context 'rule 4: a rooted Local root that is NOT there' {

        It 'falls back to the probe when a rooted root is not there' {
            # A boot image that was right yesterday should not be unbootable
            # because a disk was added and the letters moved.
            $fs = New-HDTFakeFileSystem -File @{ 'E:\Share\rules.yaml' = 'schemaVersion: 1' }

            $row = Resolve-HDTDeployRoot -DeployRoot 'D:\Share' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs -WarningAction SilentlyContinue

            $row.Path | Should -BeExactly 'E:\Share'
            $row.Source | Should -BeExactly 'Discovered'
        }

        It 'warns naming both the configured root and the one it found' {
            $fs = New-HDTFakeFileSystem -File @{ 'E:\Share\rules.yaml' = 'schemaVersion: 1' }

            $outcome = & $script:resolveWithWarning @{
                DeployRoot    = 'D:\Share'
                Provider      = 'Local'
                CandidateRoot = $script:candidate
                FileSystem    = $fs
            }

            $outcome.Warning.Count | Should -BeGreaterOrEqual 1
            ($outcome.Warning -join ' ') | Should -BeLike '*D:\Share*'
            ($outcome.Warning -join ' ') | Should -BeLike '*E:\Share*'
        }
    }

    Context 'rule 5: nothing matched' {

        It 'throws HDTConfigurationError when nothing matched' {
            $fs = New-HDTFakeFileSystem

            $record = & $script:errorOf {
                Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                    -CandidateRoot $script:candidate -FileSystem $fs
            }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
        }

        It 'names the deployRoot, the marker and every candidate when nothing matched' {
            # THE LAST SENTENCE A MACHINE WITH NO OPERATOR WILL EVER SAY. It says
            # everything a human needs to fix it, in the order it looked.
            $fs = New-HDTFakeFileSystem

            $record = & $script:errorOf {
                Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                    -CandidateRoot $script:candidate -FileSystem $fs
            }

            $message = [string] $record.Exception.Message

            $message | Should -BeLike '*\Share*'
            $message | Should -BeLike '*rules.yaml*'
            $message | Should -BeLike '*C:\*'
            $message | Should -BeLike '*D:\*'
            $message | Should -BeLike '*E:\*'
        }

        It 'names the candidate list as empty when it was given none' {
            $fs = New-HDTFakeFileSystem

            $record = & $script:errorOf {
                Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local -FileSystem $fs
            }

            $record | Should -Not -BeNullOrEmpty
            $record.FullyQualifiedErrorId | Should -BeLike 'HDTConfigurationError*'
            [string] $record.Exception.Message | Should -BeLike '*no candidate*'
        }
    }

    Context 'rule 6: more than one candidate matched' {

        It 'warns and takes the first when two candidates match' {
            # Refusing would strand a machine over a stale second copy; silence
            # would hide the ambiguity. So: first wins, and say so.
            $fs = New-HDTFakeFileSystem -File @{
                'D:\Share\rules.yaml' = 'schemaVersion: 1'
                'E:\Share\rules.yaml' = 'schemaVersion: 1'
            }

            $outcome = & $script:resolveWithWarning @{
                DeployRoot    = '\Share'
                Provider      = 'Local'
                CandidateRoot = $script:candidate
                FileSystem    = $fs
            }

            $outcome.Value.Path | Should -BeExactly 'D:\Share'
            $outcome.Warning.Count | Should -BeGreaterOrEqual 1
            ($outcome.Warning -join ' ') | Should -BeLike '*D:\Share*'
            ($outcome.Warning -join ' ') | Should -BeLike '*E:\Share*'
        }
    }

    Context 'the row it returns' {

        It 'carries every candidate it looked at, in order' {
            # RESULT.json records what the resolver SAW as well as what it chose,
            # which is what a support call needs when the answer was wrong.
            $fs = New-HDTFakeFileSystem -File @{ 'D:\Share\rules.yaml' = 'schemaVersion: 1' }

            $row = Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs

            @($row.Candidate) | Should -Be $script:candidate
        }

        It 'carries an empty candidate list for Smb' {
            $fs = New-HDTFakeFileSystem

            $row = Resolve-HDTDeployRoot -DeployRoot '\\HDTSRV01\HdtShare' -Provider Smb `
                -CandidateRoot $script:candidate -FileSystem $fs

            @($row.Candidate) | Should -BeNullOrEmpty
        }

        It 'reports Path, Source, Marker and Candidate and nothing else' {
            $fs = New-HDTFakeFileSystem -File @{ 'D:\Share\rules.yaml' = 'schemaVersion: 1' }

            $row = Resolve-HDTDeployRoot -DeployRoot '\Share' -Provider Local `
                -CandidateRoot $script:candidate -FileSystem $fs

            @($row.PSObject.Properties | ForEach-Object { $_.Name }) |
                Should -Be @('Path', 'Source', 'Marker', 'Candidate')
        }
    }

    Context 'the function itself' {

        It 'writes no drive letter of its own' {
            # THIS FUNCTION DECIDES; THE CALLER ENUMERATES. A letter written here
            # is the defect SPIKES S9.1 exists to prevent, and it would be
            # invisible on the developer's machine.
            $path = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Public/Resolve-HDTDeployRoot.ps1'

            $token = $null
            $parseError = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref] $token, [ref] $parseError)

            @($parseError).Count | Should -Be 0

            # The comments are dropped, so the header may explain the rule in
            # prose without failing the assertion that enforces it.
            $codeOnly = (@($token | Where-Object { $_.Kind -ne 'Comment' } |
                        ForEach-Object { [string] $_.Text }) -join ' ')

            $codeOnly | Should -Not -BeNullOrEmpty
            $codeOnly | Should -Not -Match '\b[A-Za-z]:\\'
        }

        It 'is exported with comment-based help' {
            $help = Get-Help -Name Resolve-HDTDeployRoot -ErrorAction Stop

            $help.Name | Should -BeExactly 'Resolve-HDTDeployRoot'
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}
