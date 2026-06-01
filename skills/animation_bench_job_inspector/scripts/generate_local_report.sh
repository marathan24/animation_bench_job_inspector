#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${ANIMATION_BENCH_ROOT:-$(pwd)}"
JOB_DIR=""
TRIAL_DIR=""
OUT_DIR=""
DURATION_MS="3400"
FORCE=0

usage() {
  cat <<'EOF'
Usage:
  generate_local_report.sh [--repo PATH] [--job PATH | --trial PATH] [--out PATH] [--duration-ms N] [--force]

Examples:
  generate_local_report.sh --job /path/to/animation_bench/jobs/<job-folder>
  generate_local_report.sh --trial /path/to/animation_bench/jobs/<job-folder>/<trial-folder>
  generate_local_report.sh --trial /path/to/animation_bench/jobs/<job-folder>/<trial-folder> --duration-ms 3400 --force

Creates benchmark-style local_score/report.html with:
  reference.html, candidate_playback.html, metrics.json,
  reference.gif, candidate.gif, comparison.gif, contact_sheet.png
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_ROOT="$2"
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
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --duration-ms)
      DURATION_MS="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
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

if [[ -n "$TRIAL_DIR" ]]; then
  if [[ ! -d "$TRIAL_DIR" ]]; then
    echo "Trial directory not found: $TRIAL_DIR" >&2
    exit 1
  fi
  JOB_DIR="$(dirname "$TRIAL_DIR")"
fi

if [[ -n "$JOB_DIR" && -z "$TRIAL_DIR" ]]; then
  if [[ ! -d "$JOB_DIR" ]]; then
    echo "Job directory not found: $JOB_DIR" >&2
    exit 1
  fi
  TRIAL_DIR="$(find "$JOB_DIR" -mindepth 1 -maxdepth 1 -type d -name '*__*' | sort | head -n 1)"
fi

if [[ -z "$TRIAL_DIR" || ! -d "$TRIAL_DIR" ]]; then
  echo "No trial directory found. Pass --job or --trial." >&2
  exit 1
fi

candidate="$TRIAL_DIR/artifacts/output/index.html"
if [[ ! -f "$candidate" ]]; then
  echo "Candidate HTML not found: $candidate" >&2
  exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$TRIAL_DIR/local_score"
fi

existing_report="$OUT_DIR/report.html"
if [[ "$FORCE" != "1" && -f "$existing_report" ]]; then
  echo "Report already exists: $existing_report"
  exit 0
fi

task_id="$(basename "$TRIAL_DIR")"
task_id="${task_id%%__*}"

cd "$REPO_ROOT"
mkdir -p "$OUT_DIR"

if [[ "$FORCE" == "1" ]]; then
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR"
fi

# Prefer strict task scorers when available. They write the same report layout.
if [[ "$task_id" == "ausify-vibe-canvas-carousel" ]]; then
  uv run --extra visual animation-bench-score-ausify \
    --candidate "$candidate" \
    --out "$OUT_DIR"
  exit 0
fi

if [[ "$task_id" == "motion-dev-animation" ]]; then
  uv run --extra visual animation-bench-score-motion-dev \
    --candidate "$candidate" \
    --out "$OUT_DIR"
  exit 0
fi

reference_dir="$REPO_ROOT/harbor_tasks/$task_id/environment/src/input/screenshots"
if [[ ! -d "$reference_dir" ]]; then
  echo "Reference frame directory not found: $reference_dir" >&2
  echo "No strict scorer matched task '$task_id', and generic report generation needs reference frames." >&2
  exit 1
fi

uv run --extra visual python - "$candidate" "$reference_dir" "$OUT_DIR" "$task_id" "$DURATION_MS" <<'PY'
from __future__ import annotations

import asyncio
import html as html_lib
import io
import json
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageOps
from playwright.async_api import async_playwright
from skimage.metrics import structural_similarity as ssim_metric

candidate = Path(sys.argv[1])
reference_dir = Path(sys.argv[2])
out_dir = Path(sys.argv[3])
task_id = sys.argv[4]
duration_ms = int(sys.argv[5])
viewport = {"width": 1280, "height": 720}


