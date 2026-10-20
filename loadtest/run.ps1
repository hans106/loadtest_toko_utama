<#
  Toko Utama - runner uji beban (Academic Writing Week 6)

  Jalankan dari folder root project (folder yang berisi file artisan):
    powershell -ExecutionPolicy Bypass -File loadtest\run.ps1 -Tier smoke
    powershell -ExecutionPolicy Bypass -File loadtest\run.ps1 -Tier tier1
    powershell -ExecutionPolicy Bypass -File loadtest\run.ps1 -Tier tier2

  Setiap run:
    1. reset database (migrate:fresh --seed + LoadTestSeeder)
    2. ukur baseline homepage (5 request)
    3. catat counter MySQL sebelum run, kosongkan slow log
    4. jalankan JMeter non-GUI, sambil mengambil sampel lock wait tiap 1 detik
    5. catat counter MySQL sesudah run, slow log, EXPLAIN, jumlah order
  Hasil semua run dikumpulkan ke loadtest\results\<tier>_<waktu>.zip
#>
param(
    [ValidateSet('smoke', 'tier1', 'tier2', 'tier3')]
    [string]$Tier = 'smoke',
    [string]$JMeterHome = '',
    [string]$MysqlBin = 'C:\Program Files\MySQL\MySQL Server 8.0\bin',
    [string]$MysqlUser = 'root',
    [string]$SiteHost = 'alpprimaproject.test',
    [int]$SitePort = 80,
    [string]$Protocol = 'http',
    [string]$Database = 'alpprimaproject',
    [int]$Repeats = 3,
    [int]$SteadySeconds = 120,
    [int]$BaselineOrders = 2000
)

$ErrorActionPreference = 'Continue'
$LoadDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $LoadDir
$Jmx = Join-Path $LoadDir 'toko_utama.jmx'
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutRoot = Join-Path $LoadDir ("results\{0}_{1}" -f $Tier, $Stamp)
$SiteUrl = '{0}://{1}:{2}/' -f $Protocol, $SiteHost, $SitePort

function Say([string]$msg, [string]$color = 'Gray') {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg) -ForegroundColor $color
}

function NowMs { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# ---------------------------------------------------------------- cek persiapan
Say "Cek persiapan..." 'Cyan'
if (-not (Test-Path (Join-Path $ProjectRoot 'artisan'))) {
    Write-Host "BERHENTI: folder loadtest harus ada di root project (sejajar dengan file artisan)." -ForegroundColor Red; exit 1
}
if (-not (Get-Command php -ErrorAction SilentlyContinue)) {
    Write-Host "BERHENTI: perintah php tidak ditemukan. Buka terminal dari Herd atau pastikan PHP Herd ada di PATH." -ForegroundColor Red; exit 1
}

# JMeter: dipanggil lewat java -jar ApacheJMeter.jar (jmeter.bat bisa berhenti menunggu tombol saat error)
$candidates = @()
if ($JMeterHome) { $candidates += $JMeterHome }
$candidates += @('C:\apache-jmeter-5.6.3', "$env:USERPROFILE\apache-jmeter-5.6.3", "$env:USERPROFILE\Downloads\apache-jmeter-5.6.3",
    "$env:USERPROFILE\Desktop\apache-jmeter-5.6.3", "$env:USERPROFILE\Documents\apache-jmeter-5.6.3", 'C:\Program Files\apache-jmeter-5.6.3',
    'D:\apache-jmeter-5.6.3', 'C:\tools\apache-jmeter-5.6.3')
$jmBat = Get-Command jmeter.bat -ErrorAction SilentlyContinue
if ($jmBat) { $candidates += (Split-Path -Parent (Split-Path -Parent $jmBat.Source)) }
$JMeterJar = $null
foreach ($c in $candidates) {
    $j = Join-Path $c 'bin\ApacheJMeter.jar'
    if (Test-Path $j) { $JMeterJar = $j; break }
}
if (-not $JMeterJar) {
    Write-Host "BERHENTI: JMeter tidak ketemu. Jalankan ulang dengan -JMeterHome 'C:\lokasi\apache-jmeter-5.6.3'" -ForegroundColor Red; exit 1
}
$Java = $null
if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) { $Java = Join-Path $env:JAVA_HOME 'bin\java.exe' }
elseif (Get-Command java -ErrorAction SilentlyContinue) { $Java = (Get-Command java).Source }
if (-not $Java) {
    Write-Host "BERHENTI: java tidak ditemukan (JMeter butuh Java/Temurin). Set JAVA_HOME atau tambahkan java ke PATH." -ForegroundColor Red; exit 1
}

