#!/usr/bin/env bash
# This script discovers Azure environment details, including tenants, subscriptions, and billing information.
# It outputs the collected data into JSON, CSV, and a human-readable table format.
set -uo pipefail
MISSING="MISSING"

echo "== Azure Environment Discovery =="
# Attempt to log in to Azure if not already authenticated
az account show >/dev/null 2>&1 || az login -o none || true

# --- Configuration and Output File Setup ---
# Timestamp for unique file naming
TS=$(date +%Y%m%d_%H%M%S)
# Define output file names
OUT_JSON="azure_env_discovery_${TS}.json"
OUT_CSV="azure_env_discovery_${TS}.csv"

# --- Tenant Information Collection ---
# Tenant display name (best-effort)
TENANT_NAME=$(az account tenant list -o tsv --query '[0].displayName' 2>/dev/null || echo "$MISSING")
[ -z "$TENANT_NAME" ] && TENANT_NAME="$MISSING"

echo "Collecting billing accounts (EA/MCA/PAYG hint)..."
# --- Billing Account Information Collection ---
BILLING_JSON=$(az billing account list -o json 2>/dev/null || echo "[]")
BILLING_COUNT=$(echo "$BILLING_JSON" | jq 'length' 2>/dev/null || echo 0)
AGREEMENT_TYPE="$MISSING"
if [ "$BILLING_COUNT" -eq 1 ]; then
  AGREEMENT_TYPE=$(jq -r '.[0].agreementType // "'$MISSING'"' <<< "$BILLING_JSON" 2>/dev/null || echo "$MISSING")
elif [ "$BILLING_COUNT" -gt 1 ]; then
  AGREEMENT_TYPE="Multiple/Unknown"
fi

echo "Enumerating subscriptions..."
# --- Subscription Information Collection ---
SUBS_JSON=$(az account list --all -o json 2>/dev/null || echo "[]")

# --- Function to Classify Subscription Plan ---
classify_plan() {
  local quota="${1:-}"
  local offerType="${2:-}"
  
  # Handle empty quota and offerType explicitly
  if [[ -z "$quota" && -z "$offerType" ]]; then
    echo "$MISSING"
    return
  fi
  
  # Explicit patterns for sponsored/concierge subscriptions
  case "$quota" in
    *Sponsored*|*CONCIERGE*|*Concierge*) 
      echo "Sponsored/Concierge"; 
      return;;
  esac
  
  # Check for Pay-As-You-Go offer type
  if [[ "$offerType" =~ Pay-As-You-Go ]]; then 
    echo "PAYG"; 
    return; 
  fi
  
  # Classify based on Quota ID
  case "$quota" in
    *MS-AZR-0017P*|*MS-AZR-0023P*) echo "PAYG";;
    *MS-AZR-0145P*|*MS-AZR-0148P*) echo "EA Dev/Test";;
    *MS-AZR-0033P*|*MS-AZR-0034P*) echo "EA";;
    "") echo "$MISSING";;
    *) echo "Unclear/Other";;
  esac
}

RESULTS=()

# --- CSV Header ---
echo "TenantName,TenantId,SubscriptionId,SubscriptionName,State,OfferType,QuotaId,SpendingLimit,PlanGuess,BillingAgreementType,IsDefault,Owners" > "$OUT_CSV"

# --- Process Each Subscription ---
# Iterate over each subscription and extract relevant details
jq -c '.[]' <<< "$SUBS_JSON" 2>/dev/null | while read -r sub; do
  # Extract basic subscription details
  SUB_ID=$(jq -r '.id // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  SUB_NAME=$(jq -r '.name // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  TENANT_ID=$(jq -r '.tenantId // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  STATE=$(jq -r '.state // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  OFFER_TYPE=$(jq -r '.offerType // "'$MISSING'"' <<< "$sub" 2>/dev/null || echo "$MISSING")
  IS_DEFAULT=$(jq -r '.isDefault // false' <<< "$sub" 2>/dev/null || echo false)

  QUOTA_ID="$MISSING"; SPENDING_LIMIT="$MISSING"; OWNERS="(Missing)"
  # Fetch additional details if subscription ID is available
  if [[ "$SUB_ID" != "$MISSING" ]]; then
    # Get ARM subscription details for quota and spending limit
    ARM_JSON=$(az rest --method get \
      --url "https://management.azure.com/subscriptions/${SUB_ID}?api-version=2020-01-01" \
      -o json 2>/dev/null || echo '{}')
    QUOTA_ID=$(jq -r '.subscriptionPolicies.quotaId // "'$MISSING'"' <<< "$ARM_JSON" 2>/dev/null || echo "$MISSING")
    SPENDING_LIMIT=$(jq -r '.subscriptionPolicies.spendingLimit // "'$MISSING'"' <<< "$ARM_JSON" 2>/dev/null || echo "$MISSING")

    # Get subscription owners (role assignments)
    OWNERS_LIST=$(az role assignment list \
      --subscription "$SUB_ID" --role "Owner" --include-inherited \
      -o json 2>/dev/null || echo "[]")
    OWNERS=$(jq -r '.[] | "\(.principalName // "-")(\(.principalType // "-"))"' <<< "$OWNERS_LIST" 2>/dev/null | paste -sd';' - 2>/dev/null)
    [ -z "${OWNERS:-}" ] && OWNERS="(Missing)"
  fi

  PLAN_GUESS=$(classify_plan "$QUOTA_ID" "$OFFER_TYPE")

  # Write subscription details to CSV
  printf '"%s",%s,"%s","%s",%s,"%s","%s","%s","%s","%s",%s,"%s"\n' \
    "$TENANT_NAME" "$TENANT_ID" "$SUB_ID" "$SUB_NAME" "$STATE" "$OFFER_TYPE" "$QUOTA_ID" "$SPENDING_LIMIT" \
    "$PLAN_GUESS" "$AGREEMENT_TYPE" "$IS_DEFAULT" "$OWNERS" >> "$OUT_CSV"

  # Aggregate results into an array for JSON output
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

# --- Final JSON Output Compilation ---
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
  }' > "$OUT_JSON" 2>/dev/null || echo "{\"generatedAt\":\"$(date -Iseconds)\",\"overallAgreementType\":\"$AGREEMENT_TYPE\",\"billingAccounts\":[],\"subscriptions\":[]}" > "$OUT_JSON"

echo
echo "Done."
echo "CSV:     $OUT_CSV"
echo "JSON:    $OUT_JSON"
