#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
# Load Configuration
# ------------------------------
# Configuration can be overridden by:
# 1. Setting environment variables before running
# 2. Creating a config.env file in the same directory
CONFIG_FILE="${CONFIG_FILE:-config.env}"
if [ -f "$CONFIG_FILE" ]; then
    echo "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
fi

# ------------------------------
# Configuration variables (with defaults)
# ------------------------------
InputFile="${INPUT_FILE:-services.json}"
TemplateFile="${TEMPLATE_FILE:-template.yaml}"
OutputDirectory="${OUTPUT_DIRECTORY:-API-yamls}"
SchemasDirectory="${SCHEMAS_DIRECTORY:-schemas}"

APIC_ORG="${APIC_ORG:-apic-sit}"
APIC_SERVER="${APIC_SERVER:-https://apic-sit-mgmt-api-manager-bab-sit-cp4i.apps.babsitaro.albtests.com}"

# Create output directory
mkdir -p "$OutputDirectory"

# Tracking variables

SUCCESS_COUNT=0
FAILURE_COUNT=0
CREATED_COUNT=0
UPDATED_COUNT=0

# ------------------------------
# Functions
# ------------------------------
# ------------------------------
# Temporary backup handling
# ------------------------------
TEMP_BACKUP_DIR="${OutputDirectory}/.backup_temp_$$"
BACKUP_DIR="${OutputDirectory}/.backup"

# Validate that all API names in services.json are unique
validate_unique_api_names() {
    local input_file="$1"
    
    echo ""
    echo "========================================"
    echo "Validating API Names Uniqueness..."
    echo "========================================"
    
    # Arrays to track names
    declare -A seen_names
    declare -a duplicate_names
    local total_count=0
    local has_duplicates=false
    
    # Read all API names and check for duplicates
    while read -r json_item; do
        ServiceName=$(echo "$json_item" | jq -r '."API Name"' | tr -cd '[:print:]' | xargs)
        
        # Skip blank lines or comments
        [ -z "$ServiceName" ] && continue
        case "$ServiceName" in
            \#* ) continue ;;
        esac
        
        # Generate x_ibm_name (same logic as main loop)
        x_ibm_name=$(printf '%s' "$ServiceName" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        
        total_count=$((total_count + 1))
        
        # Check if we've seen this name before
        if [ -n "${seen_names[$x_ibm_name]:-}" ]; then
            # Duplicate found
            if [ "${seen_names[$x_ibm_name]}" != "DUPLICATE_MARKED" ]; then
                # First time seeing this duplicate
                duplicate_names+=("$x_ibm_name (originally: '${seen_names[$x_ibm_name]}', duplicate: '$ServiceName')")
                seen_names[$x_ibm_name]="DUPLICATE_MARKED"
            else
                # Additional duplicate
                duplicate_names+=("$x_ibm_name (additional duplicate: '$ServiceName')")
            fi
            has_duplicates=true
        else
            # First time seeing this name
            seen_names[$x_ibm_name]="$ServiceName"
        fi
    done < <(jq -c '.[]' "$input_file")
    
    # Report results
    echo "  Total APIs found: $total_count"
    echo ""
    
    if [ "$has_duplicates" = true ]; then
        echo "  ❌ ERROR: Duplicate API names detected!"
        echo ""
        echo "  The following API names (after normalization) appear multiple times:"
        echo ""
        for dup in "${duplicate_names[@]}"; do
            echo "    - $dup"
        done
        echo ""
        echo "  Note: API names are normalized to lowercase with hyphens."
        echo "  Example: 'My Service' and 'My-Service' both become 'my-service'"
        echo ""
        echo "  Please fix the duplicate API names in: $input_file"
        echo "========================================"
        return 1
    else
        echo "  ✅ All API names are unique"
        echo "========================================"
        return 0
    fi
}
# Trap to cleanup temp backup on script exit (failure cases)
cleanup_temp_backup() {
    if [ -d "$TEMP_BACKUP_DIR" ]; then
        echo "  🧹 Cleaning up temporary backup directory..."
        rm -rf "$TEMP_BACKUP_DIR"
    fi
}
trap cleanup_temp_backup EXIT

# Function to finalize backup (call at script end on success)
finalize_backup() {
    if [ -d "$TEMP_BACKUP_DIR" ]; then
        echo ""
        echo "📦 Finalizing backup..."
        
        # Remove old backup directory if it exists
        if [ -d "$BACKUP_DIR" ]; then
            echo "  ℹ Removing old backup directory..."
            rm -rf "$BACKUP_DIR"
        fi
        
        # Move temp backup to final location
        mv "$TEMP_BACKUP_DIR" "$BACKUP_DIR"
        echo "  ✓ Backup finalized at: $BACKUP_DIR"
        
        # Disable the cleanup trap since we've successfully moved the directory
        trap - EXIT
    fi
}

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
    python3 "$(dirname "${BASH_SOURCE[0]}")/convert_json_to_yaml.py" "$schema_path"
}

