#!/bin/bash

# Check if input file is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <input_file>"
    echo "Example: $0 endpoints.csv"
    exit 1
fi

INPUT_FILE="$1"
FAILED_ENDPOINTS=()

# Check if file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: File '$INPUT_FILE' not found!"
    exit 1
fi

echo "Checking endpoints..."
echo "===================="
echo ""

# Read file line by line
while IFS='|' read -r name url schema; do
    # Trim whitespace
    url=$(echo "$url" | xargs)
    name=$(echo "$name" | xargs)
    
    # Skip empty lines
    if [ -z "$url" ]; then
        continue
    fi
    
    echo "Checking: $name"
    echo "URL: $url"
    
    # Make curl request and capture HTTP status code
    # -s: silent, -o /dev/null: discard output, -w: write out format
    # --connect-timeout: timeout for connection
    # --max-time: maximum time for the entire operation
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                --connect-timeout 10 \
                --max-time 15 \
                "$url" 2>/dev/null)
    
    # Check if curl command failed (connection issues)
    if [ $? -ne 0 ] || [ -z "$HTTP_CODE" ]; then
        echo "Status: ❌ CONNECTION FAILED"
        FAILED_ENDPOINTS+=("$url | $name | Connection failed")
    elif [ "$HTTP_CODE" -eq 404 ]; then
        echo "Status: ❌ 404 NOT FOUND"
        FAILED_ENDPOINTS+=("$url | $name | 404 Not Found")
    elif [ "$HTTP_CODE" -eq 000 ]; then
        echo "Status: ❌ NO RESPONSE"
        FAILED_ENDPOINTS+=("$url | $name | No response")
    elif [ "$HTTP_CODE" -ge 500 ]; then
        echo "Status: ⚠️  SERVER ERROR ($HTTP_CODE)"
        FAILED_ENDPOINTS+=("$url | $name | Server Error $HTTP_CODE")
    else
        echo "Status: ✅ OK ($HTTP_CODE)"
    fi
    
    echo ""
    
done < "$INPUT_FILE"

# Print summary
echo "===================="
echo "SUMMARY"
echo "===================="
echo ""

if [ ${#FAILED_ENDPOINTS[@]} -eq 0 ]; then
    echo "✅ All endpoints are responding!"
else
    echo "❌ Failed Endpoints (${#FAILED_ENDPOINTS[@]}):"
    echo ""
    for endpoint in "${FAILED_ENDPOINTS[@]}"; do
        echo "  • $endpoint"
    done
    
    # Also save to a file
    OUTPUT_FILE="failed_endpoints_$(date +%Y%m%d_%H%M%S).txt"
    printf "%s\n" "${FAILED_ENDPOINTS[@]}" > "$OUTPUT_FILE"
    echo ""
    echo "Failed endpoints saved to: $OUTPUT_FILE"
fi