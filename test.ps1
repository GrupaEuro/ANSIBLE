<#
.SYNOPSIS
    Downloads and applies a DriverPack to an offline Windows image.

.DESCRIPTION
    The script:
      - detects the offline Windows partition,
      - detects the computer manufacturer and model,
      - downloads the OSDeploy DriverPack catalog,
      - matches the correct DriverPack,
      - downloads and verifies the package,
      - extracts the drivers,
      - adds the drivers to the offline image using DISM,
      - writes execution details to a log file.

    The script does not use:
      - Microsoft.SMS.TSEnvironment,
      - Microsoft.SMS.TSProgressUI,
      - Task Sequence variables,
      - the OSDCloud module.

.EXAMPLE
    PowerShell.exe -NoProfile -ExecutionPolicy Bypass `
        -File ".\Install-DriverPack.ps1" `
        -OSVersion "Windows 11"

.EXAMPLE
    PowerShell.exe -NoProfile -ExecutionPolicy Bypass `
        -File ".\Install-DriverPack.ps1" `
        -OSDrive "C:" `
        -OSVersion "Windows 11" `
        -KeepFiles
#>

[CmdletBinding()]
param(
    [string]$OSDrive,

    [ValidateSet('Windows 10', 'Windows 11')]
    [string]$OSVersion = 'Windows 11',

    [string]$Product,

    [string]$WorkDir = 'X:\DriverPack',

    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$CatalogUrl = 'https://raw.githubusercontent.com/OSDeploy/OSD/master/cache/driverpack-catalogs/build-driverpacks.xml'
$SevenZipUrl = 'https://www.7-zip.org/a/7zr.exe'

$script:LogFile = $null


function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
    }

    $script:LogFile = Join-Path $WorkDir 'DriverPack.log'

    if (Test-Path -LiteralPath $script:LogFile) {
        Remove-Item -LiteralPath $script:LogFile -Force
    }

    Write-Log -Message 'DriverPack installation started.'
}


function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $Line = '{0} [{1}] {2}' -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
        $Level, `
        $Message

    Write-Host $Line

    if ($script:LogFile) {
        try {
            Add-Content `
                -LiteralPath $script:LogFile `
                -Value $Line `
                -Encoding UTF8
        }
        catch {
            Write-Warning "Unable to write to the log file: $($_.Exception.Message)"
        }
    }
}


function Download-File {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    Write-Log -Message "Downloading: $Url"
    Write-Log -Message "Destination file: $Destination"

    $DestinationDirectory = Split-Path -Path $Destination -Parent

    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        New-Item `
            -Path $DestinationDirectory `
            -ItemType Directory `
            -Force |
            Out-Null
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12

    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe `
            -L `
            --fail `
            --retry 3 `
            --connect-timeout 30 `
            --output $Destination `
            $Url

        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe exited with code $LASTEXITCODE."
        }
    }
    else {
        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $Destination `
            -UseBasicParsing
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "File was not downloaded: $Destination"
    }

    $DownloadedFile = Get-Item -LiteralPath $Destination

    if ($DownloadedFile.Length -eq 0) {
        throw "Downloaded file is empty: $Destination"
    }

    Write-Log -Message (
        'File downloaded. Size: {0:N2} MB' -f `
        ($DownloadedFile.Length / 1MB)
    )
}


function Find-OfflineWindows {
    $Candidates = @()

    if ($OSDrive) {
        $Candidates += $OSDrive
    }

    $Candidates += @(
        'C:',
        'D:',
        'E:',
        'F:',
        'G:',
        'H:',
        'I:',
        'J:'
    )

    foreach ($Candidate in $Candidates) {
        if (-not $Candidate) {
            continue
        }

        $Drive = ([string]$Candidate).Trim().TrimEnd('\')

        if ($Drive -match '^[A-Za-z]$') {
            $Drive = "$Drive`:"
        }

        $SystemHive = Join-Path `
            $Drive `
            'Windows\System32\Config\SYSTEM'

        if (Test-Path -LiteralPath $SystemHive) {
            return $Drive.ToUpper()
        }
    }

    throw 'No offline Windows partition was found.'
}


