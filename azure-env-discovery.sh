#!/usr/bin/env bash
# Azure Environment Discovery (quiet & robust)
# Collects high-level info: tenant, subscriptions, owners, offer/plan, billing agreement.
# Writes CSV + JSON. Avoids interactive prompts & stray output in CSV.

set -uo pipefail
MISSING="MISSING"

echo "== Azure Environment Discovery =="

# --- Helper: quiet az wrapper (adds --only-show-errors) ---
azq() { az --only-show-errors "$@"; }

# --- Login (non-fatal if already logged in) ---
azq account show >/dev/null 2>&1 || azq login -o none || true

# --- Ensure required extensions (quiet, non-interactive) ---
# 'account' is needed for `az account tenant list` on some installations.
azq extension show --name account >/dev/null 2>&1 || azq extension add --name account -y >/dev/null 2>&1 || true
# 'billing' may be required for `az billing account list` (safe to try).
azq extension show --name billing >/dev/null 2>&1 || azq extension add --name billing -y >/dev/null 2>&1 || true

# --- Timestamp & outputs ---
TS=$(date +%Y%m%d_%H%M%S)
OUT_JSON="azure_env_discovery_${TS}.json"
OUT_CSV="azure_env_discovery_${TS}.csv"

# --- Tenant name (best-effort, silenced) ---
TENANT_NAME=$(azq account tenant list -o tsv --query '[0].displayName' 2>/dev/null || echo "$MISSING")
[ -z "$TENANT_NAME" ] && TENANT_NAME="$MISSING"

echo "Collecting billing accounts (EA/MCA/PAYG hint)..."
# --- Billing accounts (silenced) ---
BILLING_JSON=$(azq billing account list -o json 2>/dev/null || echo "[]")
BILLING_COUNT=$(echo "$BILLING_JSON" | jq 'length' 2>/dev/null || echo 0)
AGREEMENT_TYPE="$MISSING"
if [ "$BILLING_COUNT" -eq 1 ]; then
  AGREEMENT_TYPE=$(jq -r '.[0].agreementType // "'$MISSING'"' <<< "$BILLING_JSON" 2>/dev/null || echo "$MISSING")
elif [ "$BILLING_COUNT" -gt 1 ]; then
  AGREEMENT_TYPE="Multiple/Unknown"
fi

echo "Enumerating subscriptions..."
SUBS_JSON=$(azq account list --all -o json 2>/dev/null || echo "[]")

# --- Plan classifier ---
classify_plan() {
  local quota="${1:-}"
  local offerType="${2:-}"

  if [[ -z "$quota" && -z "$offerType" ]]; then
    echo "$MISSING"; return
  fi

  case "$quota" in
    *Sponsored*|*CONCIERGE*|*Concierge*) echo "Sponsored/Concierge"; return;;
  esac

  if [[ "$offerType" =~ Pay-As-You-Go ]]; then echo "PAYG"; return; fi

  case "$quota" in
    *MS-AZR-0017P*|*MS-AZR-0023P*) echo "PAYG";;
    *MS-AZR-0145P*|*MS-AZR-0148P*) echo "EA Dev/Test";;
    *MS-AZR-0033P*|*MS-AZR-0034P*) echo "EA";;
    "") echo "$MISSING";;
    *) echo "Unclear/Other";;
  esac
}

RESULTS=()

# --- CSV header ---
echo "TenantName,TenantId,SubscriptionId,SubscriptionName,State,OfferType,QuotaId,SpendingLimit,PlanGuess,BillingAgreementType,IsDefault,Owners" > "$OUT_CSV"

