<#
.Synopsis
  This module implements a tenant-focused catalog and database API over the Shard Management APIs. 
  It simplifies catalog management by presenting operations done to a tenant and tenant databases.
#>

Import-Module $PSScriptRoot\..\WtpConfig -Force
Import-Module $PSScriptRoot\AzureShardManagement -Force
Import-Module $PSScriptRoot\SubscriptionManagement -Force
Import-Module sqlserver -ErrorAction SilentlyContinue

# Stop execution on error
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
    Adds extended tenant meta data associated with a mapping using the raw value of the tenant key
#>
function Add-ExtendedTenantMetaDataToCatalog
{
    param(
        [parameter(Mandatory=$true)]
        [object]$Catalog,

        [parameter(Mandatory=$true)]
        [int32]$TenantKey,

        [parameter(Mandatory=$true)]
        [string]$TenantName
    )

    $config = Get-Configuration

    # Get the raw tenant key value used within the shard map
    $tenantRawKey = Get-TenantRawKey ($TenantKey)
    $rawkeyHexString = $tenantRawKey.RawKeyHexString


    # Add the tenant name into the Tenants table
    $commandText = "
        MERGE INTO Tenants as [target]
        USING (VALUES ($rawkeyHexString, '$TenantName')) AS source
            (TenantId, TenantName)
        ON target.TenantId = source.TenantId
        WHEN MATCHED THEN
            UPDATE SET TenantName = source.TenantName
        WHEN NOT MATCHED THEN
            INSERT (TenantId, TenantName)
            VALUES (source.TenantId, source.TenantName);"

    Invoke-SqlAzureWithRetry `
        -ServerInstance $Catalog.FullyQualifiedServerName `
        -Username $config.TenantAdminuserName `
        -Password $config.TenantAdminPassword `
        -Database $Catalog.Database.DatabaseName `
        -Query $commandText `
        -ConnectionTimeout 30 `
        -QueryTimeout 30 `
}



<#
.SYNOPSIS
    Registers a tenant database in the catalog, including adding the tenant name as extended tenant meta data. Idempotent
#>
function Add-TenantDatabaseToCatalog
{
    param(
        [parameter(Mandatory=$true)]
        [object]$Catalog,

        [parameter(Mandatory=$true)]
        [string]$TenantName,

        [parameter(Mandatory=$true)]
        [int32]$TenantKey,

        [parameter(Mandatory=$true)]
        [string]$TenantServerName,

        [parameter(Mandatory=$true)]
        [string]$TenantDatabaseName
    )

    $tenantServerFullyQualifiedName = $tenantServerName + ".database.windows.net"

    # Add the database to the catalog shard map (idempotent)
    Add-Shard -ShardMap $Catalog.ShardMap `
        -SqlServerName $tenantServerFullyQualifiedName `
        -SqlDatabaseName $tenantDatabaseName

    # Add the tenant-to-database mapping to the catalog (idempotent)
    Add-ListMapping `
        -KeyType $([int]) `
        -ListShardMap $Catalog.ShardMap `
        -SqlServerName $tenantServerFullyQualifiedName `
        -SqlDatabaseName $tenantDatabaseName `
        -ListPoint $TenantKey

    # Add the tenant name to the catalog as extended meta data (idempotent)
    Add-ExtendedTenantMetaDataToCatalog `
        -Catalog $Catalog `
        -TenantKey $TenantKey `
        -TenantName $TenantName
}

<#
.SYNOPSIS
    Initializes and returns a catalog object based on the catalog database created during deployment of the
    WTP application.  The catalog contains the initialized shard map manager and shard map, which can be used to access
    the associated databases (shards) and tenant key mappings.
