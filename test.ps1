
<#
.SYNOPSIS
    Pobiera i aplikuje DriverPack do obrazu offline Windows.

.DESCRIPTION
    Skrypt:
      - wykrywa partycję z offline Windows,
      - wykrywa producenta i model komputera,
      - pobiera katalog DriverPacków OSDeploy,
      - dopasowuje odpowiedni DriverPack,
      - pobiera i weryfikuje pakiet,
      - rozpakowuje sterowniki,
      - dodaje sterowniki do obrazu offline przez DISM,
      - zapisuje przebieg działania do pliku logu.

    Skrypt nie korzysta z:
      - Microsoft.SMS.TSEnvironment,
      - Microsoft.SMS.TSProgressUI,
      - zmiennych Task Sequence,
      - modułu OSDCloud.

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

    Write-Log -Message 'Uruchomiono instalację DriverPack.'
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
            Write-Warning "Nie można zapisać do pliku logu: $($_.Exception.Message)"
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

    Write-Log -Message "Pobieranie: $Url"
    Write-Log -Message "Plik docelowy: $Destination"

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
            throw "curl.exe zakończył pracę kodem $LASTEXITCODE."
        }
    }
    else {
        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $Destination `
            -UseBasicParsing
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Nie pobrano pliku: $Destination"
    }

    $DownloadedFile = Get-Item -LiteralPath $Destination

    if ($DownloadedFile.Length -eq 0) {
        throw "Pobrany plik jest pusty: $Destination"
    }

    Write-Log -Message (
        'Pobrano plik. Rozmiar: {0:N2} MB' -f `
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

    throw 'Nie znaleziono partycji zawierającej offline Windows.'
}


