#!/bin/bash
# Ensure script is run as root/sudo for installing certs
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run with sudo or as root to install certificates system-wide."
  echo "Usage: sudo bash $0 <employee-email>"
  exit 1
fi

EMAIL=$1
if [ -z "$EMAIL" ]; then
  echo "Error: Employee email argument is required."
  echo "Usage: sudo bash $0 <employee-email>"
  exit 1
fi

command -v openssl >/dev/null 2>&1 || { echo "Error: openssl is required."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required."; exit 1; }

echo "--------------------------------------------------"
echo "         CIM - Laptop Certificate Enrollment       "
echo "--------------------------------------------------"

read -sp "Enter Enrollment Token: " ENROLL_TOKEN
echo
if [ -z "$ENROLL_TOKEN" ]; then
  echo "Error: Enrollment token is required."
  exit 1
fi

API_SERVER=${API_SERVER:-"http://localhost:8000"}
API_SERVER="${API_SERVER%/}"

echo "Detecting laptop serial number..."
# 1. Serial Number Detection
if [[ "$OSTYPE" == "darwin"* ]]; then
  SERIAL=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $4}')
else
  SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | xargs)
  if [ -z "$SERIAL" ]; then
    SERIAL=$(dmidecode -t system 2>/dev/null | grep -i "Serial Number:" | cut -d: -f2- | xargs)
  fi
fi

if [ -z "$SERIAL" ] || [ "$SERIAL" = "TBD" ]; then
  echo "Error: Could not detect a valid serial number for this laptop."
  exit 1
fi
echo "Detected Serial Number: $SERIAL"

# 2. Generate keypair + CSR locally — private key never leaves this machine
TMP_DIR=$(mktemp -d)
KEY_FILE="$TMP_DIR/client.key"
CSR_FILE="$TMP_DIR/client.csr"

echo "Generating local keypair and certificate request..."
openssl genrsa -out "$KEY_FILE" 2048 >/dev/null 2>&1
openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" -subj "/CN=$SERIAL" >/dev/null 2>&1
chmod 600 "$KEY_FILE"

CSR_JSON=$(python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read()))" "$CSR_FILE" 2>/dev/null)
if [ -z "$CSR_JSON" ]; then
  # fallback if python3 unavailable — escape newlines manually
  CSR_JSON=$(awk '{printf "%s\\n", $0}' "$CSR_FILE" | sed 's/"/\\"/g')
  CSR_JSON="\"$CSR_JSON\""
fi

PAYLOAD=$(cat <<EOF
{
  "employee_email": "$EMAIL",
  "serial_number": "$SERIAL",
  "csr": $CSR_JSON
}
EOF
)

echo "Requesting certificate for $EMAIL..."
RESPONSE_FILE="$TMP_DIR/response.json"
HTTP_CODE=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -H "X-Enroll-Token: $ENROLL_TOKEN" \
  -d "$PAYLOAD" \
  -o "$RESPONSE_FILE" \
  "$API_SERVER/enroll")

if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
  echo "Certificate issued. Installing..."

  CERT_FILE="$TMP_DIR/client.crt"
  CA_FILE="$TMP_DIR/cim_ca.crt"
  jq -r '.certificate' "$RESPONSE_FILE" > "$CERT_FILE"
  jq -r '.ca_root' "$RESPONSE_FILE" > "$CA_FILE"
  EXPIRES_AT=$(jq -r '.expires_at' "$RESPONSE_FILE")

  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Installing for macOS..."
    # Install CA cert into System Keychain
    security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CA_FILE"

    # Import client cert + local private key into login Keychain
    PFX_PASS=$(openssl rand -hex 12)
    openssl pkcs12 -export -out "$TMP_DIR/client.pfx" -inkey "$KEY_FILE" -in "$CERT_FILE" -passout pass:"$PFX_PASS"
    echo "Please enter your mac password if prompted to install the certificate to your keychain."
    sudo -u "$SUDO_USER" security import "$TMP_DIR/client.pfx" -k "/Users/$SUDO_USER/Library/Keychains/login.keychain-db" -P "$PFX_PASS" -T /usr/bin/security
  else
    echo "Installing for Linux..."
    mkdir -p /etc/ssl/cim-client-certs

    cp "$KEY_FILE" /etc/ssl/cim-client-certs/client.key
    cp "$CERT_FILE" /etc/ssl/cim-client-certs/client.crt
    chmod 600 /etc/ssl/cim-client-certs/client.key

    if [ -d "/usr/local/share/ca-certificates" ]; then
      cp "$CA_FILE" /usr/local/share/ca-certificates/cim_ca.crt
      update-ca-certificates > /dev/null 2>&1
    elif [ -d "/etc/pki/ca-trust/source/anchors" ]; then
      cp "$CA_FILE" /etc/pki/ca-trust/source/anchors/cim_ca.crt
      update-ca-trust > /dev/null 2>&1
    fi
  fi

  echo ""
  echo "✅ Success: Certificate installed successfully! (expires: $EXPIRES_AT)"
  echo "You can now access CIM."
  echo ""
else
  echo ""
  echo "❌ Error: Failed to issue certificate (HTTP Status: $HTTP_CODE)"
  cat "$RESPONSE_FILE"
  echo ""
fi

# Cleanup — private key existed only in $TMP_DIR and the OS cert store, wipe the temp copy
rm -rf "$TMP_DIR"
