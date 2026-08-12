export const meta = {
  name: 'hdt-phase',
  description: 'Run one HDT roadmap phase through the GSD pipeline: plan -> check -> execute -> verify, test-first',
  whenToUse: 'Building or rebuilding a single HDT phase. Pass args: {id, dir, title, goal, planDetail, withChecker, maxPlans}',
  phases: [
    { title: 'Plan' },
    { title: 'Check' },
    { title: 'Execute' },
    { title: 'Verify' },
  ],
}

// ---------------------------------------------------------------------------
// args: { id, dir, title, goal, planDetail, withChecker=true, e2e=false }
// ---------------------------------------------------------------------------
const a = args || {}
if (!a.id || !a.dir || !a.goal) {
  throw new Error('hdt-phase requires args {id, dir, goal}; got: ' + JSON.stringify(a))
}
const title = a.title || `Phase ${a.id}`
const withChecker = a.withChecker !== false

const CONTEXT = `
PROJECT: Hephaestus Deployment Toolkit (HDT) — a PowerShell replacement for MDT.
Repo root: C:\\Users\\Itamartz\\Documents\\GithubRepos\\HDT (git, branch main).

READ THESE FIRST, IN THIS ORDER. They are the specification and they already
settle nearly every decision. Do not re-derive or contradict them:
  1. .planning/PROJECT.md   — settled decisions, constraints, environment,
                              LAB SAFETY RULES, staged media, ADK paths
  2. docs/DESIGN.md         — full technical design
  3. docs/ROADMAP.md        — milestones with per-milestone "Tests first" lists

NON-NEGOTIABLE CONSTRAINTS (violating any is a defect):
  * TDD. A FAILING Pester test is written BEFORE the implementation it covers.
    The only exception is thin adapters over external tools (DISM, CIM, oscdimg,
    registry) which must stay branch-free BECAUSE they are not unit tested.
  * Windows PowerShell 5.1 compatible syntax in src/Hephaestus/ — the engine runs
    in WinPE which has no pwsh. FORBIDDEN: ?? , ?. , ternary, -Parallel,
    $PSStyle, 'clean' blocks, ConvertFrom-Json -AsHashtable.
    Suite must pass under BOTH pwsh 7 and powershell.exe 5.1.
  * EVERY function named Verb-HDTNoun, uppercase HDT, approved verbs, singular
    nouns — public, private, adapters, test helpers, build functions alike.
  * ZERO MDT dependencies. MDT is deprecated. No MicrosoftDeploymentToolkit
    module, no MDTProvider drive, no Microsoft.BDD.* assemblies, no ZTI*/LTI*
    scripts, no ts.xml or MDT Control layout, no MDT database schema.
    PSD (at C:\\HDTLab\\reference\\PSD, MIT licensed) is reference reading ONLY —
    it is an MDT *extension*, so strip every MDT dependency you find in it.
    Mine it for real-world MECHANISM (exact DISM args, CIM properties that are
    empty on VMs, registry values Winlogon actually reads), never for structure.
    ADK and WDS are allowed — they are independent of MDT.
  * Engine logic NEVER calls DISM/CIM/filesystem/registry/network directly; it
    takes injected services so everything runs under Pester against fakes.
  * SupportsShouldProcess on anything destructive; refuse ambiguous targets.
  * Set-StrictMode -Version Latest and $ErrorActionPreference='Stop' in engine code.

HYPER-V LAB SAFETY — the host runs the user's LIVE lab:
  * PROTECTED, never touch: VMs 'CM01' (SCCM, has a PXE responder) and 'DC01'
    (domain controller), both on 'Default Switch' 192.168.25.0/24.
  * HDT test VMs are named HDT-* , Generation 2, attached ONLY to the isolated
    'HDT Lab' switch, files under C:\\HDTLab\\vms\\, under 12 GB combined.
  * Never run an unfiltered Hyper-V pipeline (no 'Get-VM | Remove-VM').
  * PXE/WDS testing ONLY on 'HDT Lab' — never on Default Switch, or it collides
    with CM01's PXE.

Commit atomically as you go.
`

const PLAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    planFiles: { type: 'array', items: { type: 'string' }, description: 'Repo-relative PLAN.md paths in execution order' },
    summary: { type: 'string' },
    risks: { type: 'array', items: { type: 'string' } },
  },
  required: ['planFiles', 'summary'],
}

const EXEC_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    completed: { type: 'boolean' },
    testsPassing: { type: 'boolean' },
    testCount: { type: 'string' },
    filesWritten: { type: 'array', items: { type: 'string' } },
    deviations: { type: 'array', items: { type: 'string' } },
    blockers: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['completed', 'testsPassing', 'summary'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    goalMet: { type: 'boolean' },
    exitCriteriaMet: { type: 'boolean' },
    tddFollowed: { type: 'boolean' },
    ps51Compatible: { type: 'boolean' },
    namingContractPasses: { type: 'boolean' },
    noMdtDependencies: { type: 'boolean' },
    testCount: { type: 'string' },
    issues: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['goalMet', 'exitCriteriaMet', 'issues', 'summary'],
}

phase('Plan')
const plan = await agent(
  `${CONTEXT}

You are planning PHASE ${a.id} of HDT.

PHASE GOAL: ${a.goal}

${a.planDetail || ''}

TASK: Write the execution plan(s) to .planning/phases/${a.dir}/ named
${a.id}-01-PLAN.md, ${a.id}-02-PLAN.md, ... Split into multiple plans ONLY if the
phase has genuinely separable chunks; prefer 1-3.

Each plan must be executable by another agent with no further questions, and must
be structured TEST-FIRST: for each unit of work state the Pester test(s) to write
and watch fail, THEN the implementation that makes them pass. Expand the
"Tests first" bullets from docs/ROADMAP.md for this milestone into concrete
Describe/It names.

Include exact file paths, function names (Verb-HDTNoun), the service interfaces
and fakes needed, and the milestone exit criteria restated as checkable assertions.`,
  { agentType: 'gsd-planner', schema: PLAN_SCHEMA, phase: 'Plan', effort: 'high' }
)

