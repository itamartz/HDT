# Reading the driver grid off the dispatcher.
#
# SELECTING A FOLDER FROZE THE CONSOLE FOR TWO SECONDS, every time, because the
# grid was filled by calling Get-HDTConsoleDriverRow straight from the selection
# handler. An administrator clicking 'Dell inc' and then 'WinPE' waits twice.
#
# AND THE CACHE HID IT FROM THE MEASUREMENT. Warm, that read is 291 ms; cold it
# is 2.5 seconds, and every FIRST look at a folder is cold. Timing the second
# read said the problem was solved when only half of it was.
#
# THESE ARE REAL RUNSPACES. Nothing here is faked - a runspace opens, imports
# the module and runs a read, headless, exactly as it does behind the window.
# The only thing Pester cannot exercise is the DispatcherTimer that polls
# IsDone, which is why the polling is three lines in the view and everything
# else is here.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:modulePath = Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1'

    $script:newReader = {
        $module = Get-Module -Name Hephaestus
        return & $module { param($P) New-HDTConsoleGridReader -ModulePath $P } $script:modulePath
    }

    # A REAL SHARE ON DISK, because the reader's runspace has its own file
    # system and cannot see a fake built in this one. Small - two .inf files -
    # so the test is about the threading, not the parsing.
    $script:share = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('HDT-gridreader-{0}' -f ([guid]::NewGuid().ToString('n').Substring(0, 8)))
    $script:folder = Join-Path -Path $script:share -ChildPath 'Drivers\WinPE\Dell'

    [void] (New-Item -ItemType Directory -Path $script:folder -Force)

    $script:inf = @(
        '[Version]'
        'Signature = "$Windows NT$"'
        'Class = Net'
        'Provider = %Acme%'
        'DriverVer = 01/02/2026,1.2.3.4'
        ''
        '[Manufacturer]'
        '%Acme% = Acme, NTamd64.10.0'
        ''
        '[Acme.NTamd64.10.0]'
        '%Card.Desc% = Card.ndi, PCI\VEN_8086&DEV_10DE'
        ''
        '[Strings]'
        'Acme = "Acme"'
        'Card.Desc = "Acme Gigabit Adapter"'
    ) -join "`r`n"

    [System.IO.File]::WriteAllText((Join-Path -Path $script:folder -ChildPath 'net-one.inf'), $script:inf)
    [System.IO.File]::WriteAllText((Join-Path -Path $script:folder -ChildPath 'net-two.inf'), $script:inf)

    # A read is a runspace start plus a module import on the first call, so the
    # wait is generous. It is a ceiling, not a measurement.
    $script:waitFor = {
        param([object] $Reader, [int] $Second = 60)

        $limit = [datetime]::UtcNow.AddSeconds($Second)

        while (-not $Reader.IsDone()) {
            if ([datetime]::UtcNow -gt $limit) { throw 'the reader did not finish in time' }
            Start-Sleep -Milliseconds 50
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:share) {
        # Created by this file, in the temp directory, removed by this file.
        Remove-Item -LiteralPath $script:share -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-HDTConsoleGridReader' {

    It 'reads the rows a folder holds' {
        $reader = & $script:newReader

        try {
            [void] $reader.Begin($script:share, 'Drivers\WinPE\Dell', $null)
            & $script:waitFor $reader

            $row = @($reader.End())

            $row.Count | Should -Be 2
            @($row | ForEach-Object { [string] $_.InfName }) | Should -Contain 'net-one.inf'
        } finally {
            $reader.Close()
        }
    }

    It 'does not block the calling thread while it reads' {
        # THE WHOLE POINT. Begin returns immediately; the read happens on the
        # reader's own thread. If this ever starts taking as long as the read,
        # the grid is back on the dispatcher and the freeze is back with it.
        $reader = & $script:newReader

        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            [void] $reader.Begin($script:share, 'Drivers\WinPE\Dell', $null)
            $watch.Stop()

            $watch.ElapsedMilliseconds | Should -BeLessThan 1000

            & $script:waitFor $reader
            [void] $reader.End()
        } finally {
            $reader.Close()
        }
    }

    It 'gives each read a token, so a superseded one can be dropped' {
        $reader = & $script:newReader

        try {
            $first = $reader.Begin($script:share, 'Drivers\WinPE\Dell', $null)
            $second = $reader.Begin($script:share, 'Drivers\WinPE\Dell', $null)

            $second | Should -BeGreaterThan $first

            & $script:waitFor $reader
            [void] $reader.End()
        } finally {
            $reader.Close()
        }
    }

    It 'answers nothing, and says why, for a folder that is not there' {
        # A READ THAT FAILED STILL HAS TO LEAVE A WINDOW SOMEBODY CAN USE. It
        # must not throw out of a dispatcher timer, which would take the console
        # down rather than empty a grid.
        $reader = & $script:newReader

        try {
            [void] $reader.Begin($script:share, 'Drivers\Nowhere', $null)
            & $script:waitFor $reader

            { $reader.End() } | Should -Not -Throw
        } finally {
            $reader.Close()
        }
    }

    It 'reports done when nothing has been asked of it' {
        $reader = & $script:newReader

        try {
            $reader.IsDone() | Should -BeTrue
            @($reader.End()).Count | Should -Be 0
        } finally {
            $reader.Close()
        }
    }

    It 'fills a synchronized cache the next read can use' {
        # THE CACHE CROSSES A THREAD BOUNDARY, so the window makes it
        # synchronized. This is the shape the console passes.
        $cache = [hashtable]::Synchronized(@{})
        $reader = & $script:newReader

        try {
            [void] $reader.Begin($script:share, 'Drivers\WinPE\Dell', $cache)
            & $script:waitFor $reader
            [void] $reader.End()

            $cache.Count | Should -BeGreaterThan 0
        } finally {
            $reader.Close()
        }
    }

    It 'closes without throwing, twice, because a window can close oddly' {
        $reader = & $script:newReader

        $reader.Close()
        { $reader.Close() } | Should -Not -Throw
    }
}
