function Show-HDTWizard {
    <#
        .SYNOPSIS
            Shows the technician wizard and returns what the technician chose.

        .DESCRIPTION
            W1 of the WPF-first direction, and MDT's
            LiteTouch wizard is what it grows into: the window a technician sees
            when a machine boots the deployment image and nothing has been
            decided for it in advance.

            THE WINDOW IS NOT IN THIS FUNCTION. An injected IWizardHost owns
            everything WPF - Add-Type, XamlReader, ShowDialog - and this function
            owns the decisions. That is the same split every other service in
            this engine uses, and it is what lets the wizard be
            asserted on a developer machine with no display and no WinPE.
            New-HDTWizardHost is the real one, and it is branch-free BECAUSE it
            is not unit tested.

            A DISMISSED WINDOW IS A CANCEL, and that is the one piece of logic
            here that is not plumbing. Next leads to a task sequence that
            partitions a disk. A window closed with the X, a dialog killed by
            the shell, a host that returns nothing at all - none of those are a
            technician saying yes, so anything that is not on the allow-list
            comes back as 'Cancel'. The refusal is deliberate rather than
            defensive: reading an empty answer as approval is how an unattended
            machine wipes a disk nobody meant to wipe.

            THREE ANSWERS, AND ONLY THESE THREE:

              Next           the technician approved. The only one that deploys.
              Cancel         everything else, including silence.
              CommandPrompt  MDT's "Exit to Command Prompt" - the escape hatch
                             for a wrong network, a missing driver, or diskpart.

            OPENING THE PROMPT IS THE CALLER'S JOB, NOT THIS COMMAND'S. This
            reports what the technician asked for; the payload decides what a
            prompt means on that machine - which shell, whether the wizard comes
            back afterwards, whether the console has to be un-hidden first. The
            same split that keeps the window out of this function keeps
            cmd.exe out of it.

            THE XAML IS CHECKED BEFORE THE WINDOW IS SHOWN. A file that is not
            there, or that is not well-formed, is refused by name - on the build
            host if the image is being tested there, and with a readable
            sentence in WinPE if not. What is checked is XML well-formedness,
            not XAML semantics: a tag that WPF dislikes still fails at Show, but
            a truncated or half-written file - the shape a bad copy into a boot
            image produces - fails here, before a technician is staring at it.

        .PARAMETER XamlPath
            The window to show. X:\HDT\UI\HDTWizard.xaml inside a boot image.

        .PARAMETER Title
            The window title.

        .PARAMETER Field
            What every box should say, from Get-HDTWizardField. Each entry is a
            control Name and its Text; the host applies them by name and this
            command interprets none of them. Omitted, the window opens with
            whatever the markup declares.

        .PARAMETER Pane
            Which panes are visible, from Get-HDTWizardSkip. Each entry is a
            control Name and a Visible flag; the host collapses the ones that
            are not. Omitted, every pane the markup declares is shown.

            NOTE THAT HDTSkipWelcome IS NOT HANDLED HERE. Skipping the whole
            window means NOT CALLING THIS COMMAND, which is the caller's
            decision - a Show-HDTWizard that sometimes showed nothing would
            return an Action for a window nobody saw.

        .PARAMETER WizardHost
            An IWizardHost. Defaults to the real adapter.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real adapter.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Action ('Next',
            'Cancel' or 'CommandPrompt'), Title and XamlPath.

        .EXAMPLE
            Show-HDTWizard -XamlPath 'X:\HDT\UI\HDTWizard.xaml'

            What the payload calls in WinPE.

        .EXAMPLE
            $answer = Show-HDTWizard -XamlPath $p -WizardHost (New-HDTFakeWizardHost -Action 'Next')
            if ($answer.Action -ne 'Next') { return }

            How every caller must read it: proceed only on an explicit Next.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $XamlPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Title = 'Hephaestus Deployment Toolkit',

        [Parameter()]
        [AllowNull()]
        [object[]] $Field,

        [Parameter()]
        [AllowNull()]
        [object[]] $Pane,

        [Parameter()]
        [AllowNull()]
        [object] $WizardHost,

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem,

        # F8, THE SAME AS EVERY OTHER WINDOW IN THIS IMAGE. The Welcome screen
        # is the first thing on the machine and the one shown when the share
        # cannot be reached - which is exactly when a technician wants a prompt.
        # A key that works on two of the three windows is a key nobody trusts.
        [Parameter()]
        [AllowNull()]
        [scriptblock] $CommandPrompt,

        # WHICH BOXES TO READ BACK, from Get-HDTWizardHarvest. Omitted, the
        # screen answers with an Action alone - which is what it did before this
        # existed, and why a corrected share was thrown away.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Collect = @()
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }
    if ($null -eq $WizardHost) { $WizardHost = New-HDTWizardHost }
    if ($null -eq $CommandPrompt) { $CommandPrompt = { [void] (Start-HDTCommandPrompt) } }

    # -- the window file, before anything is shown -------------------------

    if (-not $FileSystem.TestPath($XamlPath)) {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath -Category ObjectNotFound `
                    -Message ("the wizard window '{0}' is not there, so there is nothing to show. In a boot image it is staged to X:\HDT\UI\ by Update-HDTBootImage." -f $XamlPath)))
    }

    $xaml = [string] $FileSystem.ReadAllText($XamlPath)

    try {
        [void] ([xml] $xaml)
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -Path $XamlPath -Category InvalidData `
                    -Message ("the wizard window '{0}' is not well-formed XML, so it could not be shown: {1}" -f
                        $XamlPath, [string] $_.Exception.Message)))
    }

    # -- the text --------------------------------------------------------------
    #
    # THE MARKUP CARRIES NO PROSE, so the block that fills it is chosen here and
    # handed to the host, which applies it and decides nothing.
    #
    # THE FILE NAME IS THE BLOCK NAME, without the HDT and without the
    # extension: HDTWelcome.xaml is filled by Welcome, HDTFailure.xaml by
    # Failure. Every window in this module already follows it, and a convention
    # is one fewer table to keep in step with the markup.
    #
    # A WINDOW WITH NO BLOCK IS SHOWN ANYWAY. Tools and tests load scratch
    # markup that nobody has written strings for, and a wizard that refused one
    # would make the table a thing to be fed before anything can be drawn.
    $string = @{}

    try {
        $string = Get-HDTStringTable -Page (
            [System.IO.Path]::GetFileNameWithoutExtension($XamlPath) -replace '^HDT', '')
    } catch {
        Write-Verbose ("no string table block for '{0}': {1}" -f $XamlPath, [string] $_.Exception.Message)
    }

    # -- show it -----------------------------------------------------------

    $answer = [string] $WizardHost.Show($xaml, $Title, @($Field), @($Pane), $CommandPrompt, @($Collect), $string)

    # THE ALLOW-LIST, AND IT IS THE WHOLE SAFETY PROPERTY. See the header:
    # anything that is not one of these three exactly is a Cancel.
    #
    # MATCHED CASE-SENSITIVELY, and the ALLOW-LIST's spelling is what is
    # returned - never the host's string. Both halves matter. A host answering
    # 'next' is not the host this command was written against, and a widened
    # list that also normalises case is one step from "recognise anything that
    # looks close enough" - which, on the other side of Next, partitions a disk.
    $action = 'Cancel'
    foreach ($allowed in @('Next', 'Cancel', 'CommandPrompt')) {
        if ($answer -ceq $allowed) {
            $action = $allowed
            break
        }
    }

    return [pscustomobject] @{
        Action   = $action
        Title    = $Title
        XamlPath = $XamlPath

        # WHAT THE TECHNICIAN TYPED, keyed by control name. Empty when nothing
        # was asked for. The Welcome screen used to answer with an Action alone,
        # so a corrected deploy root went nowhere and the machine died on the
        # address that was already wrong - see Get-HDTWizardHarvest.
        Value    = $WizardHost.Value
    }
}
