# Wingetter Web UI Wireframe (v1)

This wireframe defines the minimum UI to replace the current script prompts and provide artifact delivery.

## 1) Create Package Page

Route: `/packages/new`

### Layout

- Left: form card
- Right: prerequisites/status card

### Form Fields

- `App name or Winget ID` (required)
- `Version` (optional)
- `Icon upload` (optional)
- `Output mode`
  - `Download files`
  - `Save to server path` (reveals `Server path` input)
- `Selection mode`
  - `Require user selection`
  - `Use exact match first`
- Submit button: `Start packaging`

### Validation

- Disable submit while request in flight.
- If `outputMode=server_path`, require `serverPath`.
- Show inline errors from API `error.code` and `error.message`.

## 2) Package Selection Modal

Displayed when job enters `awaiting_selection`.

### Content

- Table columns:
  - Name
  - Package ID
  - Version
- Primary action per row: `Select`

### Behavior

- Selecting row calls `POST /api/v1/jobs/{jobId}/selection`.
- Modal blocks further progress until selection submitted.

## 3) Job Detail Page

Route: `/jobs/{jobId}`

### Header

- Job ID
- Status pill
- Current step
- Elapsed time

### Main Content

- Progress bar (0–100)
- Step timeline:
  - searching_winget
  - resolving_metadata
  - creating_workspace
  - downloading_installer
  - calculating_hash
  - generating_scripts
  - generating_metadata_json
  - packaging_intunewin
  - finalizing_artifacts
- Live log panel (from SSE stream)

### Right Rail

- Package summary
  - selected package ID/name
  - requested version
  - resolved version
- Output summary
  - mode
  - output path (if server mode)

## 4) Artifacts Section

Visible when artifacts exist.

- Table columns:
  - Name
  - Kind
  - Size
  - SHA256
  - Download action
- Top actions:
  - `Download .intunewin`
  - `Download all artifacts` (zip)

## 5) Empty/Error States

- No jobs yet: prompt to create first job.
- Failed job:
  - show failed step
  - show error code and message
  - include retry CTA prefilled with prior inputs

## 6) Minimal Components (Frontend)

- `CreateJobForm`
- `DependencyHealthCard`
- `SelectionModal`
- `JobHeader`
- `JobTimeline`
- `JobLogsPanel`
- `ArtifactsTable`
- `ErrorCallout`
