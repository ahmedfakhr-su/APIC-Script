import json

def parse_services_file(filename):
    """
    Reads services.txt file line by line and creates JSON objects.
    
    Args:
        filename: Path to the services.txt file
        
    Returns:
        List of dictionaries containing API Name, Url, and Schema Location
    """
    services = []
    
    with open(filename, 'r', encoding='utf-8') as file:
        for line in file:
            # Strip whitespace from the line
            line = line.strip()
            
            # Skip empty lines and lines starting with #
            if not line or line.startswith('#'):
                continue
            
            # Split the line by pipe character
            parts = [part.strip() for part in line.split('|')]
            
            # Ensure we have exactly 3 parts
            if len(parts) == 3:
                schema_location = parts[2]
                
                # Determine tag based on schema filename
                tag = "soap" if "soap" in schema_location.lower() else "rest"
                
                service_obj = {
                    "API Name": parts[0],
                    "Url": parts[1],
                    "Schema Location": schema_location,
                    "tag": tag
                }
                services.append(service_obj)
            else:
                print(f"Warning: Skipping malformed line: {line}")
    
    return services


if __name__ == "__main__":
    # Parse the services.txt file
    services_file = "services.txt"
    
    try:
        result = parse_services_file(services_file)
        
        # Print the result as formatted JSON
        print(json.dumps(result, indent=2))
        
        # Optionally, write to output file
        with open("services_output.json", 'w', encoding='utf-8') as output_file:
            json.dump(result, output_file, indent=2)
            
        print(f"\nSuccessfully parsed {len(result)} services from {services_file}")
        
    except FileNotFoundError:
        print(f"Error: {services_file} not found")
    except Exception as e:
        print(f"Error: {e}")
