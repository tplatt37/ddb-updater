#!/usr/bin/env bash
set -euo pipefail

TABLE_NAME="file-registry"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
new_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

# ---------------------------------------------------------------------------
# 1. Create the table (on-demand / dynamic capacity)
# ---------------------------------------------------------------------------
echo "Creating table '$TABLE_NAME' ..."
aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" \
  --output text --query "TableDescription.TableStatus"

echo "Waiting for table to become ACTIVE ..."
aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
echo "Table is ACTIVE."

# ---------------------------------------------------------------------------
# 2. Seed data
# ---------------------------------------------------------------------------
FILENAMES=(
  "structural_analysis_report.pdf"
  "site_survey_drawings.dwg"
  "material_takeoff_summary.xlsx"
  "rfi_response_package.pdf"
  "concrete_mix_design.docx"
  "electrical_load_schedule.xlsx"
  "geotechnical_boring_log.pdf"
  "hvac_equipment_submittals.pdf"
  "steel_shop_drawings_rev3.dwg"
  "project_closeout_checklist.docx"
)

EXTENSIONS=("pdf" "dwg" "xlsx" "docx")

echo ""
echo "Inserting 10 items ..."

for i in "${!FILENAMES[@]}"; do
  FILENAME="${FILENAMES[$i]}"
  # Derive extension from filename
  EXT="${FILENAME##*.}"
  # Strip extension for the base name used in resourceid
  BASE="${FILENAME%.*}"

  UUID=$(new_uuid)
  ID="R#${UUID}"
  FILE_SIZE=$(( RANDOM % 9950000 + 50000 ))
  RESOURCE_ID="/Eng/2026/${ID}_${FILENAME}"

  aws dynamodb put-item \
    --table-name "$TABLE_NAME" \
    --region "$REGION" \
    --item "{
      \"id\":         {\"S\": \"${ID}\"},
      \"filename\":   {\"S\": \"${FILENAME}\"},
      \"file_size\":  {\"N\": \"${FILE_SIZE}\"},
      \"resourceid\": {\"S\": \"${RESOURCE_ID}\"}
    }"

  echo "  [$(( i + 1 ))/10] id=${ID}  file_size=${FILE_SIZE}  file=${FILENAME}"
done

echo ""
echo "Done. Run the following to verify:"
echo "  aws dynamodb scan --table-name $TABLE_NAME --region $REGION"
