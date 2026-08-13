# DESIGN 4.4.2: "HDT.jsonl ... is what ConvertTo-HDTReport renders to HTML".
#
# The report is what a technician opens when a deployment failed, and the two
# facts that shape every test here are operational rather than aesthetic:
#
#   1. It is opened from a USB stick, a share, or a machine with no network, so
#      the file is SELF-CONTAINED - inline CSS, no script, no CDN, no font.
#      Anything external is a report that renders blank exactly when it matters.
#   2. It is rendered from the log of a machine that may have DIED mid-write, so
#      a truncated final line is normal input, not an error. A renderer that
#      throws on it is a renderer that never works on the day it is needed.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTFakes/HDTFakes.psd1') -Force -ErrorAction Stop

    $script:jsonlPath = 'C:\HDT\Logs\HDT.jsonl'
    $script:reportPath = 'C:\HDT\Logs\report.html'

    # One record, rendered the way Write-HDTLog renders it: compressed, one
    # physical line, ts as a STRING.
    $script:line = {
        param([System.Collections.IDictionary] $Field)

        ConvertTo-Json -InputObject $Field -Depth 8 -Compress
    }

    # A small but complete run: two legs, one retry, one skip, one failure, a
    # variable resolution and a reboot. Every section of the report has
    # something in it.
    $script:record = @(
        [ordered] @{ ts = '2026-08-13T09:00:00.0000000Z'; runId = 'run-0007'; seq = 1; level = 'Info'; phase = 'WinPE'
            component = 'Engine'; event = 'run.start'; message = 'Run run-0007 starting at step 1 of 4 in the WinPE phase (leg 1)'
            data = [ordered] @{ sequenceId = 'DEMO-M2'; stepIndex = 1; stepCount = 4; leg = 1 }
        }
        [ordered] @{ ts = '2026-08-13T09:00:01.0000000Z'; runId = 'run-0007'; seq = 2; level = 'Info'; phase = 'WinPE'
            component = 'Rules'; event = 'var.resolve'; message = "HDTComputerName = 'PC-FIXTURE-SERIAL-0001' (Rule)"
            data = [ordered] @{ name = 'HDTComputerName'; value = 'PC-FIXTURE-SERIAL-0001'; source = 'Rule'; rule = 'Fallback' }
        }
        [ordered] @{ ts = '2026-08-13T09:00:02.0000000Z'; runId = 'run-0007'; seq = 3; level = 'Info'; phase = 'WinPE'
            stepIndex = 1; stepName = 'Announce'; stepType = 'NoOp'
            component = 'Engine'; event = 'step.start'; message = "step 1 'Announce' (NoOp) starting, attempt 1 of 1"
            data = [ordered] @{ index = 1; name = 'Announce'; type = 'NoOp'; attempt = 1 }
        }
        [ordered] @{ ts = '2026-08-13T09:00:03.0000000Z'; runId = 'run-0007'; seq = 4; level = 'Info'; phase = 'WinPE'
            stepIndex = 1; stepName = 'Announce'; stepType = 'NoOp'
            component = 'Engine'; event = 'step.complete'; message = "step 1 'Announce' completed"; durationMs = 250
            data = [ordered] @{ index = 1; attempt = 1; exitCode = 0 }
        }
        [ordered] @{ ts = '2026-08-13T09:00:04.0000000Z'; runId = 'run-0007'; seq = 5; level = 'Info'; phase = 'WinPE'
            stepIndex = 2; stepName = 'WinPE Only Task'; stepType = 'NoOp'
            component = 'Engine'; event = 'step.skip'
            message = "step 2 'WinPE Only Task' declares runIn WinPE and this leg is running in the FullOS phase"
            data = [ordered] @{ index = 2; name = 'WinPE Only Task'; type = 'NoOp'
                reason = "step 2 'WinPE Only Task' declares runIn WinPE and this leg is running in the FullOS phase"
            }
        }
        [ordered] @{ ts = '2026-08-13T09:00:05.0000000Z'; runId = 'run-0007'; seq = 6; level = 'Info'; phase = 'WinPE'
            stepIndex = 3; stepName = 'Flaky Preflight'; stepType = 'NoOp'
            component = 'Engine'; event = 'step.start'; message = "step 3 'Flaky Preflight' (NoOp) starting, attempt 1 of 3"
            data = [ordered] @{ index = 3; name = 'Flaky Preflight'; type = 'NoOp'; attempt = 1 }
        }
        [ordered] @{ ts = '2026-08-13T09:00:06.0000000Z'; runId = 'run-0007'; seq = 7; level = 'Info'; phase = 'WinPE'
            stepIndex = 3; stepName = 'Flaky Preflight'; stepType = 'NoOp'
            component = 'Engine'; event = 'step.start'; message = "step 3 'Flaky Preflight' (NoOp) starting, attempt 2 of 3"
            data = [ordered] @{ index = 3; name = 'Flaky Preflight'; type = 'NoOp'; attempt = 2 }
        }
        [ordered] @{ ts = '2026-08-13T09:00:07.0000000Z'; runId = 'run-0007'; seq = 8; level = 'Info'; phase = 'WinPE'
            stepIndex = 3; stepName = 'Flaky Preflight'; stepType = 'NoOp'
            component = 'Engine'; event = 'step.complete'; message = "step 3 'Flaky Preflight' completed"; durationMs = 1200
            data = [ordered] @{ index = 3; attempt = 2; exitCode = 0 }
        }
        [ordered] @{ ts = '2026-08-13T09:00:08.0000000Z'; runId = 'run-0007'; seq = 9; level = 'Info'; phase = 'WinPE'
            component = 'AutoLogon'; event = 'reboot.arm'; message = 'Autologon armed for Administrator for 2 more leg(s)'
            data = [ordered] @{ userName = 'Administrator'; domainName = ''; count = 2; secretName = 'DefaultPassword'; runOnceName = 'HDTResume' }
        }
        [ordered] @{ ts = '2026-08-13T09:00:09.0000000Z'; runId = 'run-0007'; seq = 10; level = 'Info'; phase = 'FullOS'
            component = 'Engine'; event = 'reboot.resume'; message = 'Resuming at step 4 on leg 2'
            data = [ordered] @{ leg = 2; stepIndex = 4 }
        }
        [ordered] @{ ts = '2026-08-13T09:00:10.0000000Z'; runId = 'run-0007'; seq = 11; level = 'Info'; phase = 'FullOS'
            stepIndex = 4; stepName = 'Run Installer'; stepType = 'CommandLine'
            component = 'Engine'; event = 'step.start'; message = "step 4 'Run Installer' (CommandLine) starting, attempt 1 of 1"
            data = [ordered] @{ index = 4; name = 'Run Installer'; type = 'CommandLine'; attempt = 1 }
        }
        [ordered] @{ ts = '2026-08-13T09:00:11.0000000Z'; runId = 'run-0007'; seq = 12; level = 'Error'; phase = 'FullOS'
            stepIndex = 4; stepName = 'Run Installer'; stepType = 'CommandLine'
            component = 'Engine'; event = 'step.fail'
            message = 'cmd.exe /c echo "a<b" & echo done returned 1603'; durationMs = 9000
            data = [ordered] @{ index = 4; attempt = 1; exitCode = 1603; failureClass = 'Transient'; timedOut = $false }
        }
        [ordered] @{ ts = '2026-08-13T09:00:12.0000000Z'; runId = 'run-0007'; seq = 13; level = 'Info'; phase = 'FullOS'
            component = 'Engine'; event = 'run.end'; message = 'Run run-0007 ended Failed: 2 completed, 1 failed, 1 skipped'
            data = [ordered] @{ status = 'Failed'; completed = 2; failed = 1; skipped = 1; leg = 2 }
        }
    )

    $script:jsonl = (@($script:record | ForEach-Object { & $script:line $_ }) -join "`n") + "`n"

    # The section extractor. Every assertion about WHERE something appears goes
    # through it, so 'the failing step is called out in the summary' cannot pass
    # because the name happens to appear in the log table.
    $script:section = {
        param([string] $Html, [string] $Id)

        $open = '<section id="{0}">' -f $Id
        $start = $Html.IndexOf($open)
        if ($start -lt 0) {
            return ''
        }

        $start += $open.Length
        $end = $Html.IndexOf('</section>', $start)

        return $Html.Substring($start, $end - $start)
    }

    $script:render = {
        param([string] $Jsonl, [hashtable] $Argument)

        $fs = New-HDTFakeFileSystem -File @{ $script:jsonlPath = $Jsonl }

        $splat = @{ JsonlPath = $script:jsonlPath; Path = $script:reportPath; FileSystem = $fs }
        if ($null -ne $Argument) {
            foreach ($key in @($Argument.Keys)) { $splat[$key] = $Argument[$key] }
        }

        $written = ConvertTo-HDTReport @splat

        return [pscustomobject] @{
            FileSystem = $fs
            Path       = $written
            Html       = $fs.ReadAllText($script:reportPath)
        }
    }
}

