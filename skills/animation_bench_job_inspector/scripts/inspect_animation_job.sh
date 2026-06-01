#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${ANIMATION_BENCH_ROOT:-$(pwd)}"
JOBS_DIR=""
TASK_FILTER=""
JOB_DIR=""
TRIAL_DIR=""
LIMIT=10
LIST_ONLY=0

usage() {
  cat <<'EOF'
Usage:
  inspect_animation_job.sh [--repo PATH] [--jobs-dir PATH] [--task NAME] [--job PATH] [--trial PATH] [--list] [--limit N]

Examples:
  inspect_animation_job.sh --list --limit 20
  inspect_animation_job.sh --task ausify-vibe-canvas-carousel
  inspect_animation_job.sh --job /path/to/animation_bench/jobs/<job-folder>
  inspect_animation_job.sh --trial /path/to/animation_bench/jobs/<job-folder>/ausify-vibe-canvas-carousel__abc123
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_ROOT="$2"
      shift 2
      ;;
    --jobs-dir)
      JOBS_DIR="$2"
      shift 2
      ;;
    --task)
      TASK_FILTER="$2"
      shift 2
      ;;
    --job)
      JOB_DIR="$2"
      shift 2
      ;;
    --trial)
      TRIAL_DIR="$2"
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$JOBS_DIR" ]]; then
  JOBS_DIR="$REPO_ROOT/jobs"
fi

if [[ ! -d "$JOBS_DIR" ]]; then
  echo "Jobs directory not found: $JOBS_DIR" >&2
  exit 1
fi

job_sort_rows() {
  local pattern="*"
  if [[ -n "$TASK_FILTER" ]]; then
    pattern="*${TASK_FILTER}*"
  fi

  find "$JOBS_DIR" -mindepth 1 -maxdepth 1 -type d -name "$pattern" -print0 |
    while IFS= read -r -d '' dir; do
      local birth mtime key
      birth="$(stat -f '%B' "$dir" 2>/dev/null || echo -1)"
      mtime="$(stat -f '%m' "$dir" 2>/dev/null || echo 0)"
      key="$birth"
      if [[ "$key" == "-1" || "$key" == "0" ]]; then
        key="$mtime"
      fi
      printf '%s\t%s\n' "$key" "$dir"
    done |
    sort -rn
}

if [[ "$LIST_ONLY" == "1" ]]; then
  job_sort_rows | head -n "$LIMIT"
  exit 0
fi

if [[ -n "$TRIAL_DIR" ]]; then
  if [[ ! -d "$TRIAL_DIR" ]]; then
    echo "Trial directory not found: $TRIAL_DIR" >&2
    exit 1
  fi
  JOB_DIR="$(dirname "$TRIAL_DIR")"
fi

if [[ -z "$JOB_DIR" ]]; then
  JOB_DIR="$(job_sort_rows | head -n 1 | cut -f2-)"
fi

if [[ -z "$JOB_DIR" || ! -d "$JOB_DIR" ]]; then
  echo "No matching job directory found." >&2
  exit 1
fi

if [[ -z "$TRIAL_DIR" ]]; then
  TRIAL_DIR="$(find "$JOB_DIR" -mindepth 1 -maxdepth 1 -type d -name '*__*' | sort | head -n 1)"
fi

if [[ -z "$TRIAL_DIR" || ! -d "$TRIAL_DIR" ]]; then
  echo "No trial directory found under: $JOB_DIR" >&2
  exit 1
fi

candidate="$TRIAL_DIR/artifacts/output/index.html"

echo "Job directory:"
echo "$JOB_DIR"
echo
echo "Trial directory:"
echo "$TRIAL_DIR"
echo

echo "Candidate HTML:"
if [[ -f "$candidate" ]]; then
  ls -lh "$candidate"
else
  echo "missing: $candidate"
fi
echo

echo "Local reports and visual artifacts:"
find "$TRIAL_DIR" -maxdepth 3 -type f \( \
  -name 'report.html' -o \
  -name 'metrics.json' -o \
  -name 'reference.gif' -o \
  -name 'candidate.gif' -o \
  -name 'comparison.gif' -o \
  -name 'contact_sheet.png' -o \
  -name 'candidate_playback.html' -o \
  -name 'reference.html' \
\) -print | sort || true
echo

echo "Trial artifacts:"
find "$TRIAL_DIR/artifacts" -maxdepth 4 -type f -print 2>/dev/null | sort || true
echo

echo "Result JSON files:"
for result in "$TRIAL_DIR/result.json" "$JOB_DIR/result.json"; do
  if [[ -f "$result" ]]; then
    echo "$result"
  fi
done
echo

if command -v jq >/dev/null 2>&1; then
  if [[ -f "$TRIAL_DIR/result.json" ]]; then
    echo "Trial cost and tokens:"
    jq '{agent: .agent_info, cost_usd: .agent_result.cost_usd, input_tokens: .agent_result.n_input_tokens, cache_tokens: .agent_result.n_cache_tokens, output_tokens: .agent_result.n_output_tokens, started_at, finished_at}' "$TRIAL_DIR/result.json"
    echo
  fi

  if [[ -f "$JOB_DIR/result.json" ]]; then
    echo "Job total cost and tokens:"
    jq '{cost_usd: .stats.cost_usd, input_tokens: .stats.n_input_tokens, cache_tokens: .stats.n_cache_tokens, output_tokens: .stats.n_output_tokens, started_at, finished_at}' "$JOB_DIR/result.json"
    echo
  fi
else
  echo "jq not found; open result.json files above for cost and token counts."
  echo
fi

echo "Image/HAR/output proof lines:"
log_files=()
for log_file in \
  "$TRIAL_DIR/trial.log" \
  "$TRIAL_DIR/agent/claude-code.txt" \
  "$TRIAL_DIR/agent/opencode.txt" \
  "$TRIAL_DIR/agent/trajectory.json"
do
  if [[ -f "$log_file" ]]; then
    log_files+=("$log_file")
  fi
done

if command -v rg >/dev/null 2>&1; then
  rg -n 'Read|frame_000|frame_011|tool_result.*image|Image read successfully|/app/input/screenshots|\.har|ausify_vibe.har|motion_css_spring.har|/app/output/index.html|total_cost_usd|costUSD|modelUsage' \
    --max-columns 300 --max-columns-preview \
    "${log_files[@]}" 2>/dev/null | head -n 120 || true
else
  grep -RInE 'frame_000|frame_011|/app/input/screenshots|\.har|/app/output/index.html|total_cost_usd|costUSD|modelUsage' \
    "${log_files[@]}" 2>/dev/null | head -n 120 || true
fi
