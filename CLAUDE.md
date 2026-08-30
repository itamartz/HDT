# CLAUDE.md — Hephaestus Deployment Toolkit (HDT)

A replacement for the Microsoft Deployment Toolkit (MDT), which has been in
maintenance mode since 2019. Same operational model — deployment share, task
sequences, driver store, application catalog — rebuilt on PowerShell instead of
VBScript/WSH.

## Specification — read before changing anything

| Document | What it holds |
|---|---|
| `docs/DESIGN.md` | Full technical design, 15 sections. Authoritative. |
| `docs/ROADMAP.md` | Milestones M0–M8, each with a "Tests first" list and exit criteria |
| `.planning/PROJECT.md` | Settled decisions, environment, lab safety rules, staged media, ADK paths |
| `.planning/SPIKES.md` | **Verified-by-execution environment findings.** Read before writing anything that touches WinPE, oscdimg, Pester imports, or Hyper-V — it records traps already hit and the working fixes |

These already settle nearly every design question. **Do not re-derive or
contradict them.** If you believe one is wrong, say so and update the document —
don't quietly diverge in code.

## Commands

```powershell
./build.ps1 test        # unit + contract suites
./build.ps1 lint        # PSScriptAnalyzer
./build.ps1 ci          # what CI runs
Invoke-Pester tests/unit -Output Detailed          # one suite
Invoke-Pester tests/unit/Rules.Tests.ps1           # one file
```

Always verify under **both** shells before calling something done:

```powershell
pwsh -NoProfile -Command "./build.ps1 test"
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "./build.ps1 test"
```

## Hard rules

These are enforced by contract tests. Breaking one is a defect, not a style
preference.

1. **TDD.** A failing Pester test exists before the implementation it covers.
   Every time. The sole exception is thin adapters over external tools (DISM,
   CIM, oscdimg, registry) — and those must stay branch-free *because* they are
   not unit tested.

2. **Windows PowerShell 5.1 syntax** in `src/Hephaestus/`. The engine runs inside
   WinPE, which has no `pwsh`. Forbidden: `??`, `?.`, ternary, `ForEach-Object
   -Parallel`, `$PSStyle`, `clean` blocks, `ConvertFrom-Json -AsHashtable`.

3. **`Verb-HDTNoun`, uppercase HDT** — public cmdlets, private helpers, adapters,
   test helpers, build functions alike. Approved verbs (`Get-Verb`), singular
   nouns. The engine dot-sources user scripts from `Scripts\` and third-party
   step types from `Modules\`, so an unprefixed `Invoke-Dism` is a live
   collision risk in WinPE.

4. **Zero MDT dependencies.** MDT is deprecated; a replacement that needs it
   installed isn't a replacement. No `MicrosoftDeploymentToolkit` module,
   `MDTProvider` drive, `Microsoft.BDD.*` assembly, `ZTI*`/`LTI*` script,
   `ts.xml`, MDT `Control\` layout, or MDT database schema. **ADK and WDS are
   fine** — they're independent Microsoft products.

5. **Engine logic never touches hardware directly.** Steps take injected
   services (`IDiskService`, `IImageService`, `IContentProvider`,
   `ICimProvider`, `IFileSystem`, `IRegistryService`, `ILsaService`) so the whole
   engine runs under Pester against hand-written fakes. The benchmark test is a
   full multi-group sequence with reboots executing end-to-end against fakes and
   asserting the exact ordered operation list.

6. **`SupportsShouldProcess` on anything destructive**, and refuse ambiguous
   targets. `DiskPartition` must not guess which disk to wipe.

7. `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in
   engine code.

