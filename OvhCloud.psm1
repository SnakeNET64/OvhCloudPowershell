# Initialisation des variables globales. Accessible en dehors du module aussi.
#$global:headers = @{}
#$global:Regions = @()

# Variables privées 
$script:headers = @{}
$script:Regions = @()
$script:RegionID = ""
$script:ProjectId = ""
$script:NetworkId = ""
$script:base_url = ""
$script:Catalog = $null


function Connect-Ovh {
    param (
        [string] $username,
        [string] $password,
        [string] $region = $null
    )
    
    $body = @{
        auth = @{
            identity = @{
                methods = @("password")
                password = @{
                    user = @{
                        name = "$($username)"
                        domain = @{ id = "default" }
                        password = "$($password)"
                    }
                }
            }
        }
    } | ConvertTo-Json -Depth 8

    $script:headers = @{"Content-Type" = "application/json"}
    try {
        $result = Invoke-WebRequest -Headers $script:headers -Method POST -Body $body -Uri 'https://auth.cloud.ovh.net/v3/auth/tokens'

        $token = $result.Headers['x-subject-token']
        $script:headers.Add('X-Auth-Token', "$token")
$global:headers=$script:headers
        $script:Regions = ($result.Content | ConvertFrom-Json).token.catalog.endpoints | Select-Object -Unique region_id -ExpandProperty region_id
        $script:Catalog = ($result.Content | ConvertFrom-Json).token.catalog
        $script:ProjectId = ($result.Content | ConvertFrom-Json).token.project.id

        Write-Host "Authenticated" -ForegroundColor Green

    } catch [System.Net.WebException] {
        Throw "OvhCloud : An exception was caught: $($_.Exception.Message)"
    }
    if ($region) { 
      Set-Region -region $region;
    }
}


function Get-Regions {
    return $script:Regions
}

function Set-Region {
    param (
        [string] $region
    )

    if ($region -in $script:Regions) {
        $script:RegionID = $region

        $script:base_url = (($script:Catalog | Where-Object { $_.type -eq "compute" }).endpoints | Where-Object { $_.region -eq $region -and $_.interface -eq "public" }).url

        $result = Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/os-networks"
        $networks = ($result.Content | ConvertFrom-Json).networks
        $script:NetworkId = $networks | Where-Object { $_.label -eq "ext-net" } | Select-Object -ExpandProperty id
    } else {
        Write-Error "Unknown region. Please select a valid region with Get-Regions"
    }
}

function Get-Flavors {

    $result = Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/flavors"
    $flavors = ($result.Content | ConvertFrom-Json).flavors
    foreach ($flavor in $flavors) {
        $result = Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/flavors/$($flavor.id)"
 
        $flavor | Add-Member -MemberType NoteProperty -Name vcpus -Value ($result.Content | ConvertFrom-Json).flavor.vcpus
        $flavor | Add-Member -MemberType NoteProperty -Name ram -Value ($result.Content | ConvertFrom-Json).flavor.ram
        $flavor | Add-Member -MemberType NoteProperty -Name disk -Value ($result.Content | ConvertFrom-Json).flavor.disk
    }

    return $flavors | Sort-Object vcpus, ram, disk | Select-Object vcpus, ram, disk, name, id
}

function Set-Flavor {
    param (
        [string] $flavor
    )

    $result = Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/flavors"
    $flavors = ($result.Content | ConvertFrom-Json).flavors

    if ($flavor -in $flavors.name) {
        return ($flavors | Where-Object { $_.name -eq $flavor } | Select-Object -ExpandProperty id)
    } else {
        Throw "OvhCloud.Set-Flavor(): Sorry, this flavor is not available. Please check with Get-Flavors"
    }
}

# Fonction publique pour récupérer les images disponibles
function Get-Images {
    $result = Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/images"
    $images = ($result.Content | ConvertFrom-Json).images
    return ($images | Sort-Object name | Select-Object name)
}

# Fonction publique pour sélectionner une image
function Set-Image {
    param (
        [string] $image
    )

    $result = Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/images"
    $images = ($result.Content | ConvertFrom-Json).images

    if ($image -in $images.name) {
        return ($images | Where-Object { $_.name -eq $image } | Select-Object -ExpandProperty id)
    } else {
        Throw "OvhCloud.Set-Image(): Sorry, this image is not available. Please check with Get-Images"
    }
}

# Fonction publique pour récupérer les paires de clés
function Get-Keypair {
    $result = Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/os-keypairs"
    return (($result.Content | ConvertFrom-Json).keypairs.keypair | Select-Object name, Public_key)
}