#>
function Get-Catalog
{
    param (
        [parameter(Mandatory=$true)]
        [string]$ResourceGroupName,

        [parameter(Mandatory=$true)]
        [string]$WtpUser
    )
    $config = Get-Configuration

    $catalogServerName = $config.CatalogServerNameStem + $WtpUser
    $catalogServerFullyQualifiedName = $catalogServerName + ".database.windows.net"

    # Check catalog database exists
    $catalogDatabase = Get-AzureRmSqlDatabase `
        -ResourceGroupName $ResourceGroupName `
        -ServerName $catalogServerName `
        -DatabaseName $config.CatalogDatabaseName `
        -ErrorAction Stop

    # Initialize shard map manager from catalog database
    [Microsoft.Azure.SqlDatabase.ElasticScale.ShardManagement.ShardMapManager]$shardMapManager = Get-ShardMapManager `
        -SqlServerName $catalogServerFullyQualifiedName `
        -UserName $config.CatalogAdminUserName `
        -Password $config.CatalogAdminPassword `
        -SqlDatabaseName $config.CatalogDatabaseName

    if (!$shardmapManager)
    {
        throw "Failed to initialize shard map manager from '$($config.CatalogDatabaseName)' database. Ensure catalog is initialized by opening the Events app and try again."
    }

    # Initialize shard map
    [Microsoft.Azure.SqlDatabase.ElasticScale.ShardManagement.ShardMap]$shardMap = Get-ListShardMap `
        -KeyType $([int]) `
        -ShardMapManager $shardMapManager `
        -ListShardMapName $config.CatalogShardMapName

    If (!$shardMap)
    {
        #throw "Failed to load shard map '$($config.CatalogShardMapName)' from '$($config.CatalogDatabaseName)' database. Ensure catalog is initialized by opening the Events app and try again."
        
        [Microsoft.Azure.SqlDatabase.ElasticScale.ShardManagement.ShardMap]$shardMap = New-ListShardMap `
            -KeyType $([int]) `
            -ShardMapManager $shardMapManager `
            -ListShardMapName $config.CatalogShardMapName
    }

    $catalog = New-Object PSObject -Property @{
        ShardMapManager=$shardMapManager
        ShardMap=$shardMap
        FullyQualifiedServerName = $catalogServerFullyQualifiedName
        Database = $catalogDatabase
        }

    return $catalog

}


<#
.SYNOPSIS
  Validates and normalizes the name for use in creating the tenant key and database name. Removes spaces and sets to lowercase.
#>
function Get-NormalizedTenantName
{
    param
    (
        [parameter(Mandatory=$true)]
        [string]$TenantName
    )

    return $TenantName.Replace(' ','').ToLower()
}


<#
.SYNOPSIS
    Retrieves the server and database name for each database registered in the catalog.
#>
function Get-TenantDatabaseLocations
{
    param(
        [parameter(Mandatory=$true)]
        [object]$Catalog
    )
    # return all databases registered in the catalog shard map
    return Get-Shards -ShardMap $Catalog.ShardMap
}


<#
.SYNOPSIS
    Returns an integer tenant key from a normalized tenant name for use in the catalog.
#>
function Get-TenantKey
{
    param
    (
        # Tenant name 
        [parameter(Mandatory=$true)]
        [String]$TenantName
    )

    $normalizedTenantName = $TenantName.Replace(' ', '').ToLower()

    # Produce utf8 encoding of tenant name 
    $utf8 = New-Object System.Text.UTF8Encoding
    $tenantNameBytes = $utf8.GetBytes($normalizedTenantName)

    # Produce the md5 hash which reduces the size
    $md5 = new-object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
    $tenantHashBytes = $md5.ComputeHash($tenantNameBytes)

    # Convert to integer for use as the key in the catalog 
    $tenantKey = [bitconverter]::ToInt32($tenantHashBytes,0)

    return $tenantKey
}


<#
.SYNOPSIS
    Returns the raw key used within the shard map for the tenant  Returned as an object containing both the
    byte array and a text representation suitable for insert into SQL.
#>
function Get-TenantRawKey
{
    param
    (
        # Integer tenant key value
        [parameter(Mandatory=$true)]
        [int32]$TenantKey
    )

    # retrieve the byte array 'raw' key from the integer tenant key - the key value used in the catalog database.
    $shardKey = New-Object Microsoft.Azure.SqlDatabase.ElasticScale.ShardManagement.ShardKey($TenantKey)
    $rawValueBytes = $shardKey.RawValue

    # convert the raw key value to text for insert into the database
    $rawValueString = [BitConverter]::ToString($rawValueBytes)
    $rawValueString = "0x" + $rawValueString.Replace("-", "")

    $tenantRawKey = New-Object PSObject -Property @{
        RawKeyBytes = $shardKeyRawValueBytes
        RawKeyHexString = $rawValueString
    }

    return $tenantRawKey
}


<#
.SYNOPSIS
    Initializes a catalog by adding the tenantcatalog shardmap and returns a catalog object based on the catalog database created during deployment of the
    WTP application.  The catalog contains the initialized shard map manager and shard map, which can be used to access
    the associated databases (shards) and tenant key mappings.