if (!plan || !plan.planFiles || !plan.planFiles.length) {
  log(`Phase ${a.id}: planner produced no plans — aborting`)
  return { id: a.id, failed: 'no-plan' }
}
log(`Phase ${a.id}: ${plan.planFiles.length} plan(s) — ${plan.planFiles.join(', ')}`)
if (plan.risks && plan.risks.length) log(`  risks: ${plan.risks.join(' | ')}`)

if (withChecker) {
  phase('Check')
  const check = await agent(
    `${CONTEXT}

Verify the plan(s) for PHASE ${a.id} will actually achieve the phase goal.

PHASE GOAL: ${a.goal}
PLAN FILES: ${plan.planFiles.join(', ')}

Work goal-backward: executing these plans exactly as written, is the milestone
exit criteria in docs/ROADMAP.md satisfied?

Check specifically:
  * Is every step genuinely test-first, or does some plan write implementation
    before the test covering it?
  * Are injected-service boundaries right, so logic is unit-testable with no hardware?
  * Any PowerShell 5.1 incompatibility planned in?
  * Any Verb-HDTNoun naming violations?
  * Any MDT dependency sneaking in from PSD?
  * Any Hyper-V lab safety rule violated?
  * Gaps versus the "Tests first" list in docs/ROADMAP.md.

If you find problems, EDIT the plan files to fix them. Report what you changed.`,
    { agentType: 'gsd-plan-checker', phase: 'Check', effort: 'high' }
  )
  log(`Phase ${a.id} plan check: ${String(check).slice(0, 400)}`)
}

phase('Execute')
const results = []
for (let i = 0; i < plan.planFiles.length; i++) {
  const pf = plan.planFiles[i]
  const prior = results.length
    ? `\n\nPRIOR PLANS IN THIS PHASE ARE ALREADY EXECUTED:\n${results.map((r, n) => `[${n + 1}] ${r && r.summary}`).join('\n')}\nBuild on that; do not redo it.`
    : ''
  const r = await agent(
    `${CONTEXT}

Execute plan ${pf} (phase ${a.id}, plan ${i + 1} of ${plan.planFiles.length}).${prior}

METHOD — follow strictly:
  1. Write the Pester test(s) for the next unit of behaviour.
  2. RUN them. Confirm they FAIL, and for the right reason (not a syntax error,
     not a missing file). A test that passes before implementation is a broken
     test — fix it.
  3. Write the smallest implementation that makes them pass.
  4. RUN the full suite. Green before moving on.
  5. Refactor, suite still green.
  6. git commit — one logical unit per commit.

RUN TESTS FOR REAL with the Bash or PowerShell tool. Never claim a test passes
without having executed it and read the output. If the suite is red at the end,
say so explicitly rather than reporting success.

Verify PS 5.1 compatibility at least once by running the suite under
  & "$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -Command "..."

Report honestly: real test counts from real output, deviations and why, blockers.`,
    { agentType: 'gsd-executor', schema: EXEC_SCHEMA, phase: 'Execute', effort: 'high', label: `exec:${a.id}-${i + 1}` }
  )
  results.push(r)
  if (r) log(`Phase ${a.id} plan ${i + 1}: completed=${r.completed} green=${r.testsPassing} ${r.testCount || ''}`)
  if (r && r.blockers && r.blockers.length) log(`  BLOCKERS: ${r.blockers.join('; ')}`)
}

phase('Verify')
const verdict = await agent(
  `${CONTEXT}

Verify PHASE ${a.id} achieved its goal.

PHASE GOAL: ${a.goal}
EXIT CRITERIA: docs/ROADMAP.md for this milestone.
Executor summaries: ${results.map(r => r && r.summary).join(' | ')}

Goal-backward verification. Do NOT take the executors' word for anything — RUN
the suite yourself and read the real output.

Verify:
  1. Exit criteria actually met, demonstrably.
  2. TDD followed — check git history: do test files appear in commits before or
     alongside the implementation they cover, never after?
  3. Suite green under BOTH pwsh 7 AND powershell.exe 5.1. Run both.
  4. Verb-HDTNoun naming contract test exists and passes.
  5. No-MDT-dependency contract test exists and passes.
  6. PSScriptAnalyzer clean.
  7. No engine code calling hardware/filesystem/registry directly instead of an
     injected service.
  8. Hyper-V lab untouched: CM01 and DC01 still present and Running, and no
     stray HDT-* VMs left powered on.

Write .planning/phases/${a.dir}/${a.id}-VERIFICATION.md with findings.
Report failures plainly — a false pass compounds into every later phase.`,
  { agentType: 'gsd-verifier', schema: VERIFY_SCHEMA, phase: 'Verify', effort: 'high' }
)

if (verdict) {
  log(`PHASE ${a.id} VERDICT: goal=${verdict.goalMet} exit=${verdict.exitCriteriaMet} tdd=${verdict.tddFollowed} ps51=${verdict.ps51Compatible} noMdt=${verdict.noMdtDependencies}`)
  if (verdict.issues && verdict.issues.length) log(`  ISSUES: ${verdict.issues.join(' | ')}`)
}

return { id: a.id, planFiles: plan.planFiles, verdict }
