---
name: animation_bench_job_inspector
description: Inspect Animation Bench Harbor/Daytona job folders for candidate HTML, benchmark-style local reports, GIFs, contact sheets, metrics, result JSON, model cost, token counts, and image/HAR usage proof.
---

# Animation Bench Job Inspector

Use this skill for local `animation_bench` Harbor job folders. It is designed
to inspect a job or trial directory and, when needed, generate the same compact
benchmark-style `local_score/report.html` used by local visual scorers.

Set the benchmark root once when it is not the current directory:

```bash
export ANIMATION_BENCH_ROOT=/path/to/animation_bench
```

## Quick Command

Run the bundled inspector first:

```bash
bash skills/animation_bench_job_inspector/scripts/inspect_animation_job.sh
```

Common variants:

```bash
# List newest job folders by creation time, newest first.
bash skills/animation_bench_job_inspector/scripts/inspect_animation_job.sh --list --limit 20

# Inspect the newest job matching a task name.
bash skills/animation_bench_job_inspector/scripts/inspect_animation_job.sh --task ausify-vibe-canvas-carousel

# Inspect an exact job directory.
bash skills/animation_bench_job_inspector/scripts/inspect_animation_job.sh \
  --job /path/to/animation_bench/jobs/<job-folder>

# Inspect an exact trial directory.
bash skills/animation_bench_job_inspector/scripts/inspect_animation_job.sh \
  --trial /path/to/animation_bench/jobs/<job-folder>/<trial-folder>
```

## Required Report Generation Step

When given a job folder or trial folder, always make sure a benchmark-style
`local_score/report.html` exists before the final answer. The report should
include:

- a metric line with final reward, animation match, LPIPS match, and mean LPIPS
- links to `reference.html`, `candidate_playback.html`, and `metrics.json`
- animated playback GIFs for reference, candidate, and comparison
- `contact_sheet.png` with reference/candidate/diff frames

Use this command after the initial inspection if `local_score*/report.html` is
missing, incomplete, or the user asks for the report HTML:

```bash
bash skills/animation_bench_job_inspector/scripts/generate_local_report.sh \
  --job /path/to/animation_bench/jobs/<job-folder>
```

For an exact trial:

```bash
bash skills/animation_bench_job_inspector/scripts/generate_local_report.sh \
  --trial /path/to/animation_bench/jobs/<job-folder>/<trial-folder>
```

To regenerate an existing report:

```bash
bash skills/animation_bench_job_inspector/scripts/generate_local_report.sh \
  --trial /path/to/animation_bench/jobs/<job-folder>/<trial-folder> \
  --force
```

What this script does:

- Detects the trial from `--job` or uses the exact `--trial`.
- Uses strict local scorers for known tasks:
  - `ausify-vibe-canvas-carousel` runs `uv run --extra visual animation-bench-score-ausify`.
  - `motion-dev-animation` runs `uv run --extra visual animation-bench-score-motion-dev`.
- For rollout-only tasks with reference frames under
  `harbor_tasks/<task>/environment/src/input/screenshots`, generates the same
  report shape directly:
  - captures candidate frames from `<trial>/artifacts/output/index.html`
  - writes `reference/frame_*.png`, `candidate/frame_*.png`, and
    `comparison/frame_*.png`
  - writes `reference.gif`, `candidate.gif`, `comparison.gif`, and
    `contact_sheet.png`
  - writes `reference.html`, `candidate_playback.html`, and `candidate.html`
  - writes `metrics.json` and `report.html`

Use `--duration-ms 3400` for Slow Down footer reveal style tasks when you need
the same capture timing used in the verified report generation:

```bash
bash skills/animation_bench_job_inspector/scripts/generate_local_report.sh \
  --trial /path/to/animation_bench/jobs/<job-folder>/<trial-folder> \
  --duration-ms 3400 \
  --force
```

## What To Report

Always report these if present:

- Candidate HTML: `<trial>/artifacts/output/index.html`
- Local score reports: `<trial>/local_score*/report.html`
- Metrics: `<trial>/local_score*/metrics.json`
- GIFs: `<trial>/local_score*/reference.gif`, `candidate.gif`, `comparison.gif`
- Contact sheet: `<trial>/local_score*/contact_sheet.png`
- Trial result JSON: `<trial>/result.json`
- Job result JSON: `<job>/result.json`
- Cost and tokens from `agent_result` in trial `result.json`; fall back to
  `stats` in job `result.json`.

Use clickable absolute file links in final answers when working locally.

## Finding Newest Jobs Manually

Use creation time when macOS birth time exists; fall back to modification time:

```bash
cd "$ANIMATION_BENCH_ROOT"
find jobs -maxdepth 1 -mindepth 1 -type d -print0 |
  while IFS= read -r -d '' dir; do
    birth="$(stat -f '%B' "$dir" 2>/dev/null || echo -1)"
    mtime="$(stat -f '%m' "$dir" 2>/dev/null || echo 0)"
    key="$birth"
    if [ "$key" = "-1" ] || [ "$key" = "0" ]; then key="$mtime"; fi
    printf '%s\t%s\n' "$key" "$dir"
  done |
  sort -rn |
  head -20
```

## Cost Commands

For a trial:

```bash
jq '{agent: .agent_info, cost_usd: .agent_result.cost_usd, input_tokens: .agent_result.n_input_tokens, cache_tokens: .agent_result.n_cache_tokens, output_tokens: .agent_result.n_output_tokens}' \
  /path/to/trial/result.json
```

For a job-level total:

```bash
jq '{cost_usd: .stats.cost_usd, input_tokens: .stats.n_input_tokens, cache_tokens: .stats.n_cache_tokens, output_tokens: .stats.n_output_tokens}' \
  /path/to/job/result.json
```

Claude Code traces often also contain `total_cost_usd` and `modelUsage`:

```bash
rg -n 'total_cost_usd|costUSD|modelUsage|n_input_tokens|n_output_tokens' /path/to/trial/agent/claude-code.txt
```

## Generate Local Reports If Missing

Prefer the required report generation command above. If manually running strict
scorers is useful for debugging, these are the underlying commands:

```bash
cd "$ANIMATION_BENCH_ROOT"

uv run --extra visual animation-bench-score-ausify \
  --candidate /path/to/trial/artifacts/output/index.html \
  --out /path/to/trial/local_score

uv run --extra visual animation-bench-score-motion-dev \
  --candidate /path/to/trial/artifacts/output/index.html \
  --out /path/to/trial/local_score
```

For Ausify, if strict scoring fails with `waiting for locator("canvas")`,
report that the candidate missed the visible canvas requirement. A relaxed
visual report may still be useful, but label it as relaxed and not strict task
scoring.

For rollout-only tasks where tests intentionally exit and no strict scorer is
registered, do not stop at "report missing" if reference frames exist. Run
`generate_local_report.sh` so the skill still produces benchmark-style report
files every time.

## Image And HAR Usage Proof

Search the agent logs for image reads and HAR reads:

```bash
rg -n 'Read|frame_000|frame_011|tool_result.*image|Image read successfully|/app/input/screenshots|\\.har|ausify_vibe.har|motion_css_spring.har|/app/output/index.html' \
  /path/to/trial/agent /path/to/trial/trial.log
```

For Claude Code, actual image visibility is proven when `Read` calls for
`frame_*.png` are followed by tool results with `type":"image"` and image
dimensions.
