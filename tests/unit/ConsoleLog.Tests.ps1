# The console's own log.
#
# IT HAD NONE. The engine writes HDT.jsonl, a numbered file per step and a native
# tool log beside each one; the window an administrator drives all of that from
# wrote nothing at all. So "the console crashed when I imported a driver" could
# only be answered by reading source and reasoning about it - which is how the
# wrong half of the system gets blamed, and did: the freeze was the dispatcher,
# not the importer, and a log would have said so in a line.
#
# IT LIVES IN THE SHARE'S Logs FOLDER, at the author's direction: beside the
# deployment logs, where an administrator already looks. The cost is stated
# rather than hidden - a console opened on no share writes no log, and neither
# does one whose share refuses the write, so the session least able to afford
# going unrecorded is the one this cannot record.
#
# PARAMETER NAMES, NEVER VALUES. The console is where the local administrator
# password is set (DESIGN 4.5.2). A log that helpfully recorded every argument
# would be the one place that password came to rest in plain text.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    # Get-HDTLogRecord lives here, and without it four assertions fail as
    # 'CommandNotFoundException' - which reads like the log was never written.
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    $script:share = 'C:\HDTLab\Share'
    $script:logFolder = 'C:\HDTLab\Share\Logs'

    # START AND STOP ARE PRIVATE. They are the session's lifecycle, called by
    # Show-HDTConsole, and the console surface contract says an exported command
    # is one an administrator has a reason to type. So the tests reach them the
    # way the rest of this suite reaches private commands.
    $script:start = {
        param([hashtable] $Argument)

        $module = Get-Module -Name Hephaestus
        return & $module { param($A) Start-HDTConsoleLog @A } $Argument
    }

    $script:stop = {
        $module = Get-Module -Name Hephaestus
        & $module { Stop-HDTConsoleLog }
    }
}

Describe 'Get-HDTConsoleLogPath' {

    It 'puts the log in the share''s own Logs folder' {
        Get-HDTConsoleLogPath -WorkspaceRoot $script:share | Should -BeExactly $script:logFolder
    }

    It 'agrees with the workspace layout rather than joining Logs itself' {
        # A SECOND OPINION ABOUT WHERE A WORKSPACE KEEPS THINGS is how the two
        # drift. This has to be the same answer Get-HDTWorkspacePath gives.
        Get-HDTConsoleLogPath -WorkspaceRoot $script:share |
            Should -BeExactly (Get-HDTWorkspacePath -Root $script:share -Kind Logs)
    }

    It 'names a directory, not a file' {
        [System.IO.Path]::GetExtension((Get-HDTConsoleLogPath -WorkspaceRoot $script:share)) |
            Should -BeExactly ''
    }

    It 'works for a share on a UNC path, which most of them are' {
        Get-HDTConsoleLogPath -WorkspaceRoot '\\srv\Deploy' | Should -BeExactly '\\srv\Deploy\Logs'
    }
}

Describe 'Start-HDTConsoleLog and Stop-HDTConsoleLog' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem -File @{}
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 27, 22, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 100
    }

    AfterEach {
        # MODULE SCOPE OUTLIVES A TEST unless something puts it down, and a test
        # that inherited a previous session's context would write into a
        # directory it never named.
        & $script:stop
    }

    It 'records that the console opened' {
        $context = & $script:start @{ FileSystem = $script:fs; Clock = $script:clock; Path = $script:logFolder }

        $context | Should -Not -BeNullOrEmpty

        @(Get-HDTLogRecord -FileSystem $script:fs -Path ('{0}\Console.jsonl' -f $script:logFolder) `
                -Event 'console.session').Count | Should -BeGreaterThan 0
    }

    It 'records that the console closed, so a death is not read as a shutdown' {
        $null = & $script:start @{ FileSystem = $script:fs; Clock = $script:clock; Path = $script:logFolder }

        & $script:stop
        @(Get-HDTLogRecord -FileSystem $script:fs -Path ('{0}\Console.jsonl' -f $script:logFolder) `
                -Event 'console.session').Count | Should -Be 2
    }

    It 'gives each session its own run id, so two consoles do not interleave' {
        $first = & $script:start @{ FileSystem = $script:fs; Clock = $script:clock; Path = $script:logFolder }
        $second = & $script:start @{ FileSystem = $script:fs; Clock = $script:clock; Path = $script:logFolder }

        [string] $first.RunId | Should -Not -BeExactly ([string] $second.RunId)
    }

    It 'answers null rather than throwing when the log cannot be opened' {
        # THE LOGGING IS THERE TO EXPLAIN FAILURES, NOT TO BECOME ONE.
        $broken = New-HDTFakeFileSystem -File @{}
        $broken.WriteFailure['C:\denied\Console.jsonl'] = 'access is denied'

        { & $script:start @{ FileSystem = $broken; Clock = $script:clock; Path = 'C:\denied' } } |
            Should -Not -Throw
    }

    It 'writes Console.log and Console.jsonl, not HDT.log' {
        # A CONSOLE SESSION AND A DEPLOYMENT IN ONE FILE would interleave two
        # machines' worth of story into one thread. Both formats, because
        # CMTrace has to work on this the way it works on every other HDT log.
        $null = & $script:start @{ FileSystem = $script:fs; Clock = $script:clock; Path = $script:logFolder }

        $script:fs.TestPath(('{0}\Console.jsonl' -f $script:logFolder)) | Should -BeTrue
        $script:fs.TestPath(('{0}\Console.log' -f $script:logFolder)) | Should -BeTrue
        $script:fs.TestPath(('{0}\HDT.log' -f $script:logFolder)) | Should -BeFalse
    }

    It 'opens no log at all when no share has been chosen' {
        # THE STATE A CONSOLE STARTS IN. There is nowhere the log is meant to go
        # until a share is open, and inventing somewhere would put half a
        # session's records in a place nobody looks.
        & $script:start @{ FileSystem = $script:fs; Clock = $script:clock } | Should -BeNullOrEmpty
    }

    It 'writes into the share when given one' {
        $null = & $script:start @{ WorkspaceRoot = $script:share; FileSystem = $script:fs; Clock = $script:clock }

        $script:fs.TestPath(('{0}\Console.log' -f $script:logFolder)) | Should -BeTrue
    }
}

