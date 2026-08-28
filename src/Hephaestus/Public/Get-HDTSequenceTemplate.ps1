function Get-HDTSequenceTemplate {
    <#
        .SYNOPSIS
            The task sequence templates a new sequence can be created from.

        .DESCRIPTION
            A TEMPLATE IS A REAL sequence.yaml ON DISK. New-HDTTaskSequence asks
            which template and copies that file into the new sequence's folder;
            nothing is generated.

            THAT IT IS A FILE IS THE DESIGN, not an implementation detail. It can
            be opened, read, diffed and edited before it is ever used; a shop
            with its own standard build writes one file rather than a plugin; and
            the comments an author reads in a new sequence are the comments
            somebody wrote in the template, not strings assembled by code.

            THE DESCRIPTION COMES OUT OF THE DOCUMENT, so a template cannot
            describe itself one way in a picker and another way in the file. Id
            is the file's own name, which is what the picker passes back.

        .PARAMETER Id
            One template, by id. Omitted, every template is listed.

        .PARAMETER Line
            Return the template's lines rather than a description of it - which
            is what a new sequence is written from. Requires Id.

        .PARAMETER Path
            The directory templates are read from. Defaults to the ones this
            module ships; a workspace with its own is how a shop adds theirs.

        .PARAMETER FileSystem
            An IFileSystem. Defaults to the real one.

        .INPUTS
            None. This command does not accept pipeline input.

        .OUTPUTS
            System.Management.Automation.PSCustomObject[] with Id, Name,
            Description and Path - or System.String[] with -Line.

        .EXAMPLE
            Get-HDTSequenceTemplate | Format-Table Id, Name

        .EXAMPLE
            Get-HDTSequenceTemplate -Id client -Line
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]], [string[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Id,

        [Parameter()]
        [switch] $Line,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = (Join-Path -Path $script:HDTModuleRoot -ChildPath 'Templates'),

        [Parameter()]
        [AllowNull()]
        [object] $FileSystem
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($null -eq $FileSystem) { $FileSystem = New-HDTFileSystem }

    $found = New-Object -TypeName System.Collections.ArrayList

    # A DIRECTORY THAT IS NOT THERE HAS NO TEMPLATES, which is an answer rather
    # than a failure: a workspace is entitled to ship none of its own.
    if ($FileSystem.TestPath($Path)) {
        foreach ($file in @($FileSystem.GetChildItem($Path))) {
            if ([System.IO.Path]::GetExtension([string] $file) -ne '.yaml') { continue }

            $name = [System.IO.Path]::GetFileNameWithoutExtension([string] $file)

            if (-not [string]::IsNullOrWhiteSpace($Id) -and $name -ne $Id) { continue }

            [void] $found.Add([string] $file)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        if (@($found).Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-HDTErrorRecord -TargetObject $Id -Category ObjectNotFound `
                        -Message ("there is no task sequence template called '{0}' in '{1}'." -f $Id, $Path)))
        }

        if ($Line) {
            return [string[]] @([string] $FileSystem.ReadAllText($found[0]) -split "`r?`n")
        }
    }

    $result = New-Object -TypeName System.Collections.ArrayList

    foreach ($file in @($found)) {
        $text = [string] $FileSystem.ReadAllText($file)

        # THE NAME AND DESCRIPTION ARE THE DOCUMENT'S OWN, read the same way the
        # engine reads them - so a template cannot say one thing in the picker
        # and another in the file.
        $reader = New-HDTFileSystemFromText -Path $file -Text $text
        $document = Import-HDTSequenceDocument -Path $file -FileSystem $reader

        [void] $result.Add([pscustomobject] @{
                Id          = [System.IO.Path]::GetFileNameWithoutExtension([string] $file)
                Name        = [string] $document.Name
                Description = [string] $document.Description
                StepCount   = @($document.Step).Count
                Path        = [string] $file

                Command     = ("Get-HDTSequenceTemplate -Id {0} -Line" -f
                    [System.IO.Path]::GetFileNameWithoutExtension([string] $file))
            })
    }

    return [pscustomobject[]] @($result)
}
