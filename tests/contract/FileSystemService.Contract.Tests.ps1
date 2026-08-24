# The IFileSystem contract (PROJECT constraint 4, DESIGN 12.2.1).
#
# Every implementation of IFileSystem - the hand-written fake and the real
# adapter - must pass this file unchanged. Adding an implementation is a one-row
# change to $script:HDTImplementation below, not a new test file.
#
# The registry is built at discovery time, not in BeforeAll: Pester 5 expands
# -ForEach while discovering, so a BeforeAll would produce zero test cases.
#
# Each Factory is invoked at run time as & $Factory $repositoryRoot. It is passed
# the repository root because a discovery-phase variable does not survive into
# Pester's run phase, so a factory may not close over one; a factory that does not
# need the root just ignores the argument, as both of these do.
#
# The Skip key and the Context that consumes it are here even though every row
# runs today, so all contract files share one shape. The skip goes on a
# Context INSIDE the Describe, never on the Describe itself: verified against
# Pester 5.7.1, -Skip: on a -ForEach Describe is bound where Describe is called,
# before -ForEach binds the row's keys, so $Skip is unset there and every row
# runs regardless.
#
# EXCEPTION ASSERTIONS UNWRAP. Should -Throw -ExceptionType passes against a
# class-based fake and FAILS against a ScriptMethod-based real adapter, whose
# exception reaches the caller wrapped in MethodInvocationException. The
# innermost-exception loop below is a no-op for the fake and unwraps twice for
# the adapter, so one assertion serves both rows (tests/helpers/README.md 5).
$script:HDTImplementation = @(
    @{
        Name           = 'FakeFileSystem'
        Skip           = $false
        Factory        = { New-HDTFakeFileSystem }
        JournalFactory = { param($Journal) New-HDTFakeFileSystem -Journal $Journal }
        OnDisk         = $false
    }
    @{
        Name           = 'FileSystem'
        Skip           = $false
        Factory        = { New-HDTFileSystem }
        JournalFactory = { param($Journal) New-HDTFileSystem -Journal $Journal }
        OnDisk         = $true
    }
)

