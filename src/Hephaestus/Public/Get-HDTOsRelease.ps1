function Get-HDTOsRelease {
    <#
        .SYNOPSIS
            The operating system releases a Windows update can be filed under.

        .DESCRIPTION
            THE LIST EXISTS BECAUSE A .msu DOES NOT SAY WHAT IT IS FOR. The
            2026-06 cumulative update for Windows 11 24H2 and the one for Windows
            Server 2025 are both delivered as
            windows11.0-kb50941xx-x64_<sha>.msu, and both describe themselves
            internally as Product="Desktop", BuildArch="amd64", baseline
            10.0.26100.1742, build 26100. Nothing in either file separates them.
            So an administrator names the release at import, and this is what
            they choose from - in the console's import dialog, and on the command
            line.

            SHARE FIRST, MODULE SECOND, WHICH IS wimscript.ini's RULE. A share
            with Control\os-releases.yaml gets its own list; a share without one
            gets the module's Templates\Control\os-releases.yaml. That is what stops
            feature being invisible on every share created before it existed -
            the failure mode DESIGN 11.2 and CLAUDE.md both warn about, where a
            seeded tree is never overwritten and so never gains anything added
            afterwards.

            IT IS NOT THE OPERATING SYSTEM CATALOG. OperatingSystems\ is what has
            been imported; a release is what an update TARGETS, and an
            administrator legitimately imports next month's updates before the
            media lands. Binding an update to an os.yaml would refuse that
            perfectly ordinary thing.

            Verified IS CARRIED THROUGH RATHER THAN SMOOTHED AWAY. A release is
            verified only when its build number was read off real media or a real
            package. An unverified release still matches - the administrator's
            label is the authority and HDT does not refuse an import because this
            repository has not seen the media - but Import-HDTWindowsUpdate warns,
            and the console marks the row, so a number somebody typed from memory
            never passes for one that was measured.

            A RELEASE WITH NO BUILD IS A RELEASE THAT CANNOT BE CHECKED, and
            HasBuild says so in one boolean rather than making every caller
            reason about a zero. Windows 11 26H2 ships that way on purpose: its
            build was not read here, and a guessed number would silently refuse
            every correct import filed under it.

        .PARAMETER WorkspaceRoot
            The workspace root. Its Control\os-releases.yaml is used when it has
            one; otherwise the module's own list is returned.

        .PARAMETER Id
            One release id to return. Omit it for the whole list.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one; a test passes
            New-HDTFakeFileSystem and the whole reader is provable with no share.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject, one per release:

              Id          the key an update records
              Name        what the console shows
              Build       the major build, or 0 when it was never read
              HasBuild    whether Build is a fact
              Branch      the expected servicing branch token, or empty
              Verified    whether Build was read off media or a package
              Note        why, in one line
              Source      'workspace' or 'module' - which list answered

        .EXAMPLE
            Get-HDTOsRelease -WorkspaceRoot 'C:\HDTLab\Share' | Format-Table Id, Name, Build, Verified

            The releases this share offers, and which of their build numbers were
            measured.

        .EXAMPLE
            Get-HDTOsRelease -WorkspaceRoot 'C:\HDTLab\Share' -Id 'WS2025'

            One release, as Import-HDTWindowsUpdate resolves it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [ValidateNotNull()]
        [object] $FileSystem = (New-HDTFileSystem)
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $sharePath = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Control -ChildPath 'os-releases.yaml'

    # THE SHARE'S OWN LIST WINS, AND THE MODULE'S IS THE FLOOR. Neither is
    # merged into the other: a share that has taken ownership of the list has
    # said which releases it deploys, and quietly adding rows it did not write
    # would make its own file a partial truth.
    $path = $sharePath
    $source = 'workspace'

    if (-not $FileSystem.TestPath($sharePath)) {
        # Templates\Control\, NOT Templates\. Templates\*.yaml IS the task
        # sequence template folder - Get-HDTSequenceTemplate enumerates every
        # .yaml in it and parses each as a sequence - so a release list left
        # there is offered in the New Task Sequence picker and throws when
        # somebody picks it. Found by the gate, not by reading.
        $path = [System.IO.Path]::Combine($script:HDTModuleRoot, 'Templates', 'Control', 'os-releases.yaml')
        $source = 'module'
    }

    $document = ConvertFrom-HDTYaml -Yaml ($FileSystem.ReadAllText($path)) -Path $path
    Assert-HDTOsReleaseDocument -Document $document -Path $path

    $row = foreach ($entry in @($document['releases'])) {

        # A MISSING build IS ZERO AND HasBuild IS FALSE, rather than a null every
        # caller has to remember to test. Windows 11 26H2 ships this way: the
        # release is real and its build was never read here.
        $build = 0
        if ($entry.Contains('build')) { $build = [int] $entry['build'] }

        $name = [string] $entry['id']
        if ($entry.Contains('name')) { $name = [string] $entry['name'] }

        $branch = ''
        if ($entry.Contains('branch')) { $branch = [string] $entry['branch'] }

        $verified = $false
        if ($entry.Contains('verified')) { $verified = [bool] $entry['verified'] }

        $note = ''
        if ($entry.Contains('note')) { $note = [string] $entry['note'] }

        [pscustomobject] @{
            Id       = [string] $entry['id']
            Name     = $name
            Build    = $build
            HasBuild = ($build -gt 0)
            Branch   = $branch
            Verified = $verified
            Note     = $note
            Source   = $source
        }
    }

    $result = @($row)

    if ($PSBoundParameters.ContainsKey('Id')) {
        $result = @($result | Where-Object { $_.Id -eq $Id })

        if ($result.Count -eq 0) {
            $known = (@($row | ForEach-Object { $_.Id }) -join ', ')

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $path `
                        -Message ("no operating system release with the id '{0}' is listed. This share offers: {1}. Add a release by copying the module's os-releases.yaml into Control\ and editing it there." -f $Id, $known) `
                        -Category ObjectNotFound))
        }
    }

    return [pscustomobject[]] @($result)
}
