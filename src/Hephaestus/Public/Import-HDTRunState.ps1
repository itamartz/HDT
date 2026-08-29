function Import-HDTRunState {
    <#
        .SYNOPSIS
            Reads and validates the state document, for a resume.

        .DESCRIPTION
            Reads state.json through the injected IFileSystem, parses it, holds
            it to Assert-HDTRunStateDocument and rehydrates it into the same
            shape New-HDTRunState produces, so a resumed run and a fresh one are
            the same object to everything downstream.

            Rehydration matters in two places:

              variable  becomes an ordered, CASE-INSENSITIVE dictionary, because
                        a rule or a step may spell HDTComputerName however it
                        likes and ConvertFrom-Json gives back a case-sensitive
                        object
              step      becomes an array in index order, because a resume finds
                        the next step by index and must not depend on the order
                        the JSON happened to list them in

            A CORRUPT DOCUMENT IS A TERMINATING ERROR, NOT "no state". Treating
            an unreadable state.json as an absent one would restart the sequence
            from step 1 on a machine that is already half built - re-running a
            destructive step such as a partition wipe. So a truncated file, a
            missing runId or a schemaVersion from the future all throw
            HDTConfigurationError naming the file, and a missing file throws
            HDTStateNotFound, which is a different and recoverable answer.

            Parsing never uses ConvertFrom-Json -AsHashtable: it is PowerShell
            6+ only, and the engine runs under 5.1 in WinPE.

        .PARAMETER Path
            The state document to read.

        .PARAMETER FileSystem
            An IFileSystem - New-HDTFileSystem in production,
            New-HDTFakeFileSystem in a test.
            Defaults to the real one.

        .OUTPUTS
            System.Management.Automation.PSCustomObject

        .EXAMPLE
            $state = Import-HDTRunState -Path 'C:\HDT\state.json'
            $state.stepIndex

            Reads the checkpoint back after a restart. C:\HDT\ is where W:\HDT\ ends up
            once the machine boots what was applied to it.

        .EXAMPLE
            @($state.step | Where-Object { $_.status -eq 'Failed' }) | ForEach-Object { $_.name }

            Which steps failed on the run being resumed. A half-written state.json is
            refused by name rather than resumed from - a checkpoint that cannot be
            trusted is worse than none.

    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $text = $null
    try {
        $text = $FileSystem.ReadAllText($Path)
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message 'the state document could not be read. A run with no state document starts from the beginning; one that cannot be read does not.' `
                    -ErrorId 'HDTStateNotFound' -Category ObjectNotFound))
    }

    $document = $null
    try {
        # Never -AsHashtable: it is PowerShell 6+ only and banned outright.
        $document = ConvertFrom-Json -InputObject $text
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("the state document is not valid JSON and cannot be trusted. A corrupt state document is not the same as no state document: resuming from the beginning would re-run steps that have already run. Underlying error: {0}" -f $_.Exception.Message)))
    }

    Assert-HDTRunStateDocument -Document $document -Path $Path

    $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($property in @($document.variable.PSObject.Properties)) {
        $variable[$property.Name] = $property.Value
    }
    $document.variable = $variable

    $document.step = @(@($document.step) | Sort-Object -Property index)

    $document.stepIndex = [int] $document.stepIndex
    $document.leg = [int] $document.leg
    $document.seq = [long] $document.seq

    # THE ABSENCE IS ANSWERED HERE, ONCE, so no caller has to ask whether the
    # key is there. logLevel is optional in both validators - a document written
    # by an engine that predates it belongs to a run that is still going, and
    # refusing it would strand a machine mid-deployment over a log setting - so
    # this is the one place that turns "the document said nothing" into Info,
    # which is New-HDTLogContext's own default.
    #
    # Add-Member, NOT ASSIGNMENT: a PSCustomObject does not grow a property when
    # one is assigned to it, so $document.logLevel = 'Info' throws on exactly the
    # documents this exists for.
    if (@($document.PSObject.Properties | ForEach-Object { $_.Name }) -notcontains 'logLevel') {
        $document | Add-Member -MemberType NoteProperty -Name 'logLevel' -Value 'Info'
    } elseif ([string]::IsNullOrWhiteSpace([string] $document.logLevel)) {
        $document.logLevel = 'Info'
    }

    # ConvertFrom-Json under pwsh 7 rehydrates an ISO 8601 string into a
    # [datetime]; under Windows PowerShell 5.1 it leaves the string alone. The
    # engine writes state.json under 5.1 in WinPE and reads it under whichever
    # engine is running, so every timestamp is normalised back to the round-trip
    # string here - an imported document has one shape, not one per engine.
    $normalize = {
        param($Object, [string] $Name)

        if (@($Object.PSObject.Properties | ForEach-Object { $_.Name }) -notcontains $Name) {
            return
        }

        $value = $Object.$Name
        if ($value -is [datetime]) {
            $Object.$Name = $value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }

    & $normalize $document 'startedUtc'
    & $normalize $document 'updatedUtc'

    foreach ($step in @($document.step)) {
        & $normalize $step 'startedUtc'
        & $normalize $step 'endedUtc'
    }

    return $document
}