# Insert a new schema section into an API YAML file (OpenAPI 3.0 only)
# Inserts under components:/schemas: section
insert_schema_section() {
    local yaml_file="$1"
    local operation_name="$2"
    local schema_file="$3"
    local output_file="$4"
    
    echo "     Inserting new schema section..." >&2
    echo "     Operation name: $operation_name" >&2
    echo "     Schema file: $schema_file" >&2
    
    local key_name="${operation_name}Request"
    
    # Check if components exists
    local has_components=false
    local has_schemas=false
    
    if yq eval 'has("components")' "$yaml_file" | grep -q "true"; then
        has_components=true
        echo "     ℹ Found components section" >&2
    fi
    
    # Check if components.schemas exists
    if yq eval 'has("components") and .components | has("schemas")' "$yaml_file" | grep -q "true"; then
        has_schemas=true
        echo "     ℹ Found schemas section" >&2
    fi
    
    # Path 1: components/schemas both exist
    if [ "$has_components" = true ] && [ "$has_schemas" = true ]; then
        echo "     ℹ Found existing components/schemas section" >&2
        
        # Insert under existing schemas section
        yq eval ".components.schemas.${key_name} = load(\"$schema_file\")" "$yaml_file" > "$output_file"
        
        echo "  ✅ Inserted schema under components/schemas" >&2
        
    # Path 2: components exists but no schemas
    elif [ "$has_components" = true ]; then
        echo "     ℹ components exists but no schemas section, creating it" >&2
        
        # Create schemas object with the new schema
        yq eval ".components.schemas = {\"${key_name}\": load(\"$schema_file\")}" "$yaml_file" > "$output_file"
        
        echo "  ✅ Created schemas section under components" >&2
        
    # Path 3: No components section at all
    else
        echo "     ℹ No components section found, creating new one" >&2
        
        # Create entire components structure
        yq eval ".components.schemas = {\"${key_name}\": load(\"$schema_file\")}" "$yaml_file" > "$output_file"
        
        echo "  ✅ Created new components/schemas section" >&2
    fi
    
    # Verify no duplicate schemas sections
    local schemas_count=$(yq eval '.components | keys | map(select(. == "schemas")) | length' "$output_file")
    if [ "$schemas_count" -gt 1 ]; then
        echo "❌ ERROR: Duplicate schemas sections detected" >&2
        return 1
    fi
}
# Replace schema section in an existing API YAML file (OpenAPI 3.0 only)
# Uses indentation-based detection to find and replace the {OperationName}Request schema
replace_schema_section() {
    local yaml_file="$1"
    local operation_name="$2"
    local new_schema_file="$3"
    local output_file="$4"
    
    echo "     Schema replacement starting..." >&2
    echo "     YAML file: $yaml_file" >&2
    echo "     Operation name: $operation_name" >&2
    echo "     New schema file: $new_schema_file" >&2
    
    local key_name="${operation_name}Request"
    echo "     Search key: '$key_name'" >&2
    
    # Check if the key exists anywhere in the YAML structure
    if yq eval ".. | select(has(\"$key_name\")) | path | join(\".\")" "$yaml_file" | grep -q .; then
        echo "  ✅ Key FOUND in file" >&2
        
        # Get the path(s) where this key exists
        local paths=$(yq eval ".. | select(has(\"$key_name\")) | path | join(\".\")" "$yaml_file")
        echo "  📍 Found at path(s): $paths" >&2
        
        # Count how many times the key appears
        local count=$(echo "$paths" | grep -c .)
        echo "  🔢 Key appears $count time(s)" >&2
        
        # Read the new schema content
        local new_schema=$(cat "$new_schema_file")
        local line_count=$(echo "$new_schema" | wc -l)
        
        # For each path where the key exists, replace its content
        echo "$paths" | while IFS= read -r path; do
            if [ -n "$path" ]; then
                local full_path="${path}.${key_name}"
                echo "  🔄 Replacing content at: $full_path" >&2
                
                # Use yq to replace the content at this path with the new schema
                yq eval "${full_path} = load(\"$new_schema_file\")" "$yaml_file" > "$output_file.tmp"
                mv "$output_file.tmp" "$yaml_file"
            fi
        done
        
        # Move final result to output file
        mv "$yaml_file" "$output_file"
        
        echo "  ✅ Inserted $line_count lines of new schema" >&2
        echo "  ✓ Replacement complete." >&2
    else
        echo "  ❌ Key NOT FOUND in file!" >&2
        echo "  ❌ ERROR: Key was NEVER matched in entire file!" >&2
        # Copy original to output if key not found
        cp "$yaml_file" "$output_file"
        return 1
    fi
}

