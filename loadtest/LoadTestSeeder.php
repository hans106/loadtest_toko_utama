<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;

/**
 * Data uji beban (load test) untuk penelitian Week 6.
 *
 * Dijalankan oleh loadtest/run.ps1 setelah `php artisan migrate:fresh --seed`:
 *   php artisan db:seed --class=LoadTestSeeder --force
 *
 * Membuat:
 *  1. LOADTEST_CUSTOMERS akun customer uji: loadtest1@toko.test ... loadtestN@toko.test
 *     (password: loadtest123), satu akun per virtual user JMeter.
 *  2. LOADTEST_ORDERS order awal (default 2000) beserta 1-3 item per order,
 *     supaya halaman admin tidak mulai dari tabel kosong. Data dibuat dengan
 *     seed acak tetap, sehingga kondisi awal setiap run identik.
 */
class LoadTestSeeder extends Seeder
{
    public function run(): void
    {
        $customers = max(1, (int) env('LOADTEST_CUSTOMERS', 1000));
        $orders    = max(0, (int) env('LOADTEST_ORDERS', 2000));

        mt_srand(20261020); // seed tetap: data awal sama persis di setiap run

        $now  = Carbon::now();
        $hash = Hash::make('loadtest123');

        // ---------- 1. Akun customer uji ----------
        $batch = [];
        for ($i = 1; $i <= $customers; $i++) {
            $batch[] = [
                'name'              => "Load Test {$i}",
                'email'             => "loadtest{$i}@toko.test",
                'email_verified_at' => $now,
                'password'          => $hash,
                'role'              => 'customer',
                'created_at'        => $now,
                'updated_at'        => $now,
            ];
            if (count($batch) === 500) {
                DB::table('users')->insert($batch);
                $batch = [];
            }
        }
        if ($batch) {
            DB::table('users')->insert($batch);
        }

        if ($orders === 0) {
            return;
        }

        $userIds  = DB::table('users')->where('email', 'like', 'loadtest%@toko.test')->orderBy('id')->pluck('id')->all();
        $products = DB::table('products')->select('id', 'name', 'price')->orderBy('id')->get()->all();
        if (!$userIds || !$products) {
            $this->command?->warn('LoadTestSeeder: tidak ada user/produk, order awal dilewati.');
            return;
        }

        // ---------- 2. Order awal ----------
        // 70% berstatus pending/paid/settlement (tampil di halaman admin), 30% sudah diproses.
        $statuses = ['pending', 'pending', 'pending', 'paid', 'paid', 'settlement', 'settlement', 'processing', 'sent', 'done'];
        $startId  = (int) (DB::table('orders')->max('id') ?? 0) + 1;

        $orderRows = [];
        $itemRows  = [];
        for ($n = 0; $n < $orders; $n++) {
            $orderId   = $startId + $n;
            $status    = $statuses[mt_rand(0, count($statuses) - 1)];
            $createdAt = $now->copy()->subMinutes(mt_rand(60, 30 * 24 * 60));

            $total     = 0;
            $itemCount = mt_rand(1, 3);
            for ($k = 0; $k < $itemCount; $k++) {
                $p   = $products[mt_rand(0, count($products) - 1)];
                $qty = mt_rand(1, 3);
                $total += $p->price * $qty;
                $itemRows[] = [
                    'order_id'     => $orderId,
                    'product_id'   => $p->id,
                    'qty'          => $qty,
                    'price'        => $p->price,
                    'product_name' => $p->name,
                    'created_at'   => $createdAt,
                ];
            }

            $orderRows[] = [
                'id'           => $orderId,
                'user_id'      => $userIds[mt_rand(0, count($userIds) - 1)],
                'total_price'  => $total,
                'status'       => $status,
                'invoice_code' => sprintf('INV-BASE%06d', $orderId),
                'address'      => 'Jalan Raya Darmo Nomor 10 Surabaya (No HP: 081234567890)',
                'paid_at'      => in_array($status, ['pending'], true) ? null : $createdAt->copy()->addMinutes(10),
                'created_at'   => $createdAt,
                'updated_at'   => $createdAt,
            ];

            if (count($orderRows) === 500) {
                DB::table('orders')->insert($orderRows);
                DB::table('order_items')->insert($itemRows);
                $orderRows = [];
                $itemRows  = [];
            }
        }
        if ($orderRows) {
            DB::table('orders')->insert($orderRows);
            DB::table('order_items')->insert($itemRows);
        }

        $this->command?->info("LoadTestSeeder: {$customers} customer uji, {$orders} order awal.");
    }
}
