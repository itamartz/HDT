function ConvertTo-HDTCmTraceLine {
    <#
        .SYNOPSIS
            Renders one CMTrace line.

        .DESCRIPTION
            The second of the two formats every Write-HDTLog call emits. A
            deployment technician has CMTrace or OneTrace open already and knows
            how to read it, so emitting the format those readers expect means
            their existing workflow, filtering and error highlighting work on day
            one - deliberately not a new thing to learn.

            The line, exactly:

              <![LOG[<message>]LOG]!><time="HH:mm:ss.fff-180" date="MM-dd-yyyy"
              component="<component>" context="" type="<1|2|3>" thread="<id>"
              file="<file>">

            THE TIME IS THE TECHNICIAN'S OWN WALL CLOCK, not UTC. The engine
            stamps every record with Clock.GetUtcNow(), and this line renders
            that instant in the machine's time zone - because the person reading
            it is correlating the deployment against Event Viewer, against
            setupact.log, or against a user saying "it broke around half nine".

            The offset field carries ActiveTimeBias: the minutes to ADD to local
            to get UTC, so a machine three hours ahead of Greenwich writes -180.
            That is the ConfigMgr convention, not ISO 8601's, and the sign is
            inverted relative to "+03:00". See the block above the render for
            the captured evidence.

            type maps 1 = Info and Debug, 2 = Warning, 3 = Error, which is what
            gives CMTrace its colour coding for free. CMTrace has no debug value,
            so a Debug message says so in its own text - "[DEBUG] " in front of
            it - rather than in a type field that would stop CMTrace colouring
            and filtering the file at all. MDT reaches the same place from the
            other direction: ZTIUtility.vbs defines a LogTypeVerbose and rewrites
            it to LogTypeInfo before the line is written.

            ONE PHYSICAL LINE, ALWAYS. CMTrace's parser is line oriented, so a
            carriage return or a line feed inside the message would split one
            entry into two malformed ones. Both are replaced by a space.

            Every field is rendered in the INVARIANT culture. A German or Swedish
            machine would otherwise write a dotted date or a comma decimal
            separator into a format whose reader expects neither, and the engine
            ships to machines whose culture nobody chose.

            The function is pure: same arguments, same string, no clock, no
            filesystem, no state. The one machine fact it reads - the time zone
            - is a parameter with a default, so a test names it and gets the
            same string on any host.

        .PARAMETER Message
            The message. Carriage returns and line feeds are replaced by spaces.

        .PARAMETER Component
            The component attribute - the subsystem the entry came from.

        .PARAMETER Severity
            Error, Warning, Info or Debug.

        .PARAMETER Timestamp
            The instant to render, in UTC - which is what Clock.GetUtcNow()
            returns and what every producer in this module writes. A Local kind
            is converted; an Unspecified kind is taken as UTC.

        .PARAMETER TimeZone
            The zone to render the instant in. Defaults to the machine's own,
            which is what a deployment log wants: it is read on the machine that
            wrote it. Injectable so the tests can assert a fixed offset instead
            of whichever one the build agent happens to sit in.

        .PARAMETER ThreadId
            The thread attribute.

        .PARAMETER File
            The file attribute - the step type, the script name or Engine.

        .OUTPUTS
            System.String

        .EXAMPLE
            ConvertTo-HDTCmTraceLine -Message 'Applied index 1' -Component 'ImageService' `
                -Severity Info -Timestamp $utcNow -ThreadId 4820 -File 'ApplyImage'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Component,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Error', 'Warning', 'Info', 'Debug')]
        [string] $Severity,

        [Parameter(Mandatory = $true)]
        [datetime] $Timestamp,

        [Parameter(Mandatory = $true)]
        [int] $ThreadId,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $File,

        # CMTrace's OWN COLUMN FOR WHO DID IT, and it was always written empty.
        # The console log lives on the share, where two administrators append to
        # one file, so "who ran this" is not a detail - it is the difference
        # between a session somebody can account for and a line they cannot.
        #
        # CMTrace shows it as a column with no configuration and no plugin,
        # which is the reason this format was chosen at all: an MDT admin's
        # existing tooling works on day one.
        #
        # EMPTY BY DEFAULT, so a deployment's own logs stay byte-for-byte what
        # they were. The engine runs as SYSTEM in WinPE and "who" is not a
        # question anybody asks of it.
        [Parameter()]
        [AllowEmptyString()]
        [string] $UserContext = '',

        # THE MACHINE'S ZONE BY DEFAULT, and named by the tests. Reading
        # TimeZoneInfo::Local here rather than in the render keeps the body a
        # pure function of its arguments, which is the only reason a fixed
        # "-180" can be asserted on a host that is not in Israel.
        #
        # In WinPE the zone is unset and Windows reports UTC, so the WinPE leg
        # renders exactly what it rendered before this change - UTC under
        # "+000", MDT's own line. That is the correct degradation: this function
        # is right for WHATEVER offset the machine reports, and setting WinPE's
        # zone correctly is a separate matter that this must not second-guess or
        # the two corrections would compound.
        [Parameter()]
        [System.TimeZoneInfo] $TimeZone = [System.TimeZoneInfo]::Local
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture

    # CRLF first, so one line break becomes one space rather than two.
    $flat = $Message.Replace("`r`n", ' ').Replace("`r", ' ').Replace("`n", ' ')

    # DEBUG IS SAID IN THE MESSAGE, BECAUSE THE TYPE FIELD CANNOT SAY IT.
    #
    # CMTrace's type is 1 = Info, 2 = Warning, 3 = Error and nothing else. A
    # fourth value would cost the colouring and the level filter that are the
    # whole reason this format was chosen, so HDT does not invent one - and
    # neither does MDT, whose ZTIUtility.vbs defines LogTypeVerbose = 4 and then
    # rewrites it to LogTypeInfo before writing the line.
    #
    # THE RESULT WAS EIGHTY RECORDS INDISTINGUISHABLE FROM INFO. A run at Debug
    # writes a var.resolve line per variable, and in CMTrace they looked exactly
    # like the handful of Info lines an administrator actually wanted - the
    # verbosity was invisible in the one view a technician uses.
    #
    # SO IT GOES IN THE LOG TEXT, which is the column CMTrace shows and the
    # field its filter box searches: "[DEBUG]" in the filter now hides or
    # isolates them. The JSONL beside it carries the real level in its own
    # field, so nothing machine-read depends on this prefix.
    if ($Severity -eq 'Debug') {
        $flat = '[DEBUG] ' + $flat
    }

    $type = '1'
    if ($Severity -eq 'Warning') {
        $type = '2'
    }
    if ($Severity -eq 'Error') {
        $type = '3'
    }

    # THE CONTEXT IS FLATTENED LIKE THE MESSAGE. A user name cannot normally
    # hold a quote or a newline, but this writes an attribute in a line-oriented
    # format and a value that could close it early would corrupt every entry
    # after it - so it is treated as untrusted text, exactly as the message is.
    $flatContext = ([string] $UserContext) -replace '[\r\n]', ' ' -replace '"', "'"

    # LOCAL WALL CLOCK, AND THE REAL BIAS.
    #
    # This line used to render the UTC instant it was handed under a hardcoded
    # "+000". Measured on a Dell run: HDT.log said time="20:43:07.612+000" while
    # the technician's watch said 22:43. The reader was three hours out AND the
    # field told him it was not - so nothing in the file could be lined up
    # against Event Viewer, setupact.log or anybody's memory of when it broke.
    #
    # MICROSOFT'S TWO WRITERS SETTLE BOTH HALVES, and both are on disk here:
    #
    #   ZTIUtility.vbs:194 builds the line from Now() - LOCAL - and appends the
    #   literal ".000+000". MDT writes wall-clock time and does not bother
    #   computing the field. OSDEndTime.vbs:17 reads ActiveTimeBias when it
    #   wants UTC: local is what MDT writes, UTC is what it derives.
    #
    #   The ConfigMgr client fills the field in properly. 49,096 captured lines
    #   from a real client on a UTC+3 machine carry, without exception:
    #
    #     <![LOG[Starting CCMEXEC service...]LOG]!><time="12:07:10.740-180" ...
    #
    # SO THE FIELD IS ActiveTimeBias, NOT AN ISO OFFSET. It is the minutes to
    # add to local to reach UTC, which makes it the NEGATIVE of GetUtcOffset:
    # -180 three hours east of Greenwich, +420 in Pacific daylight time. The
    # registry on a UTC+3 host agrees - ActiveTimeBias = 0xffffff4c = -180. PSD
    # reaches for the opposite sign (PSDUtility.psm1:215 appends
    # GetUtcOffset().TotalMinutes, which yields a bare "180" east of Greenwich,
    # unsigned and inverted) and is simply wrong for it.
    #
    # A UTC MACHINE THEREFORE STILL GETS MDT'S EXACT LINE: bias 0 renders
    # "+000", so the WinPE leg is byte-for-byte what it always was.
    #
    # THE OFFSET IS THE ONE IN FORCE AT THE INSTANT OF THE RECORD, taken from
    # the UTC value rather than from "now". A run that crosses a DST boundary,
    # or a line re-rendered later, then still says what the clock said at the
    # time - GetUtcOffset given a UTC instant resolves the transition itself.
    $utc = [datetime]::SpecifyKind($Timestamp, [System.DateTimeKind]::Utc)
    if ($Timestamp.Kind -eq [System.DateTimeKind]::Local) {
        $utc = $Timestamp.ToUniversalTime()
    }

    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $TimeZone)

    # '+000;-000' is one format string with a positive section and a negative
    # one, and .NET applies the second to the absolute value - so this signs and
    # pads without a branch, and zero takes the positive section and gives the
    # "+000" MDT writes.
    $bias = ([int] [Math]::Round(-$TimeZone.GetUtcOffset($utc).TotalMinutes)).ToString('+000;-000', $invariant)

    return ('<![LOG[{0}]LOG]!><time="{1}{8}" date="{2}" component="{3}" context="{4}" type="{5}" thread="{6}" file="{7}">' -f
        $flat,
        $local.ToString('HH:mm:ss.fff', $invariant),
        $local.ToString('MM-dd-yyyy', $invariant),
        $Component,
        $flatContext,
        $type,
        $ThreadId.ToString($invariant),
        $File,
        $bias)
}