# Remove schema section from an existing API YAML file and backup (OpenAPI 3.0 only)
# Uses indentation-based detection to find and remove the {OperationName}Request schema
remove_schema_section() {
    local yaml_file="$1"
    local operation_name="$2"
    local backup_file="$3"
    local output_file="$4"
    
    echo "     Schema removal starting..." >&2
    echo "     YAML file: $yaml_file" >&2
    echo "     Operation name: $operation_name" >&2
    echo "     Backup file: $backup_file" >&2
    
    local key_name="${operation_name}Request"
    
    # Check if the key exists
    if yq eval ".. | select(has(\"$key_name\")) | path | join(\".\")" "$yaml_file" | grep -q .; then
        echo "  ✅ Found schema section" >&2
        
        # Get the path where this key exists
        local path=$(yq eval ".. | select(has(\"$key_name\")) | path | join(\".\")" "$yaml_file" | head -n 1)
        echo "  📍 Found at path: $path" >&2
        
        local full_path="${path}.${key_name}"
        
        # Extract the schema section to backup file
        # This creates a YAML document with just the key and its content
        yq eval "{ \"$key_name\": .$full_path }" "$yaml_file" > "$backup_file"
        
        echo "  💾 Schema section backed up to $backup_file" >&2
        
        # Remove the schema section from the YAML
        yq eval "del(.$full_path)" "$yaml_file" > "$output_file"
        
        echo "  🛑 Schema section removed from output" >&2
        echo "  ✓ Schema section backed up and removed" >&2
    else
        echo "  ⚠ Warning: No schema section found to remove" >&2
        # Copy original to output if key not found
        cp "$yaml_file" "$output_file"
        # Create empty backup file
        touch "$backup_file"
        return 1
    fi
}

# Update target-url in an existing API YAML file
update_target_url() {
    local yaml_file="$1"
    local new_url="$2"
    
    # Escape the new URL for sed
    local escaped_url
    escaped_url=$(printf '%s' "$new_url" | sed -e 's/[\/&]/\\&/g')
    

    
    if command -v python3 >/dev/null 2>&1; then
        python3 "$(dirname "${BASH_SOURCE[0]}")/update_target_url.py" "$yaml_file" "$new_url"
    else
        echo "Error: Python3 required for URL update" >&2
        return 1
    fi
}

# Check if required commands are available
command -v apic >/dev/null 2>&1 || { echo "Error: apic CLI is required but not installed."; exit 1; }

# Check if python3 is available for schema processing
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required for schema processing but not found." >&2
    echo "Please install python3 to use schema injection features." >&2
    exit 1
fi
# Check if yq is available for yaml processing

if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq is required for YAML processing but not found." >&2
    echo "Please install yq: https://github.com/mikefarah/yq" >&2
    exit 1
fi

# ------------------------------
# Incremental Build Logic
# ------------------------------
LAST_COMMIT_FILE="${LAST_COMMIT_FILE:-API-yamls/.last_successful_commit}"

# Check prerequisites for incremental mode
check_prerequisites() {
    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is required for incremental mode but not found." >&2
        return 1
    fi
}

