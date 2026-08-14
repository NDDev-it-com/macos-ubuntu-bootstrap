# Branch rulesets

`branch-main.json` is a **checked-in projection** of the live ruleset protecting
`main`. It is documentation and a test fixture, not something any workflow
applies: GitHub is the authority, and changing the live ruleset requires
repository-administration rights that CI does not have and should not have.

Keeping the projection under review means a required-check change is proposed,
reviewed and recorded in a diff before anyone touches the live configuration.
`tests/test_support_evidence_matrix.py` binds it, so a check that must be
required cannot silently drop out of the projection.

## Pending live delta

The projection currently declares **eight** required checks; live ruleset
`20188391` declares seven. The difference is `evidence-gate`, added here when
that gate stopped being declaration-only and began opening every lane's
artifact.

Applying it needs administrator authorization and is a separate act:

```bash
gh api --method PUT /repos/NDDev-it-com/macos-ubuntu-bootstrap/rulesets/20188391 \
  --input .github/rulesets/branch-main.json
```

Before running it, confirm the projection still matches the live ruleset in
every other respect:

```bash
gh api /repos/NDDev-it-com/macos-ubuntu-bootstrap/rulesets/20188391 \
  --jq '[.rules[] | select(.type=="required_status_checks")
         | .parameters.required_status_checks[].context] | sort'
```

`evidence-gate` runs on `pull_request` and on pushes to `main`. It must be green
on a PR head before merge and on the merge commit before a release, so making it
required does not introduce a check that cannot report.
