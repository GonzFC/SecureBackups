<#
.SYNOPSIS
    Machine-independent encryption utilities for VLABS Resilience Ring

.DESCRIPTION
    Provides AES encryption using the Windows Machine GUID as a key derivation seed.
    This allows credentials to be decrypted by any user on the same machine,
    including SYSTEM (used by Scheduled Tasks).

.NOTES
    The Machine GUID is unique per Windows installation and persists across reboots.
    It's stored in: HKLM:\SOFTWARE\Microsoft\Cryptography\MachineGuid
#>

#region Machine Key Derivation

function Get-MachineKey {
    <#
    .SYNOPSIS
        Derives a 256-bit AES key from the Windows Machine GUID
    #>
    try {
        # Get Machine GUID from registry
        $machineGuid = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -ErrorAction Stop).MachineGuid
        
        # Add a salt for additional security
        $salt = "VLABS_ResilienceRing_2024"
        $combined = "$machineGuid|$salt"
        
        # Derive a 256-bit key using SHA256
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $keyBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combined))
        $sha256.Dispose()
        
        return $keyBytes
    }
    catch {
        Write-Error "Failed to derive machine key: $_"
        return $null
    }
}

#endregion

#region AES Encryption

function ConvertTo-AesEncryptedString {
    <#
    .SYNOPSIS
        Encrypts a string using AES with machine-derived key
    .PARAMETER PlainText
        The string to encrypt
    .OUTPUTS
        Base64-encoded encrypted string with IV prefix
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$PlainText
    )
    
    try {
        $key = Get-MachineKey
        if ($null -eq $key) {
            throw "Could not derive machine key"
        }
        
        # Create AES provider
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.GenerateIV()
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        
        # Encrypt
        $encryptor = $aes.CreateEncryptor()
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $encryptedBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
        
        # Combine IV + encrypted data
        $combined = New-Object byte[] ($aes.IV.Length + $encryptedBytes.Length)
        [Array]::Copy($aes.IV, 0, $combined, 0, $aes.IV.Length)
        [Array]::Copy($encryptedBytes, 0, $combined, $aes.IV.Length, $encryptedBytes.Length)
        
        # Cleanup
        $encryptor.Dispose()
        $aes.Dispose()
        
        # Return as Base64 with prefix for identification
        return "AES:" + [Convert]::ToBase64String($combined)
    }
    catch {
        Write-Error "AES encryption failed: $_"
        return $null
    }
}

function ConvertFrom-AesEncryptedString {
    <#
    .SYNOPSIS
        Decrypts an AES-encrypted string using machine-derived key
    .PARAMETER EncryptedText
        Base64-encoded encrypted string (with or without AES: prefix)
    .OUTPUTS
        Decrypted plain text string
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$EncryptedText
    )
    
    try {
        # Remove AES: prefix if present
        if ($EncryptedText.StartsWith("AES:")) {
            $EncryptedText = $EncryptedText.Substring(4)
        }
        
        $key = Get-MachineKey
        if ($null -eq $key) {
            throw "Could not derive machine key"
        }
        
        # Decode from Base64
        $combined = [Convert]::FromBase64String($EncryptedText)
        
        # Extract IV (first 16 bytes) and encrypted data
        $iv = New-Object byte[] 16
        $encryptedBytes = New-Object byte[] ($combined.Length - 16)
        [Array]::Copy($combined, 0, $iv, 0, 16)
        [Array]::Copy($combined, 16, $encryptedBytes, 0, $encryptedBytes.Length)
        
        # Create AES provider
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        
        # Decrypt
        $decryptor = $aes.CreateDecryptor()
        $plainBytes = $decryptor.TransformFinalBlock($encryptedBytes, 0, $encryptedBytes.Length)
        
        # Cleanup
        $decryptor.Dispose()
        $aes.Dispose()
        
        return [System.Text.Encoding]::UTF8.GetString($plainBytes)
    }
    catch {
        # Return null on failure - caller should handle fallback to DPAPI
        return $null
    }
}

#endregion

#region Hybrid Encryption (AES with DPAPI fallback)

function Protect-Password {
    <#
    .SYNOPSIS
        Encrypts a password using AES (machine-independent)
    .DESCRIPTION
        Always uses AES encryption for new passwords.
        This ensures any user/service on the machine can decrypt.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$PlainTextPassword
    )
    
    return ConvertTo-AesEncryptedString -PlainText $PlainTextPassword
}

function Unprotect-Password {
    <#
    .SYNOPSIS
        Decrypts a password, trying AES first, then DPAPI for legacy support
    .DESCRIPTION
        Provides backward compatibility with DPAPI-encrypted passwords
        while supporting the new AES format.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$EncryptedPassword
    )
    
    # Try AES first (new format)
    if ($EncryptedPassword.StartsWith("AES:")) {
        $result = ConvertFrom-AesEncryptedString -EncryptedText $EncryptedPassword
        if ($null -ne $result) {
            return $result
        }
    }
    
    # Try AES without prefix (in case it was stored without)
    $aesResult = ConvertFrom-AesEncryptedString -EncryptedText $EncryptedPassword
    if ($null -ne $aesResult) {
        return $aesResult
    }
    
    # Fallback to DPAPI (legacy format)
    try {
        $securePassword = ConvertTo-SecureString -String $EncryptedPassword -ErrorAction Stop
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        return $plainPassword
    }
    catch {
        # Both methods failed
        return $null
    }
}

function Test-PasswordDecryption {
    <#
    .SYNOPSIS
        Tests if a password can be decrypted
    .OUTPUTS
        Hashtable with: CanDecrypt, Method (AES/DPAPI/None), NeedsMigration
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$EncryptedPassword
    )
    
    # Check if already AES format
    if ($EncryptedPassword.StartsWith("AES:")) {
        $result = ConvertFrom-AesEncryptedString -EncryptedText $EncryptedPassword
        return @{
            CanDecrypt = ($null -ne $result)
            Method = if ($null -ne $result) { "AES" } else { "None" }
            NeedsMigration = $false
        }
    }
    
    # Try DPAPI
    try {
        $securePassword = ConvertTo-SecureString -String $EncryptedPassword -ErrorAction Stop
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        
        return @{
            CanDecrypt = $true
            Method = "DPAPI"
            NeedsMigration = $true  # Should migrate to AES
            PlainPassword = $plainPassword  # For migration
        }
    }
    catch {
        return @{
            CanDecrypt = $false
            Method = "None"
            NeedsMigration = $true
        }
    }
}

#endregion

# Functions are automatically available when this script is dot-sourced
