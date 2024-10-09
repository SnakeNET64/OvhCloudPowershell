class OvhCloud {
    hidden [Collections.IDictionary] $headers
    hidden [Object[]] $Regions
    hidden [string] $RegionID
    hidden [string] $ProjectId
    hidden [string] $NetworkId
    hidden [string] $base_url
    hidden [string] $Username
    hidden [string] $Password




    hidden Initialize([string] $username, [string] $password){
        $body = (New-Object PSObject -Property @{ 
            auth = (New-Object PSObject -Property @{ 
                identity = (New-Object PSObject -Property @{ 
                    methods = @("password"); 
                    password = (New-Object PSObject -Property @{ 
                        user = (New-Object PSObject -Property @{ 
                            name = "$($username)"; 
                            domain = (New-Object PSObject -Property @{ 
                                id = "default" 
                            }); 
                            password = "$($password)" 
                        }) 
                    }) 
                }) 
            }) 
        })  | ConvertTo-Json -Depth 10


        $this.headers = @{"Content-Type" = "application/json"}
        try{
          $result = Invoke-WebRequest -Headers $this.headers -Method POST -Body $body -Uri 'https://auth.cloud.ovh.net/v3/auth/tokens' 
          $token = $result.Headers['x-subject-token']
          $this.headers.Add('X-Auth-Token', "$token")  ## Save it so we can reuse it easily.

          $this.Regions=($result.Content | ConvertFrom-Json).token.catalog.endpoints | Select-Object -Unique region_id -ExpandProperty region_id 
          $this.ProjectId=($result.Content | ConvertFrom-Json).token.project.id

          $this.Username=$username
          $this.Password=$password

          Write-Host "Authenticated" -ForegroundColor Green

        } catch  [System.Net.WebException] {
          Throw "OvhCloud : An exception was caught: $($_.Exception.Message)"
        }
    }

    OvhCloud([string] $username, [string] $password) {
        $this.Initialize($username,$password)
    }
    OvhCloud([string] $username, [string] $password, [string] $region){
        $this.Initialize($username,$password)
        $this.setRegion($region)
    }


#Get-Region
    [Object[]] getRegions() {
        return($this.Regions)
    }

#Select-Region
    [void] setRegion([string]$region) {
        if ($region -in $this.Regions){
            $this.RegionID = $region
            ## RÃ©cupÃ©rer les URLs des APIs. Je n'ai peut Ãªtre pas pris la bonne, mais la "public" me semblait sympa...
            $body = (New-Object PSObject -Property @{ 
                auth = (New-Object PSObject -Property @{ 
                    identity = (New-Object PSObject -Property @{ 
                        methods = @("password"); 
                        password = (New-Object PSObject -Property @{ 
                            user = (New-Object PSObject -Property @{ 
                                name = "$($this.Username)"; 
                                domain = (New-Object PSObject -Property @{ 
                                    id = "default" 
                                }); 
                                password = "$($this.Password)" 
                            }) 
                        }) 
                    }) 
                }) 
            })  | ConvertTo-Json -Depth 10

            $result = Invoke-WebRequest -Headers $this.headers -Method POST -Body $body -Uri 'https://auth.cloud.ovh.net/v3/auth/tokens' 
            $this.base_url=((($result.content | convertfrom-json).token.catalog | ? { $_.type -eq "compute"} ).endpoints | Where-Object { $_.region -eq $region -and $_.interface -eq "public"}).url

            ## Trouver l'ID de reseau qui convient
            $result = Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/os-networks"
            $networks = ($result.Content | convertFrom-Json).networks
            $this.NetworkId = $networks | Where-Object { $_.label -eq "ext-net" } | Select-Object -ExpandProperty id

        }else{
            Write-Error "Unknown region. Please select valid region in getRegion()"
        }
    }

#getFlavors
    [Object[]] getFlavors(){
        ## Lister les Flavors disponibles et garnir les infos sur leurs specs
        $Result = Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/flavors"
        $Flavors= ($Result.Content | ConvertFrom-Json).flavors

        foreach ($Flavor in $Flavors){
        $Result = Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/flavors/$($flavor.id)"
        $Flavor | Add-Member -MemberType NoteProperty -name vcpus -value ($result.Content | convertFrom-Json).flavor.vcpus
        $Flavor | Add-Member -MemberType NoteProperty -name ram   -value ($result.Content | convertFrom-Json).flavor.ram
        $Flavor | Add-Member -MemberType NoteProperty -name disk  -value ($result.Content | convertFrom-Json).flavor.disk
        }

        return ($flavors | Sort-Object vcpus,ram,disk  | Select-Object vcpus,ram,disk,name,id)

    }
    
#Select-Flavor
    [string] getFlavor([string]$flavor){
        $Result = Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/flavors"
        $Flavors= ($Result.Content | ConvertFrom-Json).flavors

        if ($Flavor -in $Flavors.name){
          return($Flavors | Where-Object { $_.name -eq $flavor} | Select-Object -ExpandProperty id)
        }else{
          Throw "OvhCloud.setFlavor(): Sorry, this flavor is not available. Please check with GetFlavor()"
        }

    }

#Get-Image
    [Object[]] getImages(){
        ## Trouver la distribution Linux qui me convient
        $Result = Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/images"
        $images = ($result.Content | convertFrom-Json).images
        return ($images | Sort-Object name | Select-Object name)
    }
#Set-Image
    [string] getImage([string]$image){
        ## Trouver la distribution Linux qui me convient
        $Result = Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/images"
        $images = ($result.Content | convertFrom-Json).images
        
        if ($image -in $images.name){
          return($images | Where-Object { $_.name -eq $image} | Select-Object -ExpandProperty id)
        }else{
          Throw "OvhCloud.setImage(): Sorry, this image is not available. Please check with GetImages()"
        }

    }

    [Object[]] GetKeypair(){
        $result = Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/os-keypairs"
        return(($result.Content | convertFrom-Json).keypairs.keypair | Select-Object  name,Public_key)

    }

    [void] CreateKeypair([string]$keyName,[string]$PrivateKey){
        ## Create KeyPair SSH
        $body = New-Object PSObject -Property @{  keypair = New-Object PSObject -Property @{ name = $keyName; public_key = $PrivateKey } } | ConvertTo-Json
        try{
            $result = Invoke-WebRequest -Headers $this.headers -Method POST -Uri "$($this.base_url)/os-keypairs" -body $body
        } catch  [System.Net.WebException] {
            Throw "OvhCloud.CreateKeypair : An exception was caught during keypair creation : $($_.Exception.Message)"
        }
    }
    [void] RemoveKeypair($keyName){
        try{
            $result = Invoke-WebRequest -Headers $this.headers -Method DELETE -Uri "$($this.base_url)/os-keypairs/$($keyName)"
        } catch  [System.Net.WebException] {
            Throw "OvhCloud.RemoveKeypair : An exception was caught during keypair removal : $($_.Exception.Message)"
        }
    }

#List existing instances
    [Object[]] GetInstances(){
        if ($this.base_url -eq $null){
            Throw "OvhCloud.GetInstances(): You need to select a region first..." 
            return($null)
        }else{
            $RunningServers=((Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/servers").content | convertFrom-Json).servers
            $RunningServers | Select-Object Id,Name  
            $resultats=@()
            foreach($RunningServer in $RunningServers){
              $Result=Invoke-WebRequest -Headers $this.headers -Method GET -Uri "$($this.base_url)/servers/$($runningserver.id)"
              $resultats+= ($result.content | convertfrom-json).server | Select-Object id,name,status,created,OS-EXT-STS:task_state,OS-EXT-STS:vm_state,@{n='IPv4';e={($_.addresses.'Ext-Net' | Where-Object {$_.version -eq 4}).addr}},metadata 
            }
            if ($resultats.count -eq 0 ) { Write-Host "No running instances..." -ForegroundColor Cyan}
            return($resultats)
        }
    }

#Create new instance
    [void] CreateInstance($NameRequested,$ImageRequested,$FlavorRequested,$BillingRequested,$KeyPairName){
        $this.Instanciate($NameRequested,$ImageRequested,$FlavorRequested,$BillingRequested,"",$KeyPairName)
    }
    [void] CreateInstance($NameRequested,$ImageRequested,$FlavorRequested,$BillingRequested,$InitialScriptRequested,$KeyPairName){
        $this.Instanciate($NameRequested,$ImageRequested,$FlavorRequested,$BillingRequested,$InitialScriptRequested,$KeyPairName)
    }

    [void] hidden Instanciate($NameRequested,$ImageRequested,$FlavorRequested,$BillingRequested,$InitialScriptRequested,$KeyPairName){

    ##Checks
    if ($BillingRequested -notin @("Monthly","Hourly")){Throw "OvhCloud.CreateInstance : Billing incorrect. must be 'Monthly' or 'Hourly'"}
    $Image=$this.getImage($ImageRequested)
    $flavor=$this.getFlavor($FlavorRequested)
    $InitialScript=[Convert]::ToBase64String([System.Text.Encoding]::utf8.GetBytes(($InitialScriptRequested)))
    if (($KeyPairName -ne $null) -and (-not ($this.GetKeypair() | Where-Object { $_.name -eq $KeyPairName }) ) ) {Throw "OvhCloud.CreateInstance : Cannot find requested KeyPair. Create first."}

    ##Generate info
    $body= (New-Object PSObject -Property @{
        server = New-Object PSObject -Property @{ 
            name = $NameRequested; 
            imageRef = $Image; 
            flavorRef = $flavor; 
            metadata = New-Object PSObject -Property @{ 
                billing = "$($BillingRequested)" 
            }; 
            user_data = "$InitialScript"; 
            key_name = $KeyPairName;
            networks = @(New-Object PSObject -Property @{ 
                uuid = $this.NetworkId 
            }) 
        } 
    }) 
    if ($KeyPairName -eq $null) {$body.server.PSObject.Properties.Remove("key_name")}
    $body=$body | ConvertTo-Json -Depth 10

    ##Build
    #Write-host $body

    ## Creation de l'instance
    $Result = Invoke-WebRequest -Headers $this.headers -Method POST -Uri "$($this.base_url)/servers" -body $body

    }

# Delete Instance
    [Object[]] getInstance($instance){
    $Server = $this.GetInstances() | Where-Object { $_.name -eq $instance}
    if (($Server |Measure-Object).Count -ne 1) {Throw "OvhCloud.getInstance : Cannot find instance : $($instance)"}
    return($Server)
    }


    [void] DestroyInstance($name){
        $Server=$this.getInstance($name)
        $Result = Invoke-WebRequest -Headers $this.headers -Method DELETE -Uri "$($this.base_url)/servers/$($Server.id)" 
        Write-Host -nonewline "$($Server.name) :: "
        if ($($result.StatusCode) -eq 204) {Write-Host "Deleted" -foregroundcolor Green}else{Write-host "Failed" -foregroundcolor red}

    }

    [void] debug(){
        Write-Host "Region ID  : $($this.RegionID)"
        Write-Host "Project ID : $($this.ProjectId)"
        Write-Host "Base URL   : $($this.base_url)"
        Write-Host "Network ID : $($this.NetworkId)"
    }
        
}



<#
$MonCloud = [OvhCloud]::new("LOGIN","PASSWORD","GRA11")
$MonCloud.setRegion("GRA11")
$MonCloud.getRegions()
$MonCloud.getImages()
$MonCloud.getImage("Debian 12 - Docker")
$MonCloud.GetKeypair()
$MonCloud.CreateKeypair("MyPublicSSH","ssh-rsa aaaBBBccc== My Very Own Key")
$MonCloud.RemoveKeypair("MyPublicSSH")
$MonCloud.debug()
$ScriptToRun=@"
#!/bin/bash
apt-key export 0EBFCD88 | gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
docker run -d -p 9001:9001 --name portainer_agent --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/volumes:/var/lib/docker/volumes  -v /:/host portainer/agent:latest
"@
$MonCloud.CreateInstance("New VM","Debian 12 - Docker","d2-2","Hourly",$ScriptToRun,"MyPublicSSH")
$MonCloud.GetInstances()
$MonCloud.GetInstance("New VM")
$MonCloud.DestroyInstance("New VM")
#>