def image(data: bytes) -> Image.Image:
    return Image.open(io.BytesIO(data)).convert("RGB")


def read_reference_frames() -> list[bytes]:
    paths = sorted(reference_dir.glob("frame_*.png"))
    if not paths:
        raise SystemExit(f"No reference frames found in {reference_dir}")
    return [path.read_bytes() for path in paths]


def frame_times(samples: int) -> list[float]:
    denom = max(samples - 1, 1)
    return [i * duration_ms / denom for i in range(samples)]


async def capture_candidate_frames(samples: int) -> list[bytes]:
    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        context = await browser.new_context(viewport=viewport, service_workers="block")
        page = await context.new_page()
        try:
            await page.goto(candidate.resolve().as_uri(), wait_until="domcontentloaded")
            await page.wait_for_selector("canvas", timeout=5000, state="visible")
            try:
                await page.evaluate(
                    "() => document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve()"
                )
            except Exception:
                pass
            await page.wait_for_timeout(100)
            frames: list[bytes] = []
            last = 0.0
            for t_ms in frame_times(samples):
                wait = max(0, round(t_ms - last))
                if wait:
                    await page.wait_for_timeout(wait)
                frames.append(await page.screenshot(animations="allow"))
                last = t_ms
            return frames
        finally:
            await context.close()
            await browser.close()


def ssim(a: bytes, b: bytes) -> float:
    ia = np.asarray(image(a).convert("L"))
    ib = np.asarray(image(b).convert("L"))
    h, w = min(ia.shape[0], ib.shape[0]), min(ia.shape[1], ib.shape[1])
    if h < 7 or w < 7:
        return 0.0
    return float(ssim_metric(ia[:h, :w], ib[:h, :w], data_range=255))


def to_tensor(img: Image.Image, size: tuple[int, int]):
    import torch

    arr = np.asarray(img.resize(size, Image.BILINEAR), dtype=np.float32) / 127.5 - 1.0
    return torch.from_numpy(arr.transpose(2, 0, 1))


def lpips_per_frame(ref_frames: list[bytes], cand_frames: list[bytes]) -> list[float]:
    import lpips
    import torch

    ref_imgs = [image(frame) for frame in ref_frames]
    cand_imgs = [image(frame) for frame in cand_frames]
    h = max(min(img.height for img in ref_imgs + cand_imgs), 32)
    w = max(min(img.width for img in ref_imgs + cand_imgs), 32)
    size = (w, h)

    ref_t = torch.stack([to_tensor(img, size) for img in ref_imgs])
    cand_t = torch.stack([to_tensor(img, size) for img in cand_imgs])
    net = lpips.LPIPS(net="alex", verbose=False)
    net.eval()
    if torch.cuda.is_available():
        net = net.cuda()
    device = next(net.parameters()).device
    with torch.no_grad():
        dists = net(ref_t.to(device), cand_t.to(device)).flatten().cpu().numpy()
    return [float(value) for value in dists]


def write_pngs(frames: list[bytes], path: Path) -> list[str]:
    path.mkdir(parents=True, exist_ok=True)
    outputs: list[str] = []
    for i, frame in enumerate(frames):
        file = path / f"frame_{i:03d}.png"
        file.write_bytes(frame)
        outputs.append(str(file))
    return outputs


def diff_image(ref: Image.Image, cand: Image.Image) -> Image.Image:
    width, height = min(ref.width, cand.width), min(ref.height, cand.height)
    raw = ImageChops.difference(
        ref.crop((0, 0, width, height)),
        cand.crop((0, 0, width, height)),
    )
    return ImageOps.autocontrast(raw.point(lambda px: min(px * 4, 255)))


def label(img: Image.Image, text: str) -> Image.Image:
    out = Image.new("RGB", (img.width, img.height + 20), "white")
    out.paste(img, (0, 20))
    ImageDraw.Draw(out).text((4, 3), text, fill="black")
    return out


