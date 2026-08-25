function Get-HDTConsoleNewWorkspaceMessage {
    <#
        .SYNOPSIS
            Which sentence the New Deployment Share page shows, and whether
            Create stays live.

        .DESCRIPTION
            THREE THINGS CAN HAVE SOMETHING TO SAY AND THERE IS ONE LINE TO SAY
            IT IN: the path and id check, the share name check, and whether this
            console is elevated enough to publish a share at all. A page that
            shows whichever complaint ran last sends a technician to fix the
            wrong thing, so the precedence is decided here rather than by the
            order of assignments in a handler.

            THE ELEVATION SENTENCE OUTRANKS THE OTHERS, because it is the one
            NOTHING ON THIS PAGE CAN FIX. Every other message names something
            somebody can type their way out of; this one means closing the
            console and reopening it as an administrator. It has to be said even
            when a lesser complaint is also true, or the person fixes the lesser
            one and presses Create again into the same wall.

            AND IT DOES NOT DISABLE CREATE. The folder is still worth writing
            without the share - the share can be added afterwards - and refusing
            the whole page over the half that needs elevation sends somebody away
            with nothing. It is the one message on this page that warns without
            blocking, which is exactly the kind of asymmetry that gets "tidied
            up" by someone who did not know why.

            IT DOES NOT UN-REFUSE ANYTHING EITHER. Outranking the path
            complaint's SENTENCE does not overturn its VERDICT: a folder that
            already holds a share still cannot be created, elevated or not.

            NOT PUBLISHING MEANS ELEVATION IS IRRELEVANT. An empty share name
            publishes nothing and the document allows it, so telling an
            unelevated technician they cannot publish a share they never asked
            for is a refusal they cannot act on - and the share check's opinion
            about a share nobody wants is not worth showing either.

        .PARAMETER CanCreate
            What the path and id check made of the page.

        .PARAMETER Message
            What the path and id check had to say, '' when it is content.

        .PARAMETER ShareMessage
            What Get-HDTWorkspaceShareName had to say about the share name.

        .PARAMETER Publishing
            Whether a share name was given at all.

        .PARAMETER Elevated
            Whether this console can publish a share.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject:

              Message    the one sentence to show
              CanCreate  whether Create stays live

        .EXAMPLE
            Get-HDTConsoleNewWorkspaceMessage -CanCreate $true -Message '' -ShareMessage '' -Publishing $true -Elevated $false

        .EXAMPLE
            $say = Get-HDTConsoleNewWorkspaceMessage -CanCreate $answer.CanCreate -Message $answer.Message -ShareMessage $share.Message -Publishing $publishing -Elevated $elevated
            $messageText.Text = $say.Message
            $create.IsEnabled = $say.CanCreate
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $CanCreate,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Message,

        [Parameter()]
        [AllowEmptyString()]
        [string] $ShareMessage = '',

        [Parameter(Mandatory = $true)]
        [bool] $Publishing,

        [Parameter(Mandatory = $true)]
        [bool] $Elevated
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $say = $Message
    $can = $CanCreate

    # THE SHARE CHECK SPEAKS ONLY WHEN THE PATH CHECK IS CONTENT, and only when
    # a share was actually asked for.
    if ($Publishing -and -not [string]::IsNullOrWhiteSpace($ShareMessage) -and
        [string]::IsNullOrWhiteSpace($Message)) {

        $say = $ShareMessage
        $can = $false
    }

    # THE ELEVATION SENTENCE OUTRANKS THE OTHERS - see above. It replaces the
    # sentence and leaves the verdict alone.
    if ($Publishing -and -not $Elevated) {
        $say = 'this console is not running as an administrator, so it cannot publish the share. Create the deployment share here and add the share yourself, or close this and reopen the console as an administrator - right-click, Run as administrator.'

        # NOT $false. The folder is still worth writing.
        $can = $CanCreate
    }

    return [pscustomobject] @{
        Message   = $say
        CanCreate = $can
    }
}
