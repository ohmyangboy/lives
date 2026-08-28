# Release smoke fixtures

This directory contains only synthetic media used to test the already-published Lives DMG on a stable Apple Silicon GitHub runner. It does not contain product source code or user media.

- `clip-red.mp4`, `clip-green.mp4`, and `clip-blue.mp4` are four-second solid-color H.264/AAC clips generated with FFmpeg.
- `run_release_smoke.py` starts the `live-photo-service` executable from the mounted Release DMG, submits a three-cell export request, waits for the service result, and verifies that the exported JPEG and MOV are non-empty media files.
- The Lives service itself performs `PHLivePhoto` pair validation before returning a successful export result.

The workflow is manual (`workflow_dispatch`) so a frozen Release is tested intentionally after publication. It downloads the GitHub Release asset again and verifies its expected SHA-256 before execution.
