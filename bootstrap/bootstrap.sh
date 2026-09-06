#!/usr/bin/env bash
# Phase 0 - creates THREE isolated environments (dev/staging/prod):
# per env: project + billing, versioned state bucket, CI SA, repo-locked WIF.
# Idempotent - safe to re-run. Compatible with macOS bash 3.2.
set -euo pipefail

BILLING_ACCOUNT="${BILLING_ACCOUNT:-011816-4C2450-0A84DD}"
REGION="${REGION:-us-central1}"
GITHUB_REPO="${GITHUB_REPO:-naren9876/fintech-gcp}"
SUFFIX="${SUFFIX:-$RANDOM}"

SUMMARY=""

for ENV in dev staging prod; do
  case "$ENV" in
    dev)     PROJECT_ID="fintech-gcp-dev-${SUFFIX}";  K="DEV" ;;
    staging) PROJECT_ID="fintech-gcp-stg-${SUFFIX}";  K="STG" ;;
    prod)    PROJECT_ID="fintech-gcp-prd-${SUFFIX}";  K="PRD" ;;
  esac
  SA_EMAIL="github-actions@${PROJECT_ID}.iam.gserviceaccount.com"
  BUCKET="${PROJECT_ID}-tfstate"

  echo ""
  echo "############ ${ENV} -> ${PROJECT_ID} ############"

  echo "==> project + billing"
  gcloud projects create "${PROJECT_ID}" --name="FinTech ${ENV}" 2>/dev/null || echo "    (exists)"
  gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT}"

  echo "==> bootstrap APIs"
  gcloud services enable cloudresourcemanager.googleapis.com iam.googleapis.com \
    iamcredentials.googleapis.com sts.googleapis.com serviceusage.googleapis.com \
    storage.googleapis.com --project "${PROJECT_ID}"

  echo "==> state bucket gs://${BUCKET} (versioned)"
  gcloud storage buckets create "gs://${BUCKET}" --project "${PROJECT_ID}" \
    --location="${REGION}" --uniform-bucket-level-access 2>/dev/null || echo "    (exists)"
  gcloud storage buckets update "gs://${BUCKET}" --versioning

  echo "==> CI service account + roles"
  gcloud iam service-accounts create github-actions --project "${PROJECT_ID}" \
    --display-name="GitHub Actions CI/CD" 2>/dev/null || echo "    (exists)"
  for ROLE in roles/editor roles/resourcemanager.projectIamAdmin roles/secretmanager.secretAccessor; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${SA_EMAIL}" --role="${ROLE}" --quiet >/dev/null
  done

  echo "==> Workload Identity Federation (keyless, repo-locked)"
  for ATTEMPT in 1 2 3 4; do
    if gcloud iam workload-identity-pools describe github-pool --project "${PROJECT_ID}" --location=global >/dev/null 2>&1; then
      echo "    pool ready"; break
    fi
    gcloud iam workload-identity-pools create github-pool --project "${PROJECT_ID}" \
      --location=global --display-name="GitHub pool" && break
    echo "    pool create failed (attempt ${ATTEMPT}) - waiting 20s for API propagation"
    sleep 20
  done
  gcloud iam workload-identity-pools providers describe github-provider \
    --project "${PROJECT_ID}" --location=global --workload-identity-pool=github-pool >/dev/null 2>&1 \
  || gcloud iam workload-identity-pools providers create-oidc github-provider \
    --project "${PROJECT_ID}" --location=global --workload-identity-pool=github-pool \
    --display-name="GitHub provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'"

  PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
  gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" --project "${PROJECT_ID}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${GITHUB_REPO}" \
    --quiet >/dev/null

  SUMMARY="${SUMMARY}GCP_PROJECT_ID_${K}   = ${PROJECT_ID}
GCP_CI_SA_${K}        = ${SA_EMAIL}
GCP_WIF_PROVIDER_${K} = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/providers/github-provider
"

  sed -i.bak "s|REPLACE_ME_${ENV}-tfstate|${BUCKET}|" "terraform/environments/${ENV}.gcsbackend" && rm -f "terraform/environments/${ENV}.gcsbackend.bak"
  sed -i.bak "s|REPLACE_ME_${ENV}|${PROJECT_ID}|" "terraform/environments/${ENV}.tfvars" && rm -f "terraform/environments/${ENV}.tfvars.bak"
done

echo ""
echo "=================================================================="
echo "DONE. Three manual finishers:"
echo ""
echo "A) GitHub repo -> Settings -> Actions -> Variables (repo-level; NINE):"
echo "${SUMMARY}"
echo "B) GitHub repo -> Settings -> Environments:"
echo "   - 'dev' (no protection)"
echo "   - 'staging'    -> Required reviewers: you"
echo "   - 'production' -> Required reviewers: you"
echo ""
echo "C) backend + tfvars auto-filled - review with: git diff"
echo ""
echo "Then: git push. Dev deploys itself; staging and prod wait for your click."
