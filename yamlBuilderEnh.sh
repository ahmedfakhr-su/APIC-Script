#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
# Configuration variables
# ------------------------------
InputFile="services.txt"
TemplateFile="template.yaml"
OutputDirectory="API-yamls"
SchemasDirectory="schemas"

mkdir -p "$OutputDirectory"

APIC_ORG="apic-sit"
APIC_SERVER="https://apic-sit-mgmt-api-manager-bab-sit-cp4i.apps.babsitaro.albtests.com"

# Tracking variables
SUCCESS_COUNT=0
FAILURE_COUNT=0

# ------------------------------
# Functions
# ------------------------------

# Extract a value from a YAML file by key
extract_yaml_value() {
    local file="$1"
    local key="$2"
    grep "^[[:space:]]*$key:" "$file" | sed 's/.*:[[:space:]]*//'
}

# Escape a string so it is safe to use as a sed replacement (escapes / | &)
escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\/|&]/\\&/g'
}

# Load and convert JSON schema to YAML format
load_json_schema() {
    local schema_path="$1"
    
    # Check if schema file exists
    if [ ! -f "$schema_path" ]; then
        echo "Error: Schema file not found: $schema_path" >&2
        return 1
    fi
    
    # Validate JSON format before processing - FIXED: no command injection
    if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$schema_path" 2>/dev/null; then
        echo "Error: Invalid JSON in schema file: $schema_path" >&2
        return 1
    fi
    
    # Convert JSON to YAML with proper indentation
    python3 - "$schema_path" <<'EOF'
import json
import sys

def json_to_yaml(obj, indent=0):
    """
    Convert JSON Schema to OpenAPI-compatible YAML format.
    Filters out JSON Schema-specific properties that aren't valid in OpenAPI 3.0.
    Ensures 'type' appears first for better API Connect display.
    """
    lines = []
    spaces = '  ' * indent
    
    # Properties to exclude (JSON Schema specific, not OpenAPI)
    excluded_props = {'$schema', '$id', '$comment', 'definitions', '$defs'}
    
    if isinstance(obj, dict):
        # CRITICAL: We must output 'type' FIRST for API Connect to display correctly
        # Define the exact order - this is the order they will appear in YAML
        property_order = [
            'type',           # MUST BE FIRST
            'format',
            'title', 
            'description',
            'required',
            'enum',
            'default',
            'example',
            'minimum',
            'maximum',
            'exclusiveMinimum',
            'exclusiveMaximum',
            'minLength',
            'maxLength',
            'minItems',
            'maxItems',
            'pattern',
            'properties',
            'items',
            'additionalProperties',
            'allOf',
            'oneOf',
            'anyOf'
        ]
        
        # Build ordered list of keys to process
        all_keys = []
        
        # First pass: add keys in our defined order
        for prop in property_order:
            if prop in obj and prop not in excluded_props:
                all_keys.append(prop)
        
        # Second pass: add any remaining keys alphabetically
        remaining = sorted([k for k in obj.keys() if k not in all_keys and k not in excluded_props])
        all_keys.extend(remaining)
        
        for key in all_keys:
            value = obj[key]
            
            if isinstance(value, dict):
                lines.append(f"{spaces}{key}:")
                lines.extend(json_to_yaml(value, indent + 1))
            elif isinstance(value, list):
                lines.append(f"{spaces}{key}:")
                lines.extend(json_to_yaml(value, indent + 1))
            elif isinstance(value, bool):
                lines.append(f"{spaces}{key}: {str(value).lower()}")
            elif isinstance(value, str):
                # Escape strings that might need quotes
                if ':' in value or '#' in value or value.startswith(('*', '&', '!')) or value == '':
                    lines.append(f"{spaces}{key}: '{value}'")
                else:
                    lines.append(f"{spaces}{key}: {value}")
            elif value is None:
                lines.append(f"{spaces}{key}: null")
            else:
                lines.append(f"{spaces}{key}: {value}")
    
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, (dict, list)):
                lines.append(f"{spaces}-")
                nested = json_to_yaml(item, indent + 1)
                # For nested objects/arrays, don't duplicate the indent
                for i, nested_line in enumerate(nested):
                    if i == 0:
                        # First line goes on same line as dash
                        lines[-1] = f"{spaces}- {nested_line.strip()}"
                    else:
                        lines.append(f"{spaces}  {nested_line.strip()}")
            else:
                # Simple values in array
                if isinstance(item, str):
                    lines.append(f"{spaces}- {item}")
                else:
                    lines.append(f"{spaces}- {item}")
    
    return lines