function Get-HardwareData {
    Write-Log -Message 'Reading hardware information.'

    try {
        $ComputerSystem = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop

        $ComputerProduct = Get-CimInstance `
            -ClassName Win32_ComputerSystemProduct `
            -ErrorAction Stop

        $Enclosure = Get-CimInstance `
            -ClassName Win32_SystemEnclosure `
            -ErrorAction Stop
    }
    catch {
        Write-Log `
            -Message 'Get-CimInstance is unavailable. Falling back to Get-WmiObject.' `
            -Level 'WARN'

        $ComputerSystem = Get-WmiObject `
            -Class Win32_ComputerSystem `
            -ErrorAction Stop

        $ComputerProduct = Get-WmiObject `
            -Class Win32_ComputerSystemProduct `
            -ErrorAction Stop

        $Enclosure = Get-WmiObject `
            -Class Win32_SystemEnclosure `
            -ErrorAction Stop
    }

    [pscustomobject]@{
        Manufacturer      = [string]$ComputerSystem.Manufacturer
        Model             = [string]$ComputerSystem.Model
        SystemSKU         = [string]$ComputerSystem.SystemSKUNumber
        ProductName       = [string]$ComputerProduct.Name
        ProductVersion    = [string]$ComputerProduct.Version
        IdentifyingNumber = [string]$ComputerProduct.IdentifyingNumber
        ChassisSKU        = [string]$Enclosure.SKU
    }
}


function Get-PackProductValues {
    param(
        [Parameter(Mandatory)]
        $Pack
    )

    $Values = @()

    if ($null -ne $Pack.Product) {
        foreach ($Item in @($Pack.Product)) {
            if ($null -ne $Item) {
                $Value = ([string]$Item).Trim()

                if ($Value) {
                    $Values += $Value
                }
            }
        }
    }

    foreach ($PropertyName in @(
        'Model',
        'SystemId',
        'SystemSKU'
    )) {
        if ($Pack.PSObject.Properties.Name -contains $PropertyName) {
            $Value = ([string]$Pack.$PropertyName).Trim()

            if ($Value) {
                $Values += $Value
            }
        }
    }

    $Values |
        Where-Object { $_ } |
        Select-Object -Unique
}


