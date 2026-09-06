# FinTech Platform on GCP — Multi-Environment

Node.js auth-service on GCP with the full enterprise promotion model:
**dev -> staging -> prod**, isolated projects, keyless CI, Trivy gate,
build-once-promote-many, and human approval gates before staging and prod.

```
                         merge to main
                              |
        ┌─────────────────────┼───────────────────────────┐
        v (infra pipeline)                                v (app pipeline)
  apply DEV (auto)                          build once -> Trivy -> push :SHA
        |                                                 |
  plan STAGING -> [APPROVAL] -> apply STAGING       deploy DEV (auto) -> /health
        |                                                 |
  plan PROD    -> [APPROVAL] -> apply PROD          [APPROVAL] -> deploy STAGING -> /health
                                                          |
                                                    [APPROVAL] -> deploy PROD -> /health
```

## The three environments

| | dev | staging | prod |
|---|---|---|---|
| GCP project | fintech-gcp-dev-* | fintech-gcp-stg-* | fintech-gcp-prd-* |
| DB | db-f1-micro, ZONAL, no backups | db-g1-small, ZONAL, backups | custom, **REGIONAL HA**, backups+PITR, deletion-protected |
| Redis | BASIC 1GB | BASIC 1GB | **STANDARD_HA** |
| Cloud Run | scale to 0 | scale to 0 | **min 1** (no cold starts) |
| Deploys | automatic | **approval required** | **approval required** |

One code path — these differences live ONLY in `environments/*.tfvars`.

## Design decisions (say these in interviews)
1. **Project-per-environment** = blast-radius isolation. A staging mistake
   physically cannot touch prod: different project, different state,
   different service account, different WIF trust.
2. **Plan-before-gate.** Each promotion is plan (ungated, output published)
   then apply (gated, executes the SAVED plan). The approver reads the
   contract BEFORE approving — never approve blind.
3. **Build once, promote many.** One docker build, one Trivy verdict; the
   identical SHA flows dev -> staging -> prod. Prod runs the exact bytes
   dev verified.
4. **Approvals are GitHub Environments** (Required Reviewers) — auditable
   in the repo, not in a chat thread.

## Rollout

| Phase | What | How |
|---|---|---|
| 0 | Bootstrap 3 environments | `bash bootstrap/bootstrap.sh` -> set 9 repo Variables -> create 3 GitHub Environments (staging+production with Required Reviewers) -> commit the auto-filled backend/tfvars |
| 1 | Foundation x3 | First push: dev applies auto; approve staging; approve prod |
| Interlude | First certified image | Copy `app/` from fintech-aws, push - image lands in every existing registry |
| 2 | Data layer | Branch -> uncomment Phase 2 in main.tf + outputs -> fmt -> PR (3 plan comments!) -> merge -> dev auto -> approve stg -> approve prod |
| 3 | Cloud Run | Same ritual |
| 4 | Monitoring | Same ritual |

## Rules of the road
- Plans are contracts; **read the staging/prod plan in the job summary before approving**.
- Zero destroys is the number to check first.
- Console is a window, not a workbench.
- Never :latest — every environment runs a git SHA.
- Deployed != working: believe the /health verification, then verify security behaviors.

## Cost (rough, per day, all phases up)
dev ~ $2.5 · staging ~ $3 · prod ~ $6-8 (HA db + HA redis + min-instance)
Park anything by PR-commenting its modules out; prod DB requires flipping
deletion_protection first (that is the point of it).
