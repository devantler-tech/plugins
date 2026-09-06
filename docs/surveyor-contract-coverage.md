# Surveyor contract coverage

[`surveyor-review-contract.test.sh`](../plugins/agentic-engineering/scripts/surveyor-review-contract.test.sh)
checks the operative instructions in the bundled
[`portfolio-surveyor`](../plugins/agentic-engineering/agents/portfolio-surveyor.agent.md).
The `lint-scripts` CI job discovers this suite beside the plugin's other tests. It checks structural
drift, not whether a model follows the instructions. It introduces no runtime policy or classifier.

Every clause has a stable test ID. Each must appear inside its own section; the suite removes it
independently and requires rejection even with a copy elsewhere in the document. The corresponding
whitespace-only reflow must pass. Empty definitions fail. These controls demonstrate the guards can
detect missing operative instructions without requiring the entire role to retain identical bytes.
They do not parse arbitrary Markdown or prove that nearby contradictory prose is harmless.

Run the suite from the repository root:

```sh
bash plugins/agentic-engineering/scripts/surveyor-review-contract.test.sh
```

For a direct RED check on a temporary mutated definition, use the test-only interface:

```sh
bash plugins/agentic-engineering/scripts/surveyor-review-contract.test.sh --check /path/to/mutant.md
```

## Coverage ownership

The inventory for [#95](https://github.com/devantler-tech/agent-plugins/issues/95) is anchored to
the consumer's
[test revision f8fe925d](https://github.com/devantler-tech/monorepo/blob/f8fe925dd1c8c623606af7d8e5bdd554b6a46f37/.claude/scripts/portfolio-surveyor.test.sh),
the latest change to that file before the issue was filed. It contains **28 checks directly against
the surveyor plus three compatibility-overlay loading checks**. The 31 entries below distinguish
those checks; the issue's shorthand is not a claim that all 31 are generic. Other tests in that
consumer file cover its classifier, product cards, security surveyor, and deployment policy.

“Consumer” means the concrete deployment assertion remains there. A generic replacement pins the
current plugin contract rather than importing a login, namespace, path, or retired spelling. No
consumer overlay or test is removed by this suite.

| Inventory | Source line | Assertion | Current coverage and owner |
|---|---:|---|---|
| O01 | 68 | Exact local programmed-bot classifier path | Consumer path; E01 pins a consumer-declared exact classifier and exit 0. |
| O02 | 76 | Programmed-bot exemption digest state | E05; ordinary hygiene remains required. |
| O03 | 80 | Botantler is only a classifier candidate | Consumer identity; E01/E04 pin successful classification and fail-closed errors. |
| O04 | 82 | KSail App search identity | Consumer identity; A04 pins exact trusted-login matching. |
| O05 | 84 | Complete current-head commit provenance | E02/E03 pin the full commits endpoint result and final-commit/head match. |
| O06 | 96 | Cursor Automation trusted-author identity | Consumer grant and identity; A04 pins exact matching. |
| O07 | 118 | Connector head match before recency | R06/R07. |
| O08 | 120 | Same-head connector findings win | R08–R11 include the current explicit resolution/re-request exception. |
| O09 | 122 | Abbreviated connector SHA is a head prefix | R02/R03/R12 include minimum length and backtick tolerance. |
| O10 | 126 | Reject abbreviated/full-SHA equality | R02 positively requires prefix matching and forbids full-length equality. |
| O11 | 131 | Well-formed nonmatching marker is stale | R04. |
| O12 | 133 | Missing, malformed, or short marker is none | R05 replaces the weak single-word `absent,` check. |
| O13 | 141 | Failed check-run is not findings | K02/K04 separate the title-based states. |
| O14 | 143 | Failed check-run has an error state | K04 and D02 pin the error and signal grammar. |
| O15 | 149 | Usage-limit signal is representable | D02/T03 pin the generic lane grammar and meaning; no fixed reviewer roster or occurrence count. |
| O16 | 161 | Dependency automation short-circuits | A01/A02, conditional on the consuming contract's designation. |
| O17 | 168 | Budget sampled at start and end | B01/B02 pin the timing and both budgets; no particular forge CLI is required. |
| O18 | 170 | Budget digest grammar | D01 pins the current generic start/end spelling. |
| O19 | 172 | Budget exhausted at start is explicit | B03. |
| O20 | 174 | Every digest carries its budget | D04; B04 covers an unavailable probe. |
| O21 | 176 | Exact Renovate identity | Consumer identity; A01 pins the declared exact identities. |
| O22 | 178 | Exact Dependabot identity | Consumer identity; A01 pins the declared exact identities. |
| O23 | 180 | No heavy automation-owned PR deepening | A02. |
| O24 | 182 | Automation-owned PR does not count as fire | A03. |
| O25 | 772 | All declared writer namespaces are scanned | C01; the actual namespace list stays in the consumer. |
| O26 | 774 | Claim branch matches issue number across lanes | C01/C02/C05 include the issue suffix and takeover suffix. |
| O27 | 776 | Claim scan is not assignee-gated | C03. |
| O28 | 778 | Unassigned writer-lane claim is representable | D03/D07; C04/D08 additionally require the declared lease before using it as a skip. |
| O29 | 188 | Maintenance skill declares compatibility overlay | Consumer loading contract; retained until consumer parity is proven. |
| O30 | 190 | Maintenance skill instructs loading that overlay | Consumer loading contract; retained until consumer parity is proven. |
| O31 | 192 | Maintenance skill must not forbid overlay loading | Consumer loading contract; retained until consumer parity is proven. |

Additional generic coverage addresses the invariants explicitly named in #95 and their current
semantics: H01 pins complete thread pagination; H02–H05 pin newest-review selection by submission
time, empty newest findings, and stale body findings; R01 pins connector authentication; K01/K05/K06
pin the check-run versus login split; K03 pins neutral findings; P01/D05/D06 pin complete queries and
incomplete-candidate handling; T01/T02 pin evidence-bearing, per-lane `none` output.

The separate existing suites retain their own responsibilities:

- `portfolio-surveyor-agent.test.sh`: the prescribed dependency-summary projection and guard admission.
- `surveyor-open-pr-links.test.sh`: the prescribed linked-PR count projection and malformed responses.
- `surveyor-selection-contract.test.sh`: section-scoped ranking and actionability obligations.
- The forge-guard, adapter, and classifier suites: executable command-boundary behavior.

Passing these checks does not authorize deleting the consumer overlay. The consumer must still
verify its current overlay/procedure parity and preserve deployment-specific coverage before
removing duplicated generic assertions. Its concrete identities, lease policy, local classifier,
provider wiring, and product-specific tests remain consumer-owned.

## Model-behavior evaluation

[`fixtures/surveyor-review.json`](../plugins/agentic-engineering/scripts/fixtures/surveyor-review.json)
contains independent synthetic cases and separately keyed expected outcomes. Give an evaluator
only `consumerContract` and `cases`, together with the current bundled agent definition. Compare
the returned decisions with `expected` afterward; do not supply that answer key in its prompt.

The cases cover stale versus current-head artifacts, same-head findings and their resolution,
backtick-wrapped and too-short markers, spoofed authors, shared vendor logins, neutral check-run
errors versus findings, newest-review body counts, incomplete pagination, branch-only claims, and
classifier failure. They need no credentials, forge access, installed plugin, or mutable runtime.

Record the evaluated definition revision, evaluator, per-case result, and any disagreement in the
review evidence. This is a bounded behavior sample, not proof of compliance across models or
deployments. Real application discovery remains the separate acceptance work in
[#74](https://github.com/devantler-tech/agent-plugins/issues/74).
