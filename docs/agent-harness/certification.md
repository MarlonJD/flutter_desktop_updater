# Harness-Ready Certification

`harness-ready` is an expiring repository-harness claim for one source commit
`S`, its clean direct-child attestation commit `A`, the declared local
evaluation target, and a maximum seven-day evidence window. It is not a release,
deployment, security-review, or production-readiness claim.

## Current State

- Owner: Repository maintainers.
- Profile: adaptive custom shape with the complete canonical inventory.
- Structural command: `dart run tool/harness_gate.dart --structural`.
- Prospective project-native gate: `dart run tool/harness_gate.dart --candidate
  --attestation-key-file "$HARNESS_ATTESTATION_KEY_FILE"`.
- Final project-native full gate: `dart run tool/harness_gate.dart
  --attestation-key-file "$HARNESS_ATTESTATION_KEY_FILE"`.
- Maintenance mode: manual, on explicit harness work and before any
  `harness-ready` handoff.
- Evidence issuer: the local repository harness process; this is not externally
  authenticated.
- Key custody: the invoker supplies an owner-only regular 32–4096 byte key file
  outside the repository. The key and its value are never committed.
- Optional production verifier: unavailable and not requested.

The current adoption is `candidate-only` until all coverage rows are resolved,
the source/attestation commits exist, the full native gate passes from clean
attestation `HEAD`, and the external verifier returns `CERT000`.

## Source and Attestation Boundary

Commit implementation, commands, docs, and tests as source commit `S`. Create
one direct-child attestation commit `A` that changes only:

- `certification.json`;
- `coverage-matrix.md`;
- exactly one referenced evidence JSON for every coverage row;
- `project-native-gate.json`;
- `continuous-maintenance.json`;
- production approval/rollback records only when the production-authority row
  is verified with actual authority.

Every record and the manifest name `S`, the concrete repository identity
`scm://github.com/MarlonJD/flutter_desktop_updater`, and the stable evaluation
target
`harness://github.com/MarlonJD/flutter_desktop_updater/repository-harness`.
Certification receives trusted current `A`; `A` must be clean `HEAD`, have only
`S` as its parent, and contain no implementation change.

Prepare the overlay with `tool/harness_evidence.dart --prepare`, run the
prospective gate while `HEAD` is still `S`, and record that successful
observation with `tool/harness_evidence.dart --record-project-gate`. The
prospective mode validates every row record, maintenance record, release
authority record, manifest input, key, and exact pending overlay path while
allowing the project-gate record to be written only after the observation.
Commit the finalized overlay as `A`, then run the final full gate.

## Evidence Contract

Each JSON record uses schema version 2 and exactly these fields:
`schema_version`, `repository_commit`, `repository_identity`,
`deployment_target_id`, `capabilities`, `environment`, `command`, `exit_code`,
`observed_at`, `result`, `artifacts`, `issuer`, `key_id`, and `signature`.

The signature is HMAC-SHA256 over
`harness-engineering-evidence-v2\0` followed by canonical JSON of every field
except `signature`. The full native gate verifies schema, source and identities,
freshness, result/exit consistency, key ID, signature, coverage digest,
attestation paths, parent relation, and clean worktree. A caller-supplied HMAC
key proves local consistency only; it does not authenticate a provider, human
approval, production target, or artifact.

## Revalidation and Recovery

Any later commit, dirty attestation tree, expired timestamp, changed authority,
coverage digest, applicability decision, command, identity, or failed record
invalidates the claim. Recovery is:

1. select a trusted clean source snapshot;
2. rerun affected real commands;
3. refresh coverage and HMAC-v2 records;
4. create a new direct-child attestation commit;
5. run the full native gate;
6. run
   `python3 /Users/marlonjd/.codex/skills/harness-engineering/scripts/harness.py
   certify --root /Users/marlonjd/Developer/library/flutter_desktop_updater
   --profile adaptive --commit <trusted-attestation-commit>
   --attestation-key-file <absolute-owner-only-key>`;
7. require `CERT000`.

Safe repository-local repairs require a current explicit request. Secrets,
destructive actions, branch changes, external writes, merge, release,
deployment, privileged target-host work, production access, rollback approval,
and product judgment remain escalation boundaries.

## Production Attestation

The optional stricter profile was not requested. No provider-specific
asymmetric verifier with an independently provisioned trust root exists in this
repository. If it is explicitly requested before such a verifier and authority
exist, report `CERT015`; never relabel ordinary `CERT000` as
`production-ready`.