# --- Iterate subscriptions (quiet) ---
jq -c '.[]' <<< "$SUBS_JSON" 2>/dev/null | while read -r sub; do
  SUB_ID=$(jq -r '.id // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  SUB_NAME=$(jq -r '.name // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  TENANT_ID=$(jq -r '.tenantId // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  STATE=$(jq -r '.state // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  OFFER_TYPE=$(jq -r '.offerType // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  IS_DEFAULT=$(jq -r '.isDefault // false' <<< "$sub" 2>/dev/null || echo false)

  QUOTA_ID="$MISSING"
  SPENDING_LIMIT="$MISSING"
  OWNERS="(Missing)"

  if [[ "$SUB_ID" != "$MISSING" ]]; then
    ARM_JSON=$(azq rest --method get \
      --url "https://management.azure.com/subscriptions/${SUB_ID}?api-version=2020-01-01" \
      -o json 2>/dev/null || echo '{}')

    QUOTA_ID=$(jq -r '.subscriptionPolicies.quotaId // "'$MISSING'"' <<< "$ARM_JSON" 2>/dev/null || echo "$MISSING")
    SPENDING_LIMIT=$(jq -r '.subscriptionPolicies.spendingLimit // "'$MISSING'"' <<< "$ARM_JSON" 2>/dev/null || echo "$MISSING")

    OWNERS_LIST=$(azq role assignment list \
      --subscription "$SUB_ID" --role "Owner" --include-inherited \
      -o json 2>/dev/null || echo "[]")

    # Note: keep owners on one CSV cell separated by semicolons
    OWNERS=$(jq -r '.[] | "\(.principalName // "-")(\(.principalType // "-"))"' <<< "$OWNERS_LIST" 2>/dev/null | paste -sd';' - 2>/dev/null)
    [ -z "${OWNERS:-}" ] && OWNERS="(Missing)"
  fi

  PLAN_GUESS=$(classify_plan "$QUOTA_ID" "$OFFER_TYPE")

  # --- CSV row (quote strings to keep commas/newlines safe) ---
  printf '"%s",%s,"%s","%s",%s,"%s","%s","%s","%s","%s",%s,"%s"\n' \
    "$TENANT_NAME" "$TENANT_ID" "$SUB_ID" "$SUB_NAME" "$STATE" "$OFFER_TYPE" "$QUOTA_ID" "$SPENDING_LIMIT" \
    "$PLAN_GUESS" "$AGREEMENT_TYPE" "$IS_DEFAULT" "$OWNERS" >> "$OUT_CSV"

  # --- JSON array item ---
  RESULTS+=("$(jq -n \
    --arg tenantName "$TENANT_NAME" \
    --arg tenantId "$TENANT_ID" \
    --arg subscriptionId "$SUB_ID" \
    --arg subscriptionName "$SUB_NAME" \
    --arg state "$STATE" \
    --arg offerType "$OFFER_TYPE" \
    --arg quotaId "$QUOTA_ID" \
    --arg spendingLimit "$SPENDING_LIMIT" \
    --arg planGuess "$PLAN_GUESS" \
    --arg billingAgreementType "$AGREEMENT_TYPE" \
    --argjson isDefault "$IS_DEFAULT" \
    --arg owners "$OWNERS" \
    '{
      tenantName: $tenantName,
      tenantId: $tenantId,
      subscriptionId: $subscriptionId,
      subscriptionName: $subscriptionName,
      state: $state,
      offerType: $offerType,
      quotaId: $quotaId,
      spendingLimit: $spendingLimit,
      planGuess: $planGuess,
      billingAgreementType: $billingAgreementType,
      isDefault: $isDefault,
      owners: ( ($owners // "'$MISSING'") | split(";") )
    }'
  )")
done

# --- Final JSON ---
SUBS_AGG=$(printf '%s\n' "${RESULTS[@]:-}" | jq -s '.' 2>/dev/null || echo '[]')

jq -n --arg generatedAt "$(date -Iseconds)" --arg host "$(hostname)" \
  --arg overallAgreementType "$AGREEMENT_TYPE" \
  --argjson billingAccounts "$BILLING_JSON" \
  --argjson subscriptions "$SUBS_AGG" \
  '{
    generatedAt: $generatedAt,
    host: $host,
    overallAgreementType: $overallAgreementType,
    billingAccounts: $billingAccounts,
    subscriptions: $subscriptions
  }' > "$OUT_JSON" 2>/dev/null || {
    echo "{\"generatedAt\":\"$(date -Iseconds)\",\"overallAgreementType\":\"$AGREEMENT_TYPE\",\"billingAccounts\":[],\"subscriptions\":[]}" > "$OUT_JSON"
  }

echo
echo "Done."
echo "CSV:  $OUT_CSV"
echo "JSON: $OUT_JSON"
