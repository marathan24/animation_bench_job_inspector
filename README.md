# animation_bench_job_inspector

`animation_bench_job_inspector` is an agent skill for inspecting local Animation
Bench Harbor/Daytona job folders. It finds candidate HTML, local reports,
metrics, GIFs, contact sheets, result JSON, model cost, token counts, and
image/HAR usage proof.

It also includes a report generator that creates the compact benchmark-style
`local_score/report.html` when a job does not already have one.

## What The Skill Does

The skill helps an agent:

- inspect the latest job, a task-filtered job, an exact job folder, or an exact trial folder
- report candidate HTML and generated local visual artifacts
- generate `report.html`, `metrics.json`, `reference.gif`, `candidate.gif`, `comparison.gif`, and `contact_sheet.png`
- use strict local scorers for supported tasks
- create fallback visual reports for rollout-only tasks that have reference frames
- summarize result JSON, cost, token usage, and image/HAR evidence from logs

## Prerequisites

- A local `animation_bench` checkout with job folders under `jobs/`
- `uv` available in the benchmark repo for visual report generation
- Python visual dependencies installed through the benchmark project extras
- `jq` and `rg` are recommended for inspection output

When the benchmark repo is not the current working directory, set:

```bash
export ANIMATION_BENCH_ROOT=/path/to/animation_bench
```

## Install In Claude Code

### Option 1: Install As A Standalone Skill

For personal use, copy or symlink the skill into `~/.claude/skills/animation_bench_job_inspector`:

```bash
mkdir -p ~/.claude/skills
ln -s /path/to/animation_bench_job_inspector/skills/animation_bench_job_inspector ~/.claude/skills/animation_bench_job_inspector
```

For one repository only, copy or symlink it into `.claude/skills/animation_bench_job_inspector` inside that project:

```bash
mkdir -p .claude/skills
ln -s /path/to/animation_bench_job_inspector/skills/animation_bench_job_inspector .claude/skills/animation_bench_job_inspector
```

Once installed as a standalone skill, invoke it as:

```text
/animation_bench_job_inspector
```

### Option 2: Install As A Plugin

Add this repository as a marketplace:

```bash
/plugin marketplace add marathan24/animation_bench_job_inspector
```

Install the plugin:

```bash
/plugin install animation_bench_job_inspector@animation_bench_job_inspector
```

When installed as a plugin, invoke it as:

```text
/animation_bench_job_inspector:animation_bench_job_inspector
```

## Install In Codex

Install the published skill directly from the skill folder:

```bash
$skill-installer install https://github.com/marathan24/animation_bench_job_inspector/tree/main/skills/animation_bench_job_inspector
```

## Common Commands

Inspect a job:

```bash
bash skills/animation_bench_job_inspector/scripts/inspect_animation_job.sh \
  --job /path/to/animation_bench/jobs/<job-folder>
```

Generate or verify the local benchmark-style report:

```bash
bash skills/animation_bench_job_inspector/scripts/generate_local_report.sh \
  --job /path/to/animation_bench/jobs/<job-folder>
```

Regenerate a report:

```bash
bash skills/animation_bench_job_inspector/scripts/generate_local_report.sh \
  --trial /path/to/animation_bench/jobs/<job-folder>/<trial-folder> \
  --force
```

## Repository Layout

```text
.
├── .claude-plugin/marketplace.json
├── AGENTS.md
├── README.md
└── skills/animation_bench_job_inspector/
    ├── SKILL.md
    ├── agents/openai.yaml
    └── scripts/
        ├── generate_local_report.sh
        └── inspect_animation_job.sh
```

## Example Prompts

- `Inspect this Animation Bench job folder and bring me the report HTML.`
- `Generate the local_score report for this rollout-only task and show the contact sheet.`
- `How much did this Claude Code run cost, and did it read all screenshot frames?`

