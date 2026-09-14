# Maintenance notes

Incident accounts and measurements a maintainer needs once, at the moment
something behaves oddly, but that would drown the code they sit beside. The
invariant each one protects stays in the source as a short comment; the account
of how it was learned lives here, and the comment links to it.

See [COMPLEXITY-REDUCTION.md](COMPLEXITY-REDUCTION.md), "Comment policy", for
when to move an explanation into this file rather than leaving it in a comment.

## Header-key newline normalisation

Where: `Set-HDTDocumentHeaderKey`, the `$oneLine` collapse.

### The invariant

A document header key occupies exactly one line. The value handed to the splice
is collapsed to a single line before it is written, and the pattern that does
the collapsing writes its end-of-line characters as the two-character escapes
`\r` and `\n` - never as a real line break typed inside the pattern string.

### Why collapse at all: a folded scalar comes back with newlines in it

The shipped sequence template writes `description` as a YAML folded block:

    description: >
      Deploys Windows to a bare machine: validate it, lay out the disk
      for its firmware, apply the image ...

YAML's `>` yields a single string that still ends in a newline, so the console
displayed what it was shown and handed the same value back on save. Written out
unchanged it produced:

    description: 'Deploys Windows to a bare machine: ... make it boot.
    folder: Clients\Bare metal
    '

- which swallowed the next key into the description's value and took `folder`
off the tree. Nothing in a document header is meant to carry a paragraph, so the
value is collapsed rather than quoted across several lines.

### Why the escapes and not a literal newline: a CI-only failure

The collapsing pattern was once written with an actual line break sitting inside
the single-quoted string in place of `\n`. That parses, and it passes locally,
because a single-quoted PowerShell string does not need an escape sequence in
order to contain a newline.

But it makes the regex's *meaning* depend on the end-of-line bytes this source
file happens to be saved with, and git's CRLF normalisation rewrites those bytes
on checkout. A local working tree edited in place kept LF and stayed green; a CI
runner's fresh checkout normalised to CRLF, the embedded newline stopped
matching what it used to, the collapse silently did nothing, and
`Import-HDTSequenceDocument` died on `did not find expected key` - the exact
failure the collapse exists to prevent, reintroduced by the fix for it.

Found 2026-09-04, from a CI-only failure that would not reproduce locally.
