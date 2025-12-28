
#!/bin/bash
InputFile="services.json"

echo "Testing jq object iteration..."
exec 3< <(jq -c '.[]' "$InputFile")
while read -r json_item <&3; do
    ServiceName=$(echo "$json_item" | jq -r '."API Name"' | tr -cd '[:print:]' | xargs)
    ESBUrl=$(echo "$json_item" | jq -r '.Url' | tr -cd '[:print:]' | xargs)
    SchemaPath=$(echo "$json_item" | jq -r '."Schema Location" // ""' | tr -cd '[:print:]' | xargs)
    
    echo "Service: $ServiceName"
    echo "URL: $ESBUrl"
    echo "Schema: $SchemaPath"
    echo "---"
done
exec 3<&-
echo "Done"
