function Split-HDTTestBucket {
    <#
        .SYNOPSIS
            Packs test files into one bucket per worker process, longest first.

        .DESCRIPTION
            ./build.ps1 -Task test runs the suite across several child processes.
            This decides which files each one gets.

            LONGEST-PROCESSING-TIME FIRST, which is the classic greedy answer to
            multiprocessor scheduling: sort the files by cost descending and drop
            each onto whichever bucket is currently lightest. It is within 4/3 of
            optimal in the worst case and, on a suite whose costs range from 5 ms
            to 43 s, close enough to it that the remaining imbalance is not the
            thing worth fixing.

            WHY IT MATTERS MORE THAN THE WORKER COUNT. A sharded run cannot
            finish before its longest bucket does, so one heavy file caps the
            whole thing however many cores are free - measured here as 8 workers
            beating 4 by only 32 seconds while a single 121-second file held the
            floor. Balance is the lever; parallelism only makes balance matter.

            THE COSTS ARE A HINT AND MAY BE ABSENT. They come from the previous
            run's NUnit XML, which -Task clean deletes. A file with no recorded
            duration is priced at the mean of the ones that have one, so a new
            test file lands somewhere sane instead of being treated as free and
            piled onto an already-full bucket. With no durations at all every
            file prices the same and this degrades to a plain round-robin, which
            is what it was before and still correct - just slower.

        .PARAMETER Path
            The test files to distribute.

        .PARAMETER Worker
            How many buckets to produce. Trimmed to the file count, because an
            empty bucket is a child process that discovers nothing.

        .PARAMETER Duration
            Optional map of file path to seconds, from the last run.

        .OUTPUTS
            An array of string arrays, heaviest bucket first.

        .EXAMPLE
            Split-HDTTestBucket -Path $file -Worker 8 -Duration $seconds
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 128)]
        [int] $Worker,

        [Parameter()]
        [hashtable] $Duration = @{}
    )

    $file = @($Path | Where-Object { $_ })

    if ($file.Count -eq 0) {
        throw 'Split-HDTTestBucket was given no test file to distribute. A run that sharded nothing is not a run that passed.'
    }

    # THE PRICE OF AN UNKNOWN FILE IS THE MEAN OF THE KNOWN ONES. Not zero:
    # zero sorts last and lands on the fullest bucket, which is the worst place
    # for a file that might be the new slowest in the suite.
    $known = @($file | Where-Object { $Duration.ContainsKey($_) } | ForEach-Object { [double] $Duration[$_] })

    $default = 1.0
    if ($known.Count -gt 0) {
        $default = ($known | Measure-Object -Average).Average
    }

    $cost = @{}
    foreach ($item in $file) {
        if ($Duration.ContainsKey($item)) {
            $cost[$item] = [double] $Duration[$item]
        } else {
            $cost[$item] = $default
        }
    }

    # Ties broken by name so two runs over an unchanged tree shard identically -
    # a shard that moves between runs makes a flake impossible to attribute.
    $ordered = @($file | Sort-Object -Property @{ Expression = { $cost[$_] }; Descending = $true }, @{ Expression = { $_ } })

    $count = [Math]::Min($Worker, $ordered.Count)

    $bucket = New-Object 'object[]' $count
    $load = New-Object 'double[]' $count
    for ($i = 0; $i -lt $count; $i++) {
        $bucket[$i] = New-Object System.Collections.ArrayList
    }

    foreach ($item in $ordered) {
        $lightest = 0
        for ($i = 1; $i -lt $count; $i++) {
            if ($load[$i] -lt $load[$lightest]) {
                $lightest = $i
            }
        }

        $null = $bucket[$lightest].Add($item)
        $load[$lightest] += $cost[$item]
    }

    # HEAVIEST FIRST, because the caller starts them in this order. Launching
    # the longest bucket last leaves one worker still going when the machine is
    # otherwise idle.
    $index = @(0..($count - 1) | Sort-Object -Property @{ Expression = { $load[$_] }; Descending = $true })

    return @($index | ForEach-Object { , @($bucket[$_].ToArray()) })
}
