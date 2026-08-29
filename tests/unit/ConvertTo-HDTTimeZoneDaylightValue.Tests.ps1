# THE HALF OF THE TIME ZONE KEY DISM DOES NOT WRITE.
#
# Measured on the live Dell run: every WinPE timestamp was exactly one hour
# ahead of true UTC. The reason was NOT that WinPE refuses to perform daylight
# transitions - it is that the image was never given a daylight rule to perform.
# dism /Image:<mount> /Set-TimeZone:"Israel Standard Time" writes the STANDARD
# half of HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation and stops:
#
#   Bias                        -120        correct
#   StandardBias                0           correct
#   DaylightBias                0           WRONG - the zone's rule says -60
#   DaylightName                (empty)     absent
#   StandardStart               all zeros   no rule
#   DaylightStart               all zeros   no rule
#   ActiveTimeBias              ABSENT      so the kernel falls back to
#                                           Bias + StandardBias = -120
#   DynamicDaylightTimeDisabled 1           and dynamic DST is switched OFF
#
# -120 instead of -180 is the missing hour, exactly. The same key on a full
# Windows install of the same zone carries DaylightBias -60, ActiveTimeBias
# -180 and DynamicDaylightTimeDisabled 0, and w32tm /tz there reports
# TIME_ZONE_ID_DAYLIGHT.
#
# THIS COMMAND EMITS THE MISSING HALF, AND NOTHING THAT IS A MOMENT. Every
# value it produces is year-agnostic: the transition SYSTEMTIMEs carry wYear 0,
# which is Windows' encoding for the RECURRING rule "the wDay-th wDayOfWeek of
# wMonth", evaluated by the kernel against whatever date the machine boots on.
# An image built in August is therefore still right in November.
#
# ActiveTimeBias IS THE ONE VALUE THAT IS A MOMENT, and this command refuses to
# emit it for that reason - see the test that says so. Writing it would bake the
# build day's answer into an image that is booted for months, which is the
# failure this fix exists to avoid rather than to relocate.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    # REAL CAPTURED DATA - the REG_TZI_FORMAT blob out of the ADK's own WinPE
    # registry. See the fixture's own header for how it was read.
    $script:fixture = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot `
            -ChildPath 'tests/fixtures/winpe/timezone-israel-tzi.json') -Raw | ConvertFrom-Json

    # A zone built by hand rather than read off this host: the rules a build
    # machine happens to carry are that machine's, and a test that asserted on
    # them would pass or fail according to which Windows update it had.
    function New-HDTTestTimeZone {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory TimeZoneInfo for a test; it changes no system state and never touches this host''s own zone.')]
        [CmdletBinding()]
        [OutputType([System.TimeZoneInfo])]
        param(
            [string] $Id,
            [timespan] $BaseOffset,
            [timespan] $DaylightDelta,
            [int] $StartMonth,
            [int] $StartWeek,
            [System.DayOfWeek] $StartDay,
            [int] $EndMonth,
            [int] $EndWeek,
            [System.DayOfWeek] $EndDay
        )

        $timeOfDay = [datetime]::new(1, 1, 1, 2, 0, 0)

        $start = [System.TimeZoneInfo+TransitionTime]::CreateFloatingDateRule(
            $timeOfDay, $StartMonth, $StartWeek, $StartDay)
        $end = [System.TimeZoneInfo+TransitionTime]::CreateFloatingDateRule(
            $timeOfDay, $EndMonth, $EndWeek, $EndDay)

        $rule = [System.TimeZoneInfo+AdjustmentRule]::CreateAdjustmentRule(
            [datetime]::new(2023, 1, 1), [datetime]::MaxValue.Date, $DaylightDelta, $start, $end)

        return [System.TimeZoneInfo]::CreateCustomTimeZone($Id, $BaseOffset, $Id,
            ('{0} Standard' -f $Id), ('{0} Daylight' -f $Id), @($rule))
    }

    # Israel's shape, as the ADK's WinPE database actually records it: base
    # UTC+02:00, one hour of daylight, last Friday of March to last Sunday of
    # October, both at 02:00.
    $script:israel = New-HDTTestTimeZone -Id 'Israel Standard Time' `
        -BaseOffset ([timespan]::FromHours(2)) -DaylightDelta ([timespan]::FromHours(1)) `
        -StartMonth 3 -StartWeek 5 -StartDay ([System.DayOfWeek]::Friday) `
        -EndMonth 10 -EndWeek 5 -EndDay ([System.DayOfWeek]::Sunday)

    $script:value = @(ConvertTo-HDTTimeZoneDaylightValue -TimeZone $script:israel)

    function Get-HDTTestValue {
        param([object[]] $Value, [string] $Name)

        return @($Value | Where-Object { $_.Name -eq $Name })
    }
}

