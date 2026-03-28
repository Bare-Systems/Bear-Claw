# BearClaw Blink Contract

This file documents the real behavior of [`blink.toml`](/Users/joecaruso/Projects/BareSystems/BearClaw/blink.toml).

## Target

- `homelab`
- type: SSH
- host: `blink`
- user: `admin`
- runtime dir: `/home/admin/barelabs/runtime/blink-homelab`

## Build Sources

`bearclaw` supports two build sources:

- `local_docker` (default): build the Zig binary locally in Docker and upload the produced binary
- `github`: fetch the published GitHub release asset

The default local build uses `Dockerfile.build` and emits `edge/zig-out/bin/bareclaw`.

## Deploy Behavior

Pipeline:

- `fetch_artifact`
- `remote_script`
- `stop`
- `backup`
- `install`
- `start`
- `health_check`
- `verify`

Rollback pipeline:

- `rollback`
- `start`
- `health_check`

The deploy flow provisions the remote host, stops the current user service, installs the new binary into the shared runtime, restarts the user service, then runs health and verification checks.

## Verification

- health check: `http://127.0.0.1:8080/health`
- verification suite: `blink/suites/bearclaw_homelab.rb`
- tags: `smoke`, `health`

## Operator Notes

- BearClaw runs natively on the homelab host.
- The manifest assumes a shared runtime with Tardigrade under `runtime/blink-homelab`.
- Update this file whenever the build source, runtime path, service manager behavior, or verification suite changes.
