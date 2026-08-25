#!/usr/bin/env python3
"""Exercise the published Lives sidecar without requiring private source code."""

from __future__ import annotations

import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import time


def build_request(fixture_dir: Path, output_dir: Path) -> dict[str, object]:
    slots = (("red", "left"), ("green", "center"), ("blue", "right"))
    clips = [
        {
            "id": name,
            "sourcePath": str(fixture_dir / f"clip-{name}.mp4"),
            "sourceDurationMs": 4000,
            "startTimeMs": 0,
            "crop": {
                "normalizedCenterX": 0.5,
                "normalizedCenterY": 0.5,
                "scale": 1,
            },
            "targetSlotId": slot,
            "audioEnabled": True,
        }
        for name, slot in slots
    ]
    return {
        "requestId": "release-smoke-export",
        "action": "renderAndExport",
        "payload": {
            "project": {
                "id": "release-smoke-project",
                "templateId": "side-3",
                "canvas": {"width": 720, "height": 1280, "fps": 30, "durationMs": 3000},
                "clips": clips,
                "coverTimeMs": 1500,
            },
            "directoryPath": str(output_dir),
        },
    }


def run_service(service: Path, request: dict[str, object]) -> dict[str, object]:
    process = subprocess.Popen(
        [str(service), "serve"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None

    process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
    process.stdin.flush()

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    deadline = time.monotonic() + 600
    final: dict[str, object] | None = None

    try:
        while time.monotonic() < deadline and final is None:
            for key, _ in selector.select(timeout=1):
                line = key.fileobj.readline()
                if not line:
                    continue
                if key.data == "stderr":
                    print(line, end="", file=sys.stderr)
                    continue
                print(line, end="")
                response = json.loads(line)
                if response.get("requestId") == request["requestId"] and response.get("type") in {"result", "error"}:
                    final = response
            if process.poll() is not None and final is None:
                raise RuntimeError(f"Lives service exited before a final response: {process.returncode}")
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)

    if final is None:
        raise TimeoutError("Lives release smoke test timed out")
    if final.get("type") == "error":
        raise RuntimeError(f"Lives release returned an error: {json.dumps(final, ensure_ascii=False)}")
    payload = final.get("payload")
    if not isinstance(payload, dict):
        raise RuntimeError("Lives release returned no export payload")
    return payload


def validate_pair(payload: dict[str, object], output_dir: Path) -> None:
    photo = Path(str(payload.get("photoPath", ""))).resolve()
    video = Path(str(payload.get("videoPath", ""))).resolve()
    target_dir = output_dir.resolve()
    if photo.parent != target_dir or video.parent != target_dir:
        raise RuntimeError(f"Export escaped the isolated smoke output directory: {photo.parent} vs {target_dir}")
    if not photo.is_file() or photo.stat().st_size == 0:
        raise RuntimeError("Exported JPEG is missing or empty")
    if not video.is_file() or video.stat().st_size == 0:
        raise RuntimeError("Exported MOV is missing or empty")
    if not photo.read_bytes().startswith(b"\xff\xd8"):
        raise RuntimeError("Exported photo is not a JPEG")
    if b"ftyp" not in video.read_bytes()[:64]:
        raise RuntimeError("Exported video is not a QuickTime/ISO media file")
    print(f"Validated JPEG: {photo.name} ({photo.stat().st_size} bytes)")
    print(f"Validated MOV: {video.name} ({video.stat().st_size} bytes)")


def main() -> None:
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve()
    fixture_dir = workspace / "smoke" / "fixtures"
    service = Path(os.environ["LIVES_SERVICE"]).resolve()
    output_dir = Path(os.environ["RUNNER_TEMP"]).resolve() / "lives-smoke-output"

    expected = {fixture_dir / f"clip-{name}.mp4" for name in ("red", "green", "blue")}
    missing = sorted(path.name for path in expected if not path.is_file())
    if missing:
        raise FileNotFoundError(f"Missing synthetic fixtures: {', '.join(missing)}")
    if not service.is_file():
        raise FileNotFoundError(f"Published Lives service is missing: {service}")

    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    request = build_request(fixture_dir, output_dir)
    payload = run_service(service, request)
    validate_pair(payload, output_dir)
    print("Published Lives release rendered and validated a synthetic Live Photo pair.")


if __name__ == "__main__":
    main()