# Get files changed since last successful run
get_changed_files() {
    local current_hash
    current_hash=$(git rev-parse HEAD 2>/dev/null) || { echo "git rev-parse failed" >&2; return 0; }
    
    if [ -f "$LAST_COMMIT_FILE" ]; then
        echo "  🔍 DEBUG: File size: $(wc -c < "$LAST_COMMIT_FILE") bytes" >&2
        echo "  🔍 DEBUG: File content (hex): $(xxd -p "$LAST_COMMIT_FILE" | head -c 100)" >&2
        
        local prev_hash
        prev_hash=$(head -n 1 "$LAST_COMMIT_FILE" 2>/dev/null | tr -cd '[:alnum:]')
        
        echo "  🔍 DEBUG: Extracted hash: '$prev_hash' (length: ${#prev_hash})" >&2
        
        if [ -n "$prev_hash" ] && [ ${#prev_hash} -eq 40 ]; then
            echo "  ℹ Checking changes between $prev_hash and $current_hash" >&2
            git diff --name-only "$prev_hash" "$current_hash" 2>/dev/null || echo ""
            return 0
        else
            echo "  ⚠ Invalid hash format" >&2
        fi
    fi
    
    echo ""
}

# Parse arguments
INCREMENTAL_MODE=false
FORCE_ALL=false

for arg in "$@"; do
    case $arg in
        --incremental)
            INCREMENTAL_MODE=true
            ;;
    esac
done

CHANGED_FILES=""
if [ "$INCREMENTAL_MODE" = true ]; then
    echo "Mode: Incremental Build"
    check_prerequisites || exit 1
    
    # Get changed files
    CHANGED_FILES=$(get_changed_files)
    
    # Check for critical configuration changes that force a full build
    # Using specific filenames or basename matching
    if echo "$CHANGED_FILES" | grep -qE "(^|/)services\.txt$|(^|/)template\.yaml$|(^|/)config\.env$"; then
        echo "  ⚠ Configuration changed (services/template/config), forcing FULL update."
        FORCE_ALL=true
    else
        echo "  ℹ No critical configuration changes detected."
        if [ -z "$CHANGED_FILES" ] && [ -f "$LAST_COMMIT_FILE" ]; then
             echo "  ℹ No changes detected since last success."
        elif [ ! -f "$LAST_COMMIT_FILE" ]; then
             echo "  ℹ No previous success record found, running full update."
             FORCE_ALL=true
        fi
    fi
else
    echo "Mode: Full Build (default)"
    FORCE_ALL=true
fi
echo "========================================"

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
# Validate API Names Uniqueness
# ------------------------------
if ! validate_unique_api_names "$InputFile"; then
    echo ""
    echo "Error: Cannot proceed with duplicate API names." >&2
    exit 1
fi
# ------------------------------
# Declare API_REFS array BEFORE the loop
# ------------------------------
declare -a API_REFS=()

# ------------------------------
# Process each service with schema support
# ------------------------------
exec 3< <(jq -c '.[]' "$InputFile")
while read -r json_item <&3; do
    # Extract fields from JSON object
    ServiceName=$(echo "$json_item" | jq -r '."API Name"' | tr -cd '[:print:]' | xargs)
    ESBUrl=$(echo "$json_item" | jq -r '.Url' | tr -cd '[:print:]' | xargs)
    SchemaPath=$(echo "$json_item" | jq -r '."Schema Location" // ""' | tr -cd '[:print:]' | xargs)
    
    # Skip blank lines or comments
    [ -z "$ServiceName" ] && continue
    case "$ServiceName" in
        \#* ) continue ;;
    esac

    # Generate derived names
    x_ibm_name=$(printf '%s' "$ServiceName" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    OperationName="${ServiceName// /}"
    OUTPUT_FILE="${OutputDirectory}/${x_ibm_name}_1.0.0.yaml"

    # **ADD TO API_REFS ARRAY** (for product creation later)
    API_REFS+=("$x_ibm_name")

    # Extract name and version for validation
    API_NAME_VERSION="${x_ibm_name}:1.0.0"

    echo ""
    echo "========================================"
    echo "Processing: '$ServiceName'"
    echo "  ESB URL: $ESBUrl"
    echo "  Schema:  ${SchemaPath:-"(none - no schema section)"}"
    echo "========================================"

    # ------------------------------
    # Incremental Mode Check - BEFORE any processing
    # ------------------------------
    NEED_API_SYNC=true
    if [ "$INCREMENTAL_MODE" = true ] && [ "$FORCE_ALL" = false ]; then
        # Check if the schema file for this service has changed
        if [ -n "$SchemaPath" ]; then
            # Use -F to treat the pattern as a fixed string (safe for paths with dots/special chars)
            if ! echo "$CHANGED_FILES" | grep -Fx "$SchemaPath"; then  # -x for exact line match
                NEED_API_SYNC=false
            fi
        else
            # No schema path - check if services.txt itself changed (already covered by FORCE_ALL)
            # If no schema, and we're here, it means services.txt didn't change enough to force all,
            # so we assume this service without schema hasn't changed.
            NEED_API_SYNC=false
        fi
        
        if [ "$NEED_API_SYNC" = false ]; then
             echo "  ℹ Incremental: No changes detected for this service, skipping API Sync."
             continue
        fi
    fi

    # Escape special characters for sed replacement
    escService=$(escape_sed_replacement "$ServiceName")
    escName=$(escape_sed_replacement "$x_ibm_name")
    escOp=$(escape_sed_replacement "$OperationName")
    escUrl=$(escape_sed_replacement "$ESBUrl")

    # ------------------------------
    # Check if API already exists
    # ------------------------------
    echo "2) Checking if API exists..."
    TEMP_API_DIR="${OutputDirectory}/.temp_api"
    mkdir -p "$TEMP_API_DIR"
    
    EXISTING_API_FILE="${TEMP_API_DIR}/${x_ibm_name}_1.0.0.yaml"
    API_EXISTS=false
    
    if "$APIC_CMD" draft-apis:get "${x_ibm_name}:1.0.0" \
        --server "$APIC_SERVER" \
        --org "$APIC_ORG" \
        --output "$TEMP_API_DIR" 2>/dev/null; then
        API_EXISTS=true
        echo "  ✓ API exists, will update"
    else
        echo "  ✓ API doesn't exist, will create new"
    fi

    # ------------------------------
    # Load schema ONCE based on whether we're creating or updating
    # ------------------------------
    TEMP_SCHEMA_FILE="${OutputDirectory}/.schema_temp_$$"
    
    if [ -n "$SchemaPath" ]; then
    echo "3) Loading schema from: $SchemaPath"
    if load_json_schema "$SchemaPath" > "$TEMP_SCHEMA_FILE"; then
        echo "  ✓ Schema loaded and converted to YAML"
        SCHEMA_PROVIDED=true
    else
        echo "  ⚠ Warning: Failed to load schema, will skip schema operations" >&2
        SCHEMA_PROVIDED=false
    fi
    else
        echo "3) No schema provided, will use empty schema"
        SCHEMA_PROVIDED=false
    fi

  # ------------------------------
# Branch: Create new API vs Update existing API
# ------------------------------
if [ "$API_EXISTS" = false ]; then
    # ------------------------------
    # PATH A: Create new API
    # ------------------------------
    echo "4) Generating complete YAML from template..."
    
    # Step 1: Replace simple placeholders
    TEMP_YAML="${OutputDirectory}/.yaml_temp_$$"
    sed -e "s|{{ServiceName}}|${escService}|g" \
        -e "s|{{x_ibm_name}}|${escName}|g" \
        -e "s|{{OperationName}}|${escOp}|g" \
        -e "s|{{ESBUrl}}|${escUrl}|g" \
        "$TemplateFile" > "$TEMP_YAML"
    
    # Step 2: Replace {{SCHEMA_PLACEHOLDER}} with content or empty schema
if [ "$SCHEMA_PROVIDED" = true ]; then
    # Replace with actual schema
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
else
    # Replace with truly empty schema (no validation)
    sed 's/{{SCHEMA_PLACEHOLDER}}/      type: object\
      properties: {}/' "$TEMP_YAML" > "$OUTPUT_FILE"

fi
    
    # Cleanup temp files
    rm -f "$TEMP_YAML"
    
    echo "  ✓ Generated YAML: $OUTPUT_FILE"
    # Verify the schema was created correctly
    if [ "$SCHEMA_PROVIDED" = true ]; then
        if grep -q "${OperationName}Request:" "$OUTPUT_FILE"; then
            echo "  ✓ Verified: ${OperationName}Request definition exists in YAML"
        else
            echo "  ⚠ Warning: Schema definition not found in generated YAML" >&2
        fi
    fi

    # Validate YAML file with API Connect
    echo "5) Validating YAML locally with API Connect..."
    if ! "$APIC_CMD" validate "$OUTPUT_FILE"; then
        echo "  ✗ Validation failed: YAML file is invalid" >&2
        rm -f "$TEMP_SCHEMA_FILE"
        rm -rf "$TEMP_API_DIR"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        continue
    fi
    echo "  ✓ YAML validation passed"

    # Create draft API in IBM API Connect
    echo "6) Creating draft API in API Connect..."
    if "$APIC_CMD" draft-apis:create \
        --org "$APIC_ORG" \
        --server "$APIC_SERVER" \
        "$OUTPUT_FILE"; then
        echo "  ✓ Draft API created successfully"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        CREATED_COUNT=$((CREATED_COUNT + 1))
    else
        echo "  ✗ Failed to create draft API in API Connect" >&2
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
    
else
    # ------------------------------
    # PATH B: Update existing API
    # ------------------------------
    echo "4) Updating existing API..."
    
    UPDATED_API_FILE="${OutputDirectory}/.updated_api_$$"
    
    # Extract the ACTUAL operation name from the existing API (OpenAPI 3.0: components/schemas)
    # Use || true to prevent script exit if pattern not found
    # Remove Request: and everything after it (like {}, type: object, etc.)
    ACTUAL_OPERATION_NAME=$(awk '/^  schemas:/,/^[^ ]/ {if (/^    [A-Za-z0-9]*Request:/) print}' "$EXISTING_API_FILE" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//; s/Request:.*//' || true)
    
    # Determine if schema section exists
    SCHEMA_EXISTS=false
    if [ -n "$ACTUAL_OPERATION_NAME" ]; then
        SCHEMA_EXISTS=true
        echo "  ℹ Detected existing operation name: $ACTUAL_OPERATION_NAME"
        echo "  ℹ Existing schema section will be updated/replaced"
    else
        echo "  ℹ No existing schema section found in API"
        echo "  ℹ Will create new schema section: ${OperationName}Request"
        ACTUAL_OPERATION_NAME="$OperationName"
        SCHEMA_EXISTS=false
    fi
    
    # Handle schema operations based on whether schema is provided and exists
    if [ "$SCHEMA_PROVIDED" = true ]; then
        # New schema provided from JSON
        if [ "$SCHEMA_EXISTS" = true ]; then
            echo "  ℹ Replacing existing schema section with new schema..."
            TEMP_UPDATED="${OutputDirectory}/.temp_updated_$$"
            replace_schema_section "$EXISTING_API_FILE" "$ACTUAL_OPERATION_NAME" "$TEMP_SCHEMA_FILE" "$TEMP_UPDATED"
            mv "$TEMP_UPDATED" "$UPDATED_API_FILE"
            echo "  ✓ Schema section replaced"
        else
            echo "  ℹ Creating new schema section (no previous schema existed)..."
            TEMP_UPDATED="${OutputDirectory}/.temp_updated_$"
            insert_schema_section "$EXISTING_API_FILE" "$ACTUAL_OPERATION_NAME" "$TEMP_SCHEMA_FILE" "$TEMP_UPDATED"
            mv "$TEMP_UPDATED" "$UPDATED_API_FILE"
            echo "  ✓ New schema section created with provided schema"
            
            # Verify the schema was inserted
            if grep -q "${ACTUAL_OPERATION_NAME}Request:" "$UPDATED_API_FILE"; then
                echo "  ✓ Verified: ${ACTUAL_OPERATION_NAME}Request definition exists in YAML"
            else
                echo "  ✗ ERROR: Schema definition not found after insertion!" >&2
                echo "  Showing components/schemas section:" >&2
                grep -A 10 "^  schemas:" "$UPDATED_API_FILE" 2>/dev/null | head -20 >&2 || true
            fi
        fi
    else
        # No schema provided - use empty schema
        echo "  ℹ No schema provided in JSON, using minimal valid OpenAPI schema..."
        
        # Create minimal valid OpenAPI schema temp file
        EMPTY_SCHEMA_FILE="${OutputDirectory}/.empty_schema_$"
        cat > "$EMPTY_SCHEMA_FILE" << 'EOF'
type: object
properties: {}
EOF
        
        if [ "$SCHEMA_EXISTS" = true ]; then
            # Backup existing schema first
            SCHEMA_BACKUP_DIR="${OutputDirectory}/.schema_backups"
            mkdir -p "$SCHEMA_BACKUP_DIR"
            TIMESTAMP=$(date +%Y%m%d_%H%M%S)
            SCHEMA_BACKUP_FILE="${SCHEMA_BACKUP_DIR}/${x_ibm_name}_schema_${TIMESTAMP}.yaml"
            
            echo "  ℹ Backing up existing schema before replacement..."
            # Remove old schema and replace with empty
            TEMP_REMOVED="${OutputDirectory}/.temp_removed_$$"
            TEMP_UPDATED="${OutputDirectory}/.temp_updated_$$"

            remove_schema_section \
            "$EXISTING_API_FILE" \
            "$ACTUAL_OPERATION_NAME" \
            "$SCHEMA_BACKUP_FILE" \
            "$TEMP_REMOVED"

            insert_schema_section \
            "$TEMP_REMOVED" \
            "$ACTUAL_OPERATION_NAME" \
            "$EMPTY_SCHEMA_FILE" \
            "$TEMP_UPDATED"

            mv "$TEMP_UPDATED" "$UPDATED_API_FILE"
            rm -f "${OutputDirectory}/.temp_removed_$$"
            
            if [ -f "$SCHEMA_BACKUP_FILE" ] && [ -s "$SCHEMA_BACKUP_FILE" ]; then
                echo "  ✓ Existing schema backed up to: $SCHEMA_BACKUP_FILE"
            fi
            echo "  ✓ Schema replaced with empty schema (no validation)"
        else
            # No existing schema - create new empty schema
            echo "  ℹ Creating new empty schema section (API had no previous schema)..."
            TEMP_UPDATED="${OutputDirectory}/.temp_updated_$"
            insert_schema_section "$EXISTING_API_FILE" "$ACTUAL_OPERATION_NAME" "$EMPTY_SCHEMA_FILE" "$TEMP_UPDATED"
            mv "$TEMP_UPDATED" "$UPDATED_API_FILE"
            echo "  ✓ New empty schema section created"
            
            # Verify the schema was inserted
            if grep -q "${ACTUAL_OPERATION_NAME}Request:" "$UPDATED_API_FILE"; then
                echo "  ✓ Verified: ${ACTUAL_OPERATION_NAME}Request definition exists in YAML"
            else
                echo "  ✗ ERROR: Schema definition not found after insertion!" >&2
                echo "  Showing components/schemas section:" >&2
                grep -A 10 "^  schemas:" "$UPDATED_API_FILE" 2>/dev/null | head -20 >&2 || true
            fi
        fi
        
        rm -f "$EMPTY_SCHEMA_FILE"
    fi
    
    # Update target-url (always update URL regardless of schema)
    echo "  ℹ Updating target URL..."
    if update_target_url "$UPDATED_API_FILE" "$ESBUrl"; then
        echo "  ✓ Target URL updated to: $ESBUrl"
    else
        echo "  ⚠ Warning: Failed to update target URL" >&2
    fi
    
    # Validate the updated YAML
    echo "5) Validating updated YAML..."
    if ! "$APIC_CMD" validate "$UPDATED_API_FILE"; then
        echo "  ✗ Validation failed for updated YAML" >&2
        rm -f "$TEMP_SCHEMA_FILE" "$UPDATED_API_FILE"
        rm -rf "$TEMP_API_DIR"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        continue
    fi
    echo "  ✓ Validation passed"
    
    # Update the draft API
    echo "6) Updating draft API in API Connect..."
    if "$APIC_CMD" draft-apis:update "${x_ibm_name}:1.0.0" \
        --server "$APIC_SERVER" \
        --org "$APIC_ORG" \
        "$UPDATED_API_FILE"; then
        echo "  ✓ Draft API updated successfully"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        # Copy updated file to output directory for reference
        cp "$UPDATED_API_FILE" "$OUTPUT_FILE"
    else
        echo "  ✗ Failed to update draft API in API Connect" >&2
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
    
    # Cleanup temp files
    rm -f "$UPDATED_API_FILE"
fi
# Cleanup common temp files
rm -f "$TEMP_SCHEMA_FILE"
rm -rf "$TEMP_API_DIR"
done
exec 3<&-

echo ""
echo "========================================"
echo "API Processing Summary:"
echo "  ✓ Created: $CREATED_COUNT"
echo "  ✓ Updated: $UPDATED_COUNT"
echo "  ✓ Total Success: $SUCCESS_COUNT"
if [[ $FAILURE_COUNT -gt 0 ]]; then
    echo "  ✗ Failed: $FAILURE_COUNT"
fi
echo "========================================"

# ------------------------------
# Step 6: Product Update and Publish
# ------------------------------
# Check if we should proceed with product update
PERFORM_PRODUCT_UPDATE=true
if [ "$INCREMENTAL_MODE" = true ] && [ "$FORCE_ALL" = false ] && [ $SUCCESS_COUNT -eq 0 ]; then
    echo "  ℹ Incremental: No APIs updated, skipping Product Update."
    PERFORM_PRODUCT_UPDATE=false
fi

if [ "$PERFORM_PRODUCT_UPDATE" = true ] && [ $FAILURE_COUNT -eq 0 ]; then
# Configuration for Product (loaded from config.env with defaults)
PRODUCT_NAME="${PRODUCT_NAME:-internal-services}"
PRODUCT_VERSION="${PRODUCT_VERSION:-1.0.0}"
PRODUCT_TITLE="${PRODUCT_TITLE:-Internal Services}"
CATALOG_NAME="${CATALOG_NAME:-internal}"
PRODUCT_FILE="${OutputDirectory}/${PRODUCT_NAME}_${PRODUCT_VERSION}.yaml"
BACKUP_DIR="${OutputDirectory}/.backup"

# Create backup directory
mkdir -p "$TEMP_BACKUP_DIR"

echo ""
echo "========================================"
echo "Step 6: Updating Product and Publishing to Catalog"
echo "========================================"
echo "  Product: $PRODUCT_NAME v$PRODUCT_VERSION"
echo "  Catalog: $CATALOG_NAME"
echo ""

# ------------------------------
# 6.1: API references already collected during processing
# ------------------------------
echo "6.1) Using API references collected during processing..."
echo "  ✓ Found ${#API_REFS[@]} APIs to include in product"
# ------------------------------
# 6.2: Backup existing product (for reversibility)
# ------------------------------
echo ""
echo "6.2) Backing up existing product to temporary location..."

BACKUP_FILE="${TEMP_BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}_backup.yaml"
EXISTING_PRODUCT_FILE="${TEMP_BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}_existing.yaml"
PRODUCT_EXISTS=false

if "$APIC_CMD" draft-products:get "${PRODUCT_NAME}:${PRODUCT_VERSION}" \
    --server "$APIC_SERVER" \
    --org "$APIC_ORG" \
    --output "$TEMP_BACKUP_DIR" 2>/dev/null; then
    # Rename to existing product file for merging
    if [ -f "${TEMP_BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}.yaml" ]; then
        mv "${TEMP_BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}.yaml" "$EXISTING_PRODUCT_FILE"
        echo "  ✓ Retrieved existing product for merging"
        PRODUCT_EXISTS=true
        # Also create backup
        cp "$EXISTING_PRODUCT_FILE" "$BACKUP_FILE"
        echo "  ✓ Created temporary backup"
    fi
else
    echo "  ℹ No existing product found (will create new)"
fi
# ------------------------------
# 6.3: Generate Product YAML with API merging
# ------------------------------
echo ""
echo "6.3) Generating Product YAML..."

# Build the NEW apis section from services.txt
NEW_APIS_SECTION=""
for api_name in "${API_REFS[@]}"; do
    NEW_APIS_SECTION+="  ${api_name}:
    \$ref: ${api_name}_1.0.0.yaml
"
done

# If product exists, merge with existing APIs; otherwise create new
if [ "$PRODUCT_EXISTS" = true ]; then
    echo "  ℹ Merging with existing APIs..."
    
    # Extract existing APIs section and merge
    # Use Python to properly parse and merge YAML
    #python3 "$(dirname "${BASH_SOURCE[0]}")/merge_apis.py" "$EXISTING_PRODUCT_FILE" "${API_REFS[@]}"

    # Build merged APIs section
    MERGED_APIS_SECTION=""
    # Combine old and new APIs (preserve order: existing first, then new)
    declare -A seen_apis
    
    # First, add existing APIs from the apis section
    if [ -f "$EXISTING_PRODUCT_FILE" ]; then
        # Extract only the apis section and parse API names
        in_apis_section=false
        while IFS= read -r line; do
            # Check if we're entering the apis section
            if [[ $line =~ ^apis:$ ]]; then
                in_apis_section=true
                continue
            fi
            
            # Exit apis section when we hit another top-level key
            if [ "$in_apis_section" = true ] && [[ $line =~ ^[a-z] ]] && [[ ! $line =~ ^[[:space:]] ]]; then
                in_apis_section=false
            fi
            
            # Extract API names only from the apis section (2-space indented keys ending with :)
            if [ "$in_apis_section" = true ] && [[ $line =~ ^[[:space:]]{2}([a-z0-9-]+):$ ]]; then
                api_name="${BASH_REMATCH[1]}"
                if [ -n "$api_name" ] && [ -z "${seen_apis[$api_name]:-}" ]; then
                    MERGED_APIS_SECTION+="  ${api_name}:
    \$ref: ${api_name}_1.0.0.yaml
"
                    seen_apis[$api_name]=1
                fi
            fi
        done < "$EXISTING_PRODUCT_FILE"
    fi
    
    # Then, add new APIs not already in the product
    for api_name in "${API_REFS[@]}"; do
        if [ -z "${seen_apis[$api_name]:-}" ]; then
            MERGED_APIS_SECTION+="  ${api_name}:
    \$ref: ${api_name}_1.0.0.yaml
"
            seen_apis[$api_name]=1
        fi
    done
    
    FINAL_APIS_SECTION="$MERGED_APIS_SECTION"
    echo "  ✓ Merged new and existing APIs ($(echo "$MERGED_APIS_SECTION" | grep -c '^\s*[a-z]' || echo 0) total)"
else
    FINAL_APIS_SECTION="$NEW_APIS_SECTION"
fi
# ------------------------------
# 6.3.5: Ensure all referenced API YAML files exist locally
# ------------------------------
echo ""
echo "6.3.5) Checking for missing API YAML files..."

# Get list of all APIs we're about to reference in the product
declare -a all_product_apis=()

# Parse FINAL_APIS_SECTION to extract API names
while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]{2}([a-z0-9-]+):$ ]]; then
        api_name="${BASH_REMATCH[1]}"
        if [ -n "$api_name" ]; then
            all_product_apis+=("$api_name")
        fi
    fi
