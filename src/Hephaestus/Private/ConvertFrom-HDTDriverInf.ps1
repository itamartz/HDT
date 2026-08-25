function ConvertFrom-HDTDriverInf {
    <#
        .SYNOPSIS
            One .inf, read as a driver: what it is, who made it, and which
            devices it claims.

        .DESCRIPTION
            THE CATALOG'S CORE, and the thing M5 was waiting for. A selection
            profile names folders; this is what makes the drivers INSIDE one
            addressable - so the console can list them, a technician can read the
            PnP ids a driver claims, and a later PnP match has something to rank.

            AN .inf IS NOT AN INI FILE, however much it looks like one, and every
            rule below came off a real file rather than a specification read at a
            distance:

              THE SECTION NAME IS SOMETIMES LOWERCASE. netrtwlane.inf ships
              '[version]'. Every comparison here is case-insensitive.

              Provider AND THE MANUFACTURERS ARE %TOKENS%. 'Provider = %MSFT%'
              resolves through [Strings] to "Microsoft"; unresolved, the console
              would show an administrator a percent sign.

              DriverVer IS TWO VALUES IN ONE, DATE FIRST:
              '08/03/2015,12.19.1.32'. Reading it as a version gets a date.

              [Manufacturer] NAMES DECORATED SECTIONS. '%Intel% = Intel,
              NTamd64.10.0.1' means the models are in [Intel.NTamd64.10.0.1] -
              and ALSO possibly in plain [Intel]. Both are read, because which
              one a vendor uses is not predictable.

              A MODEL LINE HAS A DOUBLE COMMA. '%Desc% = Install,, PCI\VEN_...'
              - the empty field between them is real, so the hardware ids are
              every non-empty field after the install section, not "the second
              one".

              A LINE CAN CARRY SEVERAL IDS, and can end in a ';;' comment.

            IT READS A STRING, NOT A FILE. The caller has an IFileSystem and this
            has none, which is what lets the whole parser run under Pester with
            no disk - and is why .inf ENCODING is the caller's problem: these
            files ship UTF-16LE as often as ANSI, and a reader that assumes one
            gets one character in two from the other.

        .PARAMETER Text
            The .inf's contents.

        .PARAMETER InfName
            The file name, carried onto the result so a caller need not.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with InfName, Class,
            ClassGuid, Provider, Version, Date, CatalogFile, ModelCount and
            HardwareId - the ids in the order the file declares them, deduped.

        .EXAMPLE
            ConvertFrom-HDTDriverInf -Text $text -InfName 'e1d68x64.inf'

        .EXAMPLE
            (ConvertFrom-HDTDriverInf -Text $text -InfName 'net.inf').HardwareId

            Every PnP id the driver claims - what the properties window lists and
            what a PnP match would rank.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string] $InfName = ''
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $empty = [pscustomobject] @{
        InfName = $InfName; Name = ''; Class = ''; ClassGuid = ''; Provider = ''
        Version = ''; Date = ''; CatalogFile = ''; ModelCount = 0
        HardwareId = [string[]] @()
    }

    if ([string]::IsNullOrWhiteSpace($Text)) { return $empty }

    # -- split into sections --------------------------------------------------
    #
    # A COMMENT CAN FOLLOW ANYTHING. ';' starts one, and a model line routinely
    # ends in ';; HP Dragon'.
    $bucket = @{}
    $current = ''

    foreach ($raw in @($Text -split "`r?`n")) {
        $line = $raw

        $semicolon = $line.IndexOf(';')
        if ($semicolon -ge 0) { $line = $line.Substring(0, $semicolon) }

        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $current = $line.Substring(1, $line.Length - 2).Trim().ToLowerInvariant()
            if (-not $bucket.ContainsKey($current)) {
                $bucket[$current] = New-Object -TypeName System.Collections.ArrayList
            }
            continue
        }

        if ([string]::IsNullOrEmpty($current)) { continue }

        [void] $bucket[$current].Add($line)
    }

    # -- [Strings], so %tokens% become words ----------------------------------

    $strings = @{}

    if ($bucket.ContainsKey('strings')) {
        foreach ($line in @($bucket['strings'])) {
            $at = $line.IndexOf('=')
            if ($at -lt 1) { continue }

            $key = $line.Substring(0, $at).Trim().ToLowerInvariant()
            $value = $line.Substring($at + 1).Trim().Trim('"')

            $strings[$key] = $value
        }
    }

    $resolve = {
        param([string] $Value)

        $trimmed = ([string] $Value).Trim()

        if ($trimmed.StartsWith('%') -and $trimmed.EndsWith('%') -and $trimmed.Length -gt 2) {
            $token = $trimmed.Substring(1, $trimmed.Length - 2).ToLowerInvariant()
            if ($strings.ContainsKey($token)) { return [string] $strings[$token] }
        }

        return $trimmed
    }

    $read = {
        param([string] $SectionName, [string] $Key)

        if (-not $bucket.ContainsKey($SectionName)) { return '' }

        foreach ($line in @($bucket[$SectionName])) {
            $at = $line.IndexOf('=')
            if ($at -lt 1) { continue }

            if ($line.Substring(0, $at).Trim() -eq $Key) { return $line.Substring($at + 1).Trim() }
        }

        return ''
    }

    # -- [Version] ------------------------------------------------------------

    $class = & $read 'version' 'Class'
    $classGuid = & $read 'version' 'ClassGUID'
    $catalog = & $read 'version' 'CatalogFile'
    $provider = & $resolve (& $read 'version' 'Provider')

    # DATE FIRST, THEN VERSION. Reading it the other way round gets a date into
    # a version column and sorts it as text.
    $driverVer = & $read 'version' 'DriverVer'
    $date = ''
    $version = ''

    if (-not [string]::IsNullOrWhiteSpace($driverVer)) {
        $part = @($driverVer -split ',')
        $date = ([string] $part[0]).Trim()
        if (@($part).Count -gt 1) { $version = ([string] $part[1]).Trim() }
    }

    # -- [Manufacturer] -> the model sections ---------------------------------

    $modelSection = New-Object -TypeName System.Collections.ArrayList

    foreach ($line in @(& { if ($bucket.ContainsKey('manufacturer')) { $bucket['manufacturer'] } else { @() } })) {
        $at = $line.IndexOf('=')
        if ($at -lt 1) { continue }

        $part = @($line.Substring($at + 1) -split ',')
        $base = ([string] $part[0]).Trim()

        if ([string]::IsNullOrWhiteSpace($base)) { continue }

        # THE PLAIN SECTION AND EVERY DECORATED ONE. Which a vendor uses is not
        # predictable, and net1ic64.inf uses only the decorated one while plenty
        # of others use only the plain.
        [void] $modelSection.Add($base.ToLowerInvariant())

        for ($i = 1; $i -lt @($part).Count; $i++) {
            $decoration = ([string] $part[$i]).Trim()
            if ([string]::IsNullOrWhiteSpace($decoration)) { continue }

            [void] $modelSection.Add(('{0}.{1}' -f $base, $decoration).ToLowerInvariant())
        }
    }

    # -- the models, and the ids they claim -----------------------------------

    $hardware = New-Object -TypeName System.Collections.ArrayList
    $seen = @{}
    $models = 0

    # THE NAME THE CONSOLE'S GRID SHOWS, which is the FIRST model's description.
    # A driver has no name of its own - an .inf names DEVICES - so the choice is
    # this or the file name, and 'e1d68x64.inf' tells a technician nothing about
    # which machine it is for. It is one %token% resolution per file, not one per
    # device: the PnP list deliberately shows ids alone.
    $displayName = ''

    foreach ($name in @($modelSection)) {
        if (-not $bucket.ContainsKey($name)) { continue }

        foreach ($line in @($bucket[$name])) {
            $at = $line.IndexOf('=')
            if ($at -lt 1) { continue }

            $models++

            if ([string]::IsNullOrEmpty($displayName)) {
                $displayName = & $resolve ($line.Substring(0, $at))
            }

            # EVERY NON-EMPTY FIELD AFTER THE INSTALL SECTION. The empty one
            # between them is real - '%Desc% = Install,, PCI\VEN_...' - so this
            # cannot take "the field after the comma".
            $field = @($line.Substring($at + 1) -split ',')

            for ($i = 1; $i -lt @($field).Count; $i++) {
                $id = ([string] $field[$i]).Trim()

                if ([string]::IsNullOrWhiteSpace($id)) { continue }

                $key = $id.ToUpperInvariant()
                if ($seen.ContainsKey($key)) { continue }

                $seen[$key] = $true
                [void] $hardware.Add($id)
            }
        }
    }

    return [pscustomobject] @{
        InfName     = $InfName
        Name        = $displayName
        Class       = $class
        ClassGuid   = $classGuid
        Provider    = $provider
        Version     = $version
        Date        = $date
        CatalogFile = $catalog
        ModelCount  = $models
        HardwareId  = [string[]] @($hardware)
    }
}
