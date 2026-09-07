function Get-HDTMachineOverride {
    <#
        .SYNOPSIS
            Reads the per-machine variable override for a UUID, if one exists.

        .DESCRIPTION
            Source 2 of five: Control\machines\<UUID>.yaml, one document per
            machine keyed by its UUID. It is a per-machine database that is
            file-based - a SQL or REST provider can be plugged in later behind
            the same interface - and this is that provider's file
            implementation. (It is what an MDT database was for.)

            NO FILE IS THE NORMAL CASE. Most machines have no override, so an
            absent file returns $null rather than throwing, and an empty -Uuid
            returns $null without touching the filesystem at all - the engine
            asks before it necessarily knows the UUID.

            A file that EXISTS but is wrong is a different matter and fails fast,
            naming the file. An override that silently does nothing is the kind
            of thing nobody can debug at a bench, so an unknown key, a variable
            outside the HDT namespace or an attempt to assign an engine-owned
            _HDT* variable are all refused rather than ignored.

            The file is read through the injected IFileSystem, never Get-Content,
            so the whole path is provable with no share and no disk (PROJECT
            constraint 4).

            The returned variables are re-materialised into an ordered,
            case-insensitive dictionary for the same reason Import-HDTRuleDocument
            does it: resolution applies them in document order and looks them up
            without caring how the author spelled the case.

        .PARAMETER WorkspaceRoot
            The workspace root. The override is at
            <WorkspaceRoot>\Control\machines\<Uuid>.yaml.

        .PARAMETER Uuid
            The machine UUID, as HDTUUID reports it. Empty or $null returns $null.
            Matching is case-insensitive because Windows paths are.

        .PARAMETER FileSystem
            An IFileSystem - the real adapter in production, New-HDTFakeFileSystem
            in a test.
            Defaults to the real one.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Path and Variable, or
            $null when there is no override. Path comes back with the variables
            because provenance names the file that supplied each value.

        .EXAMPLE
            $fact = Get-HDTMachineFact
            $override = Get-HDTMachineOverride -WorkspaceRoot 'X:\Deploy' `
                -Uuid $fact['HDTUUID']

        .EXAMPLE
            Resolve-HDTVariable -MachineOverride $override.Variable `
                -MachineOverridePath $override.Path -Fact $fact

            How the result is handed to the resolution engine.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Uuid,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # A machine whose UUID is unknown has no override to find, and asking the
    # filesystem about '<root>\Control\machines\.yaml' would be a lie.
    if ([string]::IsNullOrWhiteSpace($Uuid)) {
        return $null
    }

    $control = Join-Path -Path $WorkspaceRoot -ChildPath 'Control'
    $machine = Join-Path -Path $control -ChildPath 'machines'
    $path = Join-Path -Path $machine -ChildPath ('{0}.yaml' -f $Uuid)

    if (-not $FileSystem.TestPath($path)) {
        return $null
    }

    $document = ConvertFrom-HDTYaml -Yaml $FileSystem.ReadAllText($path) -Path $path

    # ONE VALIDATOR, NOT A SECOND COPY OF THE RULES. These checks used to live
    # here inline, which left machine.schema.json as the only schema in the
    # repository with no Assert-HDT*Document beside it - the published contract
    # and the engine were two hand-written copies of one vocabulary, and nothing
    # held them together. SchemaPairing.Contract.Tests.ps1 now refuses that
    # shape; the messages an administrator reads did not change in the move.
    Assert-HDTMachineDocument -Document $document -Path $path

    # -- the variables --------------------------------------------------------
    #
    # Re-materialised into an ordered, case-insensitive dictionary for the same
    # reason Import-HDTRuleDocument does it: resolution applies them in document
    # order and looks them up without caring how the author spelled the case.
    $declared = $document['variables']

    $variable = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($key in @($declared.Keys)) {
        $variable[[string] $key] = $declared[$key]
    }

    return [pscustomobject] ([ordered] @{
            Path     = $path
            Variable = $variable
        })
}