8. **One place of truth, and the create command copies it.**
   Every wizard page — new or existing — lives in
   `src/Hephaestus/Templates/Wizard/`, and `New-HDTWorkspace` seeds a share by
   copying **the whole directory**, never a list written down somewhere. A page
   authored straight onto a share, or a copy loop naming files one by one, is
   a second source of truth and the two will disagree. The same holds for every
   other seeded tree: the templates are the product, the share is a copy of
   them.

   Corollary, and it has already cost a rebuild: **an existing share keeps its
   own copy and is never written over** — deliberately, because those files are
   somebody's edits (DESIGN 11.2). So a page added today does not reach a share
   created yesterday, and no boot image will carry it there. Adding a page means
   saying so, and updating the shares that matter by splicing their `wizard.yaml`
   rather than replacing it.

   **And when it lands, bring THIS lab's share up to it.** A change to
   `Templates\`, `Payload\` or the engine that `C:\HDTLab\Share` does not have
   is a change nobody here can test. The next deployment runs the SHARE's copy,
   not the repository's, so the old behaviour goes on proving itself green while
   the fix sits in `src/` looking finished. The change is not done until that
   share carries it — spliced, never replaced, because the rest of those files
   are somebody's edits.

   0.10.1 is the example. `client.yaml` now stages drivers BEFORE the answer
   file is applied, and `TaskSequences\PNP-TEST\sequence.yaml` on the share
   still had the old order — so the very machine that surfaced the defect would
   have reproduced it on the next run, against a repository that was already
   fixed.

   **And a thing is not added until every surface that must know about it does.**
   Adding a page, a step type, a rule, a layout means finding every place that
   has to learn about it — and proving it with a test written against the
   **set**, not against the one you just added. A test that names your new
   thing passes for it and fails nobody after it.

   The surfaces, each one of which has silently shipped a half-feature here:

   | Surface | What it looked like |
   |---|---|
   | The **shipped template** | `client.yaml` authored partitions with no drive letter and could not partition a disk. Templates were parsed and schema-checked; nothing ever *planned* one. |
   | **The other path to the same behaviour** | A named disk layout carried S/W/R, the authored path carried none — and every VM run used the named one, so 10,000 green tests missed it. |
   | **A share somebody already has** | `New-HDTWorkspace` seeds `Scripts\UI` from `Templates\Wizard` and never overwrites, by design. So an existing share silently lacks any page added afterwards, and the boot image alone will not fix it. |
   | The **document validator** | `Assert-HDT*Document` refuses unknown keys, so a new key is invisible — and a new rule name is *rejected* — until it is listed there. |
   | The **module manifest** | A public command missing from `FunctionsToExport` does not exist. |
   | The **fakes** | The fake `MoveItem` moved files and not directories while the real adapter's `Move-Item` did both. The fake was wrong, not the caller. |

   And it has to be **provable against a fake**, which means `[IO.Path]::Combine`
   and never `Join-Path` on a path that may not be mounted — `Join-Path`
   resolves the drive and throws `DriveNotFound`, so the line cannot be tested
   at all (see `Get-HDTWorkspacePath`).

## Architecture in one paragraph

A **workspace** (deployment share) is a directory tree of YAML plus content.
`rules.yaml` resolves variables from five prioritised sources and records
*provenance* for each one. A `sequence.yaml` is an ordered tree of **steps**;
the engine executes them against injected services, checkpointing to `state.json`
so it survives reboots — including the one where the OS changes underneath it.
Resume in the full OS uses autologon as the local Administrator (MDT's model)
with a per-deployment random password in an LSA secret, bounded by
`AutoLogonCount`, torn down in a `finally` plus a boot-time reconcile. One boot
image build emits both a `.wim` (for WDS/PXE) and a hash-identical `.iso` (for
VM debugging). Standalone media is a *content projection* of the share with the
provider swapped, not a second code path.

## Reference implementation

`C:\HDTLab\reference\PSD` — friendsOfMDT/PSD, MIT licensed. The closest prior
art: MDT's LiteTouch rebuilt in PowerShell, proven on real hardware.

**Mine it for mechanism, not structure.** It gives you the exact DISM argument
that works, the CIM property that's empty on VMs, the registry value Winlogon
actually reads. It is procedural and calls hardware directly — copying its shape
would defeat rule 5. It is also an *MDT extension*, so every MDT dependency in it
must be stripped, not carried across (rule 4). Where PSD and `docs/DESIGN.md`
disagree, the design wins. Derived code needs a comment on the function and an
entry in `NOTICE.md`.

## ⚠ Paths that must never be deleted

**`C:\Users\Itamartz\Documents\GithubRepos\HDT` — the repository root — is never
a delete target.** Not by a test, not by a cleanup block, not by a build task,
not with `-Recurse`, not "because it will be recreated". Nor is any parent of it.

Neither are these:

| Path | Why |
|---|---|
| `C:\Users\Itamartz\Documents\GithubRepos\HDT` | **the repository** |
| `C:\HDTLab` | the lab root itself |
| `C:\HDTLab\media` | staged Windows 11 and Server 2025 sources, ~11 GB, slow to rebuild |
| `C:\HDTLab\Share` | the test deployment share |
| `C:\HDTLab\reference` | the PSD reference clone |
| Anything under `C:\Users\Itamartz\` outside `C:\HDTLab` | the user's machine |

**What code here *may* delete**, and only these:

- `out/` — the build's own artifact directory, via `build.ps1 -Task clean`
- A temp or staging directory **this process created in this run**, removed by
  the same code that created it
- A scratch VHDX or VM folder **this test created**, under `C:\HDTLab\scratch\`
  or `C:\HDTLab\vms\`, matched by an `HDT-*` name

Delete by explicit `-LiteralPath` to a specific thing you created. Never build a
delete target by enumerating a parent directory, and never pass a variable to
`Remove-Item -Recurse` without asserting first that it is one of the permitted
locations above.

## ⚠ Networking: 192.168.1.0/24, and nothing else without asking

**The lab network is `192.168.1.0/24`, gateway `192.168.1.1`.** DHCP comes from
the real LAN and test VMs reach the host through the **`HDT External`** switch.
Everything that needs a network uses that.

**In this lab, the host's own address is local wiring, not a fact about HDT** —
a static `Manual` address on `HDT External` today, a DHCP lease that moved on
its own before that. The subnet is the part worth writing down; the octet is one
machine's setup. So this file names the subnet and never the octet, and neither
should any test, plan or line in `src/`: **read it before you build a boot
image**, because the address gets baked into what you build.

This is a fact about *this lab*, not about HDT. A real deployment share has its
own address, and nothing in `src/` should be shaped around this one.

```powershell
Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'vEthernet (HDT External)'
```

**Never assign, create or use another subnet without asking the user first.**
Not a new IP on a vSwitch, not a static address outside `192.168.1.0/24`, not a
new virtual switch with its own range. Ask, then act.

This rule exists because inventing one caused a near miss: a `10.10.10.0/24`
segment was chosen for an isolated switch and **`10.10.10.1` was already in use
by the user's VMware VMnet2 adapter**. The conflict was caught only because the
assignment failed with "The object already exists" — had it landed on a free
address in a range the user was using for something else, it would have broken
their environment silently. This host also runs VMnet1/2/3/4/8, Tailscale,
Ethernet and Wi-Fi; the free-looking ranges are not free.

`HDT Lab` (internal, isolated) still exists and carries `172.30.30.1`, assigned
before this rule. It is reserved for future PXE/WDS work, where an isolated
segment is genuinely required: a PXE responder answers **every** machine on its
segment, so it belongs on one where the only machines are the ones under test.
**Do not use it for anything else, and do not add addresses to it, without
asking.**

## ⚠ Hyper-V lab safety

This host runs the user's **live lab**. Damaging it is worse than failing a test.

- **Touch no VM this repository did not create.** The rule is the `HDT-*`
  prefix, not a list of names: act only on VMs matching it, and leave every
  other VM on the host exactly as you found it.
- HDT test VMs: named `HDT-*`, **Generation 2**, files in `C:\HDTLab\vms\`,
  under 12 GB combined, and on **one of exactly two switches**:
  - **`HDT External`** — the normal one. The VM gets DHCP from the real LAN on
    `192.168.1.0/24` and can reach the host on that subnet, which is what a
    deployment over SMB needs. Read the host's address; don't assume it.
  - **`HDT Lab`** — the isolated internal one, reserved for PXE/WDS, where a
    second responder cannot answer. A VM here gets **no lease and cannot reach a
    share on the host** (SPIKES S6), so it is the wrong choice for anything that
    needs the network.

  `New-HDTLabVirtualMachine` refuses every other switch by name, and
  **`Default Switch` must stay refused** — it is Hyper-V's own shared NAT
  switch, `172.25.16.1/20` on this host, which is not the deployment subnet. A
  VM there cannot reach the share the way one on `HDT External` can, and it
  shares a segment with whatever else Hyper-V puts on it.
- **PXE/WDS testing only on `HDT Lab`** — a PXE responder answers every machine
  on its segment, so it goes on the isolated one, where the only machines are
  the ones under test. On a shared switch it would answer machines that are not
  ours, and anything else answering there would silently invalidate the test.
- Never run an unfiltered Hyper-V pipeline. Filter to `HDT-*` explicitly.
  Reading the other VMs to prove you left them alone is the one exception, and
  it must enumerate them rather than name them — see the note above.

## Lab assets (already staged — don't re-extract)

| Asset | Path |
|---|---|
| Windows 11 Ent LTSC 2024 source | `C:\HDTLab\media\Win11-LTSC-2024\` (index 1) |
| Windows Server 2025 source | `C:\HDTLab\media\WS2025-Std\` (index 2 = Desktop Experience) |
| ADK 10.1.26100.2454 | `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit` |
| `oscdimg` / `efisys_noprompt.bin` | `…\Deployment Tools\amd64\Oscdimg\` — **not** the WinPE `Media\EFI\` tree |
| WinPE OCs | `…\Windows Preinstallation Environment\amd64\WinPE_OCs\` |

Resolve ADK paths at runtime via `Get-HDTAdkPath`; the layout has moved between
ADK releases.

## Test VM — OSDTEST01

**A machine to run the suite on that is not this laptop.** Windows 11 Enterprise
LTSC, workgroup, 4 cores / 4 GB, ~84 GB free, and the session opens elevated.

**It is a guest on the MS-A2 Hyper-V host, not a machine on this LAN**, so
reaching it is two hops: a WinRM session to MS-A2 over the tailnet, then
**PowerShell Direct** to the VM from inside that session. PowerShell Direct is
VMBus, so the guest needs no network and this host needs no `TrustedHosts`
entry. `.planning/PROJECT.md`, "Remote lab and CI host", has the nesting
pattern.

Both credentials are in `.secrets\ms-a2-win11.txt` — two blocks of three lines
either side of a blank one. The **second block is the host**, and it is the hop
that connects; the first block is the VM's own login, for the inner
`Invoke-Command -VMName`. Do not connect to the address on the first line: a
direct session to the VM is the old arrangement and does not answer.

**`.secrets\` is gitignored and stays that way.** Read the file, never repeat
what is in it — not into a doc, a test, a fixture or a commit message. Every
address in it is a lease: read it, don't memorise it.

Installed and verified: PowerShell **5.1 only** (no `pwsh` — which matches the
gate), Pester **5.9.1**, PSScriptAnalyzer 1.25.0, git 2.55, `powershell-yaml`
**0.4.12**, and the ADK 10.1.26100.2454 with Deployment Tools and the WinPE
add-on. `ExecutionPolicy` is `RemoteSigned` at LocalMachine scope; every scope
was `Undefined`, which stops an installed module loading at all.

`powershell-yaml` was the one that was missing, and it is not optional: without
it `New-HDTWorkspace` cannot write a single document. It failed correctly —
`HDTDependencyError`, naming the module and the `Install-Module` line — which is
the dependency gate doing its job rather than a surprise to debug.

| Suite | There? | Why |
|---|---|---|
| `tests/unit`, `tests/contract` | yes | the gate, and it runs clear of a working tree another session is rewriting |
| `tests/integration` | yes | real DISM and oscdimg, since the ADK went on |
| `tests/e2e` | **no** | needs nested Hyper-V, which it does not have |

Pester there is 5.9.1 and 5.7.1 here. Both satisfy `build.ps1`'s pin, so a
result that differs between the two is the version's fault before the code's.

It answers only while both it and MS-A2 are running — a refused connection is
something powered off, not a broken setup. Retry before diagnosing.

### Looking at a window on it

**A remote session has no desktop** — `[Environment]::UserInteractive` is `$false`
there — so `ShowDialog` has no window station to draw on and `PrintWindow`, the
capture this repository uses on the laptop, returns nothing. That is not a
reason to leave the console unchecked on the machine the suite actually runs on.

**`RenderTargetBitmap` needs no desktop.** WPF keeps a retained-mode visual tree,
and this walks that tree and rasterises it directly; the window never has to be
shown, or to exist on screen at all:

```powershell
$window.Width = 1500; $window.Height = 1000
$content = $window.Content
$content.Measure([System.Windows.Size]::new(1500, 1000))
$content.Arrange([System.Windows.Rect]::new(0, 0, 1500, 1000))
$content.UpdateLayout()

$bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(1500, 1000, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($content)
```

Three things it will not forgive:

- **Lay it out first.** An element that was never shown has no size, and
  `Render` on it gives a blank image. `Measure`, `Arrange`, `UpdateLayout`, then
  render.
- **Run it STA.** `Invoke-Command` gives you MTA, and WPF refuses. Start a
  `powershell.exe -STA -File` on the far side rather than rendering inline.
- **Hand the tree its ROOTS.** `Get-HDTConsoleTreeNode` returns a flat list with
  a `Depth`; `Show-HDTConsole` passes only `Depth -eq 0` and WPF builds the
  branches from each row's `Children`. Handing it the flat list draws every node
  twice, which looks exactly like a duplication bug in the tree builder and is
  not one.

It renders the element's whole extent rather than the visible viewport, which is
how a pane below the fold gets photographed at all. It captures no window chrome
— no title bar, no border — because Windows draws those and they are not in
WPF's visual tree.

## Repo layout

```
src/Hephaestus/     PowerShell module — the engine AND the WPF console
schemas/            JSON Schema per YAML file type
tests/unit/         Majority of tests — pure logic against fakes
tests/contract/     Schema, naming, no-MDT, PS5.1-syntax, provider contracts
tests/integration/  Real DISM/VHDX/ADK
tests/e2e/          Hyper-V
tests/fixtures/     Real .inf headers, captured CIM shapes, sample workspaces
.planning/          GSD phase plans, research, verification reports
.claude/workflows/  hdt-phase.js — the per-phase build pipeline
```

## Logging: write too much, never too little

**Every log this engine writes is as detailed as it can be made.** A hundred
lines beats two. Size and run time are not a reason to leave something out —
a deployment log is read once, at the worst possible moment, by someone who
was not there when it ran.

So: log the decision *and the reason for it*, the value *and where it came
from*, the command *and its exit code and what that code means*, the thing that
was skipped *and the condition that skipped it*. An error record carries the
exception type, the file, the line, the stack and the innermost message — never
one flattened sentence. Anything derived — an install plan, a driver match, a
resolved variable — says what produced it, the way `rules.yaml` resolution
already prints `HDTApplications = '…' (Rule)`.

The test is whether an administrator reading the log a week later, on a machine
they cannot touch, can tell **what happened and why** without asking anyone.
`Debug` is for volume, not for importance: something an admin needs in order to
understand an outcome belongs at `Info`, where they will see it without
re-running anything.

This says nothing about answers in chat — those stay short. It is the log that
is verbose.

## Conventions

- Fixtures come from **real captured data** (`Get-CimInstance` on actual
  hardware, real `.inf` headers), never invented shapes.
- Fakes are **hand-written**, not `Mock` — readable failures. `Mock` is reserved
  for the adapter boundary.
- Atomic commits, one logical unit each.
- Comment-based help on every public cmdlet.

## Working with me

- **Do exactly what I said — no extensions.** Nothing extra, no scope I did not
  ask for.
- **Keep answers short.** Relevant data only. If I want details, I will ask.
  A few lines, not a report. No preamble, no summary of what you just did unless
  it changes what I do next. No tables or bullet lists for a two-fact answer.

  **A subagent's report is raw material, not an answer.** They come back long
  because I asked them to be thorough. Relay the finding and the number that
  proves it — not the write-up, not its headings, not every quoted log line.
  Three lines beats thirty, and the detail is still in the transcript if I want
  it. Same for a fix: what it was and whether it is green, not a tour of the
  diff. Lead with the answer; the caveat goes after it, or nowhere.
- **Don't ask me for details.** Make the call yourself from `docs/DESIGN.md`,
  `.planning/`, and the code, and say the assumption in one line as you go. Ask
  only when proceeding either way would be unsafe or would waste the work — not
  to confirm a design choice, a name, or a file location.
- **Find a defect, fix it — don't ask.** A bug, a false warning, a wrong
  refusal, a message that names the symptom instead of the cause: fix it as
  soon as you find it, then tell me what it was. Asking permission to fix
  something broken wastes a turn and leaves it broken in the meantime. Only stop
  to ask when the fix is a design reversal I have already decided, or when it
  would change something outside what I asked for.
- **Change the UI, show me the UI.** When I ask for something on a window —
  a label, a control, a page, a colour — open the real window afterwards and
  send me the picture, without being asked. A description of the change is not
  the change; the last five defects in the console were found by looking at it,
  and every one of them passed its tests first. Drive it with an STA probe (see
  `New-HDTConsoleHost` and the scratchpad probes) and capture with
  `PrintWindow` — hardware rendering on this host paints blank often enough
  that `RenderOptions.ProcessRenderMode = SoftwareOnly` belongs in the probe.
  A pane that scrolls will not scroll for a probe: `RenderTargetBitmap` on the
  element renders its full height, which is how a row below the fold gets shown.
- **Text on screen is one or two lines. The reasoning goes in the code.**
  A hint under a control says what the setting does and what to do about it,
  in the space its neighbours use. Everything else — why it exists, which real
  machine forced it, what breaks without it — belongs in the comment above the
  markup, where the next person to change it will read it and a technician will
  not have to. Four lines of explanation under one tick box is a screen
  explaining itself at the cost of the controls around it, and this repository
  has already written that rule down twice: MDT admins are not reading the
  manual on the deployment screen.
