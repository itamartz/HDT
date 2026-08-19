function Get-HDTBootImage {
    <#
        .SYNOPSIS
            Lists the boot images built on a deployment share, and which of them
            the share still declares.

        .DESCRIPTION
            A WORKSPACE DECLARES ONE BOOT IMAGE. bootImage is an object in
            workspace.schema.json rather than an array, the way an MDT deployment
            share has one LiteTouch image. So this command is not "the share's
            boot images" - it is what is sitting in Boot\, which is a different
            question and usually a longer answer.

            RENAMING THE IMAGE IS WHAT MAKES THE DIFFERENCE. Update-HDTBootImage
            writes <name>.wim, <name>.iso and <name>.manifest.json. Change the
            name on the Windows PE window and the next build writes a new trio
            beside the old one; nothing references the old name afterwards and
            nothing reported it. The lab share reached three names and about two
            gigabytes that way, which is what this command exists to show.

            IT READS THE MANIFESTS, NOT THE ARTIFACTS. Sizes and hashes come out
            of Boot\<name>.manifest.json, which Update-HDTBootImage wrote at
            build time precisely so nothing has to hash a 500 MB ISO to answer a
            question about it.

            IT NEVER THROWS FOR A BAD FILE. One truncated manifest among good
            ones is a row with Status 'Error', not a command that fails - the
            same three-answer shape Get-HDTConsoleBootImage uses for the declared
            image, and for the same reason: a fault in one build should not hide
            the other four.

            IT REMOVES NOTHING. Naming an orphan is useful; deciding to delete
            half a gigabyte off somebody's deployment share is not a thing a Get-
            command should do. Pipe it to Remove-Item by hand once you have
            looked at it.

        .PARAMETER Root
            The workspace root - a local path or a UNC share.

        .PARAMETER Orphan
            Only the builds the workspace does not declare.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] - one row per manifest
            in Boot\, newest build first, with Name, Declared, Status, Error,
            BuildId, BuiltUtc, BuiltOn, EngineVersion, Architecture, Language,
            ManifestPath, WimPath, WimSizeBytes, IsoPath, IsoSizeBytes and
            SizeBytes.

        .EXAMPLE
            Get-HDTBootImage -Root 'C:\HDTLab\Share'

            Every build on the share, the declared one marked.

        .EXAMPLE
            Get-HDTBootImage -Root 'C:\HDTLab\Share' -Orphan |
                Format-Table Name, BuiltUtc, @{ n = 'GB'; e = { [math]::Round($_.SizeBytes / 1GB, 2) } }

            What renaming the image has left behind, and what it is costing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,

        [Parameter()]
        [switch] $Orphan,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $bootFolder = Get-HDTWorkspacePath -Root $Root -Kind Boot

    # A SHARE BEING SET UP HAS NO Boot FOLDER, which is a legitimate state and
    # not an error - the console draws it as Missing rather than as a fault, and
    # an empty answer here is the same statement.
    if (-not $FileSystem.TestPath($bootFolder)) { return [pscustomobject[]] @() }

    # WHAT THE SHARE DECLARES, read once. A workspace that will not parse is not
    # a reason to refuse to list what is on the disk: the orphan question is
    # exactly the one somebody asks when the document is in a state they are
    # trying to understand.
    $declared = ''

    try {
        $workspacePath = [System.IO.Path]::Combine($Root, 'workspace.yaml')

        if ($FileSystem.TestPath($workspacePath)) {
            $workspace = Import-HDTWorkspaceDocument -Path $workspacePath -FileSystem $FileSystem
            $declared = [string] $workspace.BootImage.Name
        }
    } catch {
        $declared = ''
    }

    $row = New-Object -TypeName System.Collections.ArrayList

    foreach ($child in @($FileSystem.GetChildItem($bootFolder))) {

        $leaf = [System.IO.Path]::GetFileName([string] $child)
        if ($leaf -notlike '*.manifest.json') { continue }

        # THE NAME IS THE FILE NAME MINUS THE SUFFIX, not a key inside the
        # document: a manifest that will not parse still has a name, and it is
        # the name the artifacts beside it carry.
        $name = $leaf.Substring(0, $leaf.Length - '.manifest.json'.Length)

        $entry = [pscustomobject] @{
            Name          = $name
            Declared      = [bool] ($name -eq $declared)
            Status        = 'Ok'
            Error         = ''
            BuildId       = ''
            BuiltUtc      = $null
            BuiltOn       = ''
            EngineVersion = ''
            Architecture  = ''
            Language      = ''
            ManifestPath  = [string] $child
            WimPath       = ''
            WimSizeBytes  = [long] 0
            IsoPath       = ''
            IsoSizeBytes  = [long] 0
            SizeBytes     = [long] 0
        }

        try {
            $manifest = ConvertFrom-Json -InputObject ([string] $FileSystem.ReadAllText([string] $child))

            $artifact = Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'artifacts' -Default $null
            $wim = Get-HDTConsoleJsonProperty -InputObject $artifact -Name 'wim' -Default $null
            $iso = Get-HDTConsoleJsonProperty -InputObject $artifact -Name 'iso' -Default $null

            $entry.BuildId = [string] (Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'buildId')
            $entry.BuiltOn = [string] (Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'builtOn')
            $entry.EngineVersion = [string] (Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'engineVersion')
            $entry.Architecture = [string] (Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'architecture')
            $entry.Language = [string] (Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'language')

            # THE SAME TIMEZONE TRAP Get-HDTConsoleBootImage DOCUMENTS.
            # ConvertFrom-Json coerces an ISO-8601 value to a [datetime] on its
            # own and 5.1 and pwsh 7 disagree about the resulting Kind, so a
            # DateTime is taken as one and only a genuine string is parsed.
            $builtUtcValue = Get-HDTConsoleJsonProperty -InputObject $manifest -Name 'builtUtc' -Default $null

            if ($builtUtcValue -is [datetime]) {
                $entry.BuiltUtc = ([datetime] $builtUtcValue).ToUniversalTime()
            } elseif (-not [string]::IsNullOrWhiteSpace([string] $builtUtcValue)) {
                $entry.BuiltUtc = [datetime]::Parse([string] $builtUtcValue, [cultureinfo]::InvariantCulture,
                    ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor
                        [System.Globalization.DateTimeStyles]::AdjustToUniversal))
            }

            $entry.WimPath = [string] (Get-HDTConsoleJsonProperty -InputObject $wim -Name 'path')
            $entry.WimSizeBytes = [long] (Get-HDTConsoleJsonProperty -InputObject $wim -Name 'sizeBytes' -Default 0)
            $entry.IsoPath = [string] (Get-HDTConsoleJsonProperty -InputObject $iso -Name 'path')
            $entry.IsoSizeBytes = [long] (Get-HDTConsoleJsonProperty -InputObject $iso -Name 'sizeBytes' -Default 0)
            $entry.SizeBytes = $entry.WimSizeBytes + $entry.IsoSizeBytes
        } catch {
            # A MANIFEST THAT IS THERE AND WILL NOT READ IS A FAULT, and a
            # different one from a build that never happened. Collapsing the two
            # would tell somebody to rebuild when the real problem is a truncated
            # file on the share.
            $entry.Status = 'Error'
            $entry.Error = ("the manifest at '{0}' could not be read: {1}" -f $child, $_.Exception.Message)
        }

        [void] $row.Add($entry)
    }

    # NEWEST BUILD FIRST. The interesting row is nearly always the last build,
    # and what is under it is what has been sitting there since.
    #
    # A MANIFEST WITH NO DATE SORTS TO THE TOP, not the bottom. It is the one
    # that would not parse, and it is the row somebody needs to see - under five
    # good builds is where it would be missed. Sort-Object puts $null LAST on a
    # descending sort, so the date is substituted rather than the comparison
    # inverted: MaxValue is 'newer than every real build' and says in one
    # expression what a second sort key would take two to say.
    $ordered = @($row | Sort-Object -Property @{
            Expression = {
                if ($null -eq $_.BuiltUtc) { return [datetime]::MaxValue }
                return $_.BuiltUtc
            }
            Descending = $true
        })

    if ($Orphan) { $ordered = @($ordered | Where-Object { -not $_.Declared }) }

    return [pscustomobject[]] @($ordered)
}