Describe 'the console handler log' {

    BeforeEach {
        $script:fs = New-HDTFakeFileSystem -File @{}
        $script:clock = New-HDTFakeClock -UtcNow ([datetime]::new(2026, 8, 27, 22, 0, 0, [System.DateTimeKind]::Utc)) -TickMillisecond 100

        $null = & $script:start @{ FileSystem = $script:fs; Clock = $script:clock; Path = $script:logFolder }

        $script:call = (Get-Module -Name Hephaestus).Invoke({ Get-HDTHandlerCall })
        $script:jsonl = '{0}\Console.jsonl' -f $script:logFolder
    }

    AfterEach { & $script:stop }

    It 'records the command a handler invoked' {
        $null = & $script:call 'Get-HDTConsoleLogPath' @{ WorkspaceRoot = 'C:\ws' }

        $record = @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:jsonl -Event 'console.action')

        $record.Count | Should -BeGreaterThan 0
        @($record | ForEach-Object { [string] $_.data.command }) | Should -Contain 'Get-HDTConsoleLogPath'
    }

    It 'records the call BEFORE it runs, so a hang leaves a trace' {
        # LOGGING ONLY ON COMPLETION MEANS A COMMAND THAT NEVER RETURNS LEAVES
        # NOTHING - and that is precisely the failure a crash log exists for.
        # The pair reads as a story: 'started' with no 'ran' after it names the
        # command that did not come back.
        $null = & $script:call 'Get-HDTConsoleLogPath' @{ WorkspaceRoot = 'C:\ws' }

        $record = @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:jsonl -Event 'console.action')

        @($record | ForEach-Object { [string] $_.data.phase }) | Should -Contain 'started'
        @($record | ForEach-Object { [string] $_.data.phase }) | Should -Contain 'ran'
    }

    It 'records the value of an ordinary parameter' {
        # The CMTrace file, not the JSONL: JSON escapes every backslash, so a
        # path assertion there matches 'C:\\HDTLab\\Share' and reads like a
        # failure when the value is present and correct.
        $null = & $script:call 'Get-HDTConsoleLogPath' @{ WorkspaceRoot = 'C:\HDTLab\Share' }

        [string] $script:fs.ReadAllText(('{0}\Console.log' -f $script:logFolder)) |
            Should -Match ([regex]::Escape("-WorkspaceRoot 'C:\HDTLab\Share'"))
    }

    It 'records the command as somebody could retype it, end to end' {
        $null = & $script:call 'Get-HDTConsoleLogPath' @{ WorkspaceRoot = 'C:\HDTLab\Share' }

        [string] $script:fs.ReadAllText(('{0}\Console.log' -f $script:logFolder)) |
            Should -Match ([regex]::Escape('Get-HDTConsoleLogPath -WorkspaceRoot'))
    }

    It 'records the exception type and the stack when a command throws' {
        { & $script:call 'Get-HDTDriver' @{ Root = '' } } | Should -Throw

        $record = @(Get-HDTLogRecord -FileSystem $script:fs -Path $script:jsonl -Event 'console.error')

        $record.Count | Should -BeGreaterThan 0
        [string] $record[0].data.type | Should -Not -BeNullOrEmpty
        [string] $record[0].data.stack | Should -Not -BeNullOrEmpty
    }

    It 'rethrows, so a handler still sees exactly what it saw before' {
        { & $script:call 'Get-HDTDriver' @{ Root = '' } } | Should -Throw
    }

    It 'returns the command output unchanged, with no logging object mixed in' {
        # '$imported = & $call ''Import-HDTDriver'' @{...}' is the shape every
        # handler uses. One stray object from the logging would arrive as part
        # of the result and be read as a property off the wrong thing.
        $answer = & $script:call 'Get-HDTConsoleLogPath' @{ WorkspaceRoot = 'C:\ws' }

        @($answer).Count | Should -Be 1
        $answer | Should -BeExactly 'C:\ws\Logs'
    }

    It 'runs the command even when no log has been started' {
        & $script:stop
        & $script:call 'Get-HDTConsoleLogPath' @{ WorkspaceRoot = 'C:\ws' } |
            Should -BeExactly 'C:\ws\Logs'
    }
}