function Find-DriverPack {
    param(
        [Parameter(Mandatory)]
        $Catalog,

        [Parameter(Mandatory)]
        $Hardware
    )

    $Identifiers = @(
        $Product,
        $Hardware.SystemSKU,
        $Hardware.ProductVersion,
        $Hardware.ProductName,
        $Hardware.IdentifyingNumber,
        $Hardware.ChassisSKU,
        $Hardware.Model
    ) |
        Where-Object { $_ } |
        ForEach-Object { ([string]$_).Trim() } |
        Select-Object -Unique

    if (-not $Identifiers) {
        throw 'Unable to determine hardware identifiers.'
    }

    Write-Log -Message (
        'Hardware identifiers: ' + `
        ($Identifiers -join ' | ')
    )

    $Matches = foreach ($Pack in @($Catalog)) {
        $PackValues = Get-PackProductValues -Pack $Pack
        $IsMatch = $false

        foreach ($Identifier in $Identifiers) {
            foreach ($PackValue in $PackValues) {
                if (
                    [string]::Equals(
                        $PackValue,
                        $Identifier,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    $IsMatch = $true
                    break
                }
            }

            if ($IsMatch) {
                break
            }
        }

        if ($IsMatch) {
            $Pack
        }
    }

    if (-not $Matches) {
        return $null
    }

    Write-Log -Message (
        "Number of hardware-matching packages: $(@($Matches).Count)"
    )

    $OSMatches = @(
        $Matches |
            Where-Object {
                (
                    [string]$_.OS -match `
                    [regex]::Escape($OSVersion)
                ) -or (
                    [string]$_.OperatingSystem -match `
                    [regex]::Escape($OSVersion)
                )
            }
    )

    if ($OSMatches.Count -gt 0) {
        Write-Log -Message (
            "Number of packages matching $OSVersion`: " +
            $OSMatches.Count
        )

        $Matches = $OSMatches
    }
    else {
        Write-Log `
            -Message "No exact operating system match was found for $OSVersion. Using the best hardware match." `
            -Level 'WARN'
    }

    $Matches |
        Sort-Object `
            -Property @{
                Expression = {
                    try {
                        [datetime]$_.ReleaseDate
                    }
                    catch {
                        [datetime]::MinValue
                    }
                }
                Descending = $true
            }, @{
                Expression = { [string]$_.Name }
                Descending = $true
            } |
        Select-Object -First 1
}


function Test-DriverPackHash {
    param(
        [Parameter(Mandatory)]
        $DriverPack,

        [Parameter(Mandatory)]
        [string]$PackageFile
    )

    if (-not $DriverPack.HashMD5) {
        Write-Log `
            -Message 'The DriverPack catalog does not contain an MD5 hash for this package.' `
            -Level 'WARN'

        return
    }

    $ExpectedHash = ([string]$DriverPack.HashMD5).Trim().ToUpperInvariant()

    Write-Log -Message 'Verifying package MD5 hash.'

    $ActualHash = (
        Get-FileHash `
            -LiteralPath $PackageFile `
            -Algorithm MD5
    ).Hash.ToUpperInvariant()

    Write-Log -Message "Expected MD5: $ExpectedHash"
    Write-Log -Message "Calculated MD5: $ActualHash"

    if ($ActualHash -ne $ExpectedHash) {
        throw (
            "Invalid MD5 hash. " +
            "Expected $ExpectedHash, received $ActualHash."
        )
    }

    Write-Log -Message 'The MD5 hash is valid.'
}


function Expand-DriverPack {
    param(
        [Parameter(Mandatory)]
        [string]$PackageFile,

        [Parameter(Mandatory)]
        [string]$ExtractPath,

        [Parameter(Mandatory)]
        [string]$SevenZip
    )

    if (Test-Path -LiteralPath $ExtractPath) {
        Write-Log -Message "Removing existing extraction directory: $ExtractPath"

        Remove-Item `
            -LiteralPath $ExtractPath `
            -Recurse `
            -Force
    }

    New-Item `
        -Path $ExtractPath `
        -ItemType Directory `
        -Force |
        Out-Null

    Write-Log -Message "Extracting package to: $ExtractPath"

    & $SevenZip `
        x `
        $PackageFile `
        "-o$ExtractPath" `
        -y

    $SevenZipExitCode = $LASTEXITCODE

    Write-Log -Message (
        "7-Zip exited with code $SevenZipExitCode."
    )

    if ($SevenZipExitCode -ne 0) {
        throw "7-Zip exited with code $SevenZipExitCode."
    }

    $InfFiles = @(
        Get-ChildItem `
            -LiteralPath $ExtractPath `
            -Filter '*.inf' `
            -Recurse `
            -File `
            -ErrorAction SilentlyContinue
    )

    if ($InfFiles.Count -eq 0) {
        throw 'No INF files were found after extraction.'
    }

    Write-Log -Message (
        "Number of INF files found: $($InfFiles.Count)"
    )

    return $InfFiles.Count
}


function Add-OfflineDrivers {
    param(
        [Parameter(Mandatory)]
        [string]$OfflineDrive,

        [Parameter(Mandatory)]
        [string]$DriverPath
    )

    if (-not (Get-Command dism.exe -ErrorAction SilentlyContinue)) {
        throw 'dism.exe was not found.'
    }

    Write-Log -Message (
        "Adding drivers to offline image: $OfflineDrive"
    )

    Write-Log -Message (
        "Driver source: $DriverPath"
    )

    & dism.exe `
        "/Image:$OfflineDrive\" `
        '/Add-Driver' `
        "/Driver:$DriverPath" `
        '/Recurse'

    $DismExitCode = $LASTEXITCODE

    Write-Log -Message (
        "DISM exited with code $DismExitCode."
    )

    if (
        $DismExitCode -ne 0 -and
        $DismExitCode -ne 3010
    ) {
        throw "DISM exited with code $DismExitCode."
    }

    if ($DismExitCode -eq 3010) {
        Write-Log `
            -Message 'Drivers were added successfully. A restart is required.' `
            -Level 'WARN'
    }
    else {
        Write-Log -Message 'Drivers were added successfully.'
    }
}


function Remove-TemporaryFiles {
    param(
        [string]$ExtractPath,
        [string]$PackageFile,
        [string]$SevenZip,
        [string]$CatalogFile
    )

    if ($KeepFiles) {
        Write-Log `
            -Message 'Downloaded and extracted files will be kept.' `
            -Level 'INFO'

        return
    }

    Write-Log -Message 'Removing temporary files.'

    foreach ($Path in @(
        $ExtractPath,
        $PackageFile,
        $SevenZip,
        $CatalogFile
    )) {
        if (
            $Path -and
            (Test-Path -LiteralPath $Path)
        ) {
            try {
                Remove-Item `
                    -LiteralPath $Path `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop

                Write-Log -Message "Removed: $Path"
            }
            catch {
                Write-Log `
                    -Message "Unable to remove $Path`: $($_.Exception.Message)" `
                    -Level 'WARN'
            }
        }
    }
}