done <<< "$FINAL_APIS_SECTION"

# Check each API and copy from temp backup if missing
missing_count=0
copied_count=0

for api_name in "${all_product_apis[@]}"; do
    api_file="${OutputDirectory}/${api_name}_1.0.0.yaml"
    
    # Check if API YAML file exists in output directory
    if [ ! -f "$api_file" ]; then
        echo "  ⚠ Missing: ${api_name}_1.0.0.yaml"
        missing_count=$((missing_count + 1))
        
        # Try to copy from temp backup folder
        backup_api_file="${TEMP_BACKUP_DIR}/${api_name}_1.0.0.yaml"
        if [ -f "$backup_api_file" ]; then
            cp "$backup_api_file" "$api_file"
            echo "    ✓ Copied from backup"
            copied_count=$((copied_count + 1))
        else
            echo "    ✗ Not found in backup either - product creation may fail" >&2
        fi
    fi
done

if [ $missing_count -eq 0 ]; then
    echo "  ✓ All API YAML files present (${#all_product_apis[@]} total)"
elif [ $copied_count -gt 0 ]; then
    echo "  ✓ Copied $copied_count missing API YAML files from backup"
fi
# Create the product YAML file with merged/new APIs
cat > "$PRODUCT_FILE" << EOF
product: 1.0.0
info:
  name: ${PRODUCT_NAME}
  title: ${PRODUCT_TITLE}
  version: ${PRODUCT_VERSION}

