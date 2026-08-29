function Write-HDTVariableLog {
    <#
        .SYNOPSIS
            Writes a resolution's provenance into the log stream as var.resolve
            records.

        .DESCRIPTION
            Not knowing why HDTComputerName ended up as it did is the single
            biggest debugging pain a deployment has. Export-HDTVariableProvenance
            answers that from a file; this puts the same answer into the log
            STREAM, one var.resolve record per variable, which is what the report
            renderer and the console's monitoring view read.

            Records are emitted at Debug, because variable
            resolution there: "Debug adds every variable resolution with its
            provenance and every native command line executed in full - the two
            things most often needed to explain a deployment that went wrong".
            A context at the default Info level therefore drops them, which is
            intended.

            Each record carries the whole provenance entry under data - name,
            value, source, rule, ruleIndex, file, rawValue, expanded, order - in
            resolution order, so reading the stream top to bottom is reading what
            the engine did in the order it did it.

            A SECRET'S VALUE IS NOT IN IT. The name, the source, the rule and the
            file all survive - "which rule set the administrator password" is
            exactly what this stream exists to answer - and only the value and
            the rawValue are replaced by "(set, not shown)". Which names those
            are is Protect-HDTSecretValue's decision and not this command's.

            AN UNRESOLVED %Var% IS A WARNING, NOT A FAILURE. 02-03 settled that a
            token nothing supplied is surfaced in the log and left in place rather
            than ending the deployment, so one Warning record names every
            unresolved token. It is emitted at Warning, so it survives a
            non-Debug verbosity: this is the one part of provenance an
            administrator needs without turning on Debug first.

        .PARAMETER Context
            A New-HDTLogContext result.

        .PARAMETER Resolution
            A Resolve-HDTVariable result.

        .OUTPUTS
            None.

        .EXAMPLE
            $clock = New-HDTClock
            $log = New-HDTLogContext -RunId 'run-0001' -Phase WinPE `
                -LogPath 'X:\HDT\Logs' -Clock $clock
            $context = New-HDTExecutionContext -RunId 'run-0001' -Phase WinPE `
                -WorkspaceRoot 'C:\HDTLab\Share' -Variable ([ordered] @{}) `
                -Service (New-HDTServiceCatalog -FileSystem (New-HDTFileSystem) -Clock $clock) -Log $log
            $fact = Get-HDTMachineFact -CimProvider (New-HDTCimProvider) `
                -RegistryService (New-HDTRegistryService) -EnvironmentProvider (New-HDTEnvironmentProvider)
            $resolution = Resolve-HDTVariable -Fact $fact
            Write-HDTVariableLog -Context $context -Resolution $resolution

            Writes one record per resolved variable, each carrying which source set it.
            At Info, not Debug: how a machine got its name is not a detail.

        .EXAMPLE
            @(Get-HDTRunLogRecord -Context $log | Where-Object { $_.Event -eq 'var.resolve' }).Count

            How many it wrote. The same stream the provenance export is built from, so
            the log and the file cannot disagree.

    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Context,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNull()]
        [object] $Resolution
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    foreach ($record in @(Get-HDTVariableProvenance -Resolution $Resolution)) {
        # THE VALUE GOES THROUGH THE REDACTION; THE PROVENANCE DOES NOT.
        #
        # A real run wrote "HDTAdminPassword = 'A123a123' (Rule)" into HDT.jsonl
        # and, CMTrace-formatted, into HDT.log beside it - while
        # Gather\provenance.json, written from this same resolution seconds
        # earlier, correctly said "(set, not shown)". One writer asked whether
        # the variable was secret and this one did not, which is why the answer
        # now lives in Protect-HDTSecretValue and no writer gets to decide.
        #
        # IT IS NOT A LOG THAT STAYS ON THE MACHINE. SLShare copies this pair to
        # the deployment share, which every machine being deployed can read, and
        # the finish action moves it to C:\Windows\Logs\HDT, which authenticated
        # users can read - so a local administrator password written here is
        # readable by any local user of the machine it administers.
        #
        # AND rawValue LEAKS THE SAME THING. It is the unexpanded text, which for
        # a password authored literally in rules.yaml is the password itself.
        $value = Protect-HDTSecretValue -Name ([string] $record.Name) -Value $record.Value
        $rawValue = Protect-HDTSecretValue -Name ([string] $record.Name) -Value $record.RawValue

        $data = [ordered] @{
            name      = $record.Name
            value     = $value
            source    = $record.Source
            rule      = $record.Rule
            ruleIndex = $record.RuleIndex
            file      = $record.File
            rawValue  = $rawValue
            expanded  = $record.Expanded
            order     = $record.Order
        }

        # ConvertTo-HDTVariableText, NOT THE FORMAT OPERATOR ON ITS OWN. An
        # array argument NESTS in a -f argument list rather than flattening, so
        # a multi-homed machine logged "HDTIPAddress = 'System.Object[]'" - its
        # own addresses as the name of their type - and the source shifted along
        # with it. The data field below still carries the real array; the
        # message carries the comma-delimited text a %Var% expands to.
        Write-HDTLog -Context $Context -Severity Debug -Event 'var.resolve' -Component 'Variable' `
            -Message ("{0} = '{1}' ({2})" -f $record.Name,
                (ConvertTo-HDTVariableText -Value $value), $record.Source) -Data $data
    }

    $unresolved = @($Resolution.Unresolved)
    if ($unresolved.Count -gt 0) {
        Write-HDTLog -Context $Context -Severity Warning -Event 'var.resolve' -Component 'Variable' `
            -Message ("{0} variable token(s) were never supplied and are left unexpanded: {1}." -f
                $unresolved.Count, ($unresolved -join ', ')) `
            -Data ([ordered] @{ unresolved = $unresolved })
    }
}
