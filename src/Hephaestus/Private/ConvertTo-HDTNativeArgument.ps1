function ConvertTo-HDTNativeArgument {
    <#
        .SYNOPSIS
            Quotes one argument the way CommandLineToArgvW reads it back.

        .DESCRIPTION
            THE LOGIC BEHIND AN ADAPTER THAT IS NOT ALLOWED ANY, exactly as
            ConvertFrom-HDTDismProgressLine is. New-HDTImageService.ApplyUnattend
            runs dism.exe as a POLLED process rather than a pipeline, so a pass
            that prints nothing for three minutes can still tick a heartbeat.
            A polled process is started through
            System.Diagnostics.ProcessStartInfo, and the .NET Framework that
            WinPE carries gives that class ONE Arguments STRING and no
            ArgumentList - so the command line is built by hand, and Windows
            parses it back with CommandLineToArgvW. This is the half of that
            round trip that can be tested, so it lives here and is.

            THE TRAP, MEASURED ON THIS MACHINE RATHER THAN REMEMBERED. /Image:
            takes the ROOT of the offline installation - 'W:\', ending in a
            backslash. Quoted the obvious way:

              "/Image:W:\" "/Apply-Unattend:W:\Windows\Panther\unattend.xml" ...

            argv comes back as ONE argument:

              /Image:W:" /Apply-Unattend:W:\Windows\Panther\unattend.xml ...

            because the backslash before the closing quote escaped it and the
            rest of the line was swallowed as text. dism would have been handed
            a single nonsense switch, and the only call that runs the
            offlineServicing pass would have failed for a reason no log line
            would have explained.

            THE RULE IS NOT "ESCAPE EVERY BACKSLASH". A backslash is only
            special IMMEDIATELY BEFORE A QUOTE. So a run of them before an
            embedded quote is doubled, a run of them at the END of a quoted
            argument is doubled - the closing quote is the quote it precedes -
            and every other backslash is left exactly as it is. Doubling the
            separators inside a path would hand dism a path that does not exist.

            AN ARGUMENT THAT NEEDS NOTHING GETS NOTHING. Every path this adapter
            actually passes today - 'W:\', 'W:\Windows\Panther\unattend.xml',
            'W:\HDT\Scratch' - has no space, no tab and no quote, so it goes on
            the command line bare and byte-identical to what the proven pipeline
            form passed. The quoting exists for the share path or scratch
            directory that one day has a space in it, not to change today's call.

        .PARAMETER Argument
            One argument, as the caller means the child process to receive it.
            An empty string is a real argument and comes back as a pair of
            quotes; bare, it would vanish from the command line.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.String - the argument as it should appear on a command line.
            Join the results with a single space.

        .EXAMPLE
            ConvertTo-HDTNativeArgument -Argument '/Image:W:\'

            /Image:W:\

        .EXAMPLE
            ConvertTo-HDTNativeArgument -Argument '/ScratchDir:C:\some dir\'

            "/ScratchDir:C:\some dir\\"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Argument
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # NOTHING SPECIAL IN IT MEANS NOTHING DONE TO IT. An empty string is the one
    # exception: it has nothing special in it and still has to be quoted, or
    # there would be no argument on the command line at all.
    if ($Argument.Length -gt 0 -and $Argument.IndexOfAny([char[]] @(' ', "`t", '"')) -lt 0) {
        return $Argument
    }

    $builder = New-Object -TypeName System.Text.StringBuilder
    [void] $builder.Append([char] '"')

    $backslash = 0

    foreach ($character in $Argument.ToCharArray()) {

        if ($character -eq '\') {
            # NOT EMITTED YET. Whether this backslash is an escape or a literal
            # is decided by what comes after it, which has not been read.
            $backslash++
            continue
        }

        if ($character -eq '"') {
            # The run before a quote is doubled, and the quote itself escaped.
            [void] $builder.Append([char] '\',($backslash * 2))
            [void] $builder.Append('\"')
            $backslash = 0
            continue
        }

        # An ordinary character: the run before it was literal after all.
        [void] $builder.Append([char] '\',$backslash)
        [void] $builder.Append($character)
        $backslash = 0
    }

    # THE RUN AT THE END IS THE ONE THAT BREAKS. The closing quote about to be
    # appended is a quote like any other, so the backslashes before it double.
    [void] $builder.Append([char] '\',($backslash * 2))
    [void] $builder.Append([char] '"')

    return $builder.ToString()
}
