# A deliberate scratch leak, kept as a fixture so the scanner is proven against
# the exact shape that put 7.1 GB in C:\HDTLab\scratch: a suite that names a
# build root, fills it with a boot image, and has no teardown that gives it back.
#
# Nothing runs this file: tests/fixtures is outside Run.Path, outside
# Get-HDTSourceFile, and outside ProtectedPath.Contract's scan.

BeforeAll {
    $script:buildRoot = 'C:\HDTLab\scratch\bait-leak'
    $script:buildScratch = Join-Path -Path $script:buildRoot -ChildPath 'work'
}

AfterAll {
    # The VM goes; the two gigabytes stay.
    Remove-HDTLabVirtualMachine -Name 'HDT-Bait' -Confirm:$false
}

Describe 'a suite that leaks' {
    It 'built something' {
        Test-Path -LiteralPath $script:buildScratch | Should -BeTrue
    }
}
