# SDN Network Simulator — Ryu + Mininet (notebook)

Environment simulasi jaringan SDN berbasis **Ryu** (controller OpenFlow 1.3) dan **Mininet** (emulator jaringan dengan Open vSwitch), dengan virtual environment Python. Proyek ini berisi notebook saja, tanpa antarmuka web. Notebook mengacu ke dua proyek sebelumnya:
- `software_defined_network`: topologi `data/topology.json`, model metrik & skor QoS, simulasi IDS client/server;
- `reinforcement_and_federated_network`: Q-routing (reinforcement learning) untuk optimasi jalur.

## Struktur
```
sdn/
├── setup_env.sh          # setup Linux / WSL2 Ubuntu: apt + Python 3.9 + venv + Ryu + Mininet + self-test
├── setup_env.bat         # setup dari Windows: venv mode simulasi + menjalankan setup_env.sh di WSL2
├── run_jupyter.sh        # JupyterLab sebagai root (wajib untuk Mininet)
├── run_jupyter.bat       # run_jupyter.bat wsl | win
├── requirements.txt      # library analisis + Jupyter
├── data/topology.json    # topologi mesh 10 switch (delay, bandwidth, loss)
├── colab/                # versi NetworkX murni (tanpa Ryu/Mininet/WSL) — jalan di Google Colab
│   ├── tutorial_simulasi_jaringan_networkx.ipynb   # TUTORIAL: topologi, metrik, simulasi paket, ekspor dataset
│   ├── 01_optimasi_jaringan_networkx_colab.ipynb
│   └── 02_deteksi_ddos_networkx_colab.ipynb
├── notebooks/
│   ├── tutorial_01_mininet.ipynb      # TUTORIAL: emulasi Mininet, berbagai topologi, ekspor dataset
│   ├── tutorial_02_ryu.ipynb          # TUTORIAL: controller Ryu (learning switch, routing, monitoring, REST, mitigasi)
│   ├── 00_cek_environment.ipynb     # cek versi + smoke test Ryu simple_switch_13 + pingAll
│   ├── 01_optimasi_jaringan.ipynb   # optimasi routing + traffic engineering
│   └── 02_deteksi_ddos.ipynb        # deteksi & mitigasi DDoS (statistik + ML)
├── ryu_apps/             # dibuat otomatis oleh notebook: static_router.py, ddos_monitor.py
├── runtime/              # file kerja (konfigurasi routing, CSV statistik dari Ryu, log)
└── results/              # hasil CSV + PNG tiap notebook
```

## Instalasi

### Linux / Ubuntu (native)
```bash
bash setup_env.sh                 # opsi: VENV_DIR=..., PYTHON_BIN=python3.9, SKIP_APT=1, RUN_SELFTEST=0
bash run_jupyter.sh               # buka URL yang tampil, jalankan notebook 00 → 01 → 02
```

### Windows
```bat
setup_env.bat          :: venv Windows (mode sim) + Ryu/Mininet di WSL2 (log: setup_env.log, setup_env_wsl.log)
run_jupyter.bat wsl    :: mode mininet (emulasi asli, di WSL2)
run_jupyter.bat win    :: mode sim (tanpa Mininet)
```
Jika WSL2 belum ada: buka PowerShell sebagai Administrator, jalankan `wsl --install -d Ubuntu`, restart, lalu jalankan `setup_env.bat wsl`.

### Catatan versi penting
- **Ryu 4.34 tidak berjalan di Python ≥ 3.10** (eventlet 0.30.2 gagal: `TypeError: cannot set 'is_timeout' attribute of immutable type 'TimeoutError'`). Karena itu `setup_env.sh` mencari Python 3.9/3.8. Jika tidak ada, script memasangnya lewat PPA deadsnakes (Ubuntu) atau `uv`.
- Ryu dipasang dengan `setuptools==67.6.1` dan `pip install --no-build-isolation ryu==4.34 eventlet==0.30.2`.
- Library Python Mininet diambil dari paket apt `mininet` (ditautkan ke venv), agar versinya sama dengan `mnexec`/`mn` sistem.
- Bila modul kernel `openvswitch` tidak tersedia (sebagian kernel WSL2), notebook otomatis memakai datapath userspace OVS (`datapath='user'`).

## Tutorial langkah demi langkah
Tiga notebook tutorial menjelaskan simulasi jaringan dari dasar, dengan hasil yang bisa dipakai untuk optimasi jaringan dan deteksi DDoS:

| Notebook | Fokus | Keluaran |
|---|---|---|
| `notebooks/tutorial_01_mininet.ipynb` | Emulasi **Mininet** tanpa controller: katalog topologi (single/linear/tree/ring/mesh/fat-tree/JSON), mode standalone & RSTP, ukur RTT/iperf, uji link putus | topologi JSON + matriks RTT (optimasi); rekaman `tcpdump` + fitur per jendela (DDoS) |
| `notebooks/tutorial_02_ryu.ipynb` | Controller **Ryu**: learning switch, penemuan topologi (LLDP) + rute shortest-path (NetworkX), monitoring flow/port stats, REST, blokir port | topologi JSON hasil penemuan + utilisasi link (optimasi); `flow_stats.csv` (DDoS) |
| `colab/tutorial_simulasi_jaringan_networkx.ipynb` | **NetworkX saja** (Colab, tanpa WSL): galeri topologi, metrik graf, model antrean, simulasi paket discrete-event, uji ketahanan | topologi JSON + flow berlabel + fitur per jendela |

