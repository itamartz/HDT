function Import-HDTBootImageToWds {
    <#
        .SYNOPSIS
            Imports the HDT boot image into Windows Deployment Services,
            replacing an image of the same name rather than adding a second one.

        .DESCRIPTION
            HDT does not ship a PXE server; WDS serves the WIM.
            This is the command that puts it there, and REPLACE-IN-PLACE IS THE
            WHOLE POINT OF IT ("WDS import replacing rather than
            duplicating an existing image").

            THE FAILURE IT PREVENTS is familiar to anyone who has re-imported a
            boot image by hand: a PXE boot menu with a column of identically
            named images and no way to tell which one the fleet is actually
            booting. So this command asks the server what it already has,
            and when a row matches by name it REMOVES THAT ROW BEFORE IT IMPORTS -
            in that order, which is what the ordered journal in the unit suite
            asserts. An import before the remove would leave two images for a
            moment and then delete the new one.

            FIVE STEPS, AND THE ORDER IS THE CONTRACT:

              1. refuse a -Path that still carries an unexpanded %Var% token,
                 NAMING THE TOKENS - because that is a value nothing resolved
                 and not a file anybody has to go and rebuild;
              1b. refuse a -Path that is not an existing .wim, NAMING
                 Update-HDTBootImage - and call nothing. A refusal that had
                 already asked the server for its image list is a refusal that
                 touched production;
              2. -ImageName defaults to the WIM's base name (HDTPE_x64);
              3. GetBootImage(<architecture>);
              4. a row matching -ImageName CASE-INSENSITIVELY, on the same
                 architecture: RemoveBootImage then ImportBootImage. Both are
                 logged at Info, naming the image being replaced and its previous
                 version, because an administrator needs to know what was thrown
                 away. No match: ImportBootImage alone;
              5. return ImageName, Architecture, Path, Replaced, PreviousVersion.

            SupportsShouldProcess, and not as decoration:
            step 4 deletes a boot image a fleet PXE boots from. Under -WhatIf
            NOTHING is called, including the read.

            IT HAS NOW RUN AGAINST A REAL WDS SERVER, and that sentence
            replaces "it never has". On 2026-09-07 at 20:04 this command
            replaced the boot image on the lab's HDT-WDS-01 (Windows Server
            2025 Standard, standalone WDS) with the current share build:
            Replaced True, PreviousVersion 10.0.26100, and the server left
            holding exactly ONE x64 image named HDTPE_x64. The
            replace-in-place order - GetBootImage, RemoveBootImage,
            ImportBootImage - behaved on a real server the way the fake says it
            does, which is the whole reason the fake asserts an ORDERED journal.

            THAT IS ONE RUN, NOT A CONTRACT ROW. It cannot be repeated by the
            suite: this host is Windows 11 Pro, WDS is a Windows Server role,
            and the server is a VM reached by PowerShell Direct rather than
            anything Pester can stand up. So everything here is still asserted
            against New-HDTFakeWdsService, and the one assertion this machine
            makes against the real adapter is still that New-HDTWdsService
            refuses with a named dependency error.

            THE BOOT IS PROVEN TOO, and that sentence replaces "no machine has
            PXE booted from the imported image". On 2026-09-10 the client
            HDT-PXE-01 - Generation 2, on the HDT External switch - network
            booted from HDT-WDS-01 and ran an image this command had imported.
            DHCP came from the home router, not from WDS, with no options 66/67
            and no prestaging; WDS TFTP'd wdsmgfw.efi, bootmgfw.efi, a BCD it
            composed per request, Boot.SDI, and then 534 MB of boot WIM in
            SEVEN SECONDS on a variable TFTP window. Twenty-eight seconds after
            power-on the HDT engine had mapped the share, read eight rules and
            started a task sequence with nobody at the keyboard. SPIKES S27.

            TWO THINGS ARE STILL UNPROVEN, and neither is a detail.
            SECURE BOOT WAS OFF on that client - a Secure Boot ON network boot
            is untried and runs into the ADK bootloader's SVN floor (SPIKES
            S20/S20.2). And NO PXE DEPLOYMENT HAS COMPLETED: the client had no
            disk deliberately, so the sequence refused at Validate and never
            reached an apply. An import that lands and a client that boots are
            still not a fleet that deploys, and this file will not make the
            larger claim.

            NONE OF THIS IS EVIDENCE FOR New-HDTPxePayload. WDS composes its
            own per-client BCD at request time, merging its architecture store
            with the per-image one it writes at import; the payload's ADK-media
            store was never read. That command's own claim is unchanged.

        .PARAMETER Path
            The boot WIM to import, normally <workspace>\Boot\<name>.wim as
            Update-HDTBootImage wrote it.

        .PARAMETER ImageName
            What to call it on the server. Defaults to the WIM's base name.

        .PARAMETER Architecture
            The WDS image architecture: x64 (default), x86 or arm64. Note that
            this is WDS's vocabulary, not the ADK's - the ADK calls the same
            thing amd64.

        .PARAMETER WdsService
            An IWdsService. Defaults to the real adapter, which throws
            HDTDependencyError on a machine with no WDS module.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with ImageName,
            Architecture, Path, Replaced and PreviousVersion.

        .EXAMPLE
            $build = Update-HDTBootImage -WorkspaceRoot 'C:\HDTLab\Share' -WhatIf
            Import-HDTBootImageToWds -Path 'C:\HDTLab\Share\Boot\HDTPE_x64.wim'

            Imports as HDTPE_x64, replacing an existing HDTPE_x64 if the server
            has one.

        .EXAMPLE
            Import-HDTBootImageToWds -Path $build.WimPath -ImageName 'HDT (test ring)' -WhatIf

            What it would remove and what it would import, without touching the
            server.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun is BootImageToWds, and Wds is the acronym for Windows Deployment Services - not a plural. The analyzer sees the trailing s. DESIGN 6.1 names this command.')]
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ImageName,

        [Parameter()]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string] $Architecture = 'x64',

        [Parameter()]
        [AllowNull()]
        [object] $WdsService,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    # =====================================================================
    # 1. THE PATH, JUDGED BEFORE THE SERVICE IS EVEN BUILT
    # =====================================================================
    #
    # BEFORE, not after: the default -WdsService is New-HDTWdsService, which
    # throws on a machine with no WDS module, and a bad path should say so rather
    # than being masked by a dependency error. It is also what makes "it called
    # nothing" true of the refusal.

    # AN UNEXPANDED %Var% IS DIAGNOSED FIRST, BECAUSE IT IS NOT A MISSING FILE.
    #
    # OBSERVED, on this lab's WDS server at 06:25 on 2026-09-02: this command
    # refused with "there is no boot image at %HDTDeployRoot%\Boot\HDTPE_x64.wim"
    # - the token printed back verbatim, which is the tell - and then told the
    # operator to run Update-HDTBootImage against a boot image that already
    # existed and was perfectly healthy. The message named the SYMPTOM (no file
    # there) and sent somebody half an hour in the wrong direction. Nothing was
    # wrong with the file. The PATH had never been resolved.
    #
    # HOW A CALLER COMES TO HOLD ONE, AND IT IS NOT A TYPO. A step PROPERTY is
    # expanded by the step that reads it - Get-HDTStepProperty -Expand. A
    # SEQUENCE VARIABLE is seeded into the variable set exactly as AUTHORED, and
    # deliberately so: Expand-HDTVariableToken's scope has to hold RAW values or
    # a cycle cannot be detected at all. So a PowerShell step script that reads
    # $Variable['HDTWdsBootImageSource'] is handed the raw string, and the two
    # cases look identical in the YAML. That trap is not this command's to fix.
    # Printing "there is no boot image there" when the true answer is "nothing
    # expanded that" is.
    #
    # THE GRAMMAR IS Expand-HDTVariableToken'S, NOT A LOOSER ONE, so %% stays a
    # literal per cent and a batch file's %1 or a '50% done' path is an ordinary
    # path that falls through to the ordinary refusals below.
    $unexpanded = New-Object -TypeName System.Collections.ArrayList

    foreach ($token in [regex]::Matches($Path, '%%|%([A-Za-z_][A-Za-z0-9_]*)%')) {
        if ($token.Value -eq '%%') { continue }
        if (-not ($unexpanded -contains $token.Value)) { [void] $unexpanded.Add($token.Value) }
    }

    if ($unexpanded.Count -gt 0) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("that path still contains {0} unexpanded variable token(s) - {1} - so this is not a missing file, it is a value that nothing ever resolved. Expand it in the caller before importing. A step PROPERTY is expanded by the step that reads it; a SEQUENCE VARIABLE is seeded into the variable set exactly as authored, so a PowerShell step script that reads it out of the `$Variable dictionary and passes it here is handed the raw text. The two look identical in the YAML, which is why this refusal names the tokens rather than the file." -f
                        $unexpanded.Count, ((@($unexpanded) | ForEach-Object { "'" + $_ + "'" }) -join ', '))))
    }

    if ([System.IO.Path]::GetExtension($Path) -ne '.wim') {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path `
                    -Message ("that is not a .wim, and Windows Deployment Services serves boot images as WIMs. Import the file Update-HDTBootImage wrote to <workspace>\Boot\<name>.wim; the .iso beside it is the debugging vehicle, not something WDS can serve.")))
    }

    if (-not $FileSystem.TestPath($Path)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $Path -Category ObjectNotFound `
                    -Message ("there is no boot image there to import. Run Update-HDTBootImage against the workspace first - it writes <workspace>\Boot\<name>.wim and the manifest beside it.")))
    }

    $name = $ImageName
    if (-not $PSBoundParameters.ContainsKey('ImageName')) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    }

    # =====================================================================
    # 2. WHAT THE SERVER ALREADY HAS
    # =====================================================================

    $description = 'Import boot image ''{0}'' ({1})' -f $name, $Architecture

    if (-not $PSCmdlet.ShouldProcess($Path, $description)) {
        return [pscustomobject] @{
            ImageName       = $name
            Architecture    = $Architecture
            Path            = $Path
            Replaced        = $false
            PreviousVersion = ''
        }
    }

    if ($null -eq $WdsService) { $WdsService = New-HDTWdsService }

    $existing = @($WdsService.GetBootImage($Architecture))

    # CASE-INSENSITIVELY. WDS image names are not case sensitive, and neither is
    # the decision about whether one is already there.
    $match = @($existing | Where-Object {
            [string] $_.ImageName -eq $name -or
            ([string] $_.ImageName).Equals($name, [System.StringComparison]::OrdinalIgnoreCase)
        })

    $replaced = $false
    $previousVersion = ''

    # =====================================================================
    # 3. REMOVE, THEN IMPORT - IN THAT ORDER
    # =====================================================================

    if ($match.Count -gt 0) {
        $previousVersion = [string] $match[0].Version
        $replaced = $true

        # WHAT WAS THROWN AWAY, said out loud. A fleet boots from this image;
        # a run that replaced one silently would leave nobody able to say what
        # the previous one was.
        Write-Information ("Replacing the existing WDS boot image '{0}' ({1}), version '{2}', file '{3}'. It is removed before the new image is imported, so the server ends with one image of this name rather than two." -f
            [string] $match[0].ImageName, $Architecture, $previousVersion, [string] $match[0].FileName)

        $WdsService.RemoveBootImage([string] $match[0].ImageName, $Architecture)
    }

    Write-Information ("Importing '{0}' into WDS as boot image '{1}' ({2})." -f $Path, $name, $Architecture)

    $WdsService.ImportBootImage($Path, $name, $Architecture)

    return [pscustomobject] @{
        ImageName       = $name
        Architecture    = $Architecture
        Path            = $Path
        Replaced        = $replaced
        PreviousVersion = $previousVersion
    }
}