def comparison_frame(ref: bytes, cand: bytes, score: float) -> Image.Image:
    ref_img = image(ref)
    cand_img = image(cand)
    parts = [
        label(ref_img, "reference"),
        label(cand_img, "candidate"),
        label(diff_image(ref_img, cand_img), f"diff ssim={score:.3f}"),
    ]
    height = max(part.height for part in parts)
    out = Image.new("RGB", (sum(part.width for part in parts), height), "white")
    x = 0
    for part in parts:
        out.paste(part, (x, 0))
        x += part.width
    return out


def write_gif(frames: list[Image.Image], path: Path) -> None:
    if not frames:
        return
    frame_ms = max(round(duration_ms / max(len(frames) - 1, 1)), 20)
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=frame_ms, loop=0)


def write_frame_gif(frames: list[bytes], path: Path) -> None:
    write_gif([image(frame) for frame in frames], path)


def write_contact_sheet(frames: list[Image.Image], path: Path) -> None:
    if not frames:
        return
    width = max(frame.width for frame in frames)
    sheet = Image.new("RGB", (width, sum(frame.height for frame in frames)), "white")
    y = 0
    for frame in frames:
        sheet.paste(frame, (0, y))
        y += frame.height
    sheet.save(path)


def write_sequence_html(path: Path, title: str, frame_dir: str, count: int) -> None:
    escaped_title = html_lib.escape(title)
    frames = [f"{frame_dir}/frame_{i:03d}.png" for i in range(count)]
    frame_ms = max(round(duration_ms / max(count - 1, 1)), 20)
    path.write_text(
        "\n".join(
            [
                "<!doctype html><meta charset='utf-8'>",
                f"<title>{escaped_title}</title>",
                "<style>",
                "html,body{margin:0;width:100%;height:100%;background:#050505;color:#eee;font-family:system-ui,sans-serif;overflow:hidden}",
                ".stage{position:fixed;inset:0;display:grid;place-items:center}",
                "img{max-width:100vw;max-height:100vh;width:100vw;height:100vh;object-fit:contain;background:#000}",
                ".hud{position:fixed;left:12px;bottom:10px;padding:6px 8px;background:rgba(0,0,0,.72);border:1px solid #333;font-size:12px}",
                "</style>",
                "<div class='stage'><img id='frame' alt='animation frame'></div>",
                f"<div class='hud'>{escaped_title} <span id='idx'></span></div>",
                "<script>",
                f"const frames = {json.dumps(frames)};",
                f"const frameMs = {frame_ms};",
                "const img = document.getElementById('frame');",
                "const idx = document.getElementById('idx');",
                "let i = 0;",
                "function show(){ img.src = frames[i]; idx.textContent = `${i + 1}/${frames.length}`; i = (i + 1) % frames.length; }",
                "show(); setInterval(show, frameMs);",
                "</script>",
            ]
        ),
        encoding="utf-8",
    )


def write_report(metrics: dict[str, object]) -> None:
    body = [
        "<!doctype html><meta charset='utf-8'>",
        f"<title>{task_id}</title>",
        "<style>body{font-family:system-ui,sans-serif;margin:24px;max-width:1200px}"
        ".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin:16px 0}"
        "figure{margin:0}figcaption{font-weight:600;margin:0 0 6px}"
        "img{max-width:100%;height:auto;border:1px solid #ddd;background:#000}"
        "code,pre{background:#f6f6f6;padding:2px 4px}</style>",
        f"<h1>{task_id}</h1>",
        f"<p><strong>Final reward:</strong> {metrics['final_reward']} &nbsp; "
        f"<strong>Animation match:</strong> {metrics['animation_match']} &nbsp; "
        f"<strong>LPIPS match:</strong> {metrics['lpips_match']} &nbsp; "
        f"<strong>Mean LPIPS:</strong> {metrics['mean_frame_lpips']}</p>",
        "<p><a href='reference.html'>reference playback</a> | "
        "<a href='candidate_playback.html'>candidate playback</a> | "
        "<a href='metrics.json'>metrics.json</a></p>",
        "<h2>Animated Playback</h2>",
        "<div class='grid'>",
        "<figure><figcaption>Reference</figcaption><a href='reference.html'><img src='reference.gif' alt='reference animation'></a></figure>",
        "<figure><figcaption>Candidate</figcaption><a href='candidate_playback.html'><img src='candidate.gif' alt='candidate animation'></a></figure>",
        "<figure><figcaption>Comparison</figcaption><a href='comparison.gif'><img src='comparison.gif' alt='reference candidate diff animation'></a></figure>",
        "</div>",
        "<h2>Frame Comparison</h2>",
        "<img src='contact_sheet.png' alt='reference candidate diff frames'>",
    ]
    (out_dir / "report.html").write_text("\n".join(body), encoding="utf-8")


