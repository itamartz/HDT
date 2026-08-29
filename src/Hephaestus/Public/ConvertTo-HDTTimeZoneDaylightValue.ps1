function ConvertTo-HDTTimeZoneDaylightValue {
    <#
        .SYNOPSIS
            The half of WinPE's time zone key that dism does not write.

        .DESCRIPTION
            DISM WRITES THE STANDARD HALF OF THE ZONE AND STOPS, and that is the
            whole defect. Measured by reading the registry out of a built boot
            image, `dism /Image:<mount> /Set-TimeZone:"Israel Standard Time"`
            leaves HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation
            like this:

              Bias                        -120      correct
              StandardBias                0         correct
              DaylightBias                0         WRONG - the rule says -60
              DaylightName                (empty)   absent
              StandardStart               all zero  no rule at all
              DaylightStart               all zero  no rule at all
              ActiveTimeBias              ABSENT
              DynamicDaylightTimeDisabled 1         daylight time switched OFF

            With no ActiveTimeBias the kernel falls back to Bias + StandardBias,
            which is -120 the year round. The same key on a full Windows install
            of the same zone reads DaylightBias -60, ActiveTimeBias -180 and
            DynamicDaylightTimeDisabled 0. -120 where -180 belongs is the hour
            every WinPE timestamp on the live Dell run was ahead by.

            SO WinPE WAS NEVER REFUSING TO DO DAYLIGHT TIME - IT WAS NEVER TOLD
            ANY. The image carries the complete time zone database (141 zones in
            the ADK's own winpe.wim, each with its rule); nothing had ever copied
            the daylight half of the chosen zone into the key the kernel reads.
            This command produces exactly that half, for
            IBootImageService.SetTimeZoneDaylight to write beside dism's.

            NOTHING IT EMITS IS A MOMENT, WHICH IS WHY THIS CAN BE A BUILD-TIME
            WRITE AT ALL. A boot image is built once and booted for months, so a
            fix that computed "is it daylight time today" and baked the answer
            would be wrong from the next transition onwards - correct in August
            and an hour out in November, which is worse than being honestly
            wrong all year. Every value here is year-agnostic instead: the
            transition SYSTEMTIMEs carry wYear 0, Windows' encoding for the
            RECURRING rule "the wDay-th wDayOfWeek of wMonth", which the kernel
            evaluates against whatever date the machine boots on.

            ActiveTimeBias IS THAT MOMENT, AND IS DELIBERATELY NOT EMITTED. It
            is the only value in the key that answers "is it daylight time right
            now". Left absent - exactly as dism leaves it - the kernel computes
            it at each boot from the recurring rule beside it, which is how a
            full Windows machine comes up correct the morning after a transition
            with no service running. Writing it would relocate the defect rather
            than fix it. If the WinPE kernel should turn out not to perform that
            evaluation, an image built this way is no worse than one built
            before it: the fallback is Bias + StandardBias, today's behaviour.

            IT READS THE BUILD HOST'S ZONE TABLE, and Get-HDTTimeZone's header
            already explains why that is the right table: the id was chosen from
            it, on this machine, by whoever edited the workspace. dism has
            already validated that id against the IMAGE before this is written,
            so the two are checked against each other rather than trusted apart.
            A patched build host also carries a newer rule than a frozen ADK
            image does.

            IT TAKES THE OPEN-ENDED RULE, NOT TODAY'S. .NET carries one
            adjustment rule per era; the one whose DateEnd is 9999-12-31 is the
            rule in force from now on, forever, which is the same thing Windows
            stores as a zone's static TZI. Picking the rule that covers today's
            date instead would be a moment by the back door.

        .PARAMETER TimeZone
            The zone to read the daylight rule from.

        .PARAMETER Id
            The Windows time zone id, resolved against this host's table.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] with Name, Kind and
            Data - empty for a zone that has no daylight saving time, for which
            dism's half is already the whole key.

        .EXAMPLE
            ConvertTo-HDTTimeZoneDaylightValue -Id 'Israel Standard Time'

            The five values step 9b writes into the mounted image.

        .EXAMPLE
            ConvertTo-HDTTimeZoneDaylightValue -Id 'UTC'

            Nothing. A zone with no daylight saving needs no daylight half.

        .LINK
            Get-HDTTimeZone

        .LINK
            Set-HDTBootImageTimeZone
    #>
    [CmdletBinding(DefaultParameterSetName = 'TimeZone')]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'TimeZone')]
        [ValidateNotNull()]
        [System.TimeZoneInfo] $TimeZone,

        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Id')]
        [ValidateNotNullOrEmpty()]
        [string] $Id
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $zone = $null

    if ($PSCmdlet.ParameterSetName -eq 'Id') {
        # NAMED, NOT RETHROWN. .NET's own sentence for this is "The time zone ID
        # was not found on the local computer", which does not say WHICH id - and
        # the id came out of a workspace.yaml edited on a different machine, so
        # naming it is the whole diagnosis.
        try {
            $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($Id)
        } catch {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                        -Message ("this host has no time zone '{0}', so its daylight saving rule cannot be read. Run Get-HDTTimeZone for the ids this machine knows; Windows adds time zones, so a build host patched before the zone existed will not have it." -f $Id)))
        }
    } else {
        $zone = $TimeZone
    }

    # THE OPEN-ENDED RULE IS THE ONE THAT IS NOT A MOMENT. .NET returns a rule
    # per era - Israel's changed in 2013 - and the last one runs to 9999-12-31,
    # meaning "from here on, forever". That is the rule Windows itself keeps as
    # the zone's static TZI, and the only one whose choice does not depend on
    # what today's date is.
    $rule = $null

    foreach ($candidate in @($zone.GetAdjustmentRules())) {
        if ($candidate.DateEnd.Date -eq [datetime]::MaxValue.Date) {
            $rule = $candidate
        }
    }

    # NOTHING TO ADD, AND THAT IS A NORMAL ANSWER. UTC, India, Arizona and every
    # zone that has abolished daylight time reach here. dism's half IS the whole
    # key for them, and a DaylightBias of 0 written beside a cleared
    # DynamicDaylightTimeDisabled would be a rule saying "shift by nothing"
    # where the truth is "no rule".
    if ($null -eq $rule -or $rule.DaylightDelta -eq [timespan]::Zero) {
        return [pscustomobject[]] @()
    }

    $transitionPair = @(
        @{ Name = 'DaylightStart'; Transition = $rule.DaylightTransitionStart },
        @{ Name = 'StandardStart'; Transition = $rule.DaylightTransitionEnd }
    )

    $encoded = @{}

    foreach ($pair in $transitionPair) {
        $transition = $pair['Transition']

        # REG_TZI_FORMAT HAS NO FIXED-DATE ENCODING. With wYear 0 the wDay field
        # means a week number and wDayOfWeek a weekday, so "the 25th of March
        # every year" written into those fields silently becomes a different day.
        # .NET can carry such a rule; the registry cannot, and a wrong date
        # written confidently is worse than a build that stops and says so.
        if ($transition.IsFixedDateRule) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $zone.Id `
                        -Message ("the time zone '{0}' uses a fixed-date daylight saving rule, and the Windows registry time zone format cannot express one - it encodes only 'the Nth weekday of a month'. Windows PE cannot be given this zone's rule; leave the zone set and accept that its clock reads standard time all year." -f $zone.Id)))
        }

        $bytes = New-Object -TypeName 'byte[]' -ArgumentList 16

        # SYSTEMTIME, in order: wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute,
        # wSecond, wMilliseconds - eight UInt16.
        #
        # wYear 0 IS THE RECURRING RULE and the reason this survives November.
        # wDay is a WEEK NUMBER here, 1 to 5, where 5 means "the last one in the
        # month" - .NET spells the same thing TransitionTime.Week.
        $field = [uint16[]] @(
            0,
            $transition.Month,
            [int] $transition.DayOfWeek,
            $transition.Week,
            $transition.TimeOfDay.Hour,
            $transition.TimeOfDay.Minute,
            $transition.TimeOfDay.Second,
            0
        )

        for ($index = 0; $index -lt $field.Length; $index++) {
            [BitConverter]::GetBytes($field[$index]).CopyTo($bytes, $index * 2)
        }

        $encoded[$pair['Name']] = $bytes
    }

    # WINDOWS' SIGN CONVENTION IS UTC = local + bias, so an hour of daylight
    # time REDUCES the bias by sixty. Israel: -120 standard, -60 daylight,
    # -180 in force between the transitions.
    $daylightBias = [int] (-$rule.DaylightDelta.TotalMinutes)

    # Bias, StandardBias, StandardName and TimeZoneKeyName are NOT here on
    # purpose. dism writes those and writes them correctly; re-writing them
    # would make this the second place that decides them, and the two would
    # eventually disagree.
    return [pscustomobject[]] @(
        [pscustomobject] @{ Name = 'DaylightBias'; Kind = 'DWord'; Data = $daylightBias }
        [pscustomobject] @{ Name = 'DaylightName'; Kind = 'String'; Data = [string] $zone.DaylightName }
        [pscustomobject] @{ Name = 'DaylightStart'; Kind = 'Binary'; Data = $encoded['DaylightStart'] }
        [pscustomobject] @{ Name = 'StandardStart'; Kind = 'Binary'; Data = $encoded['StandardStart'] }

        # THE ADK SHIPS THIS SET TO 1 AND dism LEAVES IT SET. A machine told not
        # to use dynamic daylight time will not use it however good the rule
        # beside it is, so the rule and the switch have to travel together.
        [pscustomobject] @{ Name = 'DynamicDaylightTimeDisabled'; Kind = 'DWord'; Data = 0 }
    )
}
