﻿# ----------------------------------------------------------------------------
# Bootstrap a clean Windows-11 system for RStudio development.
#
# Run this from an Administrator PowerShell prompt after enabling scripts
# via 'Set-ExecutionPolicy Unrestricted -force'.
#
# See README.md for more details.
# ----------------------------------------------------------------------------

# Set to $false to keep downloads after installing; helpful for debugging script
$DeleteDownloads = $true

function Test-Administrator {
    [CmdletBinding()]
    $user = [Security.Principal.WindowsIdentity]::GetCurrent();
    (New-Object Security.Principal.WindowsPrincipal $user).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Invoke-DownloadFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$url,
        
        [Parameter(Mandatory = $true)]
        [string]$output
    )
    Write-Verbose "Downloading from $url to $output"
    try {
        Invoke-WebRequest -Uri $url -OutFile $output -ErrorAction Stop
        Write-Verbose "Download completed successfully"
    }
    catch {
        Write-Error "Download failed: $_"
    }
}

function Install-ChocoPackageIfMissing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$PackageName,
        
        [Parameter(Mandatory=$true)]
        [string]$TestCommand
    )
    
    if (!(Get-Command $TestCommand -ErrorAction SilentlyContinue)) {
        Write-Host "$TestCommand not found, installing $PackageName via chocolatey..."
        choco install -y $PackageName
    } else {
        Write-Host "$TestCommand already installed, skipping $PackageName installation"
    }
}

##############################################################################
# script execution starts here
##############################################################################
If (-Not (Test-Administrator)) {
    Write-Host "Error: Must run this script as Administrator"
    exit
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "Error: Requires PowerShell 5.0 or newer"
}

# install R
if (-Not (Test-Path -Path "C:\R")) {
    $RSetupPackage = "C:\R-3.6.3-win.exe"
    if (-Not (Test-Path -Path $RSetupPackage)) {
        Invoke-DownloadFile https://rstudio-buildtools.s3.amazonaws.com/R/R-3.6.3-win.exe $RSetupPackage -Verbose
    } else {
        Write-Host "Using previously downloaded R installer"
    }
    Write-Host "Installing R..."
    Start-Process $RSetupPackage -Wait -ArgumentList '/VERYSILENT /DIR="C:\R\R-3.6.3\"'
    if ($DeleteDownloads) { Remove-Item $RSetupPackage -Force }
    $env:path += ';C:\R\R-3.6.3\bin\i386\'
    [Environment]::SetEnvironmentVariable('Path', $env:path, [System.EnvironmentVariableTarget]::Machine);
} else {
    Write-Host "C:\R already exists, skipping R installation"
}

# install chocolatey
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
refreshenv

# install some deps via chocolatey
choco install -y cmake --installargs 'ADD_CMAKE_TO_PATH=""System""' --fail-on-error-output
refreshenv
choco install -y temurin11
choco install -y -i ant
choco install -y 7zip
choco install -y ninja
choco install -y nsis
choco install -y python313
choco install -y strawberryperl
choco install -y jq
Install-ChocoPackageIfMissing -PackageName "git" -TestCommand "git"

# install build tools
choco install -y windows-sdk-10.1 --version 10.1.18362.1 --force
choco install -y visualstudio2019buildtools --version 16.11.10.0 --force
choco install -y visualstudio2019-workload-vctools --version 1.0.1 --force

# cpack (an alias from chocolatey) and cmake's cpack conflict.
# Newer choco doesn't have this so don't fail if not found
$ChocoCPack = 'C:\ProgramData\chocolatey\bin\cpack.exe'
if (Test-Path $ChocoCPack) { Remove-Item -Force $ChocoCPack }

Write-Host "-----------------------------------------------------------"
Write-Host "Core dependencies successfully installed. Next steps:"
Write-Host "(1) Start a non-administrator Command Prompt"
Write-Host "(2) git clone https://github.com/rstudio/rstudio"
Write-Host "(3) change working dir to rstudio\dependencies\windows"
Write-Host "(4) install-dependencies.cmd"
Write-Host "-----------------------------------------------------------"
