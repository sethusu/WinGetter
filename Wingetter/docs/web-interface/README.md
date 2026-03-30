# Wingetter Web Interface Blueprint

This blueprint turns the existing PowerShell packaging flow into a web-based, async job system while reusing the current packaging logic.

## Scope

The web interface should:

1. Accept package inputs (`appName`, optional `version`, optional icon).
2. Resolve package selection when Winget search returns multiple matches.
3. Run packaging as a background job on a Windows worker.
4. Expose status, logs, and generated artifacts.
5. Support either browser downloads or writing outputs to an allowed server path.

## Core Deliverables

- OpenAPI contract: `docs/web-interface/openapi.yaml`
- UI wireframe: `docs/web-interface/ui-wireframe.md`
- Build plan: `docs/web-interface/implementation-plan.md`

## Design Principles

- Keep PowerShell as the packaging engine for v1.
- Avoid interactive dialogs in worker mode; all choices come from API inputs.
- Model everything as an idempotent job state machine.
- Persist logs and artifact metadata per job.
- Return explicit machine-readable error codes.

## Mapping to Current Script Stages

The API `JobStep` values map directly to script stages:

- `searching_winget`: script step 1 (search/show + parse).
- `creating_workspace`: script step 2.
- `downloading_installer`: script step 3.
- `calculating_hash`: script step 4.
- `generating_scripts`: script steps 5 and 6.
- `generating_metadata_json`: script steps 8, 9, 10.
- `packaging_intunewin`: script step 11.
- `finalizing_artifacts`: summary + artifact indexing.

## v1 Runtime Layout

- API service:
  - validates requests
  - creates jobs
  - exposes status/events/artifacts
- Worker process:
  - consumes queued jobs
  - runs the packaging script in non-interactive mode
  - emits structured events
- Storage:
  - `jobs/<jobId>/`
  - `jobs/<jobId>/logs/`
  - `jobs/<jobId>/artifacts/`

## Security and Safety Controls

- Allowlist writable server output roots for `server_path` mode.
- Enforce max upload size and allowed icon mime types.
- Sanitize artifact names and reject path traversal.
- Keep tool prerequisites visible via `/api/v1/health`.
- Use per-job working directories to avoid collisions.
