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
InputFile="${INPUT_FILE:-services.txt}"
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
    python3 "$(dirname "${BASH_SOURCE[0]}")/convert_json_to_yaml.py" "$schema_path"
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


# Update target-url in an existing API YAML file
update_target_url() {
    local yaml_file="$1"
    local new_url="$2"
    
    # Escape the new URL for sed
    local escaped_url
    escaped_url=$(printf '%s' "$new_url" | sed -e 's/[\/&]/\\&/g')
    
    # Use sed to find "target-url:" and replace the NEXT occurrence of "value: >-" or "value:" with the new URL
    # We look for the pattern:
    #     target-url:
    #       value: >-
    #         OLD_URL
    # OR potentially simple value: OLD_URL
    
    # Strategy: 
    # 1. Search for 'target-url:'
    # 2. In the block following it, find 'value: ...' and replace it.
    
    # Since our script generates:
    #     target-url:
    #       value: >-
    #         {{ESBUrl}}
    
    # We will replace the line containing the URL itself, which is the line AFTER "value: >-"
    # OR if it was flattened, replace the value line.
    
    # Let's try a robust approach for the generated format:
    # Match lines like: "        http..." which come after "value: >-" under "target-url:"
    # This is tricky with simple sed.
    
    # Simplified approach: Replace the known structure
    # We assume the file has "value: >-" followed by the URL on next line
    
    # We will simply overwrite the logic to use Python for this part as well to be safe?
    # No, let's use a temporary python script to do this safely as we already rely on python3
    
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
    current_hash=$(git rev-parse HEAD 2>/dev/null) || { echo "git rev-parse failed"; return 0; }
    
    if [ -f "$LAST_COMMIT_FILE" ]; then
        local prev_hash
        prev_hash=$(cat "$LAST_COMMIT_FILE")
        if [ -n "$prev_hash" ]; then
            echo "  ℹ Checking changes between $prev_hash and $current_hash" >&2
            git diff --name-only "$prev_hash" "$current_hash" 2>/dev/null || echo ""
            return 0
        fi
    fi
    # No previous hash or file, return empty (implies full build if not handled)
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

#!/usr/bin/env bash
# Replace lines 208-338 in your original script with this optimized version

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

    # ------------------------------
    # Incremental Mode Check - BEFORE any processing
    # ------------------------------
    NEED_API_SYNC=true
    if [ "$INCREMENTAL_MODE" = true ] && [ "$FORCE_ALL" = false ]; then
        # Check if the schema file for this service has changed
        if [ -n "$SchemaPath" ]; then
            # Use -F to treat the pattern as a fixed string (safe for paths with dots/special chars)
            if ! echo "$CHANGED_FILES" | grep -F -q "$SchemaPath"; then
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
            echo "  ⚠ Warning: Failed to load schema, using empty object" >&2
            echo "      type: object" > "$TEMP_SCHEMA_FILE"
            SCHEMA_PROVIDED=false
        fi
    else
        echo "3) No schema provided, using empty object"
        echo "      type: object" > "$TEMP_SCHEMA_FILE"
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
        rm -f "$TEMP_YAML"
        
        echo "  ✓ Generated YAML: $OUTPUT_FILE"

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
        else
            echo "  ✗ Failed to create draft API" >&2
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
        fi
        
    else
        # ------------------------------
        # PATH B: Update existing API
        # ------------------------------
        echo "4) Updating existing API with new schema..."
        
        # Replace schema section in existing API YAML (using already-loaded schema)
        UPDATED_API_FILE="${OutputDirectory}/.updated_api_$$"
        replace_schema_section "$EXISTING_API_FILE" "$OperationName" "$TEMP_SCHEMA_FILE" "$UPDATED_API_FILE"
        echo "  ✓ Schema section replaced"
        
        # Update target-url (ensure it matches services.txt)
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
            # Copy updated file to output directory for reference
            cp "$UPDATED_API_FILE" "$OUTPUT_FILE"
        else
            echo "  ✗ Failed to update draft API" >&2
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
if [[ $FAILURE_COUNT -eq 0 ]]; then
    echo "✓ All services processed successfully"
else
    echo "⚠ Completed with $SUCCESS_COUNT successes and $FAILURE_COUNT failures"
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

if [ "$PERFORM_PRODUCT_UPDATE" = true ]; then

# Configuration for Product (loaded from config.env with defaults)
PRODUCT_NAME="${PRODUCT_NAME:-internal-services}"
PRODUCT_VERSION="${PRODUCT_VERSION:-1.0.0}"
PRODUCT_TITLE="${PRODUCT_TITLE:-Internal Services}"
CATALOG_NAME="${CATALOG_NAME:-internal}"
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
    # echo "  - Found API: $x_ibm_name" # Reduce noise
done
exec 4<&-

echo "  ✓ Found ${#API_REFS[@]} APIs to include in product"

# ------------------------------
# 6.2: Backup existing product (for reversibility)
# ------------------------------
echo ""
echo "6.2) Backing up existing product (if exists)..."

BACKUP_FILE="${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}_backup.yaml"
EXISTING_PRODUCT_FILE="${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}_existing.yaml"
PRODUCT_EXISTS=false

if "$APIC_CMD" draft-products:get "${PRODUCT_NAME}:${PRODUCT_VERSION}" \
    --server "$APIC_SERVER" \
    --org "$APIC_ORG" \
    --output "$BACKUP_DIR" 2>/dev/null; then
    # Rename to existing product file for merging
    if [ -f "${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}.yaml" ]; then
        mv "${BACKUP_DIR}/${PRODUCT_NAME}_${PRODUCT_VERSION}.yaml" "$EXISTING_PRODUCT_FILE"
        echo "  ✓ Retrieved existing product for merging"
        PRODUCT_EXISTS=true
        # Also create backup
        cp "$EXISTING_PRODUCT_FILE" "$BACKUP_FILE"
        echo "  ✓ Created backup at: $BACKUP_FILE"
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
    python3 "$(dirname "${BASH_SOURCE[0]}")/merge_apis.py" "$EXISTING_PRODUCT_FILE" "${API_REFS[@]}"

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
echo "  APIs created/updated: ${#API_REFS[@]}"
echo "  Product: $PRODUCT_NAME v$PRODUCT_VERSION"
if [ "$PERFORM_PRODUCT_UPDATE" = true ]; then
    echo "  Published to catalog: $CATALOG_NAME"
    echo ""
    echo "  Backup location: $BACKUP_FILE"
else
    echo "  (Product update skipped - no API changes)"
fi
echo "========================================"

# ------------------------------
# Save state for Incremental Mode
# ------------------------------
if [ "$INCREMENTAL_MODE" = true ]; then
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
fi