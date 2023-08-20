## S'authentifier et créer le headers qui-va-bien pour l'utiliser tout le reste du script
$headers = @{"Content-Type" = "application/json"}
$body = @"
{ "auth": {
    "identity": {
      "methods": ["password"],
      "password": {
        "user": {
          "name": "INSERT USERNAME HERE",
          "domain": { "id": "default" },
          "password": "INSERT PASSWORD HERE"
        }
      }
    }
  }
}
"@
$result = Invoke-WebRequest -Headers $headers -Method POST -Body $Body -Uri 'https://auth.cloud.ovh.net/v3/auth/tokens'

$token = $result.Headers['x-subject-token']
$headers.Add('X-Auth-Token', "$token")  ## Save it so we can reuse it easily.

$region=($result.Content | ConvertFrom-Json).token.catalog.endpoints | select -Unique region_id -ExpandProperty region_id | Out-GridView -PassThru
$project_id=($result.Content | ConvertFrom-Json).token.project.id



## Lister les Flavors disponibles et garnir les infos sur leurs specs
$Result = Invoke-WebRequest -Headers $headers -Method GET -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/flavors"
$Flavors= ($Result.Content | ConvertFrom-Json).flavors

foreach ($Flavor in $Flavors){
  $Result = Invoke-WebRequest -Headers $headers -Method GET -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/flavors/$($flavor.id)"
  $Flavor | Add-Member -MemberType NoteProperty -name vcpus -value ($result.Content | convertFrom-Json).flavor.vcpus
  $Flavor | Add-Member -MemberType NoteProperty -name ram   -value ($result.Content | convertFrom-Json).flavor.ram
  $Flavor | Add-Member -MemberType NoteProperty -name disk  -value ($result.Content | convertFrom-Json).flavor.disk
}
# Garder le plus petit modèle (le moins cher?)
# $Flavor = $Flavors | sort vcpus,ram,disk -desc | Select-Object -Last 1
$Flavor = $flavors | sort vcpus,ram,disk  | select vcpus,ram,disk,name,id,links | Out-GridView -PassThru


## Trouver la distribution Linux qui me convient
$Result = Invoke-WebRequest -Headers $headers -Method GET -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/images"
$images = ($result.Content | convertFrom-Json).images
$image = $images | sort name | select name,id,links |out-gridview -passthru


## Trouver l'ID de réseau qui convient
$Result = Invoke-WebRequest -Headers $headers -Method GET -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/os-networks"
$networks = ($result.Content | convertFrom-Json).networks
$network = $networks | ? { $_.label -eq "ext-net" }


## Lister les key pair (marche pas)
((Invoke-WebRequest -Headers $headers -Method GET -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/os-keypairs").content | convertFrom-Json)


$ScriptToRun=@"
apt update
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get install -y -q xrdp mate-core mate-desktop-environment
service xrdp restart
"@


## Créer une instance
$body = @"
{
    "server": {
        "name": "openstack01",
        "imageRef": "$($image.id)",
        "flavorRef": "$($flavor.id)",
        "monthlyBilling" : false,
        "key_name" : "INSERT SSH KEY NAME HERE",
        "user_data" : "$([Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($ScriptToRun) ) )",
        "networks": [
            {
                "uuid": "$($network.id)"
            }
        ]
    }
}
"@
$Result = Invoke-WebRequest -Headers $headers -Method POST -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/servers" -body $body



## Liste des instances 'Compute' actuelles 
$RunningServers=((Invoke-WebRequest -Headers $headers -Method GET -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/servers").content | convertFrom-Json).servers
#$RunningServers | Select-Object Id,Name
foreach($RunningServer in $RunningServers){
  $Result=Invoke-WebRequest -Headers $headers -Method GET -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/servers/$($runningserver.id)"
($result.content | convertfrom-json).server | select id,name,status,created,OS-EXT-STS:task_state,OS-EXT-STS:vm_state,@{n='IPv4';e={($_.addresses.'Ext-Net' | ? {$_.version -eq 4}).addr}}
}


## Supprimer toutes les instances.
foreach ($RunningServer in $RunningServers){
  $Result = Invoke-WebRequest -Headers $headers -Method DELETE -Uri "https://compute.$region.cloud.ovh.net/v2/$project_id/servers/$($RunningServer.id)" -SkipHttpErrorCheck
  Write-Host -nonewline "$($runningServer.name) :: "
  if ($($result.StatusCode) -eq 204) {Write-Host "Deleted" -foregroundcolor Green}else{Write-host "Failed" -foregroundcolor red}
}



