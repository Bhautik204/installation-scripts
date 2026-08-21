#!/bin/bash

# Ensure script is run as root/sudo for dmidecode
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run with sudo or as root to collect hardware information."
  echo "Usage: sudo bash $0 <employee-email>"
  exit 1
fi

EMAIL=$1
if [ -z "$EMAIL" ]; then
  echo "Error: Email argument is required."
  echo "Usage: sudo bash $0 <employee-email>"
  exit 1
fi

echo "--------------------------------------------------"
echo "    Asset Management System - Laptop Auditing     "
echo "--------------------------------------------------"
read -sp "Enter Auditing Token: " AUDIT_TOKEN
echo
if [ -z "$AUDIT_TOKEN" ]; then
  echo "Error: Audit token is required to submit results."
  exit 1
fi

echo "Collecting system specifications..."

# 1. Manufacturer
MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null | xargs)
if [ -z "$MANUFACTURER" ]; then
  MANUFACTURER=$(dmidecode -t system 2>/dev/null | grep -i "Manufacturer:" | cut -d: -f2- | xargs)
fi
[ -z "$MANUFACTURER" ] && MANUFACTURER="TBD"

# 2. Model
MODEL=$(dmidecode -s system-product-name 2>/dev/null | xargs)
if [ -z "$MODEL" ]; then
  MODEL=$(dmidecode -t system 2>/dev/null | grep -i "Product Name:" | cut -d: -f2- | xargs)
fi
[ -z "$MODEL" ] && MODEL="TBD"

# 3. Serial Number
SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | xargs)
if [ -z "$SERIAL" ]; then
  SERIAL=$(dmidecode -t system 2>/dev/null | grep -i "Serial Number:" | cut -d: -f2- | xargs)
fi
[ -z "$SERIAL" ] && SERIAL="TBD"

