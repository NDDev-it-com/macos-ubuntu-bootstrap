# Decision records

Accepted records live in this directory, numbered in the order they were taken.
A record that is still cited must still exist here; a citation that resolves to
nothing is a defect, not a shorthand.

## Retired records

Two records were removed with the subjects they described, in
`678327f feat(bootstrap)!: standardize vendor AI CLIs and Chrome` (contract
3.0.0). Their numbers are retired and must not be reused. They remain readable
in Git history at that commit's parent.

| Number | Subject | Why it was retired |
|---|---|---|
| 0004 | Profile composition and the CloakBrowser boundary | The managed browser layer was removed from the bootstrap. The part of it that still holds — desktop profiles carry no project runtime — is stated by ADR 0008, which no longer cites a missing record. |
| 0006 | Dart host and the delegated zcode harness | zcode is no longer installed or delegated here. The surviving decision, that the Dart SDK is admitted because one archive backs both source analysis and the `dart mcp-server` transport, is stated by ADR 0005. |
