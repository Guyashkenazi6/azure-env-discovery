#!/usr/bin/env bash
# Azure Environment Discovery -> Focused CSV for migration-to-EA decision
# Columns: Subscription ID, Sub. Type, Sub. Owner, Transferable (Internal)

set -uo pipefail
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt
export AZURE_CORE_NO_COLOR=1
MISSING="MISSING"

echo "== Azure Environment Discovery (CSV for EA transfer) =="

# Login if needed (quiet)
az account show --only-show-errors >/dev/null 2>&1 || az login --only-show-errors -o none || true

# Ensure useful extensions (quiet, non-fatal)
az extension show --name account           --only-show-errors >/dev/null 2>&1 || az extension add --name account           -y --only-show-errors >/dev/null 2>&1 || true
az extension show --name billing           --only-show-errors >/dev/null 2>&1 || az extension add --name billing           -y --only-show-errors >/dev/null 2>&1 || true

TS=$(date +%Y%m%d_%H%M%S)
OUT_CSV="azure_env_discovery_${TS}.csv"

# Header exactly as requested
echo "Subscription ID,Sub. Type,Sub. Owner,Transferable (Internal)" > "$OUT_CSV"

# Overall billing agreement (helps infer MCA)
BILLING_JSON=$(az billing account list --only-show-errors -o json 2>/dev/null || echo "[]")
OVERALL_AGREEMENT=$(jq -r '.[0].agreementType // empty' <<< "$BILLING_JSON" 2>/dev/null || echo "")

# Get subscriptions
SUBS=$(az account list --all --only-show-errors -o json 2>/dev/null || echo "[]")

# --- Helpers ---

# Map QuotaId/OfferType to a plan label we can use in logic below.
classify_plan() {
  local quota="${1:-}"
  local offerType="${2:-}"
  local fallback="${3:-}"   # e.g. MCA-online if overall billing is MCA

  # Explicit patterns first
  case "$quota" in
    *Sponsored*|*CONCIERGE*|*Concierge*) echo "Sponsored/Concierge"; return;;
    *MS-AZR-0017P*|*MS-AZR-0023P*)       echo "PAYG"; return;;           # MOSP
    *MS-AZR-0145P*|*MS-AZR-0148P*)       echo "EA"; return;;             # EA Dev/Test -> treat as EA
    *MS-AZR-0033P*|*MS-AZR-0034P*)       echo "EA"; return;;
  esac

  # OfferType string sometimes includes "Pay-As-You-Go"
  if [[ "$offerType" =~ Pay-As-You-Go ]]; then echo "PAYG"; return; fi

  # If overall billing is MicrosoftCustomerAgreement and we couldn't classify → MCA-online (best-effort)
  if [[ -n "$fallback" ]]; then
    echo "$fallback"; return
  fi

  # Unknown
  echo "Other"
}

# Decide if transferable to EA (Yes/No) based on plan label
is_transferable_to_EA() {
  local plan="${1:-$MISSING}"
  case "$plan" in
    EA|PAYG) echo "Yes";;  # EA↔EA supported (ticket), MOSP→EA supported (ticket)
    MCA-online|MCA-E|CSP|Previous\ CSP|Sponsored/Concierge|Other|$MISSING) echo "No";;
    *) echo "No";;
  esac
}

# Fallback MCA label if overall billing shows MCA
MCA_FALLBACK=""
if [[ "$OVERALL_AGREEMENT" =~ MicrosoftCustomerAgreement ]]; then
  # Treat unknowns as MCA-online by default (not enterprise rep flow)
  MCA_FALLBACK="MCA-online"
fi

# --- Process each subscription ---
jq -c '.[]' <<< "$SUBS" 2>/dev/null | while read -r sub; do
  SUB_ID=$(jq -r '.id // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  OFFER_TYPE=$(jq -r '.offerType // ""'          <<< "$sub" 2>/dev/null || echo "")

  # ARM call to get QuotaId (quiet)
  ARM=$(az rest --method get \
        --url "https://management.azure.com/subscriptions/${SUB_ID}?api-version=2020-01-01" \
        --only-show-errors -o json 2>/dev/null || echo '{}')

  QUOTA_ID=$(jq -r '.subscriptionPolicies.quotaId // ""' <<< "$ARM" 2>/dev/null || echo "")

  # Plan (Sub. Type)
  PLAN=$(classify_plan "$QUOTA_ID" "$OFFER_TYPE" "$MCA_FALLBACK")

  # Try to detect CSP (best-effort): if authorizationSource == "ByPartner" mark as CSP
  AUTH_SRC=$(jq -r '.authorizationSource // empty' <<< "$ARM" 2>/dev/null || echo "")
  if [[ "$AUTH_SRC" == "ByPartner" ]]; then
    PLAN="CSP"
  fi

  # Owners list (names only, semicolon-separated)
  OWNERS_JSON=$(az role assignment list \
    --subscription "$SUB_ID" --role "Owner" --include-inherited \
    --only-show-errors -o json 2>/dev/null || echo "[]")
  OWNERS=$(jq -r '.[] | (.principalName // "-")' <<< "$OWNERS_JSON" 2>/dev/null | paste -sd';' - 2>/dev/null)
  [ -z "${OWNERS:-}" ] && OWNERS="$MISSING"

  # Transferability to EA
  TRANSFER=$(is_transferable_to_EA "$PLAN")

  # Row
  printf '"%s","%s","%s","%s"\n' "$SUB_ID" "$PLAN" "$OWNERS" "$TRANSFER" >> "$OUT_CSV"
done

echo
echo "Done."
echo "CSV: $OUT_CSV"
