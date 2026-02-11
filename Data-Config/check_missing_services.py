import json

# Load the files
with open('Data-Config/services.json', 'r') as f:
    services = json.load(f)

with open('Data-Config/service_function_ids.json', 'r') as f:
    service_function_ids = json.load(f)

with open('Data-Config/api_catalog.json', 'r') as f:
    catalog = json.load(f)

# Get all service names from each source
services_names = {s['API Name'] for s in services}
function_ids_names = set(service_function_ids.keys())
catalog_rest_names = set(catalog['REST'].keys())
catalog_soap_names = set(catalog['SOAP'].keys())
catalog_all_names = catalog_rest_names | catalog_soap_names

# Find missing services
missing_from_catalog = services_names - catalog_all_names
missing_from_function_ids = services_names - function_ids_names

print(f"Total services in services.json: {len(services_names)}")
print(f"Total services in service_function_ids.json: {len(function_ids_names)}")
print(f"Total services in api_catalog.json: {len(catalog_all_names)}")
print()

print(f"Services in services.json but NOT in api_catalog.json: {len(missing_from_catalog)}")
for service in sorted(missing_from_catalog):
    print(f"  - {service}")

print()
print(f"Services in services.json but NOT in service_function_ids.json: {len(missing_from_function_ids)}")
for service in sorted(missing_from_function_ids):
    print(f"  - {service}")

# Check services with empty function IDs
print()
print("Services with empty function ID arrays:")
empty_services = [name for name, ids in service_function_ids.items() if len(ids) == 0]
print(f"Total: {len(empty_services)}")
for service in sorted(empty_services):
    print(f"  - {service}")
