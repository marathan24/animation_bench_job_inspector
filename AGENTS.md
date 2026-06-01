# AGENTS.md

This repository publishes one agent skill: `animation_bench_job_inspector`.

## Available Skill

- `skills/animation_bench_job_inspector`: Inspect Animation Bench Harbor job folders, generate benchmark-style local reports, and summarize artifacts, metrics, token usage, cost, and image/HAR proof.

## Notes

- Install `animation_bench_job_inspector` from `skills/animation_bench_job_inspector`.
- Set `ANIMATION_BENCH_ROOT=/path/to/animation_bench` when the benchmark repo is not the current working directory.
- The helper scripts expect a local Animation Bench checkout with `uv` dependencies available for visual report generation.