try {
    Initialize-Logging

    Write-Log -Message "Working directory: $WorkDir"
    Write-Log -Message "Selected operating system: $OSVersion"

    $OfflineDrive = Find-OfflineWindows

    Write-Log -Message "Offline Windows drive: $OfflineDrive"

    $Hardware = Get-HardwareData

    Write-Log -Message "Manufacturer: $($Hardware.Manufacturer)"
    Write-Log -Message "Model: $($Hardware.Model)"
    Write-Log -Message "System SKU: $($Hardware.SystemSKU)"
    Write-Log -Message "Product Name: $($Hardware.ProductName)"
    Write-Log -Message "Product Version: $($Hardware.ProductVersion)"
    Write-Log -Message (
        "Identifying Number: $($Hardware.IdentifyingNumber)"
    )
    Write-Log -Message "Chassis SKU: $($Hardware.ChassisSKU)"

    $CatalogFile = Join-Path `
        $WorkDir `
        'build-driverpacks.xml'

    Download-File `
        -Url $CatalogUrl `
        -Destination $CatalogFile

    Write-Log -Message 'Loading the DriverPack catalog.'

    try {
        $Catalog = Import-Clixml `
            -LiteralPath $CatalogFile `
            -ErrorAction Stop
    }
    catch {
        throw (
            "Unable to load the DriverPack catalog: " +
            $_.Exception.Message
        )
    }

    if (-not $Catalog) {
        throw 'The downloaded DriverPack catalog is empty.'
    }

    Write-Log -Message (
        "Number of catalog entries: $(@($Catalog).Count)"
    )

    $DriverPack = Find-DriverPack `
        -Catalog $Catalog `
        -Hardware $Hardware

    if (-not $DriverPack) {
        throw (
            "No DriverPack was found for device: " +
            "$($Hardware.Manufacturer) $($Hardware.Model)."
        )
    }

    $DriverPackName = [string]$DriverPack.Name
    $DriverPackFileName = [string]$DriverPack.FileName
    $DriverPackUrl = [string]$DriverPack.Url

    if (-not $DriverPackUrl) {
        throw 'The selected DriverPack entry does not contain a URL.'
    }

    if (-not $DriverPackFileName) {
        $DriverPackFileName = Split-Path `
            -Path $DriverPackUrl `
            -Leaf
    }

    if (-not $DriverPackFileName) {
        throw 'Unable to determine the DriverPack file name.'
    }

    Write-Log -Message "Selected DriverPack: $DriverPackName"
    Write-Log -Message "File name: $DriverPackFileName"
    Write-Log -Message "URL: $DriverPackUrl"

    $PackageFile = Join-Path `
        $WorkDir `
        $DriverPackFileName

    Download-File `
        -Url $DriverPackUrl `
        -Destination $PackageFile

    Test-DriverPackHash `
        -DriverPack $DriverPack `
        -PackageFile $PackageFile

    $SevenZip = Join-Path `
        $WorkDir `
        '7zr.exe'

    Download-File `
        -Url $SevenZipUrl `
        -Destination $SevenZip

    $ExtractPath = Join-Path `
        $WorkDir `
        'Extracted'

    $InfCount = Expand-DriverPack `
        -PackageFile $PackageFile `
        -ExtractPath $ExtractPath `
        -SevenZip $SevenZip

    Write-Log -Message (
        "Package is ready to be applied. INF files: $InfCount"
    )

    Add-OfflineDrivers `
        -OfflineDrive $OfflineDrive `
        -DriverPath $ExtractPath

    Remove-TemporaryFiles `
        -ExtractPath $ExtractPath `
        -PackageFile $PackageFile `
        -SevenZip $SevenZip `
        -CatalogFile $CatalogFile

    Write-Log -Message (
        "DriverPack was applied successfully: $DriverPackName"
    )

    Write-Log -Message 'The script completed successfully.'

    exit 0
}
catch {
    $ErrorMessage = $_.Exception.Message

    Write-Log `
        -Message "ERROR: $ErrorMessage" `
        -Level 'ERROR'

    Write-Log `
        -Message "Details: $($_ | Out-String)" `
        -Level 'ERROR'

    exit 1
}
