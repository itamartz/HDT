function Import-HDTBootstrapRuleDocument {
    <#
        .SYNOPSIS
            Reads bootstrap-rules.yaml - the rules that choose a share before
            there is one.

        .DESCRIPTION
            MDT'S Bootstrap.ini IS NOT A SETTINGS FILE, IT IS A RULES FILE.
            ZTIGather runs it in WinPE BEFORE the share is connected, with the
            whole priority engine available:

                [Settings]
                Priority=DefaultGateway, Default
                [DefaultGateway]
                192.168.2.1=Site-A
                [Site-A]
                DeployRoot=\\SERVER-A\DeploymentShare$

            That is how one boot image serves many sites, and HDT could not do
            it: bootstrap.json carries ONE deployRoot, baked in verbatim,
            because rules.yaml lives ON the share and nothing in it can choose
            the share.

            THE SAME GRAMMAR, A SMALLER VOCABULARY. This is a rules.yaml - the
            same when:, the same set:, the same first-match-wins - read by the
            same reader, so there is one rule language to learn rather than two.
            What it may SET is an allow-list, because it runs before there is a
            share, a workspace or a task sequence:

                HDTDeployRoot       which share to connect to
                HDTSkipWizard       whether to ask anybody anything
                HDTKeyboardLocale   the two the wizard needs before it draws
                HDTUILanguage

            Anything else is refused HERE, naming rules.yaml, rather than
            silently doing nothing on a machine at three in the morning. A rule
            setting HDTComputerName in this file would be deciding it from a
            document that cannot see the one that decides computer names.

            NO CREDENTIALS, AND THAT IS A DELIBERATE DIVERGENCE FROM MDT.
            Bootstrap.ini carries UserID and UserPassword in clear text, and
            DESIGN 14 lists it as one of MDT's known exposures HDT narrows. The
            account lives in Control\share-credential.json, written by
            Set-HDTShareCredential and embedded protected at build time.

            NO setFrom EITHER. setFrom names a script under Scripts\ ON THE
            SHARE, and there is no share yet. A rule that needs real logic here
            has nowhere to keep it.

        .PARAMETER Path
            The document. X:\HDT\bootstrap-rules.yaml inside a boot image;
            bootstrap-rules.yaml at the root of the share when authoring it.

        .PARAMETER FileSystem
            An IFileSystem. Injected, because this runs in WinPE.
            Defaults to the real one.

        .OUTPUTS
            The same object Import-HDTRuleDocument returns: SchemaVersion, Rule.

        .EXAMPLE
            $document = Import-HDTBootstrapRuleDocument -Path 'X:\HDT\bootstrap-rules.yaml'
            @($document.Rule).Count

            The rules that run before the share is reachable - which share to connect
            to, and as whom. MDT's Bootstrap.ini, in the boot image itself.

        .EXAMPLE
            @($document.Rule | ForEach-Object { $_.Name })

            Their names, in the order they will be considered. This file is inside the
            boot image: changing it means building the image again.

        .LINK
            Resolve-HDTBootstrapRule

        .LINK
            Import-HDTRuleDocument
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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

    # THE RULES READER, NOT A SECOND ONE. Everything about the grammar - the
    # schema version, the rule list, when:, %Var% - is already decided and
    # already tested; only the vocabulary differs.
    $document = Import-HDTRuleDocument -Path $Path -FileSystem $FileSystem

    Assert-HDTBootstrapRuleDocument -Document $document -Path $Path

    return $document
}