Describe 'IFileSystem contract: <Name>' -ForEach $script:HDTImplementation {

    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
        Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

        # A real, empty directory outside the repository. The fake never reaches
        # it; the real adapter does, and AfterAll takes it away again.
        $script:contractRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('HDT-fs-contract-' + [guid]::NewGuid().ToString())
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:contractRoot) {
            Remove-Item -LiteralPath $script:contractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'implementation' -Skip:$Skip {

        BeforeEach {
            # One fresh directory per test, so a real adapter never sees what a
            # previous test left behind.
            $script:root = Join-Path -Path $script:contractRoot -ChildPath ([guid]::NewGuid().ToString())
            $script:fs = & $Factory $script:repoRoot
        }

        It 'exposes every method the contract requires' {
            # Method, ScriptMethod: Get-Member -MemberType Method does NOT list a
            # ScriptMethod, and the real adapters are pscustomobjects carrying
            # ScriptMethod members. Do not "tidy" ScriptMethod away.
            $method = @($script:fs | Get-Member -MemberType Method, ScriptMethod | ForEach-Object { $_.Name })

            foreach ($name in @('TestPath', 'ReadAllText', 'WriteAllText', 'AppendAllText',
                    'CreateDirectory', 'RemoveItem', 'CopyItem', 'MoveItem', 'GetChildItem', 'GetDirectory',
                    'TakeOwnership', 'GrantAccess', 'GetLength', 'GetHash', 'GetVersion')) {
                $method | Should -Contain $name -Because "IFileSystem requires $name"
            }
        }

        # GetDirectory EXISTS BECAUSE GetChildItem CANNOT ANSWER THE QUESTION.
        # A driver group is a FOLDER under Drivers\, and a caller handed a flat
        # list of paths has no way to tell one from a readme.txt beside it
        # without guessing from the name - and 'Dell Latitude 7450 v2.1' has a
        # dot in it.
        It 'lists only the directories under a path' {
            $script:fs.CreateDirectory((Join-Path -Path $script:root -ChildPath 'boot-critical'))
            $script:fs.CreateDirectory((Join-Path -Path $script:root -ChildPath 'Dell Latitude 7450 v2.1'))
            $script:fs.WriteAllText((Join-Path -Path $script:root -ChildPath 'readme.txt'), 'not a group')

            $found = @($script:fs.GetDirectory($script:root) | ForEach-Object { Split-Path -Path $_ -Leaf })

            @($found).Count | Should -Be 2
            $found | Should -Contain 'boot-critical'
            $found | Should -Contain 'Dell Latitude 7450 v2.1'
            $found | Should -Not -Contain 'readme.txt'
        }

        It 'answers an empty list for a directory with no folders in it' {
            $script:fs.WriteAllText((Join-Path -Path $script:root -ChildPath 'only.txt'), 'x')

            @($script:fs.GetDirectory($script:root)).Count | Should -Be 0
        }

        It 'throws for a path that is not there, as GetChildItem does' {
            $record = $null
            try { $script:fs.GetDirectory((Join-Path -Path $script:root -ChildPath 'missing')) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
        }

        # TakeOwnership EXISTS BECAUSE OF ONE FILE: \Windows\System32\winpe.jpg
        # inside a mounted WinPE image is owned by TrustedInstaller and denies
        # write even to an elevated build. A real build proved it - "Access to
        # the path ... is denied" - and Microsoft's own instructions for
        # replacing that background are take ownership, grant Administrators
        # full control, then copy.
        It 'leaves a file writable after taking ownership of it' {
            $path = Join-Path -Path $script:root -ChildPath 'owned.txt'
            $script:fs.WriteAllText($path, 'first')

            $script:fs.TakeOwnership($path)

            # The point is not who owns it - that differs between a real ACL and
            # a fake with none - but that the caller may now write over it.
            $script:fs.WriteAllText($path, 'second')
            $script:fs.ReadAllText($path) | Should -BeExactly 'second'
        }

        It 'throws for a file that is not there' {
            $record = $null
            try { $script:fs.TakeOwnership((Join-Path -Path $script:root -ChildPath 'absent.txt')) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
        }

        # GrantAccess EXISTS BECAUSE A SHARE PERMISSION IS HALF AN ACL. SMB gates
        # the connection and NTFS gates the file, the effective right is the more
        # restrictive of the two, and until this existed HDT granted the first and
        # left the second to an icacls line in docs/share-account.md - which a
        # share published by New-HDTWorkspaceShare never ran. The result was a
        # share the deployment account could reach and not read.
        #
        # WHAT IT GRANTS IS ASSERTED IN THE JOURNAL, not read back off the disk.
        # The fake carries no Windows security model, and building one to test
        # against would be testing the invention rather than the caller. What a
        # caller has to prove is that it ASKS, and with which right.
        # THE ACCOUNT IS WHOEVER IS RUNNING, and that is not laziness. The real
        # adapter shells to icacls, which resolves the name against THIS
        # machine's accounts: a literal 'LAP-AMMSO01\svc-hdt-deploy' exists on
        # the lab laptop and nowhere else, so it passed here and failed on a
        # hosted runner with "No mapping between account names and security IDs
        # was done" - exit 1332. The current identity exists wherever the suite
        # runs, and granting it Read on a temp folder it already owns changes
        # nothing.
        It 'records the grant it was asked for' {
            $folder = Join-Path -Path $script:root -ChildPath 'granted'
            $script:fs.CreateDirectory($folder)

            $script:fs.GrantAccess($folder, ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name), 'Read')

            $script:fs.GetOperationName() | Should -Contain 'GrantAccess'
        }

        It 'throws for a path that is not there' {
            $record = $null
            try { $script:fs.GrantAccess((Join-Path -Path $script:root -ChildPath 'no-such-folder'), ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name), 'Read') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
        }

        # A right the toolkit does not grant is refused before the tool is
        # reached - FullControl on a deployment share is the Critical finding
        # Test-HDTShareAcl exists to report. Refused BEFORE icacls means this one
        # never resolves an account at all.
        It 'refuses a right it does not grant' {
            $record = $null
            try { $script:fs.GrantAccess($script:root, ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name), 'FullControl') } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
        }

        It 'returns an array even for one directory' {
            # The unary-comma trap: a ScriptMethod collapses a single-element
            # array to a scalar, and a caller doing .Count then reads the length
            # of a string.
            $script:fs.CreateDirectory((Join-Path -Path $script:root -ChildPath 'only-one'))

            $script:fs.GetDirectory($script:root) -is [System.Array] | Should -BeTrue
        }

        It 'reports a written file as existing' {
            $path = Join-Path -Path $script:root -ChildPath 'exists.txt'
            $script:fs.WriteAllText($path, 'content')

            $script:fs.TestPath($path) | Should -BeTrue
        }

        It 'reports an unknown path as not existing' {
            $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'unknown.txt')) | Should -BeFalse
        }

        It 'round-trips text through WriteAllText and ReadAllText' {
            $path = Join-Path -Path $script:root -ChildPath 'roundtrip.txt'
            $script:fs.WriteAllText($path, "line one`nline two")

            $script:fs.ReadAllText($path) | Should -BeExactly "line one`nline two"
        }

        It 'overwrites an existing file on a second WriteAllText' {
            $path = Join-Path -Path $script:root -ChildPath 'overwrite.txt'
            $script:fs.WriteAllText($path, 'first')
            $script:fs.WriteAllText($path, 'second')

            $script:fs.ReadAllText($path) | Should -BeExactly 'second'
        }

        It 'creates missing parent directories when writing' {
            $path = Join-Path -Path $script:root -ChildPath 'deep/deeper/file.txt'
            $script:fs.WriteAllText($path, 'x')

            $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'deep')) | Should -BeTrue
            $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'deep/deeper')) | Should -BeTrue
        }

        It 'appends to a file that does not exist' {
            $path = Join-Path -Path $script:root -ChildPath 'appended.jsonl'
            $script:fs.AppendAllText($path, '{"seq":1}')

            $script:fs.ReadAllText($path) | Should -BeExactly '{"seq":1}'
        }

        It 'appends to an existing file without truncating it' {
            $path = Join-Path -Path $script:root -ChildPath 'grows.jsonl'
            $script:fs.WriteAllText($path, "{`"seq`":1}`n")
            $script:fs.AppendAllText($path, "{`"seq`":2}`n")
            $script:fs.AppendAllText($path, "{`"seq`":3}`n")

            $script:fs.ReadAllText($path) | Should -BeExactly "{`"seq`":1}`n{`"seq`":2}`n{`"seq`":3}`n"
        }

        It 'creates parent directories when appending' {
            $path = Join-Path -Path $script:root -ChildPath 'Logs/Steps/003-ApplyImage.log'
            $script:fs.AppendAllText($path, 'x')

            $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'Logs/Steps')) | Should -BeTrue
            $script:fs.ReadAllText($path) | Should -BeExactly 'x'
        }

        It 'writes UTF-8 with no byte order mark' {
            # Set-Content -Encoding UTF8 emits 239 187 191 under Windows PowerShell
            # 5.1 and nothing under pwsh 7, so the adapter uses System.IO.File with
            # an explicit UTF8Encoding($false) instead. An implementation that
            # really wrote to disk is checked byte for byte; the in-memory fake has
            # no bytes, so it is checked through its own reader.
            $path = Join-Path -Path $script:root -ChildPath 'bom.jsonl'
            $script:fs.WriteAllText($path, '{"a":1}')
            $script:fs.AppendAllText($path, "`n" + '{"a":2}')

            if ($OnDisk) {
                Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
                $byte = [System.IO.File]::ReadAllBytes($path)
            } else {
                Test-Path -LiteralPath $path | Should -BeFalse
                $byte = [System.Text.Encoding]::UTF8.GetBytes($script:fs.ReadAllText($path))
            }

            ($byte[0] -eq 239 -and $byte[1] -eq 187 -and $byte[2] -eq 191) | Should -BeFalse
            $script:fs.ReadAllText($path) | Should -BeExactly ('{"a":1}' + "`n" + '{"a":2}')
        }

        It 'round-trips a non-ASCII character' {
            $path = Join-Path -Path $script:root -ChildPath 'unicode.txt'
            $text = [string]::Concat('na', [char] 0x00EF, 've ', [char] 0x2014, ' ', [char] 0x2713)
            $script:fs.WriteAllText($path, $text)

            $script:fs.ReadAllText($path) | Should -BeExactly $text
        }

        It 'throws FileNotFoundException for a missing file' {
            # The directory has to exist, or System.IO reports the missing
            # DIRECTORY - a different and equally correct answer that says
            # nothing about the file.
            $script:fs.CreateDirectory($script:root)
            $path = Join-Path -Path $script:root -ChildPath 'missing.txt'

            $record = $null
            try { $script:fs.ReadAllText($path) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'throws UnauthorizedAccessException when reading a directory' {
            $path = Join-Path -Path $script:root -ChildPath 'adirectory'
            $script:fs.CreateDirectory($path)

            $record = $null
            try { $script:fs.ReadAllText($path) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.UnauthorizedAccessException])
        }

        It 'creates a directory' {
            $path = Join-Path -Path $script:root -ChildPath 'created'
            $script:fs.CreateDirectory($path)

            $script:fs.TestPath($path) | Should -BeTrue
        }

        It 'treats CreateDirectory as idempotent' {
            $path = Join-Path -Path $script:root -ChildPath 'twice'
            $script:fs.CreateDirectory($path)

            { $script:fs.CreateDirectory($path) } | Should -Not -Throw
            $script:fs.TestPath($path) | Should -BeTrue
        }

        It 'creates intermediate directories' {
            $path = Join-Path -Path $script:root -ChildPath 'a/b/c'
            $script:fs.CreateDirectory($path)

            $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'a')) | Should -BeTrue
            $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'a/b')) | Should -BeTrue
            $script:fs.TestPath($path) | Should -BeTrue
        }

        It 'lists only immediate children' {
            $path = Join-Path -Path $script:root -ChildPath 'listing'
            $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'top.txt'), 'x')
            $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'nested/deep.txt'), 'x')

            $child = @($script:fs.GetChildItem($path))

            $child.Count | Should -Be 2
            @($child | ForEach-Object { Split-Path -Path $_ -Leaf }) | Should -Contain 'top.txt'
            @($child | ForEach-Object { Split-Path -Path $_ -Leaf }) | Should -Contain 'nested'
            @($child | ForEach-Object { Split-Path -Path $_ -Leaf }) | Should -Not -Contain 'deep.txt'
        }

        It 'returns children sorted' {
            # Ordinal, so an implementation has to sort deliberately rather than
            # inherit whatever order the underlying store happens to hand back.
            $path = Join-Path -Path $script:root -ChildPath 'sorted'
            foreach ($leaf in @('c.txt', 'a.txt', 'B.txt')) {
                $script:fs.WriteAllText((Join-Path -Path $path -ChildPath $leaf), 'x')
            }

            $child = @($script:fs.GetChildItem($path) | ForEach-Object { Split-Path -Path $_ -Leaf })

            $child | Should -Be @('B.txt', 'a.txt', 'c.txt')
        }

        It 'throws DirectoryNotFoundException when listing a missing directory' {
            $path = Join-Path -Path $script:root -ChildPath 'no-such-directory'

            $record = $null
            try { $script:fs.GetChildItem($path) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.DirectoryNotFoundException])
        }

        It 'returns an empty array for an empty directory' {
            $path = Join-Path -Path $script:root -ChildPath 'empty'
            $script:fs.CreateDirectory($path)

            @($script:fs.GetChildItem($path)).Count | Should -Be 0
        }

        It 'returns an array even for a single child' {
            # A ScriptMethod collapses a single-element array to a scalar unless
            # the implementation returns it with the unary comma.
            $path = Join-Path -Path $script:root -ChildPath 'onechild'
            $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'only.txt'), 'x')

            $script:fs.GetChildItem($path) -is [System.Array] | Should -BeTrue
        }

        It 'copies a file' {
            $source = Join-Path -Path $script:root -ChildPath 'source.txt'
            $destination = Join-Path -Path $script:root -ChildPath 'copies/destination.txt'
            $script:fs.WriteAllText($source, 'payload')

            $script:fs.CopyItem($source, $destination)

            $script:fs.ReadAllText($destination) | Should -BeExactly 'payload'
            $script:fs.TestPath($source) | Should -BeTrue
        }

        It 'throws FileNotFoundException when copying a missing source' {
            $source = Join-Path -Path $script:root -ChildPath 'absent.txt'
            $destination = Join-Path -Path $script:root -ChildPath 'copied.txt'

            $record = $null
            try { $script:fs.CopyItem($source, $destination) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'removes a file' {
            $path = Join-Path -Path $script:root -ChildPath 'doomed.txt'
            $script:fs.WriteAllText($path, 'x')

            $script:fs.RemoveItem($path, $false)

            $script:fs.TestPath($path) | Should -BeFalse
        }

        It 'ignores RemoveItem on a missing path' {
            $path = Join-Path -Path $script:root -ChildPath 'never-existed.txt'

            { $script:fs.RemoveItem($path, $false) } | Should -Not -Throw
        }

        It 'throws IOException removing a non-empty directory without Recurse' {
            $path = Join-Path -Path $script:root -ChildPath 'populated'
            $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'child.txt'), 'x')

            $record = $null
            try { $script:fs.RemoveItem($path, $false) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty
            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.IOException])
        }

        It 'removes a non-empty directory with Recurse' {
            $path = Join-Path -Path $script:root -ChildPath 'tree'
            $script:fs.WriteAllText((Join-Path -Path $path -ChildPath 'a/child.txt'), 'x')

            $script:fs.RemoveItem($path, $true)

            $script:fs.TestPath($path) | Should -BeFalse
            $script:fs.TestPath((Join-Path -Path $path -ChildPath 'a')) | Should -BeFalse
            $script:fs.TestPath((Join-Path -Path $path -ChildPath 'a/child.txt')) | Should -BeFalse
        }

        It 'reports the byte length of a file' {
            $path = Join-Path -Path $script:root -ChildPath 'length.txt'
            $script:fs.WriteAllText($path, 'hello')

            $script:fs.GetLength($path) | Should -Be 5
        }

        # -- GetHash, the tenth method (05-04) ------------------------------
        #
        # DESIGN 6.1.1's whole debugging story is "the WIM inside the ISO hashes
        # identical to the standalone WIM", and Update-HDTBootImage has to write
        # that hash into the manifest so an operator can check it without this
        # suite. Hashing a 500 MB ISO cannot go through ReadAllText, so the
        # interface grew a tenth method rather than the builder growing a
        # Get-FileHash call that no fake could answer.

        It 'returns a 64 character uppercase hex SHA256 from GetHash' {
            $path = Join-Path -Path $script:root -ChildPath 'hash.txt'
            $script:fs.WriteAllText($path, 'hello')

            $hash = $script:fs.GetHash($path)

            $hash | Should -Match '^[0-9A-F]{64}$'
        }

        It 'hashes the known SHA256 of hello' {
            # Not a fixture and not an invention: the SHA256 of the five ASCII
            # bytes 'hello'. Asserting the VALUE is what makes the fake's hash
            # and the real adapter's hash the same number rather than merely the
            # same shape - Update-HDTBootImage compares hashes computed on two
            # different files and a fake with its own hashing scheme would let a
            # builder that compared nothing pass.
            $path = Join-Path -Path $script:root -ChildPath 'hello.txt'
            $script:fs.WriteAllText($path, 'hello')

            $script:fs.GetHash($path) |
                Should -BeExactly '2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824'
        }

        It 'gives two files with identical content the same hash' {
            $first = Join-Path -Path $script:root -ChildPath 'first.wim'
            $second = Join-Path -Path $script:root -ChildPath 'sources/boot.wim'
            $script:fs.WriteAllText($first, 'the same bytes')
            $script:fs.CopyItem($first, $second)

            $script:fs.GetHash($second) | Should -BeExactly $script:fs.GetHash($first)
        }

        It 'gives two files with different content different hashes' {
            $first = Join-Path -Path $script:root -ChildPath 'a.wim'
            $second = Join-Path -Path $script:root -ChildPath 'b.wim'
            $script:fs.WriteAllText($first, 'one')
            $script:fs.WriteAllText($second, 'two')

            $script:fs.GetHash($second) | Should -Not -BeExactly $script:fs.GetHash($first)
        }

        It 'throws FileNotFoundException from GetHash for a path that is not a file' {
            $record = $null
            try { $script:fs.GetHash((Join-Path -Path $script:root -ChildPath 'absent.wim')) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'records GetHash before it can throw' {
            try { $script:fs.GetHash((Join-Path -Path $script:root -ChildPath 'absent.wim')) } catch { $null = $_ }

            $script:fs.GetOperationName() | Should -Be @('GetHash')
        }

        # -- GetVersion, the eleventh method (07-01) ------------------------
        #
        # DESIGN 8's file detection rule is only worth having WITH a version:
        # a path test alone reports "installed" for a stale build the sequence
        # exists to replace, which is the silent-skip failure detection is
        # supposed to prevent. Reading a version resource cannot go through
        # ReadAllText, so the interface grew an eleventh method rather than
        # Test-HDTApplicationDetection growing a
        # [System.Diagnostics.FileVersionInfo] call no fake could answer.
        #
        # The four-part form is what both implementations return, so a caller
        # can always cast it to [version] rather than parsing whatever text a
        # vendor put in the FileVersion string.

        It 'returns a four-part version' {
            $path = Join-Path -Path $script:root -ChildPath 'versioned.txt'
            $script:fs.WriteAllText($path, 'x')

            $script:fs.GetVersion($path) | Should -Match '^\d+\.\d+\.\d+\.\d+$'
        }

        It 'returns 0.0.0.0 for a file carrying no version resource' {
            # A text file has none, and neither does most of what a deployment
            # copies around. Reporting it as 0.0.0.0 rather than as an empty
            # string or a throw keeps the comparison in the detection rule a
            # plain version comparison with no special case.
            $path = Join-Path -Path $script:root -ChildPath 'unversioned.txt'
            $script:fs.WriteAllText($path, 'x')

            $script:fs.GetVersion($path) | Should -BeExactly '0.0.0.0'
        }

        It 'throws FileNotFoundException from GetVersion for a path that is not a file' {
            $record = $null
            try { $script:fs.GetVersion((Join-Path -Path $script:root -ChildPath 'absent.exe')) } catch { $record = $_ }

            $record | Should -Not -BeNullOrEmpty

            $inner = $record.Exception
            while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
            $inner | Should -BeOfType ([System.IO.FileNotFoundException])
        }

        It 'records GetVersion before it can throw' {
            try { $script:fs.GetVersion((Join-Path -Path $script:root -ChildPath 'absent.exe')) } catch { $null = $_ }

            $script:fs.GetOperationName() | Should -Be @('GetVersion')
        }

        It 'treats paths case-insensitively' {
            $path = Join-Path -Path $script:root -ChildPath 'CaseSensitive.txt'
            $script:fs.WriteAllText($path, 'insensitive')

            $script:fs.TestPath((Join-Path -Path $script:root -ChildPath 'casesensitive.TXT')) | Should -BeTrue
            $script:fs.ReadAllText((Join-Path -Path $script:root -ChildPath 'CASESENSITIVE.txt')) | Should -BeExactly 'insensitive'
        }

        It 'normalises a trailing separator' {
            $path = Join-Path -Path $script:root -ChildPath 'trailing'
            $script:fs.CreateDirectory(($path + [System.IO.Path]::DirectorySeparatorChar))

            $script:fs.TestPath($path) | Should -BeTrue
            @($script:fs.GetChildItem(($path + [System.IO.Path]::DirectorySeparatorChar))).Count | Should -Be 0
        }

        It 'records every operation including reads' {
            $path = Join-Path -Path $script:root -ChildPath 'recorded.txt'
            $script:fs.CreateDirectory($script:root)
            $script:fs.WriteAllText($path, 'x')
            $script:fs.AppendAllText($path, 'y')
            $script:fs.TestPath($path) | Out-Null
            $script:fs.ReadAllText($path) | Out-Null
            $script:fs.GetLength($path) | Out-Null

            $script:fs.GetOperationName() |
                Should -Be @('CreateDirectory', 'WriteAllText', 'AppendAllText', 'TestPath', 'ReadAllText', 'GetLength')
        }

        It 'honours -Journal' {
            $journal = [System.Collections.ArrayList]::new()
            $journalled = & $JournalFactory $journal
            $path = Join-Path -Path $script:root -ChildPath 'journalled.jsonl'

            $journalled.WriteAllText($path, 'x')
            $journalled.AppendAllText($path, 'y')

            @($journal | ForEach-Object { '{0}.{1}' -f $_.Service, $_.Operation }) |
                Should -Be @('FileSystem.WriteAllText', 'FileSystem.AppendAllText')
            @($journal | ForEach-Object { $_.Sequence }) | Should -Be @(1, 2)
        }

        It 'names itself FileSystem' {
            $script:fs.ServiceName | Should -BeExactly 'FileSystem'
        }
    }
}