function Get-HardwareData {
    Write-Log -Message 'Odczytywanie danych sprzętowych.'

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
            -Message 'Get-CimInstance niedostępny. Używam Get-WmiObject.' `
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
        throw 'Nie udało się ustalić identyfikatorów sprzętu.'
    }

    Write-Log -Message (
        'Identyfikatory sprzętu: ' + `
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
        "Liczba pakietów zgodnych ze sprzętem: $(@($Matches).Count)"
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
            "Liczba pakietów zgodnych z $OSVersion`: " +
            $OSMatches.Count
        )

        $Matches = $OSMatches
    }
    else {
        Write-Log `
            -Message "Nie znaleziono jednoznacznego wpisu dla $OSVersion. Używam najlepszego dopasowania sprzętowego." `
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
            -Message 'Brak sumy MD5 w katalogu DriverPack.' `
            -Level 'WARN'

        return
    }

    $ExpectedHash = ([string]$DriverPack.HashMD5).Trim().ToUpperInvariant()

    Write-Log -Message 'Sprawdzanie sumy MD5 pakietu.'

    $ActualHash = (
        Get-FileHash `
            -LiteralPath $PackageFile `
            -Algorithm MD5
    ).Hash.ToUpperInvariant()

    Write-Log -Message "Oczekiwana suma MD5: $ExpectedHash"
    Write-Log -Message "Obliczona suma MD5: $ActualHash"

    if ($ActualHash -ne $ExpectedHash) {
        throw (
            "Niepoprawna suma MD5. " +
            "Oczekiwano $ExpectedHash, otrzymano $ActualHash."
        )
    }

    Write-Log -Message 'Suma MD5 jest poprawna.'
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
        Write-Log -Message "Usuwanie starego katalogu: $ExtractPath"

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

    Write-Log -Message "Rozpakowywanie pakietu do: $ExtractPath"

    & $SevenZip `
        x `
        $PackageFile `
        "-o$ExtractPath" `
        -y

    $SevenZipExitCode = $LASTEXITCODE

    Write-Log -Message (
        "7-Zip zakończył pracę kodem $SevenZipExitCode."
    )

    if ($SevenZipExitCode -ne 0) {
        throw "7-Zip zakończył pracę kodem $SevenZipExitCode."
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
        throw 'Po rozpakowaniu nie znaleziono żadnych plików INF.'
    }

    Write-Log -Message (
        "Liczba znalezionych plików INF: $($InfFiles.Count)"
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
        throw 'Nie znaleziono programu dism.exe.'
    }

    Write-Log -Message (
        "Dodawanie sterowników do obrazu: $OfflineDrive"
    )

    Write-Log -Message (
        "Źródło sterowników: $DriverPath"
    )

    & dism.exe `
        "/Image:$OfflineDrive\" `
        '/Add-Driver' `
        "/Driver:$DriverPath" `
        '/Recurse'

    $DismExitCode = $LASTEXITCODE

    Write-Log -Message (
        "DISM zakończył pracę kodem $DismExitCode."
    )

    if (
        $DismExitCode -ne 0 -and
        $DismExitCode -ne 3010
    ) {
        throw "DISM zakończył pracę kodem $DismExitCode."
    }

    if ($DismExitCode -eq 3010) {
        Write-Log `
            -Message 'Sterowniki dodano poprawnie. Wymagany jest restart.' `
            -Level 'WARN'
    }
    else {
        Write-Log -Message 'Sterowniki dodano poprawnie.'
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
            -Message 'Pozostawiam pobrane i rozpakowane pliki.' `
            -Level 'INFO'

        return
    }

    Write-Log -Message 'Usuwanie plików tymczasowych.'

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

                Write-Log -Message "Usunięto: $Path"
            }
            catch {
                Write-Log `
                    -Message "Nie można usunąć $Path`: $($_.Exception.Message)" `
                    -Level 'WARN'
            }
        }
    }
}


try {
    Initialize-Logging

    Write-Log -Message "Katalog roboczy: $WorkDir"
    Write-Log -Message "Wybrany system: $OSVersion"

    $OfflineDrive = Find-OfflineWindows

    Write-Log -Message "Offline Windows: $OfflineDrive"

    $Hardware = Get-HardwareData

    Write-Log -Message "Producent: $($Hardware.Manufacturer)"
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

    Write-Log -Message 'Wczytywanie katalogu DriverPack.'

    try {
        $Catalog = Import-Clixml `
            -LiteralPath $CatalogFile `
            -ErrorAction Stop
    }
    catch {
        throw (
            "Nie można wczytać katalogu DriverPack: " +
            $_.Exception.Message
        )
    }

    if (-not $Catalog) {
        throw 'Pobrany katalog DriverPack jest pusty.'
    }

    Write-Log -Message (
        "Liczba wpisów w katalogu: $(@($Catalog).Count)"
    )

    $DriverPack = Find-DriverPack `
        -Catalog $Catalog `
        -Hardware $Hardware

    if (-not $DriverPack) {
        throw (
            "Nie znaleziono DriverPacka dla urządzenia: " +
            "$($Hardware.Manufacturer) $($Hardware.Model)."
        )
    }

    $DriverPackName = [string]$DriverPack.Name
    $DriverPackFileName = [string]$DriverPack.FileName
    $DriverPackUrl = [string]$DriverPack.Url

    if (-not $DriverPackUrl) {
        throw 'Wybrany wpis DriverPack nie zawiera adresu URL.'
    }

    if (-not $DriverPackFileName) {
        $DriverPackFileName = Split-Path `
            -Path $DriverPackUrl `
            -Leaf
    }

    if (-not $DriverPackFileName) {
        throw 'Nie można ustalić nazwy pliku DriverPack.'
    }

    Write-Log -Message "Wybrany DriverPack: $DriverPackName"
    Write-Log -Message "Nazwa pliku: $DriverPackFileName"
    Write-Log -Message "Adres URL: $DriverPackUrl"

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
        "Pakiet przygotowany do aplikowania. INF: $InfCount"
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
        "DriverPack został zastosowany poprawnie: $DriverPackName"
    )

    Write-Log -Message 'Skrypt zakończył pracę poprawnie.'

    exit 0
}
catch {
    $ErrorMessage = $_.Exception.Message

    Write-Log `
        -Message "BŁĄD: $ErrorMessage" `
        -Level 'ERROR'

    Write-Log `
        -Message "Szczegóły: $($_ | Out-String)" `
        -Level 'ERROR'

    exit 1
}
