# Wingetter Web Interface Implementation Plan (v1)

This plan prioritizes lowest-risk delivery by keeping the existing PowerShell script as the packaging engine.

## Phase 1: API + Worker Foundation

1. Implement API endpoints from `openapi.yaml`.
2. Add persistent job store (sqlite or equivalent) with:
   - `jobs`
   - `job_events`
   - `job_artifacts`
3. Add a worker loop that transitions jobs from `queued` to terminal states.
4. Add `/api/v1/health` dependency checks for:
   - `winget`
   - `intunewinapputil`
   - PowerShell

## Phase 2: Script Integration

1. Add worker adapter for `Create-IntuneWinFromWinget.ps1`:
   - launch with non-interactive arguments
   - capture stdout/stderr
   - map script milestones to `JobStep`
2. Handle multi-match package selection:
   - run search-only pre-step
   - if multiple candidates, pause at `awaiting_selection`
   - resume with selected package ID
3. Persist all emitted logs as ordered job events.

## Phase 3: Artifact Pipeline

1. Index expected outputs:
   - installer
   - `.intunewin`
   - `detection.ps1`
   - `uninstall.ps1`
   - `app.json`
   - `win32LobApp.json`
   - `readme.txt`
   - icon
2. Compute SHA256 and size for each artifact.
3. Build optional zip bundle (`bundle_zip`) for "download all".
4. Expose file streaming endpoint with safe filename validation.

## Phase 4: Frontend v1

1. Create package form (`/packages/new`).
2. Job details page (`/jobs/{jobId}`) with:
   - timeline
   - live logs (SSE)
   - artifact downloads
3. Selection modal for `awaiting_selection`.
4. Failed-state retry using previous inputs.

## Phase 5: Hardening

1. Restrict `server_path` writes to an allowlist of roots.
2. Enforce icon upload limits and file type checks.
3. Add idempotency key support on `POST /api/v1/jobs`.
4. Add retention policy and cleanup for old jobs/artifacts.

## Data Model (Minimal)

- `jobs`:
  - `job_id` (pk)
  - `status`
  - `current_step`
  - `app_name`
  - `version_requested`
  - `version_resolved`
  - `output_mode`
  - `output_path`
  - `error_code`
  - `error_message`
  - timestamps
- `job_events`:
  - `id` (pk)
  - `job_id` (fk)
  - `event_type`
  - `payload_json`
  - `created_at`
- `job_artifacts`:
  - `id` (pk)
  - `job_id` (fk)
  - `name`
  - `kind`
  - `size_bytes`
  - `sha256`
  - `absolute_path`
  - `created_at`

## Acceptance Criteria

- User can submit a package request from UI and receive a job ID.
- User can complete package selection when multiple Winget matches exist.
- User can watch live status/log updates until terminal state.
- On success, user can download `.intunewin` and supporting artifacts.
- On failure, user sees explicit machine-readable error code and message.