# 4. CPU/Processor
CPU=$(lscpu 2>/dev/null | grep -i "Model name" | cut -d: -f2- | grep -vi "To Be Filled By O.E.M." | sort -u | head -n 1 | xargs)
if [ -z "$CPU" ]; then
  CPU=$(grep -i "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | grep -vi "To Be Filled By O.E.M." | sort -u | head -n 1 | xargs)
fi
if [ -n "$CPU" ]; then
  # Clean up (R), (TM), "Intel Core" -> "Intel", "@ speed", standalone "CPU"
  CPU=$(echo "$CPU" | sed -E -e 's/\(R\)//g' -e 's/\(TM\)//g' -e 's/[iI]ntel[[:space:]]+[cC]ore[[:space:]]+/Intel /g' -e 's/@[[:space:]]*[0-9.]+[[:space:]]*[GkM]Hz//g' -e 's/\b[cC][pP][uU]\b//g' -e 's/[[:space:]]+/ /g' | xargs)
else
  CPU="TBD"
fi

# 5. Storage (SSD/HDD)
DISK_INFO=$(lsblk -d -o name,rota,size,model 2>/dev/null | grep -E "nvme|sda" | head -n 1)
if [ -n "$DISK_INFO" ]; then
  # Normalize spacing to single spaces
  DISK_INFO=$(echo "$DISK_INFO" | tr -s ' ')
  DISK_NAME=$(echo "$DISK_INFO" | cut -d' ' -f1)
  DISK_ROTA=$(echo "$DISK_INFO" | cut -d' ' -f2)
  DISK_SIZE=$(echo "$DISK_INFO" | cut -d' ' -f3)
  DISK_MODEL=$(echo "$DISK_INFO" | cut -d' ' -f4-)

  if [ "$DISK_ROTA" = "0" ]; then
    STORAGE_TYPE="SSD"
  else
    STORAGE_TYPE="HDD"
  fi
  
  if [ -n "$DISK_MODEL" ]; then
    STORAGE="$DISK_SIZE ($DISK_MODEL)"
  else
    STORAGE="$DISK_SIZE"
  fi
else
  STORAGE="TBD"
  STORAGE_TYPE="SSD"
fi

# 6. RAM slots and type
# Parse memory modules to extract sizes and types
RAM_SLOT_A=""
RAM_SLOT_B=""
RAM_TYPE=""

IFS=$'\n'
CURRENT_LOCATOR=""
CURRENT_SIZE=""
CURRENT_TYPE=""
SLOT_INDEX=0

for line in $(dmidecode -t memory 2>/dev/null | grep -E "Memory Device$|Locator:|Size:|[[:space:]]Type:"); do
  if echo "$line" | grep -q "Memory Device$"; then
    if [ -n "$CURRENT_SIZE" ] && [ "$CURRENT_SIZE" != "No Module Installed" ]; then
      if [ $SLOT_INDEX -eq 0 ]; then
        RAM_SLOT_A="$CURRENT_SIZE"
        RAM_TYPE="$CURRENT_TYPE"
      elif [ $SLOT_INDEX -eq 1 ]; then
        RAM_SLOT_B="$CURRENT_SIZE"
        [ -z "$RAM_TYPE" ] && RAM_TYPE="$CURRENT_TYPE"
      fi
      SLOT_INDEX=$((SLOT_INDEX + 1))
    fi
    CURRENT_LOCATOR=""
    CURRENT_SIZE=""
    CURRENT_TYPE=""
  elif echo "$line" | grep -q "Locator:"; then
    CURRENT_LOCATOR=$(echo "$line" | cut -d: -f2- | xargs)
  elif echo "$line" | grep -q "Size:"; then
    CURRENT_SIZE=$(echo "$line" | cut -d: -f2- | xargs)
  elif echo "$line" | grep -Eq "[[:space:]]Type:"; then
    CURRENT_TYPE=$(echo "$line" | cut -d: -f2- | xargs)
  fi
done

# Process the last memory device block
if [ -n "$CURRENT_SIZE" ] && [ "$CURRENT_SIZE" != "No Module Installed" ]; then
  if [ $SLOT_INDEX -eq 0 ]; then
    RAM_SLOT_A="$CURRENT_SIZE"
    RAM_TYPE="$CURRENT_TYPE"
  elif [ $SLOT_INDEX -eq 1 ]; then
    RAM_SLOT_B="$CURRENT_SIZE"
    [ -z "$RAM_TYPE" ] && RAM_TYPE="$CURRENT_TYPE"
  fi
fi

# Fallback values if nothing parsed
[ -z "$RAM_SLOT_A" ] && RAM_SLOT_A="TBD"
[ -z "$RAM_TYPE" ] && RAM_TYPE="DDR4"

# Print details locally
echo ""
echo "Collected Specifications:"
echo "--------------------------------------------------"
echo "Email:             $EMAIL"
echo "Manufacturer:      $MANUFACTURER"
echo "Model:             $MODEL"
echo "Serial Number:     $SERIAL"
echo "Processor (CPU):   $CPU"
echo "RAM Slot A:        $RAM_SLOT_A"
echo "RAM Slot B:        $RAM_SLOT_B"
echo "RAM Type:          $RAM_TYPE"
echo "Storage:           $STORAGE"
echo "Storage Type:      $STORAGE_TYPE"
echo "--------------------------------------------------"
echo ""

# Build API target server URL
API_SERVER=${API_SERVER:-"https://ams.websoptimization.com"}

# Clean trailing slash if present
API_SERVER="${API_SERVER%/}"

# Strip spaces for dropdown compatibility in web app (e.g., "8 GB" -> "8GB")
RAM_SLOT_A_API=$(echo "$RAM_SLOT_A" | tr -d ' ')
RAM_SLOT_B_API=$(echo "$RAM_SLOT_B" | tr -d ' ')

# JSON payload compilation
PAYLOAD=$(cat <<EOF
{
  "email": "$EMAIL",
  "manufacturer": "$MANUFACTURER",
  "model": "$MODEL",
  "serialNumber": "$SERIAL",
  "cpu": "$CPU",
  "ramSlotA": "$RAM_SLOT_A_API",
  "ramSlotB": "$RAM_SLOT_B_API",
  "ramtype": "$RAM_TYPE",
  "storage": "$STORAGE",
  "storageType": "$STORAGE_TYPE"
}
EOF
)

echo "Submitting specifications to $API_SERVER/api/laptops/audit..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -H "X-Audit-Token: $AUDIT_TOKEN" \
  -d "$PAYLOAD" \
  "$API_SERVER/api/laptops/audit")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
  echo ""
  echo "Success: Laptop specifications submitted and assigned successfully!"
  echo "Response:"
  echo "$BODY" | grep -E '"(serialNumber|assignedToName|status)"'
  echo ""
else
  echo ""
  echo "Error: Failed to submit audit (HTTP Status: $HTTP_CODE)"
  echo "Server response:"
  echo "$BODY"
  echo ""
  exit 1
fi