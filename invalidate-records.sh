#!/usr/bin/env bash
set -euo pipefail

TABLE_NAME="file-registry"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
echo "REGION=$REGION"
WRITE_MODE=false
CSV_FILE=""

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 [--write] <csv-file>"
  echo ""
  echo "  <csv-file>   CSV whose first column contains the 'id' values to invalidate."
  echo "  --write      Actually perform the DynamoDB update. Default is dry-run."
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write) WRITE_MODE=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *)
      if [[ -z "$CSV_FILE" ]]; then
        CSV_FILE="$1"
      else
        echo "Unexpected argument: $1"; usage
      fi
      shift
      ;;
  esac
done

[[ -z "$CSV_FILE" ]] && { echo "Error: no CSV file specified."; usage; }
[[ -f "$CSV_FILE" ]] || { echo "Error: file not found: $CSV_FILE"; exit 1; }

if [[ "$WRITE_MODE" == true ]]; then
  echo "[MODE] WRITE — updates will be applied to table '$TABLE_NAME'"
else
  echo "[MODE] DRY-RUN — no changes will be made (pass --write to apply)"
fi
echo ""

# ---------------------------------------------------------------------------
# Process each row
# ---------------------------------------------------------------------------
ROW=0
SKIPPED=0
UPDATED=0
NOT_FOUND=0
ALREADY_INVALID=0

while IFS=',' read -r id _rest; do
  # Strip surrounding whitespace and quotes
  id="${id//\"/}"
  id="${id//\'/}"
  id="${id#"${id%%[![:space:]]*}"}"
  id="${id%"${id##*[![:space:]]}"}"

  # Skip header row or blank lines
  (( ROW++ )) || true
  if [[ $ROW -eq 1 && "${id,,}" == "id" ]]; then
    continue
  fi
  [[ -z "$id" ]] && continue

  # --- GET record ---
  ITEM=$(aws dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --region "$REGION" \
    --key "{\"id\": {\"S\": \"${id}\"}}" \
    --output json 2>&1) || {
    echo "  [ERROR]      id='${id}' — AWS CLI failed: ${ITEM}"
    continue
  }

  RESOURCE_ID=$(echo "$ITEM" | jq -r '.Item.resourceid.S // empty' 2>/dev/null)

  if [[ -z "$RESOURCE_ID" ]]; then
    echo "  [NOT FOUND]  id='${id}'"
    (( NOT_FOUND++ )) || true
    continue
  fi

  # --- Already invalid? ---
  if [[ "$RESOURCE_ID" == INVALID-* ]]; then
    echo "  [SKIP]       id='${id}'"
    echo "               resourceid already starts with INVALID-: '${RESOURCE_ID}'"
    (( ALREADY_INVALID++ )) || true
    continue
  fi

  NEW_RESOURCE_ID="INVALID-${RESOURCE_ID}"

  echo "  [INVALIDATE] id='${id}'"
  echo "               old resourceid: '${RESOURCE_ID}'"
  echo "               new resourceid: '${NEW_RESOURCE_ID}'"

  if [[ "$WRITE_MODE" == true ]]; then
    aws dynamodb update-item \
      --table-name "$TABLE_NAME" \
      --region "$REGION" \
      --key "{\"id\": {\"S\": \"${id}\"}}" \
      --update-expression "SET resourceid = :new_val" \
      --expression-attribute-values "{\":new_val\": {\"S\": \"${NEW_RESOURCE_ID}\"}}" \
      > /dev/null
    echo "               [UPDATED]"
    (( UPDATED++ )) || true
  else
    echo "               [DRY-RUN — skipped]"
    (( SKIPPED++ )) || true
  fi

done < "$CSV_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "------- Summary -------"
echo "  Not found:        ${NOT_FOUND}"
echo "  Already invalid:  ${ALREADY_INVALID}"
if [[ "$WRITE_MODE" == true ]]; then
  echo "  Updated:          ${UPDATED}"
else
  echo "  Would update:     ${SKIPPED}"
  echo ""
  echo "  Re-run with --write to apply changes."
fi
