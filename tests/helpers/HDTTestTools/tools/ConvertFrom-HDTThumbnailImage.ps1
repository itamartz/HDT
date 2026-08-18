function ConvertFrom-HDTThumbnailImage {
    <#
        .SYNOPSIS
            Turns Hyper-V's raw thumbnail bytes into a bitmap.

        .DESCRIPTION
            GetVirtualSystemThumbnailImage returns the VM's console as raw
            16-bit pixels - two bytes each, RGB565 - and nothing else: no header
            a decoder could read the layout from, so the layout is knowledge
            rather than something the data declares.

            LITTLE-ENDIAN, LOW BYTE FIRST, and this is the half that was wrong.
            SPIKES S4 recorded big-endian, having read the symptom backwards, so
            every capture this lab ever took came out in false colour - a dark
            WinPE background as saturated magenta, a blue banner as green. Text
            stayed legible, which is why it survived: the screenshots were used
            to read words, and nobody who saw the colours believed them enough to
            check. Proven on this host against a frame whose true colours were
            known: the WinPE background decodes correctly one way and only one.

            IT IS ITS OWN FUNCTION SO THAT A TEST CAN HOLD IT. Save-HDTLabVmScreen
            is an adapter over WMI and exempt from TDD; this is arithmetic, it
            was wrong, and arithmetic in an exempt file is how that happens.

            THE FRAME IS LONGER THAN THE PIXELS. This host returns four bytes
            more than width x height x 2. Whatever they are, they are not part of
            the picture, and a decoder that read to the end of the buffer would
            walk off the last row.

        .PARAMETER Data
            The bytes as GetVirtualSystemThumbnailImage returned them.

        .PARAMETER Width
            The frame's width in pixels - the same number the call asked for.

        .PARAMETER Height
            The frame's height in pixels.

        .OUTPUTS
            System.Drawing.Bitmap. The caller disposes it.

        .EXAMPLE
            $bitmap = ConvertFrom-HDTThumbnailImage -Data $result.ImageData -Width 1024 -Height 768
            $bitmap.Save('C:\HDTLab\scratch\winpe.png', [System.Drawing.Imaging.ImageFormat]::Png)

        .LINK
            Save-HDTLabVmScreen
    #>
    [CmdletBinding()]
    # NOT [System.Drawing.Bitmap]: an attribute's type is resolved when the file
    # is PARSED, and System.Drawing is not loaded into 5.1 until the Add-Type
    # below runs - so naming it here makes the function unloadable.
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [byte[]] $Data,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateRange(1, 16384)]
        [int] $Width,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateRange(1, 16384)]
        [int] $Height
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Add-Type -AssemblyName 'System.Drawing'

    $bitmap = New-Object -TypeName 'System.Drawing.Bitmap' -ArgumentList $Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)

    # LOCKED AND WRITTEN AS BYTES, NOT SetPixel PER PIXEL. A 1024x768 frame is
    # 786,432 calls, which took ten seconds a screenshot - long enough that a
    # capture loop watching a boot missed what it was watching for.
    $locked = $bitmap.LockBits(
        (New-Object System.Drawing.Rectangle 0, 0, $Width, $Height),
        [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)

    try {
        $stride = $locked.Stride
        $row = New-Object byte[] $stride

        for ($y = 0; $y -lt $Height; $y++) {

            [System.Array]::Clear($row, 0, $stride)

            for ($x = 0; $x -lt $Width; $x++) {

                $source = (($y * $Width) + $x) * 2
                if ($source + 1 -ge $Data.Length) { break }

                $pixel = ([int] $Data[$source + 1] -shl 8) -bor [int] $Data[$source]

                # 5 bits of red, 6 of green, 5 of blue, each widened to 8 by
                # scaling rather than by shifting: a shift leaves white at 248.
                $target = $x * 3
                $row[$target] = [byte] (($pixel -band 0x1F) * 255 / 31)
                $row[$target + 1] = [byte] ((($pixel -shr 5) -band 0x3F) * 255 / 63)
                $row[$target + 2] = [byte] ((($pixel -shr 11) -band 0x1F) * 255 / 31)
            }

            [System.Runtime.InteropServices.Marshal]::Copy(
                $row, 0, [System.IntPtr]::Add($locked.Scan0, $y * $stride), $stride)
        }
    } finally {
        $bitmap.UnlockBits($locked)
    }

    return $bitmap
}
