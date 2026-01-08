import json
import sys

def load_json(filepath):
    """Load JSON file"""
    try:
        with open(filepath, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading {filepath}: {e}")
        sys.exit(1)

def convert_services_to_dict(services_array):
    """Convert services array to dictionary keyed by API Name"""
    services_dict = {}
    for service in services_array:
        api_name = service.get("API Name")
        if api_name:
            services_dict[api_name] = service
    return services_dict

def find_matching_services(service_name, services_dict):
    """
    Find all services that match the given service name.
    First tries exact match, then tries prefix match.
    Returns a list of (service_name, service_info) tuples.
    """
    # Try exact match first
    if service_name in services_dict:
        return [(service_name, services_dict[service_name])]
    
    # Try prefix match - find all services that start with the service_name
    matches = []
    for api_name, service_info in services_dict.items():
        if api_name.startswith(service_name + " "):
            matches.append((api_name, service_info))
    
    return matches

def validate_keys(service_function_ids, services_dict):
    """Validate that each key in service_function_ids.json has a corresponding key in services.json"""
    missing_keys = []
    
    for key in service_function_ids.keys():
        matches = find_matching_services(key, services_dict)
        if not matches:
            missing_keys.append(key)
    
    if missing_keys:
        print("ERROR: The following keys in service_function_ids.json do not exist in services.json:")
        for key in sorted(missing_keys):
            print(f"  - {key}")
        return False
    
    print("✓ Validation passed: All keys in service_function_ids.json exist in services.json")
    return True

def generate_api_catalog(service_function_ids, services_dict, output_file):
    """Generate the new JSON file with REST and SOAP categorization, grouped by service name"""
    
    catalog = {
        "REST": {},
        "SOAP": {}
    }
    
    # Track which services from services.json have been processed
    processed_services = set()
    
    # First, iterate through services that have function IDs
    for service_name, function_ids in service_function_ids.items():
        # Find matching services (exact or prefix match)
        matches = find_matching_services(service_name, services_dict)
        
        if not matches:
            print(f"Warning: No matches found for '{service_name}'")
            continue
        
        # For each matching service
        for matched_service_name, service_info in matches:
            # Mark this service as processed
            processed_services.add(matched_service_name)
            
            # Determine the tag (REST or SOAP)
            tag = service_info.get("tag", "").lower()
            
            # Determine which category to use
            if tag == "rest":
                category = "REST"
            elif tag == "soap":
                category = "SOAP"
            else:
                # If tag is neither REST nor SOAP, default to REST
                category = "REST"
            
            # Initialize the service name key if it doesn't exist
            if service_name not in catalog[category]:
                catalog[category][service_name] = []
            
            # Check if function_ids is empty
            if not function_ids:
                # No function IDs - add single entry without function ID suffix
                api_entry = {
                    "API Name": matched_service_name,
                    "Url": service_info.get("Url", ""),
                    "Schema Location": service_info.get("Schema Location", ""),
                    "tag": tag
                }
                catalog[category][service_name].append(api_entry)
            else:
                # For each function ID, create an API entry
                for function_id in function_ids:
                    # Modify schema location to include function ID
                    original_schema = service_info.get("Schema Location", "")
                    if original_schema:
                        # Split the path and filename
                        if '/' in original_schema:
                            parts = original_schema.rsplit('/', 1)
                            path_part = parts[0]
                            filename = parts[1]
                        else:
                            path_part = ""
                            filename = original_schema
                        
                        # Split filename and extension
                        if '.' in filename:
                            name_part, ext = filename.rsplit('.', 1)
                            new_filename = f"{name_part}-{function_id}.{ext}"
                        else:
                            new_filename = f"{filename}-{function_id}"
                        
                        # Reconstruct the schema location
                        if path_part:
                            modified_schema = f"{path_part}/{new_filename}"
                        else:
                            modified_schema = new_filename
                    else:
                        modified_schema = ""
                    
                    api_entry = {
                        "API Name": f"{matched_service_name} {function_id}",
                        "Url": service_info.get("Url", ""),
                        "Schema Location": modified_schema,
                        "tag": tag
                    }
                    
                    # Add to the appropriate service group
                    catalog[category][service_name].append(api_entry)
    
    # Second, add services from services.json that weren't in service_function_ids.json
    for service_name, service_info in services_dict.items():
        if service_name not in processed_services:
            # This service doesn't have function IDs, add it as-is
            tag = service_info.get("tag", "").lower()
            
            # Determine which category to use
            if tag == "rest":
                category = "REST"
            elif tag == "soap":
                category = "SOAP"
            else:
                category = "REST"
            
            # Initialize the service name key
            if service_name not in catalog[category]:
                catalog[category][service_name] = []
            
            # Add single API entry without function ID
            api_entry = {
                "API Name": service_name,
                "Url": service_info.get("Url", ""),
                "Schema Location": service_info.get("Schema Location", ""),
                "tag": tag
            }
            
            catalog[category][service_name].append(api_entry)
    
    # Write to output file
    with open(output_file, 'w') as f:
        json.dump(catalog, f, indent=4)
    
    # Calculate statistics
    rest_count = sum(len(apis) for apis in catalog["REST"].values())
    soap_count = sum(len(apis) for apis in catalog["SOAP"].values())
    
    print(f"✓ API catalog generated successfully: {output_file}")
    print(f"  - REST Services: {len(catalog['REST'])}, APIs: {rest_count}")
    print(f"  - SOAP Services: {len(catalog['SOAP'])}, APIs: {soap_count}")
    print(f"  - Total APIs: {rest_count + soap_count}")

def main():
    # File paths - all files are in the same directory as this script
    import os
    script_dir = os.path.dirname(os.path.abspath(__file__))
    
    service_function_ids_file = os.path.join(script_dir, 'service_function_ids.json')
    services_file = os.path.join(script_dir, 'services.json')
    output_file = os.path.join(script_dir, 'api_catalog.json')
    
    # Load JSON files
    print("Loading JSON files...")
    service_function_ids = load_json(service_function_ids_file)
    services_array = load_json(services_file)
    
    # Convert services array to dictionary
    print("Converting services to dictionary...")
    services_dict = convert_services_to_dict(services_array)
    print(f"  - Found {len(services_dict)} services")
    
    # Validate keys
    print("\nValidating keys...")
    if not validate_keys(service_function_ids, services_dict):
        print("\n❌ Validation failed. Exiting.")
        sys.exit(1)
    
    # Generate API catalog
    print("\nGenerating API catalog...")
    generate_api_catalog(service_function_ids, services_dict, output_file)
    
    print("\n✓ Process completed successfully!")

if __name__ == "__main__":
    main()
