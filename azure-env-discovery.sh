#!/usr/bin/env bash
# Azure Environment Discovery (auto-extensions, quiet, resilient)

# --- Fail safely: don't exit on individual command errors; keep unset vars & pipefail strict ---
set -uo pipefail

# --- Force Azure CLI to auto-install required extensions WITHOUT prompting ---
# see: https://learn.microsoft.com/cli/azure/azure-cli-extensions-overview#dynamic-install
export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt
export AZURE_CORE_NO_COLOR=1

MISSING="MISSING"
echo "== Azure Environment Discovery =="

# --- Timestamp & outputs ---
TS=$(date +%Y%m%d_%H%M%S)
OUT_JSON="azure_env_discovery_${TS}.json"
OUT_CSV="azure_env_discovery_${TS}.csv"

# --- Login (non-fatal if already logged in) ---
az account show --only-show-errors >/dev/null 2>&1 || az login --only-show-errors -o none || true

# --- Make sure key extensions exist (quiet, non-interactive). Safe even if already installed. ---
az extension show --name account  --only-show-errors >/dev/null 2>&1 || az extension add --name account  -y --only-show-errors >/dev/null 2>&1 || true
az extension show --name billing  --only-show-errors >/dev/null 2>&1 || az extension add --name billing  -y --only-show-errors >/dev/null 2>&1 || true
az extension show --name resource-graph --only-show-errors >/dev/null 2>&1 || true  # optional; ignore if missing

# --- Tenant name (best-effort; keep stdout clean) ---
TENANT_NAME=$(az account tenant list --only-show-errors -o tsv --query '[0].displayName' 2>/dev/null || echo "$MISSING")
[ -z "$TENANT_NAME" ] && TENANT_NAME="$MISSING"

echo "Collecting billing accounts (EA/MCA/PAYG hint)..."
BILLING_JSON=$(az billing account list --only-show-errors -o json 2>/dev/null || echo "[]")
BILLING_COUNT=$(echo "$BILLING_JSON" | jq 'length' 2>/dev/null || echo 0)
AGREEMENT_TYPE="$MISSING"
if [ "$BILLING_COUNT" -eq 1 ]; then
  AGREEMENT_TYPE=$(jq -r '.[0].agreementType // "'$MISSING'"' <<< "$BILLING_JSON" 2>/dev/null || echo "$MISSING")
elif [ "$BILLING_COUNT" -gt 1 ]; then
  AGREEMENT_TYPE="Multiple/Unknown"
fi

echo "Enumerating subscriptions..."
SUBS_JSON=$(az account list --all --only-show-errors -o json 2>/dev/null || echo "[]")

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

# --- Iterate subscriptions ---
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
    ARM_JSON=$(az rest --method get \
      --url "https://management.azure.com/subscriptions/${SUB_ID}?api-version=2020-01-01" \
      --only-show-errors -o json 2>/dev/null || echo '{}')

    QUOTA_ID=$(jq -r '.subscriptionPolicies.quotaId // "'$MISSING'"' <<< "$ARM_JSON" 2>/dev/null || echo "$MISSING")
    SPENDING_LIMIT=$(jq -r '.subscriptionPolicies.spendingLimit // "'$MISSING'"' <<< "$ARM_JSON" 2>/dev/null || echo "$MISSING")

    OWNERS_LIST=$(az role assignment list \
      --subscription "$SUB_ID" --role "Owner" --include-inherited \
      --only-show-errors -o json 2>/dev/null || echo "[]")

    OWNERS=$(jq -r '.[] | "\(.principalName // "-")(\(.principalType // "-"))"' <<< "$OWNERS_LIST" 2>/dev/null | paste -sd';' - 2>/dev/null)
    [ -z "${OWNERS:-}" ] && OWNERS="(Missing)"
  fi

  PLAN_GUESS=$(classify_plan "$QUOTA_ID" "$OFFER_TYPE")

  # --- CSV row ---
  printf '"%s",%s,"%s","%s",%s,"%s","%s","%s","%s","%s",%s,"%s"\n' \
    "$TENANT_NAME" "$TENANT_ID" "$SUB_ID" "$SUB_NAME" "$STATE" "$OFFER_TYPE" "$QUOTA_ID" "$SPENDING_LIMIT" \
    "$PLAN_GUESS" "$AGREEMENT_TYPE" "$IS_DEFAULT" "$OWNERS" >> "$OUT_CSV"

  # --- JSON item ---
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
