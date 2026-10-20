PAKET UJI BEBAN TOKO UTAMA - WEEK 6
===================================

Isi folder:
  run.ps1            skrip yang menjalankan semua run otomatis
  toko_utama.jmx     test plan JMeter (admin + customer)
  LoadTestSeeder.php seeder akun customer uji + 2.000 order awal
  README.txt         file ini


A. SEBELUM MULAI (sekali saja)
------------------------------
1. Taruh folder "loadtest" ini di ROOT project, sejajar dengan file artisan.
   Contoh: C:\Users\Hans\Herd\alpprimaproject\loadtest\run.ps1

2. BACKUP DATABASE. Setiap run menjalankan migrate:fresh, jadi data di
   database alpprimaproject akan terhapus. Di PowerShell (root project):
     & "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqldump.exe" -u root -p --result-file=backup_alpprimaproject.sql alpprimaproject
   (pakai --result-file, JANGAN tanda ">" karena PowerShell merusak encoding file)

3. Pastikan:
   - Herd menyala dan http://alpprimaproject.test bisa dibuka di browser
   - service MySQL80 jalan
   - JMeter 5.6.3 dan Java (Temurin) sudah terpasang
   - charger tercolok, mode daya "Best performance", sleep dimatikan
   - semua aplikasi lain ditutup (browser, Discord, game, dll.)

Skrip otomatis mengosongkan MIDTRANS_SERVER_KEY di .env selama tes (supaya
ribuan checkout tidak membanjiri server sandbox Midtrans) lalu
mengembalikannya di akhir. Setelan slow log MySQL juga dikembalikan.


B. MENJALANKAN
--------------
Buka PowerShell di root project (folder yang berisi artisan), lalu:

1. SMOKE TEST dulu (sekitar 1 menit):
     powershell -ExecutionPolicy Bypass -File loadtest\run.ps1 -Tier smoke

   Masukkan password MySQL root saat diminta.
   - Kalau muncul "SMOKE TEST OK" (hijau): lanjut ke langkah 2.
   - Kalau muncul "SMOKE TEST GAGAL" (merah): JANGAN lanjut. Kirim file zip
     yang disebut di akhir (loadtest\results\smoke_....zip).

2. TIER 1 (sekitar 40 menit) - read-only dan mixed, 50 & 100 VU, 3 kali:
     powershell -ExecutionPolicy Bypass -File loadtest\run.ps1 -Tier tier1

3. TIER 2 kalau masih ada waktu (sekitar 30 menit) - write-only 50 & 100 VU,
   dan off-peak 100 VU, 3 kali:
     powershell -ExecutionPolicy Bypass -File loadtest\run.ps1 -Tier tier2

4. TIER 3 nanti untuk AFL 2 (beberapa jam) - 250, 500, 1.000 VU:
     powershell -ExecutionPolicy Bypass -File loadtest\run.ps1 -Tier tier3

Selama tes berjalan, JANGAN memakai laptop.

Di akhir tiap tier muncul tulisan "SELESAI. Kirim file ini: ...zip".
Kirim zip itu (bisa beberapa zip sekaligus). Angka di naskah diisi dari zip ini.


C. KALAU ADA MASALAH
--------------------
- "JMeter tidak ketemu":
    tambahkan  -JMeterHome "C:\lokasi\apache-jmeter-5.6.3"
- "mysql.exe tidak ketemu":
    tambahkan  -MysqlBin "C:\lokasi\MySQL Server 8.0\bin"
- Situs pakai https: tambahkan  -Protocol https -SitePort 443
- Skrip dihentikan paksa (Ctrl+C / laptop mati) dan file
  .env.loadtest-backup masih ada di root project: salin file itu menjadi .env
  lalu jalankan  php artisan config:clear
- Setelah semua selesai, kembalikan data lama kalau perlu:
    & "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -u root -p alpprimaproject -e "source backup_alpprimaproject.sql"


D. TAMBAHAN UNTUK BAGIAN METHODS (salin ke Experimental Setup, bahasa Inggris)
-------------------------------------------------------------------------------
Before every run, the database was reset with migrate:fresh and the original
seeders, after which a load-test seeder created one customer account per
virtual user and 2,000 baseline orders with one to three items each,
generated with a fixed random seed so that every run started from an
identical state. Each customer virtual user logged in once and then
repeatedly added a random product to its cart, opened the checkout page, and
submitted POST /checkout, while each administration virtual user logged in
once with the sales-administrator account and repeatedly requested
GET /admin/orders. In the mixed profile at a ladder level of N, N customer
and N administration virtual users ran concurrently, so that the
administration load matched the read-only profile at the same level. The
peak profile issued requests without think time, whereas the off-peak
profile inserted a uniformly distributed think time of one to three seconds
before each request. The Midtrans server key was left empty during load runs,
so that no request reached the Midtrans sandbox and external network latency
was excluded from the measurements. Response-time statistics were computed
only from samples recorded after the ramp-up period; lock waits were sampled
every second from sys.innodb_lock_waits, and row-lock waits, slow queries
(threshold 0.2 s, logged to a table), and deadlocks were taken as the
difference of server counters before and after each run.