Describe 'ConvertTo-HDTReport' {

    BeforeAll {
        $script:report = & $script:render $script:jsonl $null
        $script:html = $script:report.Html
    }

    Context 'reading the stream' {

        It 'reads the jsonl through the injected filesystem' {
            @($script:report.FileSystem.Operations |
                    Where-Object { $_.Operation -eq 'ReadAllText' -and $_.Arguments[0] -eq $script:jsonlPath }).Count |
                Should -BeGreaterThan 0
        }

        It 'writes the report through the injected filesystem' {
            @($script:report.FileSystem.Operations |
                    Where-Object { $_.Operation -eq 'WriteAllText' -and $_.Arguments[0] -eq $script:reportPath }).Count |
                Should -Be 1
        }

        It 'returns the path it wrote' {
            $script:report.Path | Should -BeExactly $script:reportPath
        }

        It 'ignores blank lines' {
            $withBlanks = "`n" + ($script:jsonl -replace "`n", "`n`n")

            $rendered = & $script:render $withBlanks $null

            $rendered.Html | Should -Not -Match 'could not be parsed'
            (& $script:section $rendered.Html 'log') | Should -Match 'run\.end'
        }

        It 'does not fail on a truncated final line' {
            # The machine died mid-write. This is the normal state of the log
            # somebody is opening a report for.
            $truncated = $script:jsonl + '{"ts":"2026-08-13T09:00:13.0000000Z","runId":"run-0007","se'

            $rendered = & $script:render $truncated $null

            $rendered.Html | Should -Match '1 line'
            (& $script:section $rendered.Html 'log') | Should -Match 'run\.end'
        }

        It 'reports the number of unparseable lines in the report' {
            $broken = $script:jsonl + "not json at all`n{oh dear`n"

            $rendered = & $script:render $broken $null

            $rendered.Html | Should -Match '2 line\(s\) could not be parsed'
        }

        It 'produces a report for an empty log' {
            $rendered = & $script:render '' $null

            $rendered.Html | Should -Match '<!DOCTYPE html>'
            $rendered.Html | Should -Match 'No log records'
        }

        It 'throws ObjectNotFound naming the file when the jsonl is missing' {
            $fs = New-HDTFakeFileSystem

            $record = $null
            try {
                ConvertTo-HDTReport -JsonlPath 'C:\HDT\Logs\HDT.jsonl' -Path $script:reportPath -FileSystem $fs
            } catch {
                $record = $_
            }

            $record | Should -Not -BeNullOrEmpty
            $record.CategoryInfo.Category | Should -Be 'ObjectNotFound'
            $record.Exception.Message | Should -BeLike '*HDT.jsonl*'
        }
    }

    Context 'the document' {

        It 'is a complete HTML document' {
            $script:html.TrimStart().StartsWith('<!DOCTYPE html>') | Should -BeTrue
            $script:html.TrimEnd().EndsWith('</html>') | Should -BeTrue
        }

        It 'declares utf-8' {
            $script:html | Should -Match '<meta charset="utf-8">'
        }

        It 'contains no external reference' {
            # A report read from a USB stick on a machine with no network.
            $script:html | Should -Not -Match 'http://'
            $script:html | Should -Not -Match 'https://'
            $script:html | Should -Not -Match '<link'
        }

        It 'contains no script tag at all' {
            $script:html | Should -Not -Match '<script'
        }

        It 'includes the title it was given' {
            $rendered = & $script:render $script:jsonl @{ Title = 'DEMO-M2 deployment report' }

            $rendered.Html | Should -Match '<title>DEMO-M2 deployment report</title>'
            $rendered.Html | Should -Match '<h1>DEMO-M2 deployment report</h1>'
        }
    }

    Context 'the content' {

        It 'names the run id' {
            (& $script:section $script:html 'header') | Should -Match 'run-0007'
        }

        It 'names the sequence id' {
            (& $script:section $script:html 'header') | Should -Match 'DEMO-M2'
        }

        It 'names the computer name' {
            (& $script:section $script:html 'header') | Should -Match 'PC-FIXTURE-SERIAL-0001'
        }

        It 'reports the outcome' {
            (& $script:section $script:html 'header') | Should -Match 'Failed'
        }

        It 'lists every step in index order' {
            $steps = & $script:section $script:html 'steps'

            $order = @('Announce', 'WinPE Only Task', 'Flaky Preflight', 'Run Installer') |
                ForEach-Object { $steps.IndexOf($_) }

            @($order | Where-Object { $_ -lt 0 }).Count | Should -Be 0
            $order | Should -Be (@($order) | Sort-Object)
        }

        It 'shows the status of every step' {
            $steps = & $script:section $script:html 'steps'

            $steps | Should -Match 'Completed'
            $steps | Should -Match 'Skipped'
            $steps | Should -Match 'Failed'
        }

        It 'shows the attempt count for a retried step' {
            $steps = & $script:section $script:html 'steps'

            # The Flaky Preflight row, and the 2 in its attempts cell.
            $row = @($steps -split '<tr' | Where-Object { $_ -match 'Flaky Preflight' })[0]

            $row | Should -Match '>2<'
        }

        It 'shows the exit code of a failed step' {
            $steps = & $script:section $script:html 'steps'

            $row = @($steps -split '<tr' | Where-Object { $_ -match 'Run Installer' })[0]

            $row | Should -Match '1603'
        }

        It 'shows the reason a step was skipped' {
            $steps = & $script:section $script:html 'steps'

            $row = @($steps -split '<tr' | Where-Object { $_ -match 'WinPE Only Task' })[0]

            $row | Should -Match 'declares runIn WinPE'
        }

        It 'marks the failing step' {
            (& $script:section $script:html 'summary') | Should -Match 'Run Installer'
        }

        It 'shows the counts of completed, failed and skipped steps' {
            $summary = & $script:section $script:html 'summary'

            $summary | Should -Match 'Completed'
            $summary | Should -Match 'Skipped'
            $summary | Should -Match '>2<'
            $summary | Should -Match '>1<'
        }

        It 'lists the reboot legs' {
            $legs = & $script:section $script:html 'legs'

            $legs | Should -Match 'reboot\.arm'
            $legs | Should -Match 'reboot\.resume'
        }

        It 'lists variable resolutions with their source' {
            $variables = & $script:section $script:html 'variables'

            $variables | Should -Match 'HDTComputerName'
            $variables | Should -Match 'PC-FIXTURE-SERIAL-0001'
            $variables | Should -Match 'Rule'
        }

        It 'lists every log record' {
            $log = & $script:section $script:html 'log'

            @([regex]::Matches($log, '<tr class="log')).Count | Should -Be $script:record.Count
        }
    }

    Context 'safety' {

        It 'escapes a step message containing angle brackets' {
            $script:html | Should -Not -Match '"a<b"'
            $script:html | Should -Match 'a&lt;b'
        }

        It 'escapes a command line containing an ampersand' {
            $script:html | Should -Match '&amp; echo done'
        }

        It 'does not contain the deployment password' {
            # A report gets emailed. This assertion exists for that reason and
            # for no other.
            $password = 'Hd7!qX2#pL9zV4wR'

            $state = [pscustomobject] ([ordered] @{
                    schemaVersion      = 1
                    runId              = 'run-0007'
                    sequenceId         = 'DEMO-M2'
                    status             = 'Failed'
                    leg                = 2
                    deploymentPassword = $password
                    variable           = [ordered] @{ HDTComputerName = 'PC-FIXTURE-SERIAL-0001' }
                    step               = @(
                        [pscustomobject] ([ordered] @{ index = 1; name = 'Announce'; type = 'NoOp'; group = @('Preinstall')
                                status = 'Completed'; attempt = 1; leg = 1; exitCode = 0; durationMs = 250; message = 'ok'
                            })
                    )
                })

            $rendered = & $script:render $script:jsonl @{ State = $state }

            $rendered.Html | Should -Not -Match ([regex]::Escape($password))
        }

        It 'writes UTF-8 with no byte order mark' {
            # Through the REAL adapter, and asserted on the BYTES: a report whose
            # first three bytes are 239 187 191 renders in a browser with three
            # mojibake characters ahead of the doctype, and is a report nobody
            # trusts.
            $directory = Join-Path -Path $TestDrive -ChildPath 'report'
            $jsonlPath = Join-Path -Path $directory -ChildPath 'HDT.jsonl'
            $htmlPath = Join-Path -Path $directory -ChildPath 'report.html'

            $fs = New-HDTFileSystem
            $fs.WriteAllText($jsonlPath, $script:jsonl)

            ConvertTo-HDTReport -JsonlPath $jsonlPath -Path $htmlPath -FileSystem $fs | Out-Null

            $byte = [System.IO.File]::ReadAllBytes($htmlPath)

            $byte[0] | Should -Be 60      # '<'
            $byte[1] | Should -Be 33      # '!'
        }

        It 'never touches the real filesystem' {
            $rendered = & $script:render $script:jsonl $null

            Test-Path -LiteralPath $script:reportPath | Should -BeFalse
            $rendered.Html | Should -Not -BeNullOrEmpty
        }
    }
}
