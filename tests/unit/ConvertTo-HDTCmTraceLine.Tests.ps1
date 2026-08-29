# DESIGN 4.4.2's second format: one physical CMTrace line per log call, so an
# administrator's existing CMTrace/OneTrace workflow reads an HDT deployment on
# day one.
#
# The function is pure - timestamp, component, thread and file in, one string out
# - so every assertion here is exact rather than approximate.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:stamp = [datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)
}

Describe 'ConvertTo-HDTCmTraceLine' {

    It 'wraps the message in the LOG marker' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'Applied index 1 to W:\ in 95s' -Component 'ImageService' `
                -Severity 'Info' -Timestamp $Stamp -ThreadId 4820 -File 'Invoke-HDTApplyImage.ps1'
        }

        # StartsWith, not -BeLike: '[' opens a character class in a wildcard
        # pattern, and this format is made of square brackets.
        $line.StartsWith('<![LOG[Applied index 1 to W:\ in 95s]LOG]!><') | Should -BeTrue
    }

    It 'emits the exact DESIGN 4.4.2 line' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'Applied index 1' -Component 'ImageService' `
                -Severity 'Info' -Timestamp $Stamp -ThreadId 4820 -File 'Invoke-HDTApplyImage.ps1' `
                -TimeZone ([System.TimeZoneInfo]::Utc)
        }

        $line | Should -BeExactly ('<![LOG[Applied index 1]LOG]!><time="00:11:02.481+000" date="08-13-2026" ' +
            'component="ImageService" context="" type="1" thread="4820" file="Invoke-HDTApplyImage.ps1">')
    }

    It 'formats the time as HH:mm:ss.fff and an offset' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1' -TimeZone ([System.TimeZoneInfo]::Utc)
        }

        $line | Should -BeLike '*time="00:11:02.481+000"*'
    }

    It 'formats the date as MM-dd-yyyy' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1' -TimeZone ([System.TimeZoneInfo]::Utc)
        }

        $line | Should -BeLike '*date="08-13-2026"*'
    }

    It 'maps <Severity> to type <Type>' -ForEach @(
        @{ Severity = 'Info'; Type = '1' }
        @{ Severity = 'Debug'; Type = '1' }
        @{ Severity = 'Warning'; Type = '2' }
        @{ Severity = 'Error'; Type = '3' }
    ) {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp; Severity = $Severity } {
            param($Stamp, $Severity)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity $Severity `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line | Should -BeLike ('*type="{0}"*' -f $Type)
    }

    # CMTRACE HAS NO DEBUG, AND HDT DOES NOT INVENT ONE.
    #
    # The type field is 1 = Info, 2 = Warning, 3 = Error and nothing else; a
    # fourth value would lose CMTrace's colouring and filtering, which is the
    # entire reason this format was chosen. MDT hits the same wall and answers
    # it the same way - ZTIUtility.vbs defines LogTypeVerbose = 4 and then
    # rewrites it to LogTypeInfo before the line is written.
    #
    # SO THE LEVEL IS SAID IN THE ONE FIELD A TECHNICIAN READS. The Log Text
    # column is what CMTrace shows and what its filter box searches, so a
    # "[DEBUG] " prefix is both visible at a glance and filterable, and it
    # answers the complaint that started this: eighty resolution records that
    # looked exactly like Info. The JSONL keeps the real level either way, so
    # nothing machine-read depends on this.
    It 'says DEBUG in the message, because the type field cannot' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'HDTComputerName = ...' -Component 'Variable' -Severity 'Debug' `
                -Timestamp $Stamp -ThreadId 1 -File 'Engine'
        }

        # -Match with an escaped literal, not -BeLike: a wildcard pattern reads
        # '[' as a character class and would match almost anything here.
        $line | Should -Match ([regex]::Escape('<![LOG[[DEBUG] HDTComputerName = ...]LOG]!>'))
        $line | Should -BeLike '*type="1"*'
    }

    It 'says nothing extra at <Severity>, which is every level that is not Debug' -ForEach @(
        @{ Severity = 'Info' }, @{ Severity = 'Warning' }, @{ Severity = 'Error' }
    ) {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp; Severity = $Severity } {
            param($Stamp, $Severity)
            ConvertTo-HDTCmTraceLine -Message 'plain' -Component 'Engine' -Severity $Severity `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line | Should -Match ([regex]::Escape('<![LOG[plain]LOG]!>'))
    }

    It 'emits exactly one physical line for a multi-line message' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message "first`r`nsecond`nthird`rfourth" -Component 'Engine' `
                -Severity 'Error' -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        @($line -split "`n").Count | Should -Be 1
        $line | Should -Not -Match "`r"
    }

    It 'replaces a CRLF in the message with a space' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message "first`r`nsecond" -Component 'Engine' `
                -Severity 'Error' -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line.StartsWith('<![LOG[first second]LOG]!>') | Should -BeTrue
    }

    It 'emits the whole line in the invariant culture' {
        # A German culture renders a dotted date and a comma decimal separator. A
        # CMTrace parser expects neither, and the engine ships to machines whose
        # culture nobody chose.
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = New-Object -TypeName System.Globalization.CultureInfo -ArgumentList 'de-DE'

            $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
                param($Stamp)
                ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                    -Timestamp $Stamp -ThreadId 4820 -File 'a.ps1' -TimeZone ([System.TimeZoneInfo]::Utc)
            }

            $line | Should -BeExactly ('<![LOG[x]LOG]!><time="00:11:02.481+000" date="08-13-2026" ' +
                'component="Engine" context="" type="1" thread="4820" file="a.ps1">')
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }

    It 'includes the thread id it was given' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 12345 -File 'a.ps1'
        }

        $line | Should -BeLike '*thread="12345"*'
    }

    It 'includes the file it was given' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'Update-VendorBios.ps1'
        }

        $line | Should -BeLike '*file="Update-VendorBios.ps1">'
    }

    It 'leaves context empty' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line | Should -BeLike '*context=""*'
    }

    # ------------------------------------------------------------------------
    # LOCAL WALL CLOCK, AND THE REAL BIAS - the defect this section was written
    # for. The engine stamps every record with GetUtcNow(), and the line used to
    # render that UTC instant verbatim under a hardcoded "+000". On the Dell run
    # of 2026-08-29 that put time="20:43:07.612+000" in HDT.log while the
    # technician's watch read 22:43 - a log that disagrees with the wall clock
    # by a whole time zone, and says in its own offset field that it does not.
    #
    # MICROSOFT'S OWN WRITERS SETTLE THE SHAPE, and both are on disk here:
    #
    #   ZTIUtility.vbs:194 builds sTime from Now() - LOCAL - and appends the
    #   literal ".000+000". MDT writes local time and does not bother computing
    #   the field. OSDEndTime.vbs:17 reads ActiveTimeBias when it wants UTC,
    #   which is the other half of the same statement: local is what is written,
    #   UTC is what is derived.
    #
    #   The ConfigMgr client writes the field properly. 49,096 lines captured
    #   from a real client on a UTC+3 machine carry, without exception:
    #
    #     <![LOG[Starting CCMEXEC service...]LOG]!><time="12:07:10.740-180" date="04-22-2026"
    #
    #   -180 on a machine three hours AHEAD of UTC. That is ActiveTimeBias, not
    #   an ISO offset: UTC = local + bias, so the sign is inverted relative to
    #   "+03:00", and the registry on this host agrees (ActiveTimeBias =
    #   0xffffff4c = -180). PSD reaches for the opposite sign in
    #   PSDUtility.psm1:215 - it appends GetUtcOffset().TotalMinutes, which
    #   yields "180" with no sign at all east of Greenwich - and is wrong for it.
    #
    # SO: local time, ActiveTimeBias in the offset field. On a UTC machine that
    # is byte-for-byte the line MDT ships.

    It 'renders the instant in the given zone, not UTC' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1' `
                -TimeZone ([System.TimeZoneInfo]::FindSystemTimeZoneById('Israel Standard Time'))
        }

        # 00:11:02.481Z on 13 August is 03:11:02.481 in Israel's summer time.
        $line | Should -BeLike '*time="03:11:02.481-180"*'
        $line | Should -BeLike '*date="08-13-2026"*'
    }

    # THE OFFSET IN FORCE AT THE INSTANT OF THE RECORD, not the one in force
    # when the line is rendered. Israel is UTC+3 in August and UTC+2 in January;
    # a log written across a DST boundary - or replayed later - must carry the
    # bias each record actually had.
    It 'carries ActiveTimeBias <Bias> for <Zone> at <Utc>' -ForEach @(
        @{ Zone = 'Israel Standard Time';  Utc = '2026-08-13T00:11:02Z'; Bias = '-180'; Local = '03:11:02' }
        @{ Zone = 'Israel Standard Time';  Utc = '2026-01-13T00:11:02Z'; Bias = '-120'; Local = '02:11:02' }
        @{ Zone = 'Pacific Standard Time'; Utc = '2026-08-13T00:11:02Z'; Bias = '+420'; Local = '17:11:02' }
        @{ Zone = 'Pacific Standard Time'; Utc = '2026-01-13T00:11:02Z'; Bias = '+480'; Local = '16:11:02' }
        @{ Zone = 'India Standard Time';   Utc = '2026-08-13T00:11:02Z'; Bias = '-330'; Local = '05:41:02' }
        @{ Zone = 'UTC';                   Utc = '2026-08-13T00:11:02Z'; Bias = '+000'; Local = '00:11:02' }
    ) {
        $line = InModuleScope Hephaestus -Parameters @{ Zone = $Zone; Utc = $Utc } {
            param($Zone, $Utc)
            $style = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
                [System.Globalization.DateTimeStyles]::AssumeUniversal
            $stamp = [datetime]::Parse($Utc, [System.Globalization.CultureInfo]::InvariantCulture, $style)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $stamp -ThreadId 1 -File 'a.ps1' `
                -TimeZone ([System.TimeZoneInfo]::FindSystemTimeZoneById($Zone))
        }

        $line | Should -BeLike ('*time="{0}.000{1}"*' -f $Local, $Bias)
    }

    # A UTC MACHINE STILL GETS MDT'S EXACT LINE. WinPE boots with its time zone
    # unset, which Windows reports as UTC - so the WinPE leg renders precisely
    # what it rendered before this change, and nothing had to special-case it.
    It 'writes +000 on a machine whose zone is UTC, exactly as MDT does' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'Applied index 1' -Component 'ImageService' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 4820 -File 'Invoke-HDTApplyImage.ps1' `
                -TimeZone ([System.TimeZoneInfo]::Utc)
        }

        $line | Should -BeExactly ('<![LOG[Applied index 1]LOG]!><time="00:11:02.481+000" date="08-13-2026" ' +
            'component="ImageService" context="" type="1" thread="4820" file="Invoke-HDTApplyImage.ps1">')
    }

    # A ZONE BEHIND GREENWICH ROLLS THE DATE BACK, and the date field has to go
    # with it or a technician reads the right time on the wrong day.
    It 'moves the date with the time when the local day differs' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1' `
                -TimeZone ([System.TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time'))
        }

        $line | Should -BeLike '*time="17:11:02.481+420"*'
        $line | Should -BeLike '*date="08-12-2026"*'
    }

    # THE ENGINE HANDS OVER Clock.GetUtcNow(), so Utc is the kind that matters -
    # but an Unspecified kind reaches here from anything that round-tripped
    # through YAML or JSON, and treating it as local would shift every such
    # record by the machine's own offset. Unspecified means UTC, because that is
    # what every producer in this module writes.
    It 'treats a <Kind> timestamp as the same instant' -ForEach @(
        @{ Kind = 'Utc' }, @{ Kind = 'Unspecified' }, @{ Kind = 'Local' }
    ) {
        $line = InModuleScope Hephaestus -Parameters @{ Kind = $Kind } {
            param($Kind)

            # One instant, expressed three ways. The Local case is built from
            # the machine's own zone so it names the same moment as the others.
            $utc = [datetime]::new(2026, 8, 13, 0, 11, 2, 481, [System.DateTimeKind]::Utc)
            $stamp = $utc
            if ($Kind -eq 'Unspecified') {
                $stamp = [datetime]::SpecifyKind($utc, [System.DateTimeKind]::Unspecified)
            }
            if ($Kind -eq 'Local') {
                $stamp = $utc.ToLocalTime()
            }

            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $stamp -ThreadId 1 -File 'a.ps1' `
                -TimeZone ([System.TimeZoneInfo]::FindSystemTimeZoneById('Israel Standard Time'))
        }

        $line | Should -BeLike '*time="03:11:02.481-180"*'
    }

    # THE DEFAULT IS THE MACHINE, because Write-HDTLog does not pass a zone and
    # a deployment log is read on the machine that wrote it.
    It 'uses the machine time zone when none is given' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $zone = [System.TimeZoneInfo]::Local
        $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($script:stamp, $zone)
        $bias = ([int] [Math]::Round(-$zone.GetUtcOffset($script:stamp).TotalMinutes)).ToString('+000;-000', $invariant)

        $line | Should -BeLike ('*time="{0}{1}"*' -f $local.ToString('HH:mm:ss.fff', $invariant), $bias)
        $line | Should -BeLike ('*date="{0}"*' -f $local.ToString('MM-dd-yyyy', $invariant))
    }

    # THE FIELD IS SIGNED AND THREE DIGITS WIDE in every ConfigMgr log captured
    # here, and a reader that splits on the sign would choke on a bare "180".
    It 'always signs the offset and pads it to three digits' {
        $line = InModuleScope Hephaestus -Parameters @{ Stamp = $script:stamp } {
            param($Stamp)
            ConvertTo-HDTCmTraceLine -Message 'x' -Component 'Engine' -Severity 'Info' `
                -Timestamp $Stamp -ThreadId 1 -File 'a.ps1'
        }

        $line | Should -Match 'time="\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{3,4}"'
    }

    It 'is private' {
        Get-Command -Name ConvertTo-HDTCmTraceLine -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
