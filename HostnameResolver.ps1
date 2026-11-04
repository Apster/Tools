Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "         Hostname to IP Resolver" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "   Enter the hostnames (one per line),`n   then press Enter twice when done."

Write-Host "----------------------------------------`n"
# Loop to allow continuous hostname resolution
while ($true) {
   # Read the entire input block (allow multiple hostnames separated by newline)
   $hostnames = @()
   
   do {
       $line = Read-Host
       if ($line -ne "") {
           $hostnames += $line.Trim()
       }
   } while ($line -ne "")
   # Check if no hostnames were entered, then break out of loop
   if ($hostnames.Count -eq 0) {
       Write-Host "`nNo hostnames entered. Exiting..." -ForegroundColor Red
       break
   }
   # Write-Host "`nResolving IP addresses..." -ForegroundColor Yellow
   # Resolve all hostnames in a single go
   $hostnames | ForEach-Object {
       try {
           # Write-Host "Resolving: '$_'" -ForegroundColor Blue
           $ips = [System.Net.Dns]::GetHostAddresses($_) | ForEach-Object { $_.IPAddressToString }
           if ($ips.Count -gt 0) {
               Write-Host "$_ - $($ips -join ', ')" -ForegroundColor Green
           } else {
               Write-Host "$_ - Resolution Failed (No IP found)" -ForegroundColor Red
           }
       } catch {
           Write-Host "$_ - Resolution Failed (Error: $_)" -ForegroundColor Red
       }
   }
   # After processing, script will automatically expect a new batch
Write-Host "----------------------------------------`n`n"
}
Write-Host "`nDone!" -ForegroundColor Cyan