Describe 'ConvertTo-HDTTimeZoneDaylightValue' {

    Context 'the values it emits' {

        It 'emits the daylight bias the zone declares, as a negative DWord' {
            # Windows' sign convention: UTC = local + bias, so an hour of
            # daylight REDUCES the bias by 60. -120 + -60 = -180, which is the
            # ActiveTimeBias a correct machine computes and the exact hour the
            # Dell run was out by.
            $row = @(Get-HDTTestValue -Value $script:value -Name 'DaylightBias')

            $row.Count | Should -Be 1
            $row[0].Data | Should -Be -60
            $row[0].Kind | Should -BeExactly 'DWord'
        }

        It 'emits the daylight name, which dism leaves empty' {
            $row = @(Get-HDTTestValue -Value $script:value -Name 'DaylightName')

            $row.Count | Should -Be 1
            $row[0].Data | Should -BeExactly 'Israel Standard Time Daylight'
            $row[0].Kind | Should -BeExactly 'String'
        }

        It 'clears DynamicDaylightTimeDisabled, which WinPE ships set' {
            # The ADK's stock WinPE key carries 1, and dism leaves it at 1. A
            # machine told not to use dynamic daylight time will not use it
            # however good the rule beside it is.
            $row = @(Get-HDTTestValue -Value $script:value -Name 'DynamicDaylightTimeDisabled')

            $row.Count | Should -Be 1
            $row[0].Data | Should -Be 0
            $row[0].Kind | Should -BeExactly 'DWord'
        }

        It 'encodes the daylight transition exactly as the ADK image records it' {
            # Byte-for-byte against REAL CAPTURED DATA: the DaylightDate half of
            # the TZI blob in the ADK's own winpe.wim. If this drifts, the
            # encoder and Windows no longer agree.
            $row = @(Get-HDTTestValue -Value $script:value -Name 'DaylightStart')

            $row.Count | Should -Be 1
            $row[0].Kind | Should -BeExactly 'Binary'
            @([byte[]] $row[0].Data) | Should -Be @([byte[]] $script:fixture.daylightDate)
        }

        It 'encodes the standard transition exactly as the ADK image records it' {
            $row = @(Get-HDTTestValue -Value $script:value -Name 'StandardStart')

            $row.Count | Should -Be 1
            $row[0].Kind | Should -BeExactly 'Binary'
            @([byte[]] $row[0].Data) | Should -Be @([byte[]] $script:fixture.standardDate)
        }
    }

    Context 'the moment it refuses to bake' {

        It 'never emits ActiveTimeBias' {
            # THE WHOLE POINT. ActiveTimeBias is the only value in that key that
            # answers "is it daylight time RIGHT NOW", and an image is booted for
            # months after it is built. Left absent, the kernel computes it at
            # every boot from the recurring rule beside it - which is how a full
            # Windows machine comes up correct the morning after a transition
            # with no service running. Writing it here would make an image built
            # in August wrong from the last Sunday of October.
            @(Get-HDTTestValue -Value $script:value -Name 'ActiveTimeBias').Count | Should -Be 0
        }

        It 'writes a recurring rule rather than a date, in both transitions' {
            # wYear 0 is Windows' encoding for "the wDay-th wDayOfWeek of
            # wMonth, every year". A non-zero year would name one specific
            # transition and expire.
            foreach ($name in @('DaylightStart', 'StandardStart')) {
                $data = [byte[]] (@(Get-HDTTestValue -Value $script:value -Name $name))[0].Data

                [BitConverter]::ToUInt16($data, 0) | Should -Be 0 -Because "$name must carry no year"
            }
        }

        It 'leaves every value dism already wrote alone' {
            # Bias, StandardBias, StandardName and TimeZoneKeyName are dism's,
            # and dism gets them right. Re-writing them here would make this the
            # second place that decides them.
            $name = @($script:value | ForEach-Object { $_.Name })

            foreach ($written in @('Bias', 'StandardBias', 'StandardName', 'TimeZoneKeyName')) {
                $name | Should -Not -Contain $written
            }
        }
    }

    Context 'zones with nothing to add' {

        It 'emits nothing for a zone that has no daylight saving' {
            # India, UTC, Arizona. dism's half IS the whole key for these, and a
            # DaylightBias of 0 written beside a cleared DynamicDaylightTimeDisabled
            # would be a rule that says "shift by nothing" rather than no rule.
            $flat = [System.TimeZoneInfo]::CreateCustomTimeZone('HDT Flat Time',
                [timespan]::FromHours(5.5), 'HDT Flat Time', 'HDT Flat Standard')

            @(ConvertTo-HDTTimeZoneDaylightValue -TimeZone $flat).Count | Should -Be 0
        }

        It 'emits nothing for a zone this host resolves without daylight saving' {
            @(ConvertTo-HDTTimeZoneDaylightValue -Id 'UTC').Count | Should -Be 0
        }
    }

    Context 'the shapes it refuses' {

        It 'refuses a fixed-date rule, which the registry format cannot express' {
            # REG_TZI_FORMAT has no "the 5th of March every year" encoding: with
            # wYear 0 the fields mean week-and-weekday, so a fixed rule written
            # into them would silently become a different date. .NET can carry
            # one; Windows' registry cannot.
            $timeOfDay = [datetime]::new(1, 1, 1, 2, 0, 0)
            $start = [System.TimeZoneInfo+TransitionTime]::CreateFixedDateRule($timeOfDay, 3, 25)
            $end = [System.TimeZoneInfo+TransitionTime]::CreateFixedDateRule($timeOfDay, 10, 25)
            $rule = [System.TimeZoneInfo+AdjustmentRule]::CreateAdjustmentRule(
                [datetime]::new(2023, 1, 1), [datetime]::MaxValue.Date,
                [timespan]::FromHours(1), $start, $end)
            $fixed = [System.TimeZoneInfo]::CreateCustomTimeZone('HDT Fixed Time',
                [timespan]::FromHours(2), 'HDT Fixed Time', 'HDT Fixed Standard',
                'HDT Fixed Daylight', @($rule))

            { ConvertTo-HDTTimeZoneDaylightValue -TimeZone $fixed } |
                Should -Throw -ExpectedMessage '*fixed*'
        }

        It 'names the zone when this host has never heard of it' {
            # Get-HDTTimeZone's header already says it: a workspace is edited on
            # one machine and built on another, and Windows adds time zones. The
            # build must say which id it could not resolve rather than fail with
            # .NET's own sentence.
            { ConvertTo-HDTTimeZoneDaylightValue -Id 'Hephaestus Standard Time' } |
                Should -Throw -ExpectedMessage '*Hephaestus Standard Time*'
        }
    }

    Context 'the southern hemisphere, where daylight time spans new year' {

        It 'keeps the transitions in the order the zone declares them' {
            # Sydney: daylight starts in OCTOBER and ends in APRIL. An encoder
            # that sorted the two transitions, or assumed start month is less
            # than end month, would swap them and shift the year backwards.
            $south = New-HDTTestTimeZone -Id 'HDT South Time' `
                -BaseOffset ([timespan]::FromHours(10)) -DaylightDelta ([timespan]::FromHours(1)) `
                -StartMonth 10 -StartWeek 1 -StartDay ([System.DayOfWeek]::Sunday) `
                -EndMonth 4 -EndWeek 1 -EndDay ([System.DayOfWeek]::Sunday)

            $value = @(ConvertTo-HDTTimeZoneDaylightValue -TimeZone $south)

            $daylight = [byte[]] (@(Get-HDTTestValue -Value $value -Name 'DaylightStart'))[0].Data
            $standard = [byte[]] (@(Get-HDTTestValue -Value $value -Name 'StandardStart'))[0].Data

            [BitConverter]::ToUInt16($daylight, 2) | Should -Be 10
            [BitConverter]::ToUInt16($standard, 2) | Should -Be 4
        }
    }
}
