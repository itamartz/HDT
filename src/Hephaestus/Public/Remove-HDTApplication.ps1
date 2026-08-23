function Remove-HDTApplication {
    <#
        .SYNOPSIS
            Removes an application from a deployment share.

        .DESCRIPTION
            THE OTHER HALF OF Import-HDTApplication, and until it existed an
            application imported by mistake had to be removed with Explorer -
            which is how somebody deletes the wrong folder. Deployment Workbench
            offers Delete on the right-click menu of an application; this is the
            command behind it.

            IT DELETES A FOLDER, so the guards are the ones CLAUDE.md demands of
            anything that does. The id names a folder under Applications\ and is
            checked TWICE: once as typed - no separators, no spaces, not . or ..
            - and once as resolved, because what matters is where it ended up
            rather than how it looked. A target that is not provably inside this
            share's Applications folder is refused with nothing removed.

            A FOLDER WITH NO app.yaml IS NOT AN APPLICATION. It is somebody's
            staging directory that happens to sit under Applications\, and this
            command must not be the thing that removes it.

            TWO KINDS OF THING CAN BE USING IT, and they fail differently.
            UsedBy holds the task sequences whose InstallApplications selection
            names it: that deployment fails at that step, late. RequiredBy holds
            the applications that name it as a dependency, and that is worse -
            Resolve-HDTApplicationOrder refuses a plan with a missing
            dependency, so removing this one can stop an unrelated application
            from installing at all.

            NEITHER IS A REFUSAL. An administrator replacing a package knows
            more than this command does, and a delete that cannot be done
            because something refers to it is a delete nobody can ever do. They
            are reported - including under -WhatIf, so a dialog can name them
            before anybody agrees to anything.

            A SELECTION THAT IS A VARIABLE CANNOT BE TRACED. `selection:
            '%HDTApplications%'` is resolved from the rules at run time, so a
            sequence that installs whatever the rules say does not appear in
            UsedBy - there is nothing in the document to read. That is a limit
            of what is knowable here, not an oversight.

            ConfirmImpact IS High, so it prompts unless the caller says
            -Confirm:$false. The console says it, having asked in its own dialog.

        .PARAMETER WorkspaceRoot
            The share's root.

        .PARAMETER Id
            The application's id - the folder name under Applications\.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Id, Path, UsedBy -
            the ids of the task sequences that named it - and RequiredBy, the
            ids of the applications that depend on it.

        .EXAMPLE
            Remove-HDTApplication -WorkspaceRoot 'C:\HDTLab\Share' -Id '7Zip-24.09'

        .EXAMPLE
            (Remove-HDTApplication -WorkspaceRoot 'C:\HDTLab\Share' -Id '7Zip-24.09' -WhatIf).RequiredBy

            What would break, without removing anything.

        .LINK
            Import-HDTApplication

        .LINK
            Get-HDTApplication
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        # -WorkspaceRoot, NOT -Workspace, AND FROM THE PIPELINE. Import, Get and
        # Set all call the share -WorkspaceRoot; one concept under two names is
        # a red line after typing what worked on the previous command. Binding
        # by property name is what makes the obvious call work:
        # Get-HDTApplication ... | Remove-HDTApplication.
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspaceRoot,

        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    # ONE OBJECT AT A TIME. -WorkspaceRoot and -Id bind from the pipeline,
    # and a flat body would run once, for the last entry handed over.
    process {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

        # -- the id, before it becomes a path ------------------------------------

        if ($Id -match '[\\/:*?"<>|]' -or $Id -match '\s' -or $Id -eq '.' -or $Id -eq '..') {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id `
                        -Message ("'{0}' cannot be an application id. An id is a folder name: no spaces, and none of \ / : * ? `" < > |. This command deletes the folder it names, so an id that is a path is refused rather than resolved." -f $Id)))
        }

        $folder = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications -ChildPath $Id
        $document = Join-Path -Path $folder -ChildPath 'app.yaml'

        # -- and the path, after -------------------------------------------------
        #
        # THE SECOND CHECK IS NOT THE FIRST ONE AGAIN. That one judged what was
        # typed; this judges what it resolved to, which is the thing about to be
        # removed.
        $applicationRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind Applications

        if (-not ([System.IO.Path]::GetFullPath($folder)).StartsWith(
                ([System.IO.Path]::GetFullPath($applicationRoot)).TrimEnd('\') + '\',
                [System.StringComparison]::OrdinalIgnoreCase)) {

            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                        -Message ("'{0}' resolves to '{1}', which is not inside this workspace's Applications folder. Nothing was removed." -f $Id, $folder)))
        }

        # -- is it an application at all? ----------------------------------------

        if (-not $FileSystem.TestPath($folder)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder -Category ObjectNotFound `
                        -Message ("this workspace has no application called '{0}'." -f $Id)))
        }

        if (-not $FileSystem.TestPath($document)) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $folder `
                        -Message ("'{0}' holds no app.yaml, so it is not an application - it is a folder that happens to sit under Applications. Remove it yourself if that is what you meant." -f $folder)))
        }

        # -- who was using it ----------------------------------------------------
        #
        # READ BEFORE THE DELETE, because afterwards the answer is the same and the
        # package is gone. A document that will not read is skipped rather than
        # failing the removal: it has its own broken row in the console already.
        $usedBy = New-Object -TypeName System.Collections.ArrayList
        $sequenceRoot = Get-HDTWorkspacePath -Root $WorkspaceRoot -Kind TaskSequences

        if ($FileSystem.TestPath($sequenceRoot)) {
            foreach ($child in @($FileSystem.GetChildItem($sequenceRoot))) {

                $sequencePath = Join-Path -Path ([string] $child) -ChildPath 'sequence.yaml'
                if (-not $FileSystem.TestPath($sequencePath)) { continue }

                $named = ''

                try {
                    $parsed = ConvertFrom-HDTYaml -Yaml ([string] $FileSystem.ReadAllText($sequencePath)) -Path $sequencePath
                } catch {
                    continue
                }

                if (-not (Test-HDTSequenceNamesApplication -Document $parsed -Id $Id)) { continue }

                try { $named = [string] $parsed['id'] } catch { $named = '' }

                if ([string]::IsNullOrWhiteSpace($named)) {
                    $named = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))
                }

                [void] $usedBy.Add($named)
            }
        }

        # -- and what depends on it ----------------------------------------------

        $requiredBy = New-Object -TypeName System.Collections.ArrayList

        foreach ($child in @($FileSystem.GetChildItem($applicationRoot))) {
            $otherPath = Join-Path -Path ([string] $child) -ChildPath 'app.yaml'
            if (-not $FileSystem.TestPath($otherPath)) { continue }
            if ([string]::Equals($otherPath, $document, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            try {
                $other = ConvertFrom-HDTYaml -Yaml ([string] $FileSystem.ReadAllText($otherPath)) -Path $otherPath
            } catch {
                continue
            }

            if ($null -eq $other -or -not $other.Contains('dependencies')) { continue }

            $dependsOnIt = @(@($other['dependencies']) |
                    Where-Object { [string]::Equals(([string] $_).Trim(), $Id, [System.StringComparison]::OrdinalIgnoreCase) })

            if (@($dependsOnIt).Count -eq 0) { continue }

            $otherId = ''
            try { $otherId = [string] $other['id'] } catch { $otherId = '' }

            if ([string]::IsNullOrWhiteSpace($otherId)) {
                $otherId = [System.IO.Path]::GetFileName(([string] $child).TrimEnd('\', '/'))
            }

            [void] $requiredBy.Add($otherId)
        }

        $answer = [pscustomobject] @{
            Id         = $Id
            Path       = $folder
            UsedBy     = [string[]] @($usedBy)
            RequiredBy = [string[]] @($requiredBy)
        }

        $said = "Remove application '{0}' and everything in its folder" -f $Id
        if (@($usedBy).Count -gt 0) {
            $said = '{0}. It is installed by: {1}' -f $said, (@($usedBy) -join ', ')
        }
        if (@($requiredBy).Count -gt 0) {
            $said = '{0}. It is required by: {1}' -f $said, (@($requiredBy) -join ', ')
        }

        if (-not $PSCmdlet.ShouldProcess($folder, $said)) { return $answer }

        $FileSystem.RemoveItem($folder, $true)

        return $answer
    }
}