apis:
${FINAL_APIS_SECTION}
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
        value: 100/1hour
EOF

echo "  ✓ Generated product YAML: $PRODUCT_FILE"

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
    exit 1
fi

fi # End of PERFORM_PRODUCT_UPDATE check

# ------------------------------
# Final Summary
# ------------------------------
echo ""
echo "========================================"
echo "✓ COMPLETE: All operations finished successfully"
echo "========================================"
echo ""
echo "API Statistics:"
echo "  - APIs Created: $CREATED_COUNT"
echo "  - APIs Updated: $UPDATED_COUNT"
echo "  - Total Processed: $SUCCESS_COUNT"
if [[ $FAILURE_COUNT -gt 0 ]]; then
    echo "  - Failed: $FAILURE_COUNT"
fi
echo ""
echo "Product:"
echo "  - Name: $PRODUCT_NAME v$PRODUCT_VERSION"
echo "  - Total APIs in Product: ${#API_REFS[@]}"
if [ "$PERFORM_PRODUCT_UPDATE" = true ] && [ $FAILURE_COUNT -eq 0 ]; then
    echo "  - Published to catalog: $CATALOG_NAME"
fi
echo "========================================"

# ------------------------------
# Finalize backup on success
# ------------------------------
finalize_backup

# Display final backup location
if [ "$PERFORM_PRODUCT_UPDATE" = true ] && [ -f "${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}_backup.yaml" ]; then
    echo ""
    echo "  📦 Final backup location: ${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}_backup.yaml"
    echo "========================================"
fi

# ------------------------------
# Save state for successful runs (for future incremental builds)
# ------------------------------
if [ $FAILURE_COUNT -eq 0 ]; then
    if command -v git >/dev/null 2>&1; then
        current_hash=$(git rev-parse HEAD 2>/dev/null)
        if [ -n "$current_hash" ]; then
            echo "$current_hash" > "$LAST_COMMIT_FILE"
            echo "  ✓ Saved incremental state ($current_hash)"
        fi
    fi
else
    echo "  ⚠ Incremental state NOT saved due to failures"
fi