try:
    with open(sys.argv[1], 'r') as f:
        schema = json.load(f)
    
    # Check if this is a properly structured request schema
    if 'type' in schema and schema.get('type') == 'object' and 'properties' in schema:
        # This is the complete request schema structure - use it directly
        processed_schema = schema
    else:
        # Fallback - use as provided
        processed_schema = schema
    
    # Generate YAML lines
    yaml_lines = json_to_yaml(processed_schema, indent=0)
    
    # Print with base indentation of 6 spaces (to match the placeholder position)
    for line in yaml_lines:
        print('      ' + line)
    
except Exception as e:
    print(f"Error processing schema: {e}", file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
EOF
}

# Replace schema section in an existing API YAML file
# Uses indentation-based detection to find and replace the {OperationName}Request schema
replace_schema_section() {
    local yaml_file="$1"
    local operation_name="$2"
    local new_schema_file="$3"
    local output_file="$4"
    
    # Pattern to match: "{OperationName}Request:" with any leading whitespace
    local pattern="${operation_name}Request:"
    
    # Use awk to:
    # 1. Find the line matching the pattern
    # 2. Record its indentation level
    # 3. Skip all subsequent lines that have greater indentation (nested content)
    # 4. Insert new schema content
    # 5. Continue with the rest of the file
    awk -v pattern="$pattern" -v schema_file="$new_schema_file" '
    BEGIN { in_schema = 0; schema_indent = 0 }
    {
        # Check if this is the schema header line we are looking for
        if ($0 ~ pattern ":") {
            # Found the schema header - print it
            print $0
            
            # Calculate indentation of this line
            match($0, /^[[:space:]]*/)
            schema_indent = RLENGTH
            
            # Insert new schema content
            while ((getline line < schema_file) > 0) {
                print line
            }
            close(schema_file)
            
            # Mark that we are now inside the old schema section to skip
            in_schema = 1
            next
        }
        
        # If we are inside the old schema section, check indentation to know when to stop skipping
        if (in_schema) {
            # Calculate indentation of current line
            match($0, /^[[:space:]]*/)
            current_indent = RLENGTH
            
            # Skip empty lines
            if ($0 ~ /^[[:space:]]*$/) {
                next
            }
            
            # If current indentation is greater than schema header, skip this line (its nested content)
            if (current_indent > schema_indent) {
                next
            }
            
            # We have reached a line with same or less indentation - stop skipping
            in_schema = 0
            print $0
            next
        }
        
        # Normal line - print as-is
        print $0
    }
    ' "$yaml_file" > "$output_file"
}

# Check if required commands are available
command -v apic >/dev/null 2>&1 || { echo "Error: apic CLI is required but not installed."; exit 1; }

# Check if python3 is available for schema processing
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for schema processing but not found." >&2
    echo "Please install python3 to use schema injection features." >&2
    exit 1
fi

# ------------------------------
# Detect Toolkit executable
# ------------------------------
detect_apic_cmd() {
    if [ -f "/mnt/c/Program Files/IBM/APIC-Toolkit/apic.exe" ]; then
        echo "/mnt/c/Program Files/IBM/APIC-Toolkit/apic.exe"
    elif [ -f "C:/Program Files/IBM/APIC-Toolkit/apic.exe" ]; then
        echo "C:/Program Files/IBM/APIC-Toolkit/apic.exe"
    elif command -v apic >/dev/null 2>&1; then
        echo "apic"
    else
        echo "Error: apic CLI not found. Install the IBM API Connect Toolkit." >&2
        exit 1
    fi
}

APIC_CMD=$(detect_apic_cmd)
echo "DEBUG: APIC_CMD=$APIC_CMD"

echo "1) Logging in to API Connect..."
if ! "$APIC_CMD" login \
    --server "$APIC_SERVER" \
    --realm "provider/integration-keycloak" \
    --context "provider" \
    --accept-license \
    --sso; then
    echo "Error: Login failed" >&2
    exit 1
fi
echo "✓ Successfully logged in"