#>
function Initialize-Catalog
{
    param (
        [parameter(Mandatory=$true)]
        [string]$ResourceGroupName,

        [parameter(Mandatory=$true)]
        [string]$WtpUser
    )
    $config = Get-Configuration

    $catalogServerName = $config.CatalogServerNameStem + $WtpUser
    $catalogServerFullyQualifiedName = $catalogServerName + ".database.windows.net"

    # Check catalog database exists
    $catalogDatabase = Get-AzureRmSqlDatabase `
        -ResourceGroupName $ResourceGroupName `
        -ServerName $catalogServerName `
        -DatabaseName $config.CatalogDatabaseName `
        -ErrorAction Stop

    # Initialize shard map manager from catalog database
    [Microsoft.Azure.SqlDatabase.ElasticScale.ShardManagement.ShardMapManager]$shardMapManager = Get-ShardMapManager `
        -SqlServerName $catalogServerFullyQualifiedName `
        -UserName $config.CatalogAdminUserName `
        -Password $config.CatalogAdminPassword `
        -SqlDatabaseName $config.CatalogDatabaseName

    if (!$shardmapManager)
    {
        throw "Failed to initialize shard map manager from '$($config.CatalogDatabaseName)' database. Ensure catalog is initialized by opening the Events app and try again."
    }

    # Initialize shard map
    [Microsoft.Azure.SqlDatabase.ElasticScale.ShardManagement.ShardMap]$shardMap = Get-ListShardMap `
        -KeyType $([int]) `
        -ShardMapManager $shardMapManager `
        -ListShardMapName $config.CatalogShardMapName

    If (!$shardMap)
    {
        throw "Failed to load shard map '$($config.CatalogShardMapName)' from '$($config.CatalogDatabaseName)' database. Ensure catalog is initialized by opening the Events app and try again."
    }
    else
    {
        $catalog = New-Object PSObject -Property @{
            ShardMapManager=$shardMapManager
            ShardMap=$shardMap
            FullyQualifiedServerName = $catalogServerFullyQualifiedName
            Database = $catalogDatabase
            }

        return $catalog
    }
}

<#
.SYNOPSIS
    Initializes the Venue name and other Venue properties in the database and resets event dates on the
    default events.
#>
function Initialize-TenantDatabase
{
    param(
        [parameter(Mandatory=$true)]
        [string]$ServerName,

        [parameter(Mandatory=$true)]
        [string]$DatabaseName,

        [parameter(Mandatory=$true)]
        [int]$TenantKey,

        [parameter(Mandatory=$true)]
        [string]$TenantName,

        [parameter(Mandatory=$false)]
        [string]$VenueType,

        [parameter(Mandatory=$false)]
        [string]$PostalCode = "98052",

        [parameter(Mandatory=$false)]
        [string]$CountryCode = "USA"

    )

    if ($PostalCode.Length -eq 0) {$PostalCode = "98052"}
    if ($CountryCode.Length -eq 0) {$CountryCode = "USA"}

    $config = Get-Configuration

    if (!$VenueType) {$VenueType = $config.DefaultVenueType}

    # Initialize tenant info in the tenant database (idempotent)
    $emaildomain = (Get-NormalizedTenantName $TenantName)

    if ($emailDomain.Length -gt 40) 
    {
        $emailDomain = $emailDomain.Substring(0,40)
    }

    $VenueAdminEmail = "admin@" + $emailDomain + ".com"

    $commandText = "
        DELETE FROM Venue
        INSERT INTO Venue
            (VenueId, VenueName, VenueType, AdminEmail, PostalCode, CountryCode, Lock  )
        VALUES
            ($TenantKey,'$TenantName', '$VenueType','$VenueAdminEmail', '$PostalCode', '$CountryCode', 'X');
        -- reset event dates for initial default events (these exist and this reset of their dates is done for demo purposes only) 
        EXEC sp_ResetEventDates;"

    Invoke-SqlAzureWithRetry `
        -ServerInstance ($ServerName + ".database.windows.net") `
        -Username $config.TenantAdminuserName `
        -Password $config.TenantAdminPassword `
        -Database $DatabaseName `
        -Query $commandText `

}



<#
.SYNOPSIS
    Invokes a SQL command. Uses ADO.NET not Invoke-SqlCmd. Always uses an encrypted connection.
#>
function Invoke-SqlAzure{
    param
    (
        [Parameter(Mandatory=$true)]
        [string] $ServerInstance,

        [Parameter(Mandatory=$false)]
        [string] $DatabaseName,

        [Parameter(Mandatory=$true)]
        [string] $Query,

        [Parameter(Mandatory=$true)]
        [string] $UserName,

        [Parameter(Mandatory=$true)]
        [string] $Password,

        [Parameter(Mandatory=$false)]
        [int] $ConnectionTimeout = 30,
        
        [Parameter(Mandatory=$false)]
        [int] $QueryTimeout = 60
      )
    $Query = $Query.Trim()

    $connectionString = `
        "Data Source=$ServerInstance;Initial Catalog=$DatabaseName;Connection Timeout=$ConnectionTimeOut;User ID=$UserName;Password=$Password;Encrypt=true;"

    $connection = new-object system.data.SqlClient.SQLConnection($connectionString)
    $command = new-object system.data.sqlclient.sqlcommand($Query,$connection)
    $command.CommandTimeout = $QueryTimeout

    $connection.Open()

    $reader = $command.ExecuteReader()
    
    $results = @()

    while ($reader.Read())
    {
        $row = @{}
        
        for ($i=0;$i -lt $reader.FieldCount; $i++)
        {
           $row[$reader.GetName($i)]=$reader.GetValue($i)
        }
        $results += New-Object psobject -Property $row
    }
     
    $connection.Close()
    $connection.Dispose()
    
    return $results  
}


