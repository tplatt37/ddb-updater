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
  echo "  <csv-file>   CSV whose first column contains the 'id' values to fix."
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
  read -r -p "Are you sure? (yN) " CONFIRM
  if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
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
NOT_INVALID=0

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

  # --- Not invalid? Nothing to fix ---
  if [[ "$RESOURCE_ID" != INVALID-* ]]; then
    echo "  [SKIP]       id='${id}'"
    echo "               resourceid does not start with INVALID-: '${RESOURCE_ID}'"
    (( NOT_INVALID++ )) || true
    continue
  fi

  NEW_RESOURCE_ID="${RESOURCE_ID#INVALID-}"

  echo "  [FIX]        id='${id}'"
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
echo "  Not invalidated:  ${NOT_INVALID}"
if [[ "$WRITE_MODE" == true ]]; then
  echo "  Fixed:            ${UPDATED}"
else
  echo "  Would fix:        ${SKIPPED}"
  echo ""
  echo "  Re-run with --write to apply changes."
fi
