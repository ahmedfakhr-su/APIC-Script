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

    # Create draft API in IBM API Connect
    echo "5) Creating draft API in API Connect..."
    if ! "$APIC_CMD" draft-apis:create \
        --org "$APIC_ORG" \
        --server "$APIC_SERVER" \
        "$OUTPUT_FILE"; then
        echo "  ⚠ Warning: Draft creation failed (may already exist)" >&2
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
    else
        echo "  ✓ Draft API created successfully"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
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