Alur keluaran: topologi JSON yang diekspor tutorial bisa dimuat `01_optimasi_jaringan.ipynb`/notebook optimasi Colab; dataset flow/fitur diproses `02_deteksi_ddos.ipynb`.

## Alternatif tanpa WSL: notebook Google Colab (NetworkX)
Bila instalasi WSL/Mininet gagal, gunakan folder `colab/`. Notebook di sana hanya memakai networkx, numpy, pandas, matplotlib, dan scikit-learn, yang semuanya sudah tersedia di Colab.
1. Buka https://colab.research.google.com → **File → Upload notebook**, lalu pilih file `.ipynb` dari folder `colab/`. Bisa juga dibuka langsung dari GitHub.
2. **Runtime → Run all**. Ubah parameter lewat form (slider/dropdown/checkbox) di tiap sel.
3. Hasil tersimpan di `hasil_networkx/`. Centang `UNDUH_ZIP` di sel terakhir untuk mengunduhnya.

| Notebook | Isi |
|---|---|
| `01_optimasi_jaringan_networkx_colab` | topologi (acak/contoh 10 switch/grid/ring) + region, trafik non-IID dengan delay antrean M/M/1, 5 algoritma routing vs oracle, **RL dengan reward terurai** (+tiba, ±kemajuan, −delay, −hop, −loop, −kongesti, −timeout) beserta slider replay per episode, **Federated Q-Routing** (global vs lokal vs terpusat vs oracle, agregasi visit-weighted/FedAvg), traffic engineering load-aware (mengikuti proyek *reinforcement_and_federated_network*) |
| `02_deteksi_ddos_networkx_colab` | topologi pohon NetworkX + simulator controller (flow table, packet_in, drop rule) dengan skema data sama seperti app Ryu, serangan SYN/UDP/ICMP (+spoofing) & flash crowd, fitur per jendela, z-score vs DT/RF/KNN/SVM, jenis serangan, port sumber, demo mitigasi online |

## Mode notebook
| Mode | Syarat | Isi |
|---|---|---|
| `mininet` | Linux/WSL2, kernel Jupyter berjalan sebagai **root** (`run_jupyter.sh`), Mininet + Ryu terpasang | Emulasi nyata: OVS, link `tc` (delay/bw/loss), controller Ryu, trafik ping/iperf/curl/hping3 |
| `sim` | selain itu (Windows, atau kernel bukan root) | Model murni Python dengan skema data yang sama, sehingga alur analisis tetap bisa dijalankan |

Mode dipilih otomatis (`MODE = "auto"`), atau dipaksa lewat sel konfigurasi.

## 01 · Optimasi jaringan
- 5 algoritma routing all-pairs: Hop-Count (baseline), Dijkstra-Delay, Widest-Path, QoS-Dijkstra, Q-Learning (Q-routing per tujuan, dengan kurva belajar).
- Ryu `static_router.py`: notebook menulis flow rule per switch ke JSON. Ryu memasangnya secara proaktif (dengan barrier), lalu mengumpulkan statistik port.
- Pengukuran ping (RTT/loss) dan iperf (throughput TCP), dibandingkan dengan estimasi analitik dan skor QoS.
- Traffic engineering: beberapa flow UDP laju tetap berjalan paralel; strategi jalur terpendek dibandingkan dengan Load-Aware (k-shortest-path, meminimalkan utilisasi link maksimum). Utilisasi link dihitung dari statistik port.

## 02 · Deteksi DDoS
- Topologi pohon: server + 9 client (3 penyerang). Ryu `ddos_monitor.py` = L2 learning, flow stats & packet_in ke CSV, serta mitigasi lewat `blocklist.json`.
- Skenario: normal, **flash crowd** (lonjakan trafik sah), SYN / UDP / ICMP flood (hping3, opsional IP spoofing).
- Fitur per jendela: laju paket/byte, flow baru, entropi IP sumber/tujuan, rasio flow 1-paket, proporsi protokol, laju packet_in.
- Deteksi: z-score/entropi dibandingkan dengan Decision Tree, Random Forest, KNN, dan SVM. Ada juga klasifikasi jenis trafik dan identifikasi port sumber.
- Demo online: deteksi berjalan tiap interval, port penyerang diblokir otomatis, lalu dampak ke client normal (RTT, waktu HTTP) diukur sebelum dan sesudah mitigasi.

## Troubleshooting
| Gejala | Solusi |
|---|---|
| `MODE='sim'` padahal di Linux | Jalankan Jupyter via `bash run_jupyter.sh` (root) |
| `Exception: Error creating interface pair` / sisa bridge | `sudo mn -c` |
| `ryu-manager berhenti` | Lihat `runtime/<notebook>/ryu.log`; pastikan port 6653 bebas (`sudo fuser -k 6653/tcp`) |
| Ryu error eventlet / `TimeoutError` | venv bukan Python 3.9: hapus venv, jalankan ulang `setup_env.sh` |
| `$'\r': command not found` di WSL | File `.sh` ber-CRLF: `sed -i 's/\r$//' *.sh` (otomatis dilakukan oleh `.bat`) |

> Trafik serangan (hping3) hanya dijalankan di dalam jaringan emulasi Mininet yang terisolasi, untuk keperluan pembelajaran dan penelitian keamanan jaringan.
