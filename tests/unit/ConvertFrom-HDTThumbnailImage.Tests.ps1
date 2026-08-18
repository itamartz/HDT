# THE COLOURS IN A VM SCREENSHOT, AND WHY THIS IS TESTED AT ALL.
#
# Save-HDTLabVmScreen is an adapter over WMI and is exempt from TDD; the pixel
# maths inside it was not, and was wrong for months. Hyper-V hands back raw
# 16-bit pixels and the decode read them BIG-endian, so every capture came out
# in false colour - black backgrounds rendered magenta - and the only thing that
# noticed was somebody looking at a screenshot and calling it a screenshot bug.
#
# SPIKES S4 SAYS BIG-ENDIAN, AND S4 IS WRONG. It recorded the symptom the other
# way round. That is exactly why this file exists: a note in a document can be
# read and believed, and a test cannot be argued with.

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module -Name (Join-Path -Path $script:repoRoot -ChildPath 'tests/helpers/HDTTestTools/HDTTestTools.psd1') -Force -ErrorAction Stop

    # RGB565, LITTLE-ENDIAN: low byte first. Black, white, and one saturated
    # channel each, which is what tells an endianness error from a channel-width
    # error - swapping the bytes turns red into a dark green, not into blue.
    $script:pixel = [byte[]] @(
        0x00, 0x00,   # black
        0xFF, 0xFF,   # white
        0x00, 0xF8,   # red     11111 000000 00000
        0xE0, 0x07,   # green   00000 111111 00000
        0x1F, 0x00    # blue    00000 000000 11111
    )
}

Describe 'ConvertFrom-HDTThumbnailImage' {

    It 'is exported by HDTTestTools' {
        Get-Command -Name 'ConvertFrom-HDTThumbnailImage' -Module 'HDTTestTools' -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty
    }

    It 'decodes little-endian RGB565, which is what this host actually sends' {
        $bitmap = ConvertFrom-HDTThumbnailImage -Data $script:pixel -Width 5 -Height 1

        try {
            $bitmap.GetPixel(0, 0).ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(0, 0, 0).ToArgb())
            $bitmap.GetPixel(1, 0).ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(255, 255, 255).ToArgb())
            $bitmap.GetPixel(2, 0).ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(255, 0, 0).ToArgb())
            $bitmap.GetPixel(3, 0).ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(0, 255, 0).ToArgb())
            $bitmap.GetPixel(4, 0).ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(0, 0, 255).ToArgb())
        } finally {
            $bitmap.Dispose()
        }
    }

    It 'reads a black pixel as black, which is the whole reported defect' {
        # A frame is mostly background. Decoded the other way round, 0x0000 is
        # still black - but 0x1082, a dark grey, comes out as saturated magenta,
        # and that is what a WinPE capture is full of.
        $bitmap = ConvertFrom-HDTThumbnailImage -Data ([byte[]] @(0x82, 0x10)) -Width 1 -Height 1

        try {
            $colour = $bitmap.GetPixel(0, 0)
            $colour.R | Should -BeLessThan 40
            $colour.G | Should -BeLessThan 40
            $colour.B | Should -BeLessThan 40
        } finally {
            $bitmap.Dispose()
        }
    }

    It 'ignores the bytes past the end of the frame' {
        # THE CALL RETURNS FOUR BYTES MORE THAN WIDTH x HEIGHT x 2 on this host.
        # Whatever they are, they are not pixels, and reading them would walk off
        # the last row.
        $data = [byte[]] ($script:pixel + @(0x11, 0x22, 0x33, 0x44))

        { ConvertFrom-HDTThumbnailImage -Data $data -Width 5 -Height 1 } | Should -Not -Throw
    }

    It 'fills what it cannot read rather than throwing, so a short frame is still a picture' {
        $bitmap = ConvertFrom-HDTThumbnailImage -Data ([byte[]] @(0xFF, 0xFF)) -Width 2 -Height 1

        try {
            $bitmap.GetPixel(0, 0).ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(255, 255, 255).ToArgb())
            $bitmap.GetPixel(1, 0).ToArgb() | Should -Be ([System.Drawing.Color]::FromArgb(0, 0, 0).ToArgb())
        } finally {
            $bitmap.Dispose()
        }
    }
}
