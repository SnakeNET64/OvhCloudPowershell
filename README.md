Objective : 
get rid of the OVH interface to create instance. I wanted a way to get some VMs available ondemand without too many clicks.

Work in progress.

This script is self explaining.
Example is provided at the end of the script.
Replace your credentials and put your Public key and... enjoy.


Installation : 
$modulePath = "$env:UserProfile\Documents\WindowsPowerShell\Modules\OvhCloud"
if (-Not (Test-Path $modulePath)) {
    New-Item -ItemType Directory -Path $modulePath
}

Invoke-WebRequest -Uri "https://github.com/SnakeNET64/OvhCloudPowershell/blob/main/OvhCloud.psm1" -OutFile "${$modulePath}\OvhCloud.psm1"



Utilisation : 
Import-Module "$modulePath\OvhCloud.psm1"
