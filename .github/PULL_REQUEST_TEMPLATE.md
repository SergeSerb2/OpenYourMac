## Problem and result

Describe the problem and the resulting behavior.

## Validation

List commands and results. Include real-flow checks and an invalid or empty case
where practical. State what you could not run. Use a separate macOS account or VM
for real windows. Use scratch HOME and a unique Mach service for IPC-only checks.
Run `make ci` locally before opening the PR and include its result here.
GitHub does not run build checks for this repository.

## Review checklist

- [ ] The change has a focused scope and the docs match its behavior.
- [ ] Existing tests remain in place. No new unit tests were added.
- [ ] `make ci` passes locally, including warning-free Swift builds.
- [ ] UI images and logs contain no private data.
- [ ] Verification limits and known failures are stated.
