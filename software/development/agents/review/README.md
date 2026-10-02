# review

The operator-owned review standard (AI_ST-111, US-7) and the four-seat review panel
(AI_ST-112, US-8), both ruled on 2026-09-25
(`~/vault/20-surface/company/tasks/day-plan-2026-09-25/rulings.md`). This directory is
documentation plus two file-only tools. It is not a module: nothing here is installed
or linked, and no tool here calls a model.

| Path | Purpose |
|---|---|
| `review-rubric.md` | The rubric. The text between its markers goes to every reviewer verbatim |
| `panel-protocol.md` | Who sits on the panel, how a round runs, void reviews, concurrence, the release record |
| `model-tiers.md` | Operator-owned, dated capability-tier table that the tier rule reads |
| `tools/assemble_prompts.py` | Rubric, instructions, brief, and artefact go in; one prompt per seat and `panel.json` come out. Refuses a panel that breaks the tier rule |
| `tools/tally_concurrence.py` | Seat findings files go in; void seats and CONFIRMED, NEAR, and SINGLE groups come out |
| `tests/` | `python3 -m pytest -q tests/` from this directory |

## Operator guide: the rubric

**Where it lives.** `review-rubric.md` on this repo's `main`. The handed text is
everything between `<!-- BEGIN RUBRIC -->` and `<!-- END RUBRIC -->`. The frontmatter,
this README, and the changelog are for you and never reach a reviewer.

**No per-review edits.** A review never edits the rubric. Put anything specific to one
review in the brief (`--brief`): what the artefact is, what it is for, and which sections
changed recently and need extra attention (the seed prompt's attention clause lives
there now). The rubric tells reviewers that it wins wherever the brief conflicts with it.

**How to bump.** Every change between the markers is a version bump:

1. Edit the body. Change the version in three places: frontmatter `version:`, the
   body's first line `REVIEW RUBRIC v<x.y.z>`, and the output-format line
   `RUBRIC: <x.y.z>`. `read_rubric()` refuses the file unless all three agree, and
   `tests/test_panel.py` fails too.
2. Choose the version number. Patch (1.0.1) is a wording fix that leaves findings
   comparable. Minor (1.1.0) adds or sharpens a criterion or a field. Major (2.0.0)
   changes the output format or the axes, so the tally parser must change in the same
   commit.
3. Add a changelog line with the date and the reason.
4. Commit on a branch and ship it through a harness release like any other harness
   change. Never bump mid-round: every seat in one round must cite the same version.

**How a review cites it.** Every reply carries `RUBRIC: <version>`, and the tally voids
any reply whose version differs from the manifest's. `panel.json` records the version
and the sha256 of the exact handed text. A release record cites both, for example
`rubric v1.0.0 (sha256 3f2a...)`, so a later reader can prove which words the
reviewers saw, even after the rubric has moved on (`git log -p review-rubric.md`).

## Quick start

```bash
cd software/development/agents/review
round=~/vault/20-surface/company/tasks/<ISSUE>/reviews/round-1
# Set MODEL_1..MODEL_4 to four distinct qualifying model ids verified in their runtimes.
tools/assemble_prompts.py --producer claude-fable-5-1 \
  --reviewer "$MODEL_1" --reviewer "$MODEL_2" --reviewer "$MODEL_3" --reviewer "$MODEL_4" \
  --brief brief.md --out "$round" --root ~/environment-foundation path/to/artefact ...
# run each $round/seat-N.prompt.txt through its reviewer; save the reply as $round/seat-N.md
tools/tally_concurrence.py --manifest "$round/panel.json"   # exit 2 = a seat is void, rerun it
```

`panel-protocol.md` covers the rest.