# Fonction pour créer une paire de clés SSH
function New-Keypair {
    param (
        [string] $keyName,
        [string] $PrivateKey
    )
    
    $body = @{ keypair = @{ name = $keyName; public_key = $PrivateKey } } | ConvertTo-Json
    try {
        $result = Invoke-WebRequest -Headers $script:headers -Method POST -Uri "$($script:base_url)/os-keypairs" -Body $body
    } catch [System.Net.WebException] {
        Throw "OvhCloud.CreateKeypair : An exception was caught during keypair creation : $($_.Exception.Message)"
    }
}

# Fonction pour supprimer une paire de clés SSH
function Remove-Keypair {
    param (
        [string] $keyName
    )
    
    try {
        $result = Invoke-WebRequest -Headers $script:headers -Method DELETE -Uri "$($script:base_url)/os-keypairs/$($keyName)"
    } catch [System.Net.WebException] {
        Throw "OvhCloud.RemoveKeypair : An exception was caught during keypair removal : $($_.Exception.Message)"
    }
}

# Fonction pour lister les instances existantes
function Get-Instances {
    if ($script:base_url -eq $null) {
        Throw "OvhCloud.GetInstances(): You need to select a region first..."
        return $null
    } else {
        $RunningServers = ((Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/servers").Content | ConvertFrom-Json).servers
        $RunningServers | Select-Object Id, Name
        $resultats = @()
        foreach ($RunningServer in $RunningServers) {
            $Result = Invoke-WebRequest -Headers $script:headers -Method GET -Uri "$($script:base_url)/servers/$($RunningServer.id)"
            $resultats += ($Result.Content | ConvertFrom-Json).server | Select-Object id, name, status, created, "OS-EXT-STS:task_state", "OS-EXT-STS:vm_state", @{n='IPv4'; e={($_.addresses.'Ext-Net' | Where-Object { $_.version -eq 4 }).addr}}, metadata
        }
        if ($resultats.Count -eq 0) { Write-Host "No running instances..." -ForegroundColor Cyan }
        return $resultats
    }
}

function New-Instance {
    param (
        [string] $NameRequested,
        [string] $ImageRequested,
        [string] $FlavorRequested,
        [string] $BillingRequested,
        [string] $InitialScriptRequested,
        [string] $KeyPairName
    )
    
    # Vérifications
    if ($BillingRequested -notin @("Monthly", "Hourly")) {
        Throw "OvhCloud.CreateInstance : Billing incorrect. must be 'Monthly' or 'Hourly'"
    }
    $Image = Get-Image -image $ImageRequested
    $Flavor = Get-Flavor -flavor $FlavorRequested
    $InitialScript = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($InitialScriptRequested))
    if (($KeyPairName -ne $null) -and (-not (Get-Keypair | Where-Object { $_.name -eq $KeyPairName }))) {
        Throw "OvhCloud.CreateInstance : Cannot find requested KeyPair. Create first."
    }

    # Générer les informations
    $body = @{
        server = @{
            name = $NameRequested
            imageRef = $Image
            flavorRef = $Flavor
            metadata = @{ billing = "$($BillingRequested)" }
            user_data = "$InitialScript"
            key_name = $KeyPairName
            networks = @(@{ uuid = $script:NetworkId })
        }
    }
    if ($KeyPairName -eq $null) { $body.server.PSObject.Properties.Remove("key_name") }
    $body = $body | ConvertTo-Json -Depth 10

    # Création de l'instance
    $Result = Invoke-WebRequest -Headers $script:headers -Method POST -Uri "$($script:base_url)/servers" -Body $body
}

# Fonction publique pour obtenir une instance par nom
function Get-Instance {
    param (
        [string] $instance
    )
    
    $Server = Get-Instances | Where-Object { $_.name -eq $instance }
    if (($Server | Measure-Object).Count -ne 1) {
        Throw "OvhCloud.GetInstance : Cannot find instance : $($instance)"
    }
    return $Server
}

# Fonction publique pour détruire une instance par nom
function Revoke-Instance {
    param (
        [string] $name
    )
    
    $Server = Get-Instance -instance $name
    $Result = Invoke-WebRequest -Headers $script:headers -Method DELETE -Uri "$($script:base_url)/servers/$($Server.id)"
    Write-Host -NoNewline "$($Server.name) :: "
    if ($Result.StatusCode -eq 204) {
        Write-Host "Deleted" -ForegroundColor Green
    } else {
        Write-Host "Failed" -ForegroundColor Red
    }
}





# Masquer la fonction Get-AuthToken pour qu'elle soit privée 
Export-ModuleMember -Function Connect-Ovh, Get-Regions, Set-Region,Get-Flavors,Get-Images,Get-Keypair,New-Keypair,Remove-Keypair,Get-Instances,New-Instance,Get-Instance,Revoke-Instance