# ------------------------------
# Process each service with schema support
# ------------------------------
exec 3< "$InputFile"
while IFS="|" read -r rawServiceName ESBUrl SchemaPath <&3 || [[ -n "$rawServiceName" ]]; do
    # Remove Windows line endings and trim whitespace
    rawServiceName=$(printf '%s' "$rawServiceName" | tr -d '\r')
    ESBUrl=$(printf '%s' "$ESBUrl" | tr -d '\r')
    SchemaPath=$(printf '%s' "$SchemaPath" | tr -d '\r')

    # Trim spaces from all fields
    ServiceName=$(printf '%s' "$rawServiceName" | tr -cd '[:print:]' | xargs || true)
    ESBUrl=$(printf '%s' "$ESBUrl" | tr -cd '[:print:]' | xargs || true)
    SchemaPath=$(printf '%s' "$SchemaPath" | tr -cd '[:print:]' | xargs || true)
    
    # Skip blank lines or comments (lines starting with #)
    [ -z "$ServiceName" ] && continue
    case "$ServiceName" in
        \#* ) continue ;;
    esac

    # Generate derived names
    x_ibm_name=$(printf '%s' "$ServiceName" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    OperationName="${ServiceName// /}"
    OUTPUT_FILE="${OutputDirectory}/${x_ibm_name}_1.0.0.yaml"

    # Extract name and version for validation (assumes _1.0.0.yaml format)
    API_NAME_VERSION="${x_ibm_name}:1.0.0"

    echo ""
    echo "========================================"
    echo "Processing: '$ServiceName'"
    echo "  ESB URL: $ESBUrl"
    echo "  Schema:  ${SchemaPath:-"(none - using empty object)"}"
    echo "========================================"

    # Escape special characters for sed replacement
    escService=$(escape_sed_replacement "$ServiceName")
    escName=$(escape_sed_replacement "$x_ibm_name")
    escOp=$(escape_sed_replacement "$OperationName")
    escUrl=$(escape_sed_replacement "$ESBUrl")

    # Load and prepare schema content
    TEMP_SCHEMA_FILE="${OutputDirectory}/.schema_temp_$$"
    
    if [ -n "$SchemaPath" ]; then
        echo "2) Loading schema from: $SchemaPath"
        if load_json_schema "$SchemaPath" > "$TEMP_SCHEMA_FILE"; then
            echo "  ✓ Schema loaded and converted to YAML"
            SCHEMA_PROVIDED=true
        else
            echo "  ⚠ Warning: Failed to load schema, using empty object" >&2
            echo "      type: object" > "$TEMP_SCHEMA_FILE"
            SCHEMA_PROVIDED=false
        fi
    else
        echo "2) No schema provided, using empty object"
        echo "      type: object" > "$TEMP_SCHEMA_FILE"
        SCHEMA_PROVIDED=false
    fi

    # Generate YAML from template
    echo "3) Generating YAML from template..."
    
    # Step 1: Replace simple placeholders
    TEMP_YAML="${OutputDirectory}/.yaml_temp_$$"
    sed -e "s|{{ServiceName}}|${escService}|g" \
        -e "s|{{x_ibm_name}}|${escName}|g" \
        -e "s|{{OperationName}}|${escOp}|g" \
        -e "s|{{ESBUrl}}|${escUrl}|g" \
        "$TemplateFile" > "$TEMP_YAML"
    
    # Step 2: Replace {{SCHEMA_PLACEHOLDER}} with content from temp file
    awk -v schema_file="$TEMP_SCHEMA_FILE" '
    {
        if ($0 ~ /{{SCHEMA_PLACEHOLDER}}/) {
            # Read and insert schema content
            while ((getline line < schema_file) > 0) {
                print line
            }
            close(schema_file)
        } else {
            print $0
        }
    }
    ' "$TEMP_YAML" > "$OUTPUT_FILE"
    
    # Cleanup temp files
    rm -f "$TEMP_SCHEMA_FILE" "$TEMP_YAML"
    
    echo "  ✓ Generated YAML: $OUTPUT_FILE"


    # Validate YAML file with API Connect (using name:version and required flags)
    echo "4) Validating YAML locally with API Connect..."
    if ! "$APIC_CMD" validate "$OUTPUT_FILE"; then
        echo "  ✗ Validation failed: YAML file is invalid" >&2
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        continue
    fi
    echo "  ✓ YAML validation passed"

    # Create or Update draft API in IBM API Connect
    echo "5) Creating/Updating draft API in API Connect..."
    
    # Temp directory for existing API retrieval
    TEMP_API_DIR="${OutputDirectory}/.temp_api"
    mkdir -p "$TEMP_API_DIR"
    
    # Check if API already exists by trying to get it
    EXISTING_API_FILE="${TEMP_API_DIR}/${x_ibm_name}_1.0.0.yaml"
    
    if "$APIC_CMD" draft-apis:get "${x_ibm_name}:1.0.0" \
        --server "$APIC_SERVER" \
        --org "$APIC_ORG" \
        --output "$TEMP_API_DIR" 2>/dev/null; then
        
        echo "  ℹ API already exists, updating schema..."
        
        # API exists - need to update schema
        # Step 5a: Load and convert the new schema from JSON to YAML
        TEMP_NEW_SCHEMA="${OutputDirectory}/.new_schema_$$"
        if [ -n "$SchemaPath" ] && [ -f "$SchemaPath" ]; then
            if load_json_schema "$SchemaPath" > "$TEMP_NEW_SCHEMA"; then
                echo "    ✓ Loaded new schema from: $SchemaPath"
            else
                echo "    ⚠ Failed to load schema, using empty object" >&2
                echo "      type: object" > "$TEMP_NEW_SCHEMA"
            fi
        else
            echo "    ℹ No schema path provided, using empty object"
            echo "      type: object" > "$TEMP_NEW_SCHEMA"
        fi
        
        # Step 5b: Replace schema section in existing API YAML
        UPDATED_API_FILE="${OutputDirectory}/.updated_api_$$"
        replace_schema_section "$EXISTING_API_FILE" "$OperationName" "$TEMP_NEW_SCHEMA" "$UPDATED_API_FILE"
        echo "    ✓ Schema section replaced"
        
        # Step 5c: Validate the updated YAML
        echo "    Validating updated YAML..."
        if ! "$APIC_CMD" validate "$UPDATED_API_FILE"; then
            echo "    ✗ Validation failed for updated YAML" >&2
            rm -f "$TEMP_NEW_SCHEMA" "$UPDATED_API_FILE"
            rm -rf "$TEMP_API_DIR"
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            continue
        fi
        echo "    ✓ Validation passed"
        
        # Step 5d: Update the draft API
        if "$APIC_CMD" draft-apis:update "${x_ibm_name}:1.0.0" \
            --server "$APIC_SERVER" \
            --org "$APIC_ORG" \
            "$UPDATED_API_FILE"; then
            echo "  ✓ Draft API updated successfully"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            # Copy updated file to output directory for reference
            cp "$UPDATED_API_FILE" "$OUTPUT_FILE"
        else
            echo "  ✗ Failed to update draft API" >&2
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
        fi
        
        # Cleanup temp files
        rm -f "$TEMP_NEW_SCHEMA" "$UPDATED_API_FILE"
        rm -rf "$TEMP_API_DIR"
        
    else
        # API doesn't exist - create new one (original logic)
        echo "  ℹ API doesn't exist, creating new..."
        if "$APIC_CMD" draft-apis:create \
            --org "$APIC_ORG" \
            --server "$APIC_SERVER" \
            "$OUTPUT_FILE"; then
            echo "  ✓ Draft API created successfully"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "  ✗ Failed to create draft API" >&2
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
        fi
        rm -rf "$TEMP_API_DIR"
    fi

done
exec 3<&-

echo ""
echo "========================================"
if [[ $FAILURE_COUNT -eq 0 ]]; then
    echo "✓ All services processed successfully"
else
    echo "⚠ Completed with $SUCCESS_COUNT successes and $FAILURE_COUNT failures"
fi
echo "========================================"

# ------------------------------
# Step 6: Product Update and Publish
# ------------------------------
# Configuration for Product
PRODUCT_NAME="internal-services"
PRODUCT_VERSION="1.0.0"
PRODUCT_TITLE="Internal Services"
CATALOG_NAME="internal"
PRODUCT_FILE="${OutputDirectory}/${PRODUCT_NAME}_${PRODUCT_VERSION}.yaml"
BACKUP_DIR="${OutputDirectory}/.backup"

# Create backup directory
mkdir -p "$BACKUP_DIR"

echo ""
echo "========================================"
echo "Step 6: Updating Product and Publishing to Catalog"
echo "========================================"
echo "  Product: $PRODUCT_NAME v$PRODUCT_VERSION"
echo "  Catalog: $CATALOG_NAME"
echo ""

# ------------------------------
# 6.1: Collect all API references from services.txt
# ------------------------------
echo "6.1) Collecting API references from services.txt..."

# Array to store API references
declare -a API_REFS=()

exec 4< "$InputFile"
while IFS="|" read -r rawServiceName ESBUrl SchemaPath <&4 || [[ -n "$rawServiceName" ]]; do
    # Remove Windows line endings and trim whitespace
    rawServiceName=$(printf '%s' "$rawServiceName" | tr -d '\r')
    ServiceName=$(printf '%s' "$rawServiceName" | tr -cd '[:print:]' | xargs || true)
    
    # Skip blank lines or comments
    [ -z "$ServiceName" ] && continue
    case "$ServiceName" in
        \#* ) continue ;;
    esac
    
    # Generate x_ibm_name (same logic as main loop)
    x_ibm_name=$(printf '%s' "$ServiceName" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    
    # Add to array
    API_REFS+=("$x_ibm_name")
    echo "  - Found API: $x_ibm_name"
done
exec 4<&-

echo "  ✓ Found ${#API_REFS[@]} APIs to include in product"

# ------------------------------
# 6.2: Generate Product YAML
# ------------------------------
echo ""
echo "6.2) Generating Product YAML..."

# Build the apis section dynamically
APIS_SECTION=""
for api_name in "${API_REFS[@]}"; do
    APIS_SECTION+="  ${api_name}:
    \$ref: ${api_name}_1.0.0.yaml
"
done

# Create the product YAML file
cat > "$PRODUCT_FILE" << EOF
product: 1.0.0
info:
  name: ${PRODUCT_NAME}
  title: ${PRODUCT_TITLE}
  version: ${PRODUCT_VERSION}

apis:
${APIS_SECTION}
visibility:
  view:
    type: public
  subscribe:
    type: authenticated

plans:
  default-plan:
    title: Default Plan
    description: Default consumption plan
    approval: false
    rate-limits:
      default:
        value: 100/hour
EOF

echo "  ✓ Generated product YAML: $PRODUCT_FILE"

# ------------------------------
# 6.3: Backup existing product (for reversibility)
# ------------------------------
echo ""
echo "6.3) Backing up existing product (if exists)..."

BACKUP_FILE="${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}_backup.yaml"
if "$APIC_CMD" draft-products:get "${PRODUCT_NAME}:${PRODUCT_VERSION}" \
    --server "$APIC_SERVER" \
    --org "$APIC_ORG" \
    --output "$BACKUP_DIR" 2>/dev/null; then
    # Rename to backup file
    if [ -f "${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}.yaml" ]; then
        mv "${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}.yaml" "$BACKUP_FILE"
        echo "  ✓ Backed up existing product to: $BACKUP_FILE"
    fi
else
    echo "  ℹ No existing product found (will create new)"
fi

# ------------------------------
# 6.4: Create or Update draft product
# ------------------------------
echo ""
echo "6.4) Creating/Updating draft product..."

# Try to update first; if it fails (product doesn't exist), create new
if "$APIC_CMD" draft-products:update "${PRODUCT_NAME}:${PRODUCT_VERSION}" \
    --server "$APIC_SERVER" \
    --org "$APIC_ORG" \
    "$PRODUCT_FILE" 2>/dev/null; then
    echo "  ✓ Draft product updated successfully"
else
    echo "  ℹ Product doesn't exist, creating new draft..."
    if "$APIC_CMD" draft-products:create \
        --server "$APIC_SERVER" \
        --org "$APIC_ORG" \
        "$PRODUCT_FILE"; then
        echo "  ✓ Draft product created successfully"
    else
        echo "  ✗ Failed to create draft product" >&2
        echo ""
        echo "========================================"
        echo "⚠ Product creation failed. APIs were created but product was not published."
        echo "   To rollback, you can restore from: $BACKUP_FILE (if exists)"
        echo "========================================"
        exit 1
    fi
fi

# ------------------------------
# 6.5: Publish product to catalog
# ------------------------------
echo ""
echo "6.5) Publishing product to catalog '$CATALOG_NAME'..."

if "$APIC_CMD" products:publish \
    --server "$APIC_SERVER" \
    --org "$APIC_ORG" \
    --catalog "$CATALOG_NAME" \
    "$PRODUCT_FILE"; then
    echo "  ✓ Product published successfully to catalog '$CATALOG_NAME'"
else
    echo "  ✗ Failed to publish product to catalog" >&2
    echo ""
    echo "========================================"
    echo "⚠ Publication failed. The draft product was created but not published."
    echo "   To rollback the draft product, run:"
    echo "   $APIC_CMD draft-products:delete ${PRODUCT_NAME}:${PRODUCT_VERSION} --server $APIC_SERVER --org $APIC_ORG"
    echo "   Or restore from backup: $BACKUP_FILE (if exists)"
    echo "========================================"
    exit 1
fi

# ------------------------------
# Final Summary
# ------------------------------
echo ""
echo "========================================"
echo "✓ COMPLETE: All operations finished successfully"
echo "========================================"
echo "  APIs created/updated: ${#API_REFS[@]}"
echo "  Product: $PRODUCT_NAME v$PRODUCT_VERSION"
echo "  Published to catalog: $CATALOG_NAME"
echo ""
echo "  Backup location: $BACKUP_FILE"
echo "  To rollback, restore the backup and run:"
echo "    $APIC_CMD draft-products:update ${PRODUCT_NAME}:${PRODUCT_VERSION} --server $APIC_SERVER --org $APIC_ORG $BACKUP_FILE"
echo "========================================"