# Provenance

Vendored copy of the DRAFT implementation used exclusively as the differential-
testing reference (never a code source for the clean-room implementation).

- Source: https://github.com/blockful/governor-nexus (private)
- Commit: 87d659bde77b3189908ffd0bfba6c270f03c5486 (v0.1 reference, main @ 2026-07)
- Contents: src/ only, byte-for-byte

Do not edit. To update the reference (a spec-level decision), re-vendor from a
new pinned commit and record it here and in docs/spec/v1.md.

Why vendored instead of a submodule: the source repo is private, so a submodule
would force every CI run and every clone to carry an org PAT. A pinned copy keeps
this repo self-contained; the commit above is the provenance.
