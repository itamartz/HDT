function Get-HDTValidateStepDescription {
    <#
        .SYNOPSIS
            Describes a Validate step by the bounds it will check.

        .DESCRIPTION
            The optional third of the step contract's triple. A technician watching the
            progress display wants to know which bound a machine failed, so the
            description names them: "Validate: 2048 MB memory, 60 GB disk, UEFI".

            IT WALKS Get-HDTValidateCheckDefinition RATHER THAN LISTING KEYS.
            That table is the one place a check is declared, and this function
            renders whatever it finds there: '<value> <Unit> <Noun>' for a
            Number that has a unit, '<Noun> <value>' for one that has not, the
            Noun alone for a Switch that is on, and each entry by name for a
            List. So a check added to the table appears here for free, in the
            table's own Order rather than the order the document happened to
            declare them in.

            THIS USED TO BE A LIST OF FOUR KEYS AND IT HAD DRIFTED FIVE BEHIND.
            minTpmVersion, diskNumber, imageVersion, imageSizeMB and
            allowOtherPartition were declarable, enforced by Invoke-HDTValidateStep,
            and invisible here - so refresh.yaml, which declares three of them,
            described itself as "Validate: 2048 MB memory, and one unambiguous
            target disk" and said nothing about the downgrade refusal, the
            free-space refusal or the partition-match refusal it exists to make.

            AN ABSENT KEY MEANS "DO NOT CHECK THIS", and so does a Switch that
            is off - the same rule the console's Validate page follows, where
            unticking a box removes the key rather than writing a zero. Neither
            is named.

            IT DESCRIBES THE AUTHORED STEP, NOT THE RESOLVED ONE. There is no
            context here and none is wanted: the tree is showing what the
            document says, so '%HDTOSImageVersion%' renders as itself.

        .PARAMETER Step
            A flattened step from Import-HDTSequenceDocument.

        .OUTPUTS
            System.String

        .EXAMPLE
            $sequence = Import-HDTSequenceDocument -Path 'C:\HDTLab\Share\TaskSequences\DEMO-05\sequence.yaml'
            $step = @($sequence.Step | Where-Object { $_.Type -eq 'Validate' })[0]

            Get-HDTValidateStepDescription -Step $step

            The one line the log and the progress display carry for this step.

        .EXAMPLE
            Get-HDTStepDescription -Step $step

            The same line through the dispatcher, which is how the engine asks.
            It finds this function by name; a step type that declares none gets
            '<Type>: <name>' instead.

        .EXAMPLE
            # Templates\client.yaml - the Validate step every new client
            # sequence is seeded with:
            #
            #     - name: Validate
            #       type: Validate
            #       minRamMB: 2048
            #       minDiskGB: 60

            Validate: 2048 MB memory, 60 GB disk, and one unambiguous target disk

            minRamMB is 2048 rather than 4096 because a 4 GB machine reports
            slightly under 4096 - the firmware keeps some of it - so 4096
            refuses machines you meant to accept.

        .EXAMPLE
            # Templates\reference.yaml - the same pair, with the bigger disk a
            # reference build needs to capture from:
            #
            #     - name: Validate
            #       type: Validate
            #       minRamMB: 2048
            #       minDiskGB: 80

            Validate: 2048 MB memory, 80 GB disk, and one unambiguous target disk

        .EXAMPLE
            # Templates\refresh.yaml - MDT's three ZTIValidate guards, under
            # HDT's own names, and no minDiskGB at all:
            #
            #     - name: Validate
            #       type: Validate
            #       minRamMB: 2048
            #       imageVersion: '%HDTOSImageVersion%'
            #       imageSizeMB: '%HDTOSImageSizeMB%'
            #       allowOtherPartition: false

            Validate: 2048 MB memory, Windows %HDTOSImageVersion%, %HDTOSImageSizeMB% MB image, and one unambiguous target disk

            allowOtherPartition is false and is therefore not named: a Refresh
            replaces the installation it started from, so refusing another
            volume is the ordinary case. Ticking it is what would earn a word,
            because that is the deliberate override.

            There is no minDiskGB because that check looks for a deployment
            TARGET disk and its first exclusion is "the disk this machine
            booted from" - which on a Refresh is precisely the disk being
            replaced. imageSizeMB is the free-space guard that belongs here
            instead.

        .EXAMPLE
            # A Validate step that declares no bounds at all.

            Validate: one unambiguous target disk

            The step always makes that check, so the description always says
            it - a Validate step is never a step that checks nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object] $Step
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $part = New-Object -TypeName System.Collections.ArrayList

    foreach ($definition in @(Get-HDTValidateCheckDefinition | Sort-Object -Property Order)) {

        $key = [string] $definition.Key
        $raw = Get-HDTStepProperty -Step $Step -Name $key

        if ($null -eq $raw) { continue }

        $kind = [string] $definition.Kind
        $noun = [string] $definition.Noun

        # A LIST NAMES ITS ENTRIES AND NOT ITSELF. 'requireVariable:
        # HDTComputerName' reads better in a tree as the variable's own name
        # than as "1 variable", which is why the table gives it no Noun.
        if ($kind -eq 'List') {
            foreach ($entry in @($raw)) {
                $text = ([string] $entry).Trim()
                if ($text.Length -gt 0) { [void] $part.Add($text) }
            }

            continue
        }

        if ($kind -eq 'Switch') {

            # -As Bool PARSES RATHER THAN CASTS, which matters: [bool] 'false'
            # is $true, and a YAML document that came back as a string would
            # otherwise name a check the author had turned off.
            #
            # A VALUE THAT IS NEITHER throws there, and this swallows it on
            # purpose. A tree line is not where a malformed document should be
            # reported - Invoke-HDTValidateStep refuses it at run time with the
            # key, the value and the reason - and a console editor that threw
            # while drawing a row would be unable to show the document the
            # author is part way through fixing.
            $on = $false
            try { $on = [bool] (Get-HDTStepProperty -Step $Step -Name $key -Default $false -As Bool) }
            catch { $on = $false }

            if ($on) { [void] $part.Add($noun) }

            continue
        }

        # 'Number'. The unit belongs between the value and the noun where there
        # is one - "2048 MB memory" - and where there is none the noun leads,
        # because "TPM 2.0" and "target disk 0" read as the thing and its
        # value while "2.0 TPM" reads as a quantity of TPMs.
        $text = ([string] $raw).Trim()
        if ($text.Length -eq 0) { continue }

        $unit = [string] $definition.Unit

        if ($unit.Length -gt 0) {
            [void] $part.Add(('{0} {1} {2}' -f $text, $unit, $noun))
        }
        else {
            [void] $part.Add(('{0} {1}' -f $noun, $text))
        }
    }

    if ($part.Count -eq 0) {
        return 'Validate: one unambiguous target disk'
    }

    return ('Validate: {0}, and one unambiguous target disk' -f (@($part) -join ', '))
}
