#!/usr/bin/env bash
set -euo pipefail

# Legacy emergency repair retired.
# Gemini now uses /api/chat/direct -> Central Jobs API.
# Keeping this file as an idempotent no-op prevents old deploy ranges
# from restarting Gemini or launching obsolete OpenClaw write tests.
echo GEMINI_URGENT_REPAIR_RETIRED
