$routes = oc get routes -n bab-sit-cp4i -o json | ConvertFrom-Json

$routes.items | ForEach-Object {
    $routeName = $_.metadata.name
    $routeHost = $_.spec.host
    $routePath = if ($_.spec.path) { $_.spec.path } else { "/" }
    $baseUrl = "http://$routeHost$routePath"

    # Try fetching swagger or wsdl
    $swaggerUrl = "$baseUrl/swagger.json"
    try {
        $swagger = Invoke-RestMethod -Uri $swaggerUrl -UseBasicParsing
        foreach ($path in $swagger.paths.Keys) {
            "$routeName | $baseUrl$path"
        }
    } catch {
        # fallback if swagger not available
        "$routeName | $baseUrl"
    }
}
