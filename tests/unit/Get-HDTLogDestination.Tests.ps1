# MDT's SLShare, which HDT did not have.
#
# The copy-back destination was derived and nothing could change it: logs landed
# under <deployRoot>\Logs and nowhere else. MDT sites point SLShare at a log
# server precisely BECAUSE it is not the deployment share - a read-only share
# that a technician's account cannot write to, a site whose deployments run from
# a replica, a team that keeps deployment logs where the rest of their logs are.
#
# THE NAME IS MDT'S AND SO IS THE BEHAVIOUR. HDTSLShare, not HDTLogShare: an
# admin arriving from Workbench searches for what they already know.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'src/Hephaestus/Hephaestus.psd1') -Force -ErrorAction Stop

    $script:bag = {
        param([System.Collections.IDictionary] $Value)

        $live = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -ne $Value) {
            foreach ($key in @($Value.Keys)) { $live[[string] $key] = $Value[$key] }
        }

        return $live
    }
}

Describe 'Get-HDTLogDestination' {

    Context 'the command exists and is shaped like the rest of the engine' {

        It 'is exported by Hephaestus' {
            Get-Command -Name 'Get-HDTLogDestination' -Module 'Hephaestus' -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'no HDTSLShare, which is every deployment that has ever run' {

        It 'lands under the deploy root, exactly where it always did' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' -Variable (& $script:bag $null)

            [string] $answer.Path | Should -BeExactly 'Z:\Deploy\Logs'
            [string] $answer.Source | Should -BeExactly 'DeployRoot'
        }

        It 'treats an empty HDTSLShare as no HDTSLShare' {
            # A rule that set it to '' is a rule that meant to leave it alone,
            # and a copy-back to the empty string is a run whose logs vanish.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '   ' }))

            [string] $answer.Path | Should -BeExactly 'Z:\Deploy\Logs'
            [string] $answer.Source | Should -BeExactly 'DeployRoot'
        }
    }

    Context 'HDTSLShare, MDT-style' {

        It 'sends the logs where the rule says' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '\\logs-01\HDTLogs' }))

            [string] $answer.Path | Should -BeExactly '\\logs-01\HDTLogs'
            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }

        It 'uses it verbatim rather than appending Logs to it' {
            # MDT's SLShare IS the folder - LiteTouch writes <SLShare>\<computer>
            # and never <SLShare>\Logs\<computer>. An engine that appended would
            # put logs somewhere the admin did not name.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '\\logs-01\HDTLogs' }))

            [string] $answer.Path | Should -Not -BeLike '*Logs\Logs*'
        }

        It 'trims what a rule left around it' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '  \\logs-01\HDTLogs  ' }))

            [string] $answer.Path | Should -BeExactly '\\logs-01\HDTLogs'
        }

        It 'takes a local path as readily as a UNC' {
            # A lab, a USB stick, standalone media: the log share does not have
            # to be a server.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = 'D:\HDTLogs' }))

            [string] $answer.Path | Should -BeExactly 'D:\HDTLogs'
            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }

        It 'reads the name case-insensitively, as every variable in this engine is' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'Z:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ hdtslshare = '\\logs-01\HDTLogs' }))

            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }
    }

    Context 'a deployment with no root at all' {

        It 'returns nothing rather than a path built from an empty root' {
            # A run that never resolved a deploy root has nowhere to copy to,
            # and '\Logs' is a path on whatever drive the process happens to be
            # standing on.
            $answer = Get-HDTLogDestination -WorkspaceRoot '' -Variable (& $script:bag $null)

            [string] $answer.Path | Should -BeExactly ''
            [string] $answer.Source | Should -BeExactly 'None'
        }

        It 'still honours HDTSLShare when there is no deploy root' {
            # THE CASE THAT MAKES IT WORTH HAVING: the share could not be
            # reached, which is exactly the run whose log somebody needs.
            $answer = Get-HDTLogDestination -WorkspaceRoot '' `
                -Variable (& $script:bag ([ordered] @{ HDTSLShare = '\\logs-01\HDTLogs' }))

            [string] $answer.Path | Should -BeExactly '\\logs-01\HDTLogs'
            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }
    }

    # A DISC IS NOT A PLACE TO WRITE LOGS TO, AND A NETWORK IS NOT A REASON TO
    # FIND ONE. The deploy root is right for a share and wrong for media: it is
    # read-only content, and a machine that happens to have a NIC is still
    # deploying from a disc - reaching for a share nobody named is not a
    # fallback, it is a guess.
    #
    # THE MACHINE STILL KEEPS ITS OWN COPY. The WinPE leg writes its log to
    # <osvolume>\HDT\Logs before the restart, which needs no network and is the
    # copy an administrator actually reads. Nothing here touches that, so this
    # removes a copy nobody could have made rather than the one that matters.

    Context 'a deployment that booted from media' {

        It 'does not send the logs to the deploy root, because that is read-only content' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'D:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTDeploymentMethod = 'MEDIA' }))

            [string] $answer.Path | Should -BeExactly ''
        }

        It 'says the method is why, with Source Media rather than None' {
            # 'None' means no deploy root was resolved at all, which is a
            # different fact about a different run. RESULT.json carries this
            # word, so a reader of that file learns which of the two happened.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'D:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTDeploymentMethod = 'MEDIA' }))

            [string] $answer.Source | Should -BeExactly 'Media'
        }

        It 'reports the destination it did NOT use, so the log can name it' {
            # "no log destination" on its own reads like a failure to resolve
            # one, and sends the reader looking for a share that is working
            # perfectly well.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'D:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTDeploymentMethod = 'MEDIA' }))

            [string] $answer.Skipped | Should -BeExactly 'D:\Deploy\Logs'
        }

        It 'still honours an explicitly set HDTSLShare, because an admin named it in so many words' {
            # THE ORDER IS THE DESIGN. The media check sits AFTER the HDTSLShare
            # branch: an administrator who names a log share is asking for one
            # outright, and that answer is right whatever the machine booted
            # from. This only removes the DERIVED destination.
            $answer = Get-HDTLogDestination -WorkspaceRoot 'D:\Deploy' `
                -Variable (& $script:bag ([ordered] @{
                            HDTDeploymentMethod = 'MEDIA'
                            HDTSLShare          = '\\logs-01\HDTLogs'
                        }))

            [string] $answer.Path | Should -BeExactly '\\logs-01\HDTLogs'
            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }

        It 'reads HDTDeploymentMethod case-insensitively, as every variable in this engine is' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'D:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ hdtdeploymentmethod = 'media' }))

            [string] $answer.Source | Should -BeExactly 'Media'
        }

        It 'trims what a rule left around the method' {
            $answer = Get-HDTLogDestination -WorkspaceRoot 'D:\Deploy' `
                -Variable (& $script:bag ([ordered] @{ HDTDeploymentMethod = '  MEDIA  ' }))

            [string] $answer.Source | Should -BeExactly 'Media'
        }

        It 'has nothing to skip when there was no deploy root either' {
            # AND IT STILL ANSWERS Media, NOT None. A media run whose root never
            # resolved skipped nothing because there was nothing to skip, and
            # the method is still the honest account of why no copy-back
            # happened.
            $answer = Get-HDTLogDestination -WorkspaceRoot '' `
                -Variable (& $script:bag ([ordered] @{ HDTDeploymentMethod = 'MEDIA' }))

            [string] $answer.Path | Should -BeExactly ''
            [string] $answer.Source | Should -BeExactly 'Media'
            [string] $answer.Skipped | Should -BeExactly ''
        }

        It 'is unmoved by a machine that happens to have a network' {
            # ASSERTED BY CONSTRUCTION, because there is no network here to
            # fake: the command takes only -WorkspaceRoot and -Variable, so
            # there is nothing in its signature that could consult one. "A
            # machine that happens to have a NIC is still deploying from a disc"
            # is a fact about the shape of this command, not a runtime check.
            $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
            @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

            $parameter = @((Get-Command -Name 'Get-HDTLogDestination').Parameters.Keys |
                    Where-Object { $common -notcontains $_ } |
                    Sort-Object)

            ($parameter -join ',') | Should -BeExactly 'Variable,WorkspaceRoot'
        }
    }

    Context 'a deployment that came from a share' {

        It 'still lands under the deploy root, exactly where it always did' {
            $answer = Get-HDTLogDestination -WorkspaceRoot '\\srv\HDTShare$' `
                -Variable (& $script:bag ([ordered] @{ HDTDeploymentMethod = 'UNC' }))

            [string] $answer.Path | Should -BeExactly '\\srv\HDTShare$\Logs'
            [string] $answer.Source | Should -BeExactly 'DeployRoot'
        }

        It 'still prefers HDTSLShare over the deploy root' {
            $answer = Get-HDTLogDestination -WorkspaceRoot '\\srv\HDTShare$' `
                -Variable (& $script:bag ([ordered] @{
                            HDTDeploymentMethod = 'UNC'
                            HDTSLShare          = '\\logs-01\HDTLogs'
                        }))

            [string] $answer.Source | Should -BeExactly 'HDTSLShare'
        }

        It 'is unchanged by the method being absent, as it is in every state.json written before this' {
            # THE COMPATIBILITY CASE, AND IT IS NOT OPTIONAL. The gate reads
            # -eq 'MEDIA' and not -ne 'UNC' precisely so that absent, empty and
            # unrecognised all keep the old behaviour; a negative test would
            # turn every state.json written before this phase into a silent
            # skip, which is the opposite of the default this engine wants.
            $answer = Get-HDTLogDestination -WorkspaceRoot '\\srv\HDTShare$' -Variable (& $script:bag $null)

            [string] $answer.Path | Should -BeExactly '\\srv\HDTShare$\Logs'
            [string] $answer.Source | Should -BeExactly 'DeployRoot'
        }

        It 'is unchanged by an empty method, which is what a cleared variable leaves' {
            $answer = Get-HDTLogDestination -WorkspaceRoot '\\srv\HDTShare$' `
                -Variable (& $script:bag ([ordered] @{ HDTDeploymentMethod = '   ' }))

            [string] $answer.Source | Should -BeExactly 'DeployRoot'
        }
    }

    Context 'the shape every caller reads' {

        # A PROPERTY THAT EXISTS ON ONE BRANCH AND NOT THE OTHERS is the shape
        # that makes Set-StrictMode -Version Latest throw in a caller three
        # files away. All four answers carry Skipped; three of them carry it
        # empty.

        It 'carries Skipped on every answer it can give' -ForEach @(
            @{ Case = 'HDTSLShare'; Root = 'Z:\Deploy'; Bag = [ordered] @{ HDTSLShare = '\\logs-01\HDTLogs' } }
            @{ Case = 'DeployRoot'; Root = 'Z:\Deploy'; Bag = [ordered] @{} }
            @{ Case = 'None'; Root = ''; Bag = [ordered] @{} }
            @{ Case = 'Media'; Root = 'D:\Deploy'; Bag = [ordered] @{ HDTDeploymentMethod = 'MEDIA' } }
        ) {
            $answer = Get-HDTLogDestination -WorkspaceRoot $Root -Variable (& $script:bag $Bag)

            @($answer.PSObject.Properties.Name) | Should -Contain 'Skipped' -Because $Case
        }

        It 'leaves Skipped empty on every answer but the media one' -ForEach @(
            @{ Case = 'HDTSLShare'; Root = 'Z:\Deploy'; Bag = [ordered] @{ HDTSLShare = '\\logs-01\HDTLogs' } }
            @{ Case = 'DeployRoot'; Root = 'Z:\Deploy'; Bag = [ordered] @{} }
            @{ Case = 'None'; Root = ''; Bag = [ordered] @{} }
        ) {
            $answer = Get-HDTLogDestination -WorkspaceRoot $Root -Variable (& $script:bag $Bag)

            [string] $answer.Skipped | Should -BeExactly '' -Because $Case
        }
    }
}
