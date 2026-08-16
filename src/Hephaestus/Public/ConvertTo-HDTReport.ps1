function ConvertTo-HDTReport {
    <#
        .SYNOPSIS
            Renders a deployment run's HDT.jsonl into one self-contained HTML
            report.

        .DESCRIPTION
            DESIGN 4.4.2: HDT.jsonl is the structured source of truth, and this
            is what turns it into the thing a technician actually opens. Two
            operational facts shape every decision in here.

            IT IS SELF-CONTAINED. Inline CSS, no script, no CDN, no external
            font, no image. A report is read from a USB stick, from a share, and
            from a machine with no network - anything external is a report that
            renders blank exactly when it matters.

            IT TOLERATES A BROKEN LOG. The file is parsed LINE BY LINE: a blank
            line is ignored and a line that does not parse is COUNTED AND
            REPORTED IN THE REPORT rather than thrown. A truncated final line is
            the normal state of a log from a machine that died, which is exactly
            when somebody renders a report. A renderer that throws on it is a
            renderer that never works on the day it is needed.

            EVERYTHING IS ESCAPED, through ConvertTo-HDTHtmlText. A step message
            containing '<' is normal - a command line, an XML fragment - and a
            report that breaks on it is worse than no report.

            THE DEPLOYMENT PASSWORD NEVER APPEARS. The report is built from the
            JSONL, which never carries it, and from -State, from
            which it reads only status, leg and the step records. A report gets
            emailed; that is the whole reason this is a rule rather than a
            preference.

            Sections, in order: the header (run, sequence, computer, phases,
            start, end, duration, outcome), the summary (counts, and the failing
            step called out), the steps in index order, the reboot legs as a
            timeline, the variable resolutions with their source - DESIGN 3.1's
            "explains every value" surfacing in the report - and every log
            record.

        .PARAMETER JsonlPath
            The run's HDT.jsonl, read through the injected filesystem.

        .PARAMETER Path
            Where the report is written, through the same filesystem: UTF-8 with
            no byte order mark, with <meta charset="utf-8"> in the head.

        .PARAMETER FileSystem
            An IFileSystem. A fake in a unit test, New-HDTFileSystem against a
            machine - which is what makes rendering a report provable without
            writing one.

        .PARAMETER State
            The run state document, when one is available. Only its status, its
            leg and its step records are read, which is how a step that never
            reached the log at all still appears in the report as Pending.

        .PARAMETER ComputerName
            The machine this run built. Without it the name is taken from the
            stream's own var.resolve record for HDTComputerName, which is where
            a gathered run puts it - and a run whose gather phase is not in this
            log has no other honest source. It is NOT read from -State: a
            variable map may carry a join password or a share credential, and
            the rule that the report reads only status, leg and the step records
            from the state is what keeps that out of an emailed file.

        .PARAMETER Title
            The page title and heading.

        .PARAMETER Timestamp
            When the report was rendered, for the footer. Omitted rather than
            defaulted, because the engine takes time from an injected clock and
            this function has none.

        .OUTPUTS
            System.String - the path it wrote.

        .EXAMPLE
            ConvertTo-HDTReport -JsonlPath C:\HDT\Logs\HDT.jsonl `
                -Path C:\HDT\Logs\report.html -FileSystem (New-HDTFileSystem)

        .EXAMPLE
            Start-Process (ConvertTo-HDTReport -JsonlPath $log.JsonlPath -Path $out `
                -FileSystem $fs -State $run.State -Title 'DEMO-M2 deployment')

            Render and open, which is how the run reads when it failed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $JsonlPath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $FileSystem,

        [Parameter()]
        [AllowNull()]
        [object] $State,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ComputerName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Title = 'HDT deployment report',

        [Parameter()]
        [AllowNull()]
        [System.Nullable[datetime]] $Timestamp
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $FileSystem.TestPath($JsonlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $JsonlPath `
                    -Message 'the log stream does not exist. A report is rendered from the HDT.jsonl a run wrote (DESIGN 4.4.2).' `
                    -ErrorId 'HDTLogNotFound' -Category ObjectNotFound))
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write deployment report')) {
        return
    }

    # -- the shared little helpers ----------------------------------------
    #
    # Scriptblocks rather than functions: they are private to one renderer, and
    # a module-level function per formatting rule would be six more names in a
    # namespace that already carries the engine.

    $fieldMap = {
        param([object] $Object)

        $map = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Object) {
            foreach ($property in @($Object.PSObject.Properties)) {
                $map[$property.Name] = $property.Value
            }
        }

        return $map
    }

    $escape = {
        param([object] $Value)

        return (ConvertTo-HDTHtmlText -Value $Value)
    }

    $cell = {
        param([object] $Value)

        return ('<td>{0}</td>' -f (ConvertTo-HDTHtmlText -Value $Value))
    }

    $formatDuration = {
        param([object] $Millisecond)

        if ($null -eq $Millisecond -or ([string] $Millisecond) -eq '') {
            return ''
        }

        $value = [double] $Millisecond
        if ($value -lt 1000) {
            return ('{0} ms' -f $value.ToString('0', [System.Globalization.CultureInfo]::InvariantCulture))
        }

        return ('{0} s' -f ($value / 1000).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))
    }

    # 'o' in, HH:mm:ss out. The full stamp is in the log table; a header that
    # repeated it would be unreadable.
    $parseStamp = {
        param([string] $Text)

        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
        if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $parsed)) {
            return $parsed
        }

        return $null
    }

    # -- parse, line by line ----------------------------------------------

    $text = [string] $FileSystem.ReadAllText($JsonlPath)

    $record = New-Object -TypeName System.Collections.ArrayList
    $unparseable = 0

    foreach ($line in @($text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parsed = $null
        try {
            $parsed = ConvertFrom-Json -InputObject $line
        } catch {
            # Counted, never fatal. See the description.
            $unparseable++
            continue
        }

        [void] $record.Add((& $fieldMap $parsed))
    }

    # -- the step model ----------------------------------------------------

    $stepByIndex = @{}
    $stepOrder = New-Object -TypeName System.Collections.ArrayList

    $touchStep = {
        param([int] $Index)

        if (-not $stepByIndex.ContainsKey($Index)) {
            $entry = [pscustomobject] ([ordered] @{
                    Index      = $Index
                    Group      = ''
                    Name       = ''
                    Type       = ''
                    Status     = 'Pending'
                    Attempt    = 0
                    DurationMs = $null
                    ExitCode   = $null
                    Message    = ''
                })

            $stepByIndex[$Index] = $entry
            [void] $stepOrder.Add($entry)
        }

        return $stepByIndex[$Index]
    }

    foreach ($item in $record) {
        if (-not $item.ContainsKey('stepIndex') -or $null -eq $item['stepIndex']) {
            continue
        }

        $entry = & $touchStep ([int] $item['stepIndex'])
        $data = & $fieldMap $item['data']

        if ($item.ContainsKey('stepName') -and -not [string]::IsNullOrEmpty([string] $item['stepName'])) {
            $entry.Name = [string] $item['stepName']
        }
        if ($item.ContainsKey('stepType') -and -not [string]::IsNullOrEmpty([string] $item['stepType'])) {
            $entry.Type = [string] $item['stepType']
        }

        if ($data.ContainsKey('attempt') -and $null -ne $data['attempt']) {
            $attempt = [int] $data['attempt']
            if ($attempt -gt $entry.Attempt) {
                $entry.Attempt = $attempt
            }
        }

        if ($data.ContainsKey('exitCode') -and $null -ne $data['exitCode']) {
            $entry.ExitCode = [int] $data['exitCode']
        }

        if ($item.ContainsKey('durationMs') -and $null -ne $item['durationMs']) {
            $entry.DurationMs = [long] $item['durationMs']
        }

        switch ([string] $item['event']) {
            'step.complete' {
                $entry.Status = 'Completed'
                $entry.Message = [string] $item['message']
            }
            'step.fail' {
                $entry.Status = 'Failed'
                $entry.Message = [string] $item['message']
            }
            'step.skip' {
                # Only from Pending. A step already Completed on an earlier leg
                # logs a step.skip on the next one, and reporting that as Skipped
                # would erase the leg it actually ran on.
                if ($entry.Status -eq 'Pending') {
                    $entry.Status = 'Skipped'
                    $entry.Message = [string] $item['message']
                }
            }
            'step.start' {
                if ($entry.Status -eq 'Pending') {
                    $entry.Status = 'Running'
                }
            }
        }
    }

    # The state fills in what the log cannot: the group path, and every step
    # that never reached the log at all because the run stopped before it.
    if ($null -ne $State -and $null -ne $State.PSObject.Properties['step']) {
        foreach ($row in @($State.step)) {
            $source = & $fieldMap $row
            if (-not $source.ContainsKey('index')) {
                continue
            }

            $entry = & $touchStep ([int] $source['index'])

            if ($source.ContainsKey('group') -and $null -ne $source['group']) {
                $entry.Group = (@($source['group']) -join ' / ')
            }
            if ([string]::IsNullOrEmpty($entry.Name) -and $source.ContainsKey('name')) {
                $entry.Name = [string] $source['name']
            }
            if ([string]::IsNullOrEmpty($entry.Type) -and $source.ContainsKey('type')) {
                $entry.Type = [string] $source['type']
            }
            # THE STATE WINS ON STATUS. A Restart step logs step.start and then
            # the machine goes down - there is no step.complete in the stream,
            # ever - so a status read from the log alone leaves every reboot
            # step Running for good, and a finished deployment renders as one
            # still in progress. The state document is the run's own record of
            # what happened to each step; Pending is the one value that means
            # "the document knows nothing", so the log keeps precedence there.
            if ($source.ContainsKey('status') -and [string] $source['status'] -ne 'Pending') {
                $entry.Status = [string] $source['status']
            }
            if ($entry.Attempt -eq 0 -and $source.ContainsKey('attempt') -and $null -ne $source['attempt']) {
                $entry.Attempt = [int] $source['attempt']
            }
            if ($null -eq $entry.ExitCode -and $source.ContainsKey('exitCode') -and $null -ne $source['exitCode']) {
                $entry.ExitCode = [int] $source['exitCode']
            }
            if ($null -eq $entry.DurationMs -and $source.ContainsKey('durationMs') -and $null -ne $source['durationMs']) {
                $entry.DurationMs = [long] $source['durationMs']
            }
            if ([string]::IsNullOrEmpty($entry.Message) -and $source.ContainsKey('message')) {
                $entry.Message = [string] $source['message']
            }
        }
    }

    $step = @($stepOrder | Sort-Object -Property Index)

    $completedCount = @($step | Where-Object { $_.Status -eq 'Completed' }).Count
    $failedCount = @($step | Where-Object { $_.Status -eq 'Failed' }).Count
    $skippedCount = @($step | Where-Object { $_.Status -eq 'Skipped' }).Count

    $failingStep = @($step | Where-Object { $_.Status -eq 'Failed' })

    # -- the header facts --------------------------------------------------

    $runId = ''
    $sequenceId = ''
    $computerText = ''
    $outcome = 'Unknown'
    $phase = New-Object -TypeName System.Collections.ArrayList
    $legRecord = New-Object -TypeName System.Collections.ArrayList
    $variableRecord = New-Object -TypeName System.Collections.ArrayList

    $legEvent = @('run.start', 'phase.change', 'reboot.arm', 'reboot.resume', 'reboot.teardown', 'run.end')

    foreach ($item in $record) {
        if ([string]::IsNullOrEmpty($runId) -and $item.ContainsKey('runId')) {
            $runId = [string] $item['runId']
        }

        if ($item.ContainsKey('phase') -and -not [string]::IsNullOrEmpty([string] $item['phase']) -and
            $phase -notcontains [string] $item['phase']) {

            [void] $phase.Add([string] $item['phase'])
        }

        $data = & $fieldMap $item['data']
        $eventName = [string] $item['event']

        if ($eventName -eq 'run.start' -and $data.ContainsKey('sequenceId')) {
            $sequenceId = [string] $data['sequenceId']
        }

        if ($eventName -eq 'run.end' -and $data.ContainsKey('status')) {
            $outcome = [string] $data['status']
        }

        if ($eventName -eq 'var.resolve') {
            [void] $variableRecord.Add($item)

            if ($data.ContainsKey('name') -and [string] $data['name'] -eq 'HDTComputerName' -and
                $data.ContainsKey('value')) {

                $computerText = [string] $data['value']
            }
        }

        if ($legEvent -contains $eventName) {
            [void] $legRecord.Add($item)
        }
    }

    if ($outcome -eq 'Unknown' -and $null -ne $State -and $null -ne $State.PSObject.Properties['status']) {
        $outcome = [string] $State.status
    }

    if ($PSBoundParameters.ContainsKey('ComputerName')) {
        $computerText = $ComputerName
    }

    if ([string]::IsNullOrEmpty($computerText)) {
        $computerText = '(not resolved)'
    }

    $startText = ''
    $endText = ''
    $durationText = ''

    if ($record.Count -gt 0) {
        $startText = [string] $record[0]['ts']
        $endText = [string] $record[$record.Count - 1]['ts']

        $startStamp = & $parseStamp $startText
        $endStamp = & $parseStamp $endText

        if ($null -ne $startStamp -and $null -ne $endStamp) {
            $durationText = & $formatDuration ([long] ($endStamp - $startStamp).TotalMilliseconds)
        }
    }

    # -- render ------------------------------------------------------------

    $html = New-Object -TypeName System.Collections.ArrayList
    $add = { param([string] $Line) [void] $html.Add($Line) }

    & $add '<!DOCTYPE html>'
    & $add '<html lang="en">'
    & $add '<head>'
    & $add '<meta charset="utf-8">'
    & $add ('<title>{0}</title>' -f (& $escape $Title))
    & $add '<style>'
    & $add 'body { font-family: Segoe UI, Tahoma, sans-serif; margin: 1.5rem; color: #202020; background: #ffffff; }'
    & $add 'h1 { font-size: 1.5rem; } h2 { font-size: 1.1rem; margin-top: 1.8rem; border-bottom: 1px solid #d0d0d0; padding-bottom: 0.2rem; }'
    & $add 'table { border-collapse: collapse; width: 100%; margin-top: 0.5rem; }'
    & $add 'th, td { border: 1px solid #d8d8d8; padding: 0.25rem 0.5rem; text-align: left; vertical-align: top; font-size: 0.85rem; }'
    & $add 'th { background: #f2f2f2; }'
    & $add 'td.msg { font-family: Consolas, monospace; white-space: pre-wrap; word-break: break-word; }'
    & $add '.status-completed { background: #e6f4ea; } .status-failed { background: #fce8e6; }'
    & $add '.status-skipped { background: #f5f5f5; color: #606060; } .status-pending { background: #fffbe6; }'
    & $add '.status-running { background: #e8f0fe; }'
    & $add '.level-error td { color: #9b1c1c; } .level-warning td { color: #8a6100; } .level-debug td { color: #606060; }'
    & $add '.warn { background: #fce8e6; padding: 0.4rem 0.6rem; border: 1px solid #f0b3ae; }'
    & $add '.count { font-size: 1.2rem; font-weight: 600; }'
    & $add '</style>'
    & $add '</head>'
    & $add '<body>'
    & $add ('<h1>{0}</h1>' -f (& $escape $Title))

    if ($unparseable -gt 0) {
        & $add ('<p class="warn">{0} line(s) could not be parsed and are not shown below. A truncated final line is what a machine that died mid-write leaves behind.</p>' -f $unparseable)
    }

    # 1. Header.
    & $add '<h2>Run</h2>'
    & $add '<section id="header">'
    & $add '<table>'
    & $add ('<tr><th>Run id</th>{0}</tr>' -f (& $cell $runId))
    & $add ('<tr><th>Sequence</th>{0}</tr>' -f (& $cell $sequenceId))
    & $add ('<tr><th>Computer</th>{0}</tr>' -f (& $cell $computerText))
    & $add ('<tr><th>Phases</th>{0}</tr>' -f (& $cell (@($phase) -join ', ')))
    & $add ('<tr><th>Started</th>{0}</tr>' -f (& $cell $startText))
    & $add ('<tr><th>Ended</th>{0}</tr>' -f (& $cell $endText))
    & $add ('<tr><th>Duration</th>{0}</tr>' -f (& $cell $durationText))
    & $add ('<tr><th>Outcome</th><td class="status-{0}">{1}</td></tr>' -f $outcome.ToLowerInvariant(), (& $escape $outcome))
    & $add '</table>'
    & $add '</section>'

    # 2. Summary.
    & $add '<h2>Summary</h2>'
    & $add '<section id="summary">'
    & $add '<table>'
    & $add '<tr><th>Completed</th><th>Failed</th><th>Skipped</th><th>Total</th></tr>'
    & $add ('<tr><td class="count status-completed">{0}</td><td class="count status-failed">{1}</td><td class="count status-skipped">{2}</td><td class="count">{3}</td></tr>' -f
        $completedCount, $failedCount, $skippedCount, @($step).Count)
    & $add '</table>'

    if ($failingStep.Count -gt 0) {
        & $add ('<p class="warn">Step {0} &quot;{1}&quot; ({2}) failed: {3}</p>' -f
            $failingStep[0].Index, (& $escape $failingStep[0].Name), (& $escape $failingStep[0].Type), (& $escape $failingStep[0].Message))
    }

    & $add '</section>'

    # 3. Steps.
    & $add '<h2>Steps</h2>'
    & $add '<section id="steps">'
    & $add '<table>'
    & $add '<tr><th>#</th><th>Group</th><th>Name</th><th>Type</th><th>Status</th><th>Attempts</th><th>Duration</th><th>Exit code</th><th>Message</th></tr>'

    if (@($step).Count -eq 0) {
        & $add '<tr><td colspan="9">No steps were recorded.</td></tr>'
    }

    foreach ($row in $step) {
        & $add ('<tr class="step status-{0}">{1}{2}{3}{4}{5}{6}{7}{8}<td class="msg">{9}</td></tr>' -f
            ([string] $row.Status).ToLowerInvariant(),
            (& $cell $row.Index),
            (& $cell $row.Group),
            (& $cell $row.Name),
            (& $cell $row.Type),
            (& $cell $row.Status),
            (& $cell $row.Attempt),
            (& $cell (& $formatDuration $row.DurationMs)),
            (& $cell $row.ExitCode),
            (& $escape $row.Message))
    }

    & $add '</table>'
    & $add '</section>'

    # 4. Legs - the multi-leg deployment as a timeline.
    & $add '<h2>Legs and reboots</h2>'
    & $add '<section id="legs">'
    & $add '<table>'
    & $add '<tr><th>Seq</th><th>Time</th><th>Phase</th><th>Event</th><th>Message</th></tr>'

    if ($legRecord.Count -eq 0) {
        & $add '<tr><td colspan="5">No run or reboot records.</td></tr>'
    }

    foreach ($item in $legRecord) {
        & $add ('<tr class="leg">{0}{1}{2}{3}<td class="msg">{4}</td></tr>' -f
            (& $cell $item['seq']),
            (& $cell $item['ts']),
            (& $cell $item['phase']),
            (& $cell $item['event']),
            (& $escape $item['message']))
    }

    & $add '</table>'
    & $add '</section>'

    # 5. Variables - DESIGN 3.1's "explains every value", in the report.
    & $add '<h2>Variables</h2>'
    & $add '<section id="variables">'
    & $add '<table>'
    & $add '<tr><th>Seq</th><th>Name</th><th>Value</th><th>Source</th><th>Rule</th></tr>'

    if ($variableRecord.Count -eq 0) {
        & $add '<tr><td colspan="5">No variable resolutions were recorded.</td></tr>'
    }

    foreach ($item in $variableRecord) {
        $data = & $fieldMap $item['data']

        $name = ''
        if ($data.ContainsKey('name')) { $name = $data['name'] }

        $value = ''
        if ($data.ContainsKey('value')) { $value = $data['value'] }

        $source = ''
        if ($data.ContainsKey('source')) { $source = $data['source'] }

        $rule = ''
        if ($data.ContainsKey('rule')) { $rule = $data['rule'] }
        if ([string]::IsNullOrEmpty([string] $rule) -and $data.ContainsKey('step')) { $rule = $data['step'] }

        & $add ('<tr class="var">{0}{1}{2}{3}{4}</tr>' -f
            (& $cell $item['seq']), (& $cell $name), (& $cell $value), (& $cell $source), (& $cell $rule))
    }

    & $add '</table>'
    & $add '</section>'

    # 6. The log itself.
    & $add '<h2>Log</h2>'
    & $add '<section id="log">'
    & $add '<table>'
    & $add '<tr><th>Seq</th><th>Time</th><th>Level</th><th>Phase</th><th>Step</th><th>Component</th><th>Event</th><th>Message</th></tr>'

    if ($record.Count -eq 0) {
        & $add '<tr><td colspan="8">No log records were found in this stream.</td></tr>'
    }

    foreach ($item in $record) {
        $stepText = ''
        if ($item.ContainsKey('stepIndex') -and $null -ne $item['stepIndex']) {
            $stepText = '{0}. {1}' -f $item['stepIndex'], $item['stepName']
        }

        & $add ('<tr class="log level-{0}">{1}{2}{3}{4}{5}{6}{7}<td class="msg">{8}</td></tr>' -f
            ([string] $item['level']).ToLowerInvariant(),
            (& $cell $item['seq']),
            (& $cell $item['ts']),
            (& $cell $item['level']),
            (& $cell $item['phase']),
            (& $cell $stepText),
            (& $cell $item['component']),
            (& $cell $item['event']),
            (& $escape $item['message']))
    }

    & $add '</table>'
    & $add '</section>'

    $footer = 'Rendered by HDT from {0}' -f $JsonlPath
    if ($PSBoundParameters.ContainsKey('Timestamp')) {
        # $Timestamp, not $Timestamp.Value: the binder converts a bound
        # [System.Nullable[datetime]] to a plain [datetime], so .Value is a
        # property that does not exist - and under Set-StrictMode that throws.
        $footer = '{0} at {1}' -f $footer,
        $Timestamp.ToUniversalTime().ToString('u', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    & $add ('<p class="footer">{0}</p>' -f (& $escape $footer))
    & $add '</body>'
    & $add '</html>'

    $FileSystem.WriteAllText($Path, ((@($html) -join "`n") + "`n"))

    return $Path
}
