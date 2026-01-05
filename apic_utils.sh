#!/usr/bin/env bash

# ------------------------------
# Utility Functions for APIC Agent
# ------------------------------

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
insert_schema_section() {
    local yaml_file="$1"
    local operation_name="$2"
    local schema_file="$3"
    local output_file="$4"
    
    echo "     Inserting new schema section..." >&2
    echo "     Operation name: $operation_name" >&2
    echo "     Schema file: $schema_file" >&2
    
    local key_name="${operation_name}Request"
    
    # Verify schema file exists
    if [ ! -f "$schema_file" ]; then
        echo "  ❌ ERROR: Schema file does not exist: $schema_file" >&2
        return 1
    fi
    
    # Check if components exists
    local has_components=false
    local has_schemas=false
    
    # Single check that's more reliable
    if yq eval '.components.schemas' "$yaml_file" 2>/dev/null | grep -q "^"; then
        has_schemas=true
        has_components=true
        echo "     ℹ Found components.schemas section" >&2
    elif yq eval '.components' "$yaml_file" 2>/dev/null | grep -q "^"; then
        has_components=true
        echo "     ℹ Found components section (no schemas)" >&2
    fi
    
    # Create a temporary wrapper file with proper YAML structure
    local temp_wrapper=$(mktemp)
    
    # Path 1: components/schemas both exist
    if [ "$has_components" = true ] && [ "$has_schemas" = true ]; then
        echo "     ℹ Adding to existing components/schemas section" >&2
        
        # Create a minimal YAML with just the new schema
        echo "components:" > "$temp_wrapper"
        echo "  schemas:" >> "$temp_wrapper"
        echo "    ${key_name}:" >> "$temp_wrapper"
        sed 's/^/      /' "$schema_file" >> "$temp_wrapper"
        
        # Merge with existing file (new schema will be added to existing schemas)
        yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$yaml_file" "$temp_wrapper" > "$output_file"
        
        echo "  ✅ Inserted schema under components/schemas" >&2
        
    # Path 2: components exists but no schemas
    elif [ "$has_components" = true ]; then
        echo "     ℹ components exists but no schemas section, creating it" >&2
        
        # Create schemas section with the new schema
        echo "components:" > "$temp_wrapper"
        echo "  schemas:" >> "$temp_wrapper"
        echo "    ${key_name}:" >> "$temp_wrapper"
        sed 's/^/      /' "$schema_file" >> "$temp_wrapper"
        
        # Merge with existing file
        yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$yaml_file" "$temp_wrapper" > "$output_file"
        
        echo "  ✅ Created schemas section under components" >&2
        
    # Path 3: No components section at all
    else
        echo "     ℹ No components section found, creating new one" >&2
        
        # Create entire components structure
        echo "components:" > "$temp_wrapper"
        echo "  schemas:" >> "$temp_wrapper"
        echo "    ${key_name}:" >> "$temp_wrapper"
        sed 's/^/      /' "$schema_file" >> "$temp_wrapper"
        
        # Merge with existing file
        yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$yaml_file" "$temp_wrapper" > "$output_file"
        
        echo "  ✅ Created new components/schemas section" >&2
    fi
    
    # Cleanup temp file
    rm -f "$temp_wrapper"
    
    # Verify the schema was inserted
    if yq eval ".components.schemas | has(\"$key_name\")" "$output_file" 2>/dev/null | grep -q "true"; then
        echo "  ✓ Verified: Schema successfully inserted" >&2
        return 0
    else
        echo "  ❌ ERROR: Schema verification failed" >&2
        return 1
    fi
}

# Remove schema section from an existing API YAML file and backup (OpenAPI 3.0 only)
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
    
    # Check if the key exists under components.schemas (OpenAPI 3.0 standard location)
    if yq eval ".components.schemas | has(\"$key_name\")" "$yaml_file" 2>/dev/null | grep -q "true"; then
        echo "  ✅ Found schema section at components.schemas.$key_name" >&2
        
        # Extract the schema to backup file using proper path syntax
        yq eval ".components.schemas.\"$key_name\"" "$yaml_file" > "$backup_file"
        
        if [ -s "$backup_file" ]; then
            echo "  💾 Schema section backed up to $backup_file" >&2
        else
            echo "  ⚠ Warning: Backup file is empty" >&2
        fi
        
        # Remove the schema section from the YAML using proper deletion syntax
        yq eval "del(.components.schemas.\"$key_name\")" "$yaml_file" > "$output_file"
        
        # Verify deletion worked
        if yq eval ".components.schemas | has(\"$key_name\")" "$output_file" 2>/dev/null | grep -q "false"; then
            echo "  🛑 Schema section removed from output" >&2
            echo "  ✓ Schema section backed up and removed" >&2
            return 0
        else
            echo "  ❌ ERROR: Schema section still exists after deletion!" >&2
            return 1
        fi
    else
        echo "  ⚠ Warning: No schema section found to remove" >&2
        # Copy original to output if key not found
        cp "$yaml_file" "$output_file"
        # Create empty backup file
        touch "$backup_file"
        return 1
    fi
}

# Replace schema section in an existing API YAML file (OpenAPI 3.0 only)
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
    
    # Verify new schema file exists
    if [ ! -f "$new_schema_file" ]; then
        echo "  ❌ ERROR: New schema file does not exist: $new_schema_file" >&2
        return 1
    fi
    
    # Check if the key exists under components.schemas
    if yq eval ".components.schemas | has(\"$key_name\")" "$yaml_file" 2>/dev/null | grep -q "true"; then
        echo "  ✅ Key FOUND in file at components.schemas.$key_name" >&2
        
        # Count lines in new schema for reporting
        local line_count=$(wc -l < "$new_schema_file")
        
        # Create a temporary file with the schema wrapped in the proper structure
        local temp_wrapper=$(mktemp)
        echo "components:" > "$temp_wrapper"
        echo "  schemas:" >> "$temp_wrapper"
        echo "    ${key_name}:" >> "$temp_wrapper"
        sed 's/^/      /' "$new_schema_file" >> "$temp_wrapper"
        
        # Merge using yq (the wrapper will overwrite the existing key)
        yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$yaml_file" "$temp_wrapper" > "$output_file"
        
        # Clean up temp file
        rm -f "$temp_wrapper"
        
        # Verify replacement worked
        if yq eval ".components.schemas | has(\"$key_name\")" "$output_file" 2>/dev/null | grep -q "true"; then
            echo "  ✅ Inserted $line_count lines of new schema" >&2
            echo "  ✓ Replacement complete." >&2
            return 0
        else
            echo "  ❌ ERROR: Schema not found after replacement!" >&2
            return 1
        fi
    else
        echo "  ❌ Key NOT FOUND in file!" >&2
        echo "  ❌ ERROR: Key '$key_name' does not exist at components.schemas" >&2
        cp "$yaml_file" "$output_file"
        return 1
    fi
}

# Update target-url in an existing API YAML file
update_target_url() {
    local yaml_file="$1"
    local new_url="$2"
    
    if command -v python3 >/dev/null 2>&1; then
        python3 "$(dirname "${BASH_SOURCE[0]}")/update_target_url.py" "$yaml_file" "$new_url"
    else
        echo "Error: Python3 required for URL update" >&2
        return 1
    fi
}

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

# Detect Toolkit executable
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