<#
.SYNOPSIS
    Wraps Invoke-SqlAzure. Retries on any error with exponential back-off policy.  
    Assumes query is idempotent.  Always uses an encrypted connection.  
#>
function Invoke-SqlAzureWithRetry{
    param(
        [parameter(Mandatory=$true)]
        [string]$DatabaseName,

        [parameter(Mandatory=$true)]
        [string]$ServerInstance,

        [parameter(Mandatory=$true)]
        [string]$Query,

        [parameter(Mandatory=$true)]
        [string]$UserName,

        [parameter(Mandatory=$true)]
        [string]$Password,

        [string]$ConnectionTimeout = 30,

        [int]$QueryTimeout = 30
    )

    $tries = 1
    $limit = 5
    $interval = 2
    do  
    {
        try
        {
            return Invoke-SqlAzure `
                        -ServerInstance $ServerInstance `
                        -Database $DatabaseName `
                        -Query $Query `
                        -Username $UserName `
                        -Password $Password `
                        -ConnectionTimeout $ConnectionTimeout `
                        -QueryTimeout $QueryTimeout `
        }
        catch
        {
                    if ($tries -ge $limit)
                    {
                        throw $_.Exception.Message
                    }                                       
                    Start-Sleep ($interval)
                    $interval += $interval
                    $tries += 1                                      
        }
    }while (1 -eq 1)
}


<#
.SYNOPSIS
    Wraps Invoke-SqlCmd.  Retries on any error with exponential back-off policy.  
    Assumes query is idempotent. Always uses an encrypted connection.
#>
function Invoke-SqlCmdWithRetry{
    param(
        [parameter(Mandatory=$true)]
        [string]$DatabaseName,

        [parameter(Mandatory=$true)]
        [string]$ServerInstance,

        [parameter(Mandatory=$true)]
        [string]$Query,

        [parameter(Mandatory=$true)]
        [string]$UserName,

        [parameter(Mandatory=$true)]
        [string]$Password,

        [string]$ConnectionTimeout = 30,

        [int]$QueryTimeout = 30
    )

    $tries = 1
    $limit = 5
    $interval = 2
    do  
    {
        try
        {
            return Invoke-Sqlcmd `
                        -ServerInstance $ServerInstance `
                        -Database $DatabaseName `
                        -Query $Query `
                        -Username $UserName `
                        -Password $Password `
                        -ConnectionTimeout $ConnectionTimeout `
                        -QueryTimeout $QueryTimeout `
                        -EncryptConnection
        }
        catch
        {
                    if ($tries -ge $limit)
                    {
                        throw $_.Exception.Message
                    }                                       
                    Start-Sleep ($interval)
                    $interval += $interval
                    $tries += 1                                      
        }

    }while (1 -eq 1)
}


