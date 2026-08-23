function Set-HDTWindowText {
    <#
        .SYNOPSIS
            Writes a string table's text onto a loaded window.

        .DESCRIPTION
            THE OTHER HALF OF Get-HDTStringTable. The table is keyed
            Control.Property; this finds each control by name and writes that
            property. Nothing else about a window changes - it is the same
            by-name application New-HDTWizardHost already does for the wizard's
            fields, which is deliberate: one mechanism for "put this text there"
            rather than two that behave differently on a machine nobody can
            debug.

            A KEY WITH NO CONTROL IS SKIPPED, because a table serves every
            window in the module and no window has all the controls. A CONTROL
            WITH NO KEY IS LEFT ALONE, because a value somebody typed into a box
            is not text this command owns.

            A MISSING STRING SHOWS ITS KEY, AND THAT IS THE POINT. The
            alternative is a blank label, which looks like a layout bug and gets
            reported as one; 'HDTBootImageNameLabel.Text' on screen names the
            key somebody has to add. It cannot happen from the shipped table -
            en-us is the floor - but it can happen the moment somebody adds a
            control and forgets the string, which is exactly when it needs to be
            obvious.

            IT RETURNS WHAT IT COULD NOT DO. Applied and Missing come back so a
            caller can log them and a test can assert them without a display.

        .PARAMETER Root
            The window, or the page root. A page loaded into a host carries its
            own name scope, so the ROOT is passed in rather than the window -
            the same reason New-HDTWizardHost's Apply takes one.

        .PARAMETER String
            The table from Get-HDTStringTable.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject with Applied and
            Missing.

        .EXAMPLE
            Set-HDTWindowText -Root $window -String (Get-HDTStringTable)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes text onto controls of a window the caller just loaded; it changes no system state and a confirmation prompt while a window is opening would hang it.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Root,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $String
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $applied = New-Object -TypeName System.Collections.ArrayList
    $missing = New-Object -TypeName System.Collections.ArrayList

    foreach ($key in @($String.Keys)) {

        $text = [string] $String[$key]
        $name = [string] $key
        $property = 'Text'

        $split = $name.LastIndexOf('.')
        if ($split -gt 0) {
            $property = $name.Substring($split + 1)
            $name = $name.Substring(0, $split)
        }

        $control = $Root.FindName($name)
        if ($null -eq $control) { continue }

        try {
            $control.$property = $text
            [void] $applied.Add([string] $key)
        } catch {
            # A KEY NAMING A PROPERTY THE CONTROL HAS NOT GOT is a mistake in
            # the table, not a reason to leave the rest of the window in
            # English: 'HDTNextButton.Text' on a Button, where the property is
            # Content, would otherwise stop every string after it.
            [void] $missing.Add(('{0}: {1}' -f $key, [string] $_.Exception.Message))
        }
    }

    return [pscustomobject] @{
        Applied = [string[]] @($applied)
        Missing = [string[]] @($missing)
    }
}