async def main() -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    ref_frames = read_reference_frames()
    cand_frames = await capture_candidate_frames(len(ref_frames))
    frame_ssim = [ssim(ref, cand) for ref, cand in zip(ref_frames, cand_frames)]
    frame_lpips = lpips_per_frame(ref_frames, cand_frames)

    reference_paths = write_pngs(ref_frames, out_dir / "reference")
    candidate_paths = write_pngs(cand_frames, out_dir / "candidate")

    comparisons = [
        comparison_frame(ref, cand, score)
        for ref, cand, score in zip(ref_frames, cand_frames, frame_ssim)
    ]
    comparison_dir = out_dir / "comparison"
    comparison_dir.mkdir(exist_ok=True)
    comparison_paths: list[str] = []
    for i, frame in enumerate(comparisons):
        path = comparison_dir / f"frame_{i:03d}.png"
        frame.save(path)
        comparison_paths.append(str(path))

    write_frame_gif(ref_frames, out_dir / "reference.gif")
    write_frame_gif(cand_frames, out_dir / "candidate.gif")
    write_gif(comparisons, out_dir / "comparison.gif")
    write_contact_sheet(comparisons, out_dir / "contact_sheet.png")
    write_sequence_html(out_dir / "reference.html", "reference", "reference", len(ref_frames))
    write_sequence_html(out_dir / "candidate_playback.html", "candidate playback", "candidate", len(cand_frames))
    shutil.copy2(candidate, out_dir / "candidate.html")

    animation_match = float(np.mean(frame_ssim)) if frame_ssim else 0.0
    mean_lpips = float(np.mean(frame_lpips)) if frame_lpips else 1.0
    lpips_match = float(1.0 - min(max(mean_lpips, 0.0), 1.0))
    style_match = 1.0
    final_reward = animation_match + 0.25 * style_match + 0.5 * lpips_match

    metrics: dict[str, object] = {
        "task_id": task_id,
        "candidate": str(candidate),
        "reference_dir": str(reference_dir),
        "duration_ms": duration_ms,
        "frame_times_ms": frame_times(len(ref_frames)),
        "viewport": viewport,
        "style_match": style_match,
        "animation_match": animation_match,
        "lpips_match": lpips_match,
        "final_reward": final_reward,
        "min_frame_ssim": min(frame_ssim) if frame_ssim else 0.0,
        "frame_ssim": frame_ssim,
        "mean_frame_lpips": mean_lpips,
        "frame_lpips": frame_lpips,
        "files": {
            "candidate_html": str(out_dir / "candidate.html"),
            "reference_html": str(out_dir / "reference.html"),
            "candidate_playback_html": str(out_dir / "candidate_playback.html"),
            "report": str(out_dir / "report.html"),
            "metrics": str(out_dir / "metrics.json"),
            "reference_frames": reference_paths,
            "candidate_frames": candidate_paths,
            "comparison_frames": comparison_paths,
            "reference_gif": str(out_dir / "reference.gif"),
            "candidate_gif": str(out_dir / "candidate.gif"),
            "comparison_gif": str(out_dir / "comparison.gif"),
            "contact_sheet": str(out_dir / "contact_sheet.png"),
        },
    }
    (out_dir / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    write_report(metrics)
    print(json.dumps({"report": str(out_dir / "report.html"), **{k: metrics[k] for k in ("final_reward", "animation_match", "lpips_match", "mean_frame_lpips")}}, indent=2))


asyncio.run(main())
PY