<#
.SYNOPSIS
    Tests that a specified database has been deployed
#>
function Test-DatabaseExists
{
    param(
        [parameter(Mandatory=$true)]
        [string]$ServerName,

        [parameter(Mandatory=$true)]
        [string] $DatabaseName
    )

    $catalogServer = Find-AzureRmResource -ResourceType microsoft.sql/servers -ResourceNameEquals $ServerName

    if (!$catalogServer) {return $false}

    $catalogDatabase = Get-AzureRmSqlDatabase `
        -ResourceGroupName $catalogServer.ResourceGroupName `
        -ServerName $ServerName `
        -DatabaseName $DatabaseName
    
    if(!$catalogDatabase) {return $false}

    $sqlCommand = "SELECT Count(VenueId) AS Value FROM Venue"
    
    $FullyQualifiedServerName = $ServerName + ".database.windows.net"

    $count = Invoke-SqlCmd `
        -ServerInstance $FullyQualifiedServerName `
        -Database $DatabaseName `
        -Query $sqlCommand `
        -UserName $config.TenantAdminUserName `
        -Password $config.TenantAdminPassword `
        -ErrorAction SilentlyContinue
    
    if ($count.Value -eq 1)
    {
        return $true
    } 
    else 
    {
        return $false
    }

}

<#
.SYNOPSIS
    Tests if a tenant key is registered. Returns true if the key exists in the catalog (whether online or offline) or false if it does not.
#>
function Test-TenantKeyInCatalog
{
    param(
        [parameter(Mandatory=$true)]
        [object]$Catalog,

        [parameter(Mandatory=$true)]
        [int32] $TenantKey
    )

    try
    {
        ($Catalog.ShardMap).GetMappingForKey($tenantKey) > $null
        return $true
    }
    catch
    {
        return $false
    }
}


<#
.SYNOPSIS
    Validates a name contains only legal characters
#>
function Test-LegalName
{
    param(
        [parameter(Mandatory=$true)]
        [ValidateScript(
        {
            if ($_ -match '^[A-Za-z0-9][A-Za-z0-9 \-_]*[^\s+]$') 
            {
                $true
            } 
            else 
            {
                throw "'$_' is not an allowed name.  Use a-z, A-Z, 0-9, ' ', '-', or '_'.  Must start with a letter or number and have no trailing spaces."
            }
         }
         )]
        [string]$Input
    )
    return $true
}


<#
.SYNOPSIS
    Validates a name fragment contains only legal characters
#>
function Test-LegalNameFragment
{
    param(
        [parameter(Mandatory=$true)]
        [ValidateScript(
        {
            if ($_ -match '^[A-Za-z0-9 \-_][A-Za-z0-9 \-_]*$') 
            {
                return $true
            } 
            else 
            {
                throw "'$_' is invalid.  Names can only include a-z, A-Z, 0-9, space, hyphen or underscore."
            }
         }
         )]
        [string]$Input
    )
}


<#
.SYNOPSIS
    Validates a venue type name contains only legal characters
#>
function Test-LegalVenueTypeName
{
    param(
        [parameter(Mandatory=$true)]
        [ValidateScript(
        {
            if ($_ -match '^[A-Za-z][A-Za-z]*$') 
            {
                return $true
            } 
            else 
            {
                throw "'$_' is invalid.  Venue type names can only include a-z, A-Z."
            }
         }
         )]
        [string]$Input
    )
}


<#
.SYNOPSIS
    Validates that a venue type is a supported venue type (validated against the  
    golden tenant database on the catalog server)
#>
function Test-ValidVenueType
{
    param(
        [parameter(Mandatory=$true)]
        [string]$VenueType,

        [parameter(Mandatory=$true)]
        [object]$Catalog
    )
    $config = Get-Configuration

    $commandText = "
        SELECT Count(VenueType) AS Count FROM [dbo].[VenueTypes]
        WHERE VenueType = '$VenueType'"

    $results = Invoke-SqlAzureWithRetry `
                    -ServerInstance $Catalog.FullyQualifiedServerName `
                    -Username $config.CatalogAdminuserName `
                    -Password $config.CatalogAdminPassword `
                    -Database $config.GoldenTenantDatabaseName `
                    -Query $commandText

    if($results.Count -ne 1)
    {
        throw "Error: '$VenueType' is not a supported venue type."
    }

    return $true
}