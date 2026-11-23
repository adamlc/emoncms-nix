# Notes for Claude

## Keep the changelog current

Every change that a user of this flake could notice (packages, pinned versions, module options, generated config, services, tests, docs that change how to use it) gets a line under `## [Unreleased]` in `CHANGELOG.md`, in the same commit or PR as the change. Use the Keep a Changelog headings: Added, Changed, Deprecated, Removed, Fixed, Security. Write each line for someone running the flake: what changed for them, not how the code changed. Call out anything that needs them to change their configuration or take a database dump first.

If a change moves the pinned Emoncms version (`pkgs/sources.nix`), say so under Changed, with the old and new version.

Pure CI or internal refactors with no visible effect need no entry.

## Versioning

The flake has its own semver, independent of Emoncms's version (`v1.0.0` pins Emoncms 12.2.1). From 1.0.0:

- Major bump (`1.0.0` → `2.0.0`): any change that needs users to edit their configuration (option renamed or removed, default changed in a way that changes behaviour), or a new Emoncms major version.
- Minor bump (`1.0.0` → `1.1.0`): new options with safe defaults, or a new Emoncms minor version.
- Patch bump (`1.0.0` → `1.0.1`): fixes and Emoncms patch updates.

## Cutting a release

1. On a branch, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a fresh empty `## [Unreleased]` above it, and put the pinned versions on the first line of the entry: `Pins **Emoncms <version>**, PHP <version>, <nixos channel>.`
2. Update the compare links at the bottom of `CHANGELOG.md`.
3. Merge that PR once CI is green.
4. Tag the merge commit on `main` as `vX.Y.Z` (annotated tag) and push the tag.
5. Create a GitHub release for the tag, titled `vX.Y.Z (Emoncms <version>)`, with the changelog entry as its body.

Users pin `github:adamlc/emoncms-nix/vX.Y.Z`, so never move or delete a tag once pushed; fix mistakes with a new patch release.