$Mysql = Join-Path $MysqlBin 'mysql.exe'
if (-not (Test-Path $Mysql)) {
    $m = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($m) { $Mysql = $m.Source } else {
        Write-Host "BERHENTI: mysql.exe tidak ketemu. Jalankan ulang dengan -MysqlBin 'C:\lokasi\MySQL Server 8.0\bin'" -ForegroundColor Red; exit 1
    }
}

try {
    $r = Invoke-WebRequest -Uri $SiteUrl -UseBasicParsing -TimeoutSec 15
    if ($r.StatusCode -ne 200) { throw "status $($r.StatusCode)" }
} catch {
    Write-Host "BERHENTI: situs $SiteUrl tidak bisa dibuka ($_). Pastikan Herd menyala." -ForegroundColor Red; exit 1
}

try {
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($bat -and $bat.BatteryStatus -ne 2) { Say "PERINGATAN: laptop tidak sedang dicas. Colokkan charger supaya performa stabil." 'Yellow' }
} catch { }

Say "JMeter : $JMeterJar"
Say "Java   : $Java"
Say "MySQL  : $Mysql"
Say "Situs  : $SiteUrl"

# ---------------------------------------------------------------- koneksi MySQL
$sec = Read-Host "Password MySQL untuk user '$MysqlUser' (Enter kalau tanpa password)" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
$Cnf = Join-Path $env:TEMP ('toko_loadtest_{0}.cnf' -f $PID)
$cnfLines = @('[client]', "user=$MysqlUser", 'host=127.0.0.1', 'port=3306')
if ($plain) { $cnfLines += ('password="{0}"' -f $plain.Replace('\', '\\').Replace('"', '\"')) }
[IO.File]::WriteAllLines($Cnf, [string[]]$cnfLines)
$plain = $null

function Sql([string]$query, [switch]$UseDb) {
    $a = @("--defaults-extra-file=$Cnf", '-B', '-N')
    if ($UseDb) { $a += "--database=$Database" }
    $a += @('-e', $query)
    $out = & $Mysql @a 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Query MySQL gagal: $query" }
    return $out
}

try { $ver = Sql 'SELECT VERSION()' } catch {
    Remove-Item $Cnf -ErrorAction SilentlyContinue
    Write-Host "BERHENTI: tidak bisa login ke MySQL. Cek password/user." -ForegroundColor Red; exit 1
}
Say "MySQL versi $ver"

$QCounters = "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME IN ('Innodb_row_lock_waits','Innodb_row_lock_time','Innodb_row_lock_time_max','Slow_queries','Threads_connected','Max_used_connections') UNION ALL SELECT NAME, COUNT FROM information_schema.INNODB_METRICS WHERE NAME IN ('lock_deadlocks','lock_timeouts')"
$QLockWaits = "SELECT NOW(3), wait_age_secs, locked_table, locked_index, locked_type, LEFT(REPLACE(REPLACE(waiting_query,CHAR(10),' '),CHAR(9),' '),200), LEFT(REPLACE(REPLACE(blocking_query,CHAR(10),' '),CHAR(9),' '),200) FROM sys.innodb_lock_waits"
$QSlow = "SELECT start_time, query_time, lock_time, rows_examined, LEFT(REPLACE(REPLACE(CONVERT(sql_text USING utf8mb4),CHAR(10),' '),CHAR(9),' '),300) FROM mysql.slow_log"
$QExplain = "EXPLAIN SELECT * FROM orders WHERE status IN ('paid','settlement','pending') ORDER BY created_at DESC LIMIT 20"

# ---------------------------------------------------------------- daftar run
$plan = @()
switch ($Tier) {
    'smoke' { $plan += @{ Profile = 'mixed'; VU = 2 }; $Repeats = 1; $SteadySeconds = 20 }
    'tier1' { foreach ($v in 50, 100) { $plan += @{ Profile = 'readonly'; VU = $v }; $plan += @{ Profile = 'mixed'; VU = $v } } }
    'tier2' { foreach ($v in 50, 100) { $plan += @{ Profile = 'writeonly'; VU = $v } }; $plan += @{ Profile = 'offpeak'; VU = 100 } }
    'tier3' { foreach ($v in 250, 500, 1000) { $plan += @{ Profile = 'readonly'; VU = $v }; $plan += @{ Profile = 'writeonly'; VU = $v }; $plan += @{ Profile = 'mixed'; VU = $v } } }
}
$totalRuns = $plan.Count * $Repeats
$estSec = 0
foreach ($p in $plan) { $estSec += ([Math]::Max(1, [int][Math]::Ceiling($p.VU / 10)) + $SteadySeconds + 45) * $Repeats }
Say ("Tier {0}: {1} run, perkiraan {2} menit. Jangan pakai laptop selama tes berjalan." -f $Tier, $totalRuns, [int]($estSec / 60)) 'Cyan'

New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null
$EnvPath = Join-Path $ProjectRoot '.env'
$EnvBackup = "$EnvPath.loadtest-backup"
$origMysql = $null
Push-Location $ProjectRoot

function Show-Summary([string]$jtl, [long]$fromMs, [string]$saveTo) {
    if (-not (Test-Path $jtl)) { Say "JTL tidak ada: $jtl" 'Red'; return @() }
    $rows = Import-Csv $jtl | Where-Object { [long]$_.timeStamp -ge $fromMs }
    $lines = @()
    foreach ($g in ($rows | Group-Object label | Sort-Object Name)) {
        $el = @($g.Group | ForEach-Object { [int]$_.elapsed } | Sort-Object)
        $err = @($g.Group | Where-Object { $_.success -ne 'true' }).Count
        $p95 = $el[[Math]::Max(0, [int][Math]::Ceiling(0.95 * $el.Count) - 1)]
        $lines += ('{0,-24} n={1,7}  error={2,6}  p95={3,7} ms' -f $g.Name, $el.Count, $err, $p95)
    }
    $lines | Set-Content -Path $saveTo
    $lines | ForEach-Object { Write-Host "    $_" }
    return $lines
}

try {
    # .env: matikan panggilan Midtrans selama uji beban (server key dikosongkan, dikembalikan di akhir)
    Copy-Item $EnvPath $EnvBackup -Force
    $envText = [IO.File]::ReadAllText($EnvPath)
    $envText = [regex]::Replace($envText, '(?m)^MIDTRANS_SERVER_KEY=[^\r\n]*', 'MIDTRANS_SERVER_KEY=')
    [IO.File]::WriteAllText($EnvPath, $envText)
    & php artisan config:clear *> $null
    Say "Midtrans dimatikan sementara (.env dibackup ke .env.loadtest-backup)."

    Copy-Item (Join-Path $LoadDir 'LoadTestSeeder.php') (Join-Path $ProjectRoot 'database\seeders\LoadTestSeeder.php') -Force

    $origMysql = (Sql 'SELECT @@GLOBAL.slow_query_log, @@GLOBAL.long_query_time, @@GLOBAL.log_output, @@GLOBAL.innodb_print_all_deadlocks') -split "`t"
    Sql "SET GLOBAL slow_query_log=ON, GLOBAL long_query_time=0.2, GLOBAL log_output='TABLE', GLOBAL innodb_print_all_deadlocks=ON" | Out-Null
    Say "Instrumentasi MySQL aktif (slow log 0.2 s ke tabel, log deadlock)."

    $runNo = 0
    for ($rep = 1; $rep -le $Repeats; $rep++) {
        foreach ($cfg in $plan) {
            $runNo++
            $vu = [int]$cfg.VU
            $prof = $cfg.Profile
            $admin = 0; $cust = 0; $thinkMin = 0; $thinkRange = 0
            if ($prof -eq 'readonly') { $admin = $vu }
            if ($prof -eq 'writeonly') { $cust = $vu }
            if ($prof -eq 'mixed') { $admin = $vu; $cust = $vu }
            if ($prof -eq 'offpeak') { $admin = $vu; $cust = $vu; $thinkMin = 1000; $thinkRange = 2000 }
            $ramp = [Math]::Max(1, [int][Math]::Ceiling($vu / 10))
            $dur = $ramp + $SteadySeconds
            $name = '{0}_{1:D4}vu_rep{2}' -f $prof, $vu, $rep
            $dir = Join-Path $OutRoot $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Say ("Run {0}/{1}: {2} (admin={3}, customer={4}, ramp={5}s, total={6}s)" -f $runNo, $totalRuns, $name, $admin, $cust, $ramp, $dur) 'Cyan'

            # 1. reset database
            $env:LOADTEST_CUSTOMERS = [string]([Math]::Max($cust, 10))
            $env:LOADTEST_ORDERS = [string]$BaselineOrders
            & php artisan migrate:fresh --seed --force *> (Join-Path $dir 'reset_migrate.log')
            if ($LASTEXITCODE -ne 0) { throw "migrate:fresh gagal, lihat $dir\reset_migrate.log" }
            & php artisan db:seed --class=LoadTestSeeder --force *> (Join-Path $dir 'reset_seed.log')
            if ($LASTEXITCODE -ne 0) { throw "LoadTestSeeder gagal, lihat $dir\reset_seed.log" }

            # 2. baseline homepage
            $baseline = @()
            for ($i = 0; $i -lt 5; $i++) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                try { Invoke-WebRequest -Uri $SiteUrl -UseBasicParsing -TimeoutSec 30 | Out-Null } catch { }
                $sw.Stop(); $baseline += [int]$sw.ElapsedMilliseconds
            }

            # 3. counter sebelum
            Sql $QCounters | Set-Content (Join-Path $dir 'counters_before.tsv')
            Sql 'TRUNCATE TABLE mysql.slow_log' | Out-Null

            # 4. sampler lock wait + JMeter
            $flag = Join-Path $dir 'sampling.flag'
            Set-Content $flag 'on'
            $lwFile = Join-Path $dir 'lock_waits.tsv'
            $job = Start-Job -ArgumentList $Mysql, $Cnf, $lwFile, $flag, $QLockWaits -ScriptBlock {
                param($m, $c, $f, $fl, $q)
                while (Test-Path $fl) {
                    $o = & $m "--defaults-extra-file=$c" -B -N -e $q 2>$null
                    if ($o) { Add-Content -Path $f -Value $o }
                    Start-Sleep -Milliseconds 1000
                }
            }

            $startMs = NowMs
            $jtl = Join-Path $dir 'results.jtl'
            $jargs = @('-Xms1g', '-Xmx3g', '-XX:MaxMetaspaceSize=256m', '-jar', $JMeterJar, '-n', '-t', $Jmx, '-l', $jtl, '-j', (Join-Path $dir 'jmeter.log'),
                "-Jhost=$SiteHost", "-Jport=$SitePort", "-Jprotocol=$Protocol",
                "-Jadmin_threads=$admin", "-Jcustomer_threads=$cust", "-Jrampup=$ramp", "-Jduration=$dur",
                "-Jthink_min=$thinkMin", "-Jthink_range=$thinkRange", '-Jproduct_max=20',
                '-Jjmeter.save.saveservice.output_format=csv', '-Jjmeter.save.saveservice.print_field_names=true')
            & $Java @jargs *> (Join-Path $dir 'jmeter_console.txt')
            $jmExit = $LASTEXITCODE
            $endMs = NowMs

            Remove-Item $flag -ErrorAction SilentlyContinue
            Wait-Job $job -Timeout 20 | Out-Null
            Remove-Job $job -Force

            # 5. counter sesudah, slow log, explain, jumlah order
            Sql $QCounters | Set-Content (Join-Path $dir 'counters_after.tsv')
            Sql $QSlow | Set-Content (Join-Path $dir 'slow_log.tsv')
            Sql $QExplain -UseDb | Set-Content (Join-Path $dir 'explain.tsv')
            $orders = Sql 'SELECT COUNT(*) FROM orders' -UseDb

            $meta = [ordered]@{
                profile = $prof; vu = $vu; rep = $rep; admin_threads = $admin; customer_threads = $cust
                rampup_s = $ramp; steady_s = $SteadySeconds; think_min_ms = $thinkMin; think_range_ms = $thinkRange
                start_ms = $startMs; end_ms = $endMs; jmeter_exit = $jmExit; orders_after = $orders
                baseline_orders = $BaselineOrders; baseline_home_ms = $baseline; computer = $env:COMPUTERNAME
            }
            $meta | ConvertTo-Json | Set-Content (Join-Path $dir 'meta.json')

            Say "  Ringkasan steady state (setelah ramp-up):"
            $sum = Show-Summary $jtl ($startMs + $ramp * 1000) (Join-Path $dir 'summary.txt')
            if ($jmExit -ne 0) { Say "  PERINGATAN: JMeter keluar dengan kode $jmExit, lihat jmeter.log" 'Yellow' }

            if ($Tier -eq 'smoke') {
                $all = Import-Csv $jtl
                $bad = @($all | Where-Object { $_.success -ne 'true' })
                $okCheckout = @($all | Where-Object { $_.label -eq 'POST /checkout' -and $_.success -eq 'true' }).Count
                $okAdmin = @($all | Where-Object { $_.label -eq 'GET /admin/orders' -and $_.success -eq 'true' }).Count
                if ($bad.Count -eq 0 -and $okCheckout -gt 0 -and $okAdmin -gt 0) {
                    Say "SMOKE TEST OK: checkout dan halaman admin berhasil tanpa error. Lanjut ke -Tier tier1." 'Green'
                } else {
                    Say ("SMOKE TEST GAGAL: {0} request error, checkout sukses={1}, admin sukses={2}. JANGAN lanjut, kirim zip hasil ini." -f $bad.Count, $okCheckout, $okAdmin) 'Red'
                    $bad | Select-Object -First 5 label, responseCode, failureMessage | Format-Table -AutoSize | Out-String | Write-Host
                }
            }
        }
    }
}
catch {
    Say "ERROR: $_" 'Red'
}
finally {
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    if ($origMysql -and $origMysql.Count -ge 4) {
        try {
            Sql ("SET GLOBAL slow_query_log={0}, GLOBAL long_query_time={1}, GLOBAL log_output='{2}', GLOBAL innodb_print_all_deadlocks={3}" -f $origMysql[0], $origMysql[1], $origMysql[2], $origMysql[3]) | Out-Null
            Say "Setelan MySQL dikembalikan."
        } catch { Say "Setelan MySQL gagal dikembalikan (tidak masalah, kembali normal setelah MySQL restart)." 'Yellow' }
    }
    if (Test-Path $EnvBackup) {
        Copy-Item $EnvBackup $EnvPath -Force
        Remove-Item $EnvBackup -Force
        & php artisan config:clear *> $null
        Say ".env dikembalikan (Midtrans aktif lagi)."
    }
    Remove-Item $Cnf -ErrorAction SilentlyContinue
    Pop-Location
    if (Test-Path $OutRoot) {
        $zip = "$OutRoot.zip"
        Compress-Archive -Path $OutRoot -DestinationPath $zip -Force
        Say "SELESAI. Kirim file ini: $zip" 'Green'
    }
}
