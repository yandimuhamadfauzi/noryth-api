import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/real_sql_engine.dart';
import '../services/xp_service.dart';
import '../services/noryth_case001_service.dart';
import '../../main.dart';

// ==========================================================
// NORYTH - MISSION SCREEN
// CASE #001: SERVER KAMPUS DIBOBOL
//
// - Real SQLite execution
// - Server-side XP claim
// - Server-side hint tracking
// - Firebase progress
// - One-time reward
// - Responsive UI
// ==========================================================

class MissionScreen extends StatefulWidget {
  const MissionScreen({super.key});

  @override
  State<MissionScreen> createState() => _MissionScreenState();
}

class _MissionScreenState extends State<MissionScreen>
    with SingleTickerProviderStateMixin {
  static const String missionId = 'case_001';

  static const List<Map<String, String>> logs = [
    {'user_id': '101', 'username': 'admin', 'aktivitas': 'login'},
    {'user_id': '102', 'username': 'raka_07', 'aktivitas': 'akses_root'},
    {'user_id': '103', 'username': 'dina_02', 'aktivitas': 'login'},
    {'user_id': '102', 'username': 'raka_07', 'aktivitas': 'akses_root'},
    {'user_id': '104', 'username': 'budi_01', 'aktivitas': 'logout'},
    {'user_id': '102', 'username': 'raka_07', 'aktivitas': 'akses_root'},
    {'user_id': '103', 'username': 'dina_02', 'aktivitas': 'akses_root'},
  ];

  late final TabController _tabController;
  late final TextEditingController _codeController;
  late final RealSqlEngine _realSqlEngine;
  late final NorythCase001Service _case001Service;
  late final XpService _xpService;
  late final Stream<XpProgress> _xpStream;

  bool _saving = false;
  bool _hintSaving = false;
  bool _hintUsed = false;
  bool _completed = false;
  bool _hasExecuted = false;
  bool _lastRunCorrect = false;

  int _attempts = 0;

  String _output =
      'NORYTH SQL TERMINAL\n\n'
      'Terminal investigasi siap.\n\n'
      'Tulis query SQL pada editor, kemudian tekan '
      'Jalankan untuk menganalisis barang bukti.';

  // ========================================================
  // INITIALIZATION
  // ========================================================

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: 4, vsync: this);

    // Editor kosong setiap kali kasus dibuka.
    _codeController = TextEditingController();

    _realSqlEngine = RealSqlEngine(
      logs: logs,
      databaseName: 'noryth_case_001.db',
    );

    _xpService = XpService();
    _case001Service = NorythCase001Service();
    _xpStream = _xpService.watchProgress();

    _loadSavedPractice();
  }

  DocumentReference<Map<String, dynamic>>? get _practiceRef {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid == null) return null;

    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('missionPractice')
        .doc(missionId);
  }

  // ========================================================
  // LOAD PROGRESS
  // ========================================================

  Future<void> _loadSavedPractice() async {
    final ref = _practiceRef;
    if (ref == null) return;

    try {
      final snapshot = await ref.get();

      if (!mounted || !snapshot.exists) return;

      final data = snapshot.data();
      if (data == null) return;

      setState(() {
        final savedAttempts = (data['attempts'] as num?)?.toInt() ?? 0;

        if (savedAttempts > _attempts) {
          _attempts = savedAttempts;
        }

        _hintUsed = _hintUsed || data['hintUsed'] == true;
        _completed = _completed || data['practiceCompleted'] == true;

        if (_completed && !_hasExecuted) {
          _output =
              'NORYTH SQL TERMINAL\n\n'
              'Riwayat investigasi ditemukan.\n\n'
              'Kasus #001 pernah berhasil diselesaikan.\n\n'
              'Kamu bisa mencoba kembali menggunakan '
              'query SQL baru.\n\n'
              'Editor tetap kosong.';
        }
      });
    } catch (e) {
      debugPrint('Gagal memuat progres: $e');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Riwayat investigasi belum dapat dimuat.'),
        ),
      );
    }
  }

  // ========================================================
  // EXECUTE REAL SQLITE
  // ========================================================

  Future<void> _executePractice() async {
    if (_saving || _hintSaving) return;

    final query = _codeController.text.trim();

    if (query.isEmpty) {
      setState(() {
        _hasExecuted = true;
        _lastRunCorrect = false;

        _output =
            'EDITOR MASIH KOSONG\n\n'
            'Silakan tulis query SQL terlebih dahulu.\n\n'
            'Petunjuk awal:\n'
            '• SELECT untuk memilih kolom.\n'
            '• FROM menentukan tabel.\n'
            '• WHERE menyaring aktivitas.\n'
            '• GROUP BY mengelompokkan username.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _hasExecuted = true;
      _lastRunCorrect = false;

      _output =
          'NORYTH SQL ENGINE\n\n'
          'Menjalankan query SQLite...\n'
          'Memeriksa barang bukti...';
    });

    RealSqlResult? sqlResult;

    try {
      // ====================================================
      // 1. VALIDASI LOKAL DENGAN SQLITE
      // ====================================================

      sqlResult = await _realSqlEngine.execute(query);

      if (!mounted) return;

      setState(() {
        _attempts++;
        _lastRunCorrect = sqlResult!.success;
        _output = sqlResult.message;
      });

      // ====================================================
      // 2. SIMPAN RIWAYAT PERCOBAAN
      // ====================================================

      try {
        final ref = _practiceRef;

        if (ref != null) {
          await ref.set({
            'attempts': FieldValue.increment(1),
            'lastQuery': query,
            'lastQueryValid': sqlResult.queryValid,
            'lastQueryCorrect': sqlResult.success,
            'sqlEngine': 'sqlite',
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      } catch (e) {
        // Gagal mencatat percobaan tidak boleh
        // menyebabkan pemberian reward lokal.
        debugPrint('Riwayat belum tersimpan: $e');
      }

      if (!mounted) return;

      // ====================================================
      // 3. SQL SALAH
      // ====================================================

      if (!sqlResult.success) {
        setState(() {
          _output =
              '${sqlResult!.message}\n\n'
              'STATUS REWARD\n'
              'Belum ada XP baru yang diberikan.\n\n'
              'Perbaiki query dan jalankan kembali.';
        });
        return;
      }

      // ====================================================
      // 4. SQL BENAR: KLAIM KE BACKEND GO
      // ====================================================

      setState(() {
        _output =
            '${sqlResult!.message}\n\n'
            'Memverifikasi hasil dengan Noryth API...';
      });

      final reward = await _case001Service.claimReward(query: query);

      if (!mounted) return;

      // Status selesai baru dikonfirmasi setelah
      // server berhasil memvalidasi jawaban.
      setState(() {
        _completed = true;
        _lastRunCorrect = true;
      });

      // ====================================================
      // 5. REWARD BARU
      // ====================================================

      if (reward.newlyAwarded) {
        setState(() {
          _output =
              '${sqlResult!.message}\n\n'
              '============================\n'
              'REWARD INVESTIGASI\n'
              '============================\n\n'
              '+${reward.earnedXp} XP\n\n'
              'Total XP : ${reward.totalXp}\n'
              'Level    : ${reward.level}\n'
              'Rank     : ${reward.rank}\n\n'
              'Reward berhasil diverifikasi '
              'dan disimpan oleh Noryth API.';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: NorythColors.greenSuccess,
            duration: const Duration(seconds: 4),
            content: Text(
              'Kasus #001 berhasil! '
              '+${reward.earnedXp} XP diperoleh.',
            ),
          ),
        );
      } else {
        // ================================================
        // REWARD SUDAH DIBERIKAN SEBELUMNYA
        // ================================================

        setState(() {
          _output =
              '${sqlResult!.message}\n\n'
              '============================\n'
              'REWARD SUDAH DIBERIKAN\n'
              '============================\n\n'
              'Hadiah XP untuk Kasus #001 '
              'sudah pernah diberikan.\n\n'
              'Total XP : ${reward.totalXp}\n'
              'Level    : ${reward.level}\n'
              'Rank     : ${reward.rank}\n\n'
              'Kamu tetap bisa mengulang investigasi.';
        });
      }
    } catch (e) {
      debugPrint('CASE #001 ERROR: $e');

      if (!mounted) return;

      final localSuccess = sqlResult?.success == true;

      setState(() {
        // Tetap tampilkan status kebenaran SQL lokal.
        // Jangan menganggap reward telah berhasil.
        _lastRunCorrect = localSuccess;

        _output =
            '${sqlResult?.message ?? 'SQL belum dapat dijalankan.'}'
            '\n\n'
            '============================\n'
            'VALIDASI BELUM DIKONFIRMASI\n'
            '============================\n\n'
            'Reward belum dapat dikonfirmasi.\n'
            'Jika SQLite berhasil tetapi backend '
            'menolak, kemungkinan sintaks query '
            'belum didukung validator server.\n\n'
            'Detail: $e';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: NorythColors.coralDanger,
          content: Text('Validasi atau klaim XP belum berhasil.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  // ========================================================
  // SERVER-SIDE HINT TRACKING
  // ========================================================

  Future<bool> _saveHint() async {
    if (_hintUsed) return true;
    if (_saving || _hintSaving) return false;

    setState(() {
      _hintSaving = true;
    });

    try {
      await _case001Service.recordHint();

      if (!mounted) return false;

      setState(() {
        _hintUsed = true;
      });

      return true;
    } catch (e) {
      debugPrint('Gagal mencatat hint: $e');

      if (!mounted) return false;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NorythColors.coralDanger,
          content: Text('Petunjuk belum dapat dibuka: $e'),
        ),
      );

      return false;
    } finally {
      if (mounted) {
        setState(() {
          _hintSaving = false;
        });
      }
    }
  }

  // ========================================================
  // HINT DIALOG
  // ========================================================

  Future<void> _showHintDialog() async {
    if (_saving || _hintSaving) return;

    final saved = await _saveHint();

    if (!saved || !mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.lightbulb_rounded, color: NorythColors.amberAccent),
              SizedBox(width: 8),
              Expanded(child: Text('Petunjuk Detektif')),
            ],
          ),
          content: const Text(
            'Perhatikan kolom aktivitas pada '
            'tabel server_logs.\n\n'
            'Temukan akun yang paling sering '
            'melakukan aktivitas akses_root.\n\n'
            'Gunakan:\n'
            '• SELECT\n'
            '• COUNT(*)\n'
            '• FROM\n'
            '• WHERE\n'
            '• GROUP BY\n\n'
            'ORDER BY boleh digunakan untuk '
            'mengurutkan hasil.\n\n'
            'Menggunakan petunjuk mengurangi '
            'potensi hadiah menjadi 150 XP.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: const Text('Mengerti'),
            ),
          ],
        );
      },
    );
  }

  // ========================================================
  // RESET EDITOR
  // ========================================================

  void _resetEditor() {
    if (_saving || _hintSaving) return;

    setState(() {
      _codeController.clear();
      _hasExecuted = false;
      _lastRunCorrect = false;

      _output =
          'NORYTH SQL TERMINAL\n\n'
          'Editor telah dikosongkan.\n\n'
          'Tulis query SQL baru untuk melanjutkan '
          'investigasi.\n\n'
          'Progres dan XP tidak dihapus.';
    });
  }

  // ========================================================
  // DISPOSE
  // ========================================================

  @override
  void dispose() {
    _tabController.dispose();
    _codeController.dispose();
    _case001Service.dispose();

    // Tutup database sesudah operasi layar berakhir.
    // Jangan memblokir dispose dengan await.
    _realSqlEngine.close().catchError((Object error) {
      debugPrint('Gagal menutup SQLite: $error');
    });

    super.dispose();
  }

  // ========================================================
  // MAIN UI
  // ========================================================

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _hintSaving;

    return Scaffold(
      backgroundColor: NorythColors.bgSoft,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text(
          'KASUS #001 • Server Kampus Dibobol',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Minta Petunjuk',
            onPressed: busy ? null : _showHintDialog,
            icon: const Icon(
              Icons.lightbulb_outline_rounded,
              color: NorythColors.amberAccent,
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

          // ================================================
          // DESKTOP / WEB
          // ================================================

          if (constraints.maxWidth >= 900) {
            return Row(
              children: [
                Expanded(
                  flex: 4,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _headerBanner(),
                        const SizedBox(height: 16),
                        _xpProgressCard(),
                        const SizedBox(height: 16),
                        _storyCard(),
                        const SizedBox(height: 16),
                        _suspectsCard(),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: _editorPanel(),
                  ),
                ),
              ],
            );
          }

          // ================================================
          // ANDROID / MOBILE
          // ================================================

          return Column(
            children: [
              if (!keyboardOpen) _headerBanner(),

              Container(
                color: Colors.white,
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelColor: NorythColors.tealPrimary,
                  unselectedLabelColor: NorythColors.textMuted,
                  indicatorColor: NorythColors.tealPrimary,
                  tabs: const [
                    Tab(text: 'Informasi'),
                    Tab(text: 'Bukti'),
                    Tab(text: 'Tersangka'),
                    Tab(text: 'Editor'),
                  ],
                ),
              ),

              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _xpProgressCard(),
                          const SizedBox(height: 16),
                          _storyCard(),
                        ],
                      ),
                    ),
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: _evidenceCard(),
                    ),
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: _suspectsCard(),
                    ),
                    SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.all(12),
                      child: _editorPanel(compact: true),
                    ),
                  ],
                ),
              ),

              if (!keyboardOpen)
                SafeArea(
                  top: false,
                  child: Container(
                    color: Colors.white,
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    child: ElevatedButton.icon(
                      onPressed: busy ? null : _showHintDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: NorythColors.amberAccent,
                        foregroundColor: NorythColors.navyDark,
                      ),
                      icon: _hintSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lightbulb_rounded),
                      label: Text(
                        _hintSaving
                            ? 'Menyimpan Petunjuk...'
                            : _hintUsed
                            ? 'Lihat Petunjuk Lagi'
                            : 'Minta Petunjuk',
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ========================================================
  // HEADER BANNER
  // ========================================================

  Widget _headerBanner() {
    final progress = _completed
        ? 1.0
        : _attempts > 0
        ? 0.5
        : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [NorythColors.navyDeep, NorythColors.navyDark],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'KASUS #001',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Server Kampus Dibobol',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _completed
                        ? NorythColors.greenSuccess
                        : NorythColors.coralDanger,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _completed ? 'SELESAI' : 'KASUS AKTIF',
                  style: TextStyle(
                    color: _completed
                        ? NorythColors.greenSuccess
                        : NorythColors.coralDanger,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Chip(
                label: Text('Sedang'),
                backgroundColor: NorythColors.amberAccent,
                side: BorderSide.none,
              ),
              Text(
                'SQL • Potensi hadiah ${_hintUsed ? 150 : 200} XP',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Text(
                'Percobaan: $_attempts',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Progress latihan: ${(progress * 100).toInt()}%',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(NorythColors.tealLight),
            ),
          ),
        ],
      ),
    );
  }

  // ========================================================
  // XP PROGRESS CARD
  // ========================================================

  Widget _xpProgressCard() {
    return StreamBuilder<XpProgress>(
      stream: _xpStream,
      builder: (context, snapshot) {
        final progress = snapshot.data ?? XpRules.calculate(0);

        return _whitePanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.emoji_events_rounded,
                    color: NorythColors.amberAccent,
                    size: 22,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'PROGRES DETEKTIF',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: NorythColors.navyDark,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: NorythColors.tealPrimary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.military_tech_rounded,
                      color: NorythColors.tealPrimary,
                      size: 30,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'LEVEL ${progress.level}',
                          style: const TextStyle(
                            color: NorythColors.navyDark,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          progress.rank,
                          style: const TextStyle(
                            color: NorythColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${progress.totalXp}',
                        style: const TextStyle(
                          color: NorythColors.tealPrimary,
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        'TOTAL XP',
                        style: TextStyle(
                          color: NorythColors.textMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: progress.progress,
                  minHeight: 9,
                  backgroundColor: NorythColors.borderSoft,
                  valueColor: const AlwaysStoppedAnimation(
                    NorythColors.tealPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 9),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      '${progress.xpInCurrentLevel} / '
                      '${progress.xpRequired} XP',
                      style: const TextStyle(
                        color: NorythColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Text(
                    'Menuju Level ${progress.level + 1}',
                    style: const TextStyle(
                      color: NorythColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // ========================================================
  // STORY
  // ========================================================

  Widget _storyCard() {
    return _whitePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Cerita Kasus',
            style: TextStyle(
              color: NorythColors.navyDark,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Pada pukul 00.14 terjadi aktivitas '
            'mencurigakan pada server kampus. '
            'Beberapa akun tercatat mengakses sistem, '
            'dan salah satunya diduga melakukan '
            'perubahan hak akses root tanpa izin.',
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: NorythColors.textDark,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Tujuan Investigasi',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: NorythColors.navyDark,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Temukan username yang paling sering '
            'melakukan aktivitas akses_root '
            'menggunakan query SQL dengan GROUP BY.',
            style: TextStyle(color: NorythColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _evidenceContent(),
        ],
      ),
    );
  }

  // ========================================================
  // EVIDENCE
  // ========================================================

  Widget _evidenceCard() {
    return _whitePanel(child: _evidenceContent());
  }

  Widget _evidenceContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Tabel Bukti • server_logs',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: NorythColors.navyDark,
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(const Color(0xFFF1F5F9)),
            columns: const [
              DataColumn(label: Text('user_id')),
              DataColumn(label: Text('username')),
              DataColumn(label: Text('aktivitas')),
            ],
            rows: logs.map((row) {
              final suspicious = row['aktivitas'] == 'akses_root';

              return DataRow(
                cells: [
                  DataCell(Text(row['user_id'] ?? '')),
                  DataCell(
                    Text(
                      row['username'] ?? '',
                      style: TextStyle(
                        color: suspicious
                            ? NorythColors.coralDanger
                            : NorythColors.textDark,
                      ),
                    ),
                  ),
                  DataCell(
                    Text(
                      row['aktivitas'] ?? '',
                      style: TextStyle(
                        color: suspicious
                            ? NorythColors.coralDanger
                            : NorythColors.textDark,
                      ),
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ========================================================
  // SUSPECTS
  // ========================================================

  Widget _suspectsCard() {
    return _whitePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Daftar Tersangka',
            style: TextStyle(
              color: NorythColors.navyDark,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 22,
            runSpacing: 16,
            children: [
              _suspect('Raka', 'Mahasiswa', Colors.blueGrey),
              _suspect('Dina', 'Teknisi', Colors.teal),
              _suspect('Budi', 'Admin', Colors.indigo),
            ],
          ),
        ],
      ),
    );
  }

  Widget _suspect(String name, String role, Color color) {
    return Column(
      children: [
        CircleAvatar(
          radius: 29,
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(Icons.person_rounded, color: color, size: 29),
        ),
        const SizedBox(height: 6),
        Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        Text(
          role,
          style: const TextStyle(color: NorythColors.textMuted, fontSize: 11),
        ),
      ],
    );
  }

  // ========================================================
  // COMMON PANEL
  // ========================================================

  Widget _whitePanel({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: NorythColors.borderSoft),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  // ========================================================
  // SQL EDITOR
  // ========================================================

  Widget _editorPanel({bool compact = false}) {
    final busy = _saving || _hintSaving;

    final outputPanel = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF15273B),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          _output,
          style: GoogleFonts.firaCode(
            color: !_hasExecuted
                ? Colors.white70
                : _lastRunCorrect
                ? const Color(0xFF7DE0AC)
                : NorythColors.amberAccent,
            fontSize: 12,
            height: 1.65,
          ),
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1E2E),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          // ================================================
          // TOOLBAR
          // ================================================

          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'SQL',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: busy ? null : _executePractice,
                style: ElevatedButton.styleFrom(
                  backgroundColor: NorythColors.tealLight,
                ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(_saving ? 'Menjalankan...' : 'Jalankan'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : _resetEditor,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white30),
                ),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reset'),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ================================================
          // INSTRUCTIONS
          // ================================================
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF152C3C),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: NorythColors.tealPrimary.withValues(alpha: 0.4),
              ),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  color: Color(0xFF7DD3FC),
                  size: 18,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'TUGAS INVESTIGASI\n'
                    'Tulis query SQL untuk mencari username '
                    'dengan jumlah aktivitas akses_root '
                    'terbanyak pada tabel server_logs.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ================================================
          // SQL INPUT
          // ================================================
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF09131E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: TextField(
              controller: _codeController,
              minLines: 4,
              maxLines: 7,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              style: GoogleFonts.firaCode(
                color: const Color(0xFF7DD3FC),
                fontSize: 12,
                height: 1.5,
              ),
              decoration: const InputDecoration(
                filled: false,
                border: InputBorder.none,
                hintText:
                    '-- Tulis query SQL kamu di sini...\n'
                    '-- Gunakan tabel server_logs\n'
                    '-- Analisis aktivitas mencurigakan',
                hintStyle: TextStyle(
                  color: Colors.white30,
                  fontSize: 12,
                  height: 1.7,
                ),
              ),
            ),
          ),

          const SizedBox(height: 15),

          const Row(
            children: [
              Icon(Icons.terminal_rounded, color: Color(0xFF7DD3FC), size: 19),
              SizedBox(width: 8),
              Text(
                'Hasil Eksekusi SQL',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          if (compact)
            SizedBox(height: 230, child: outputPanel)
          else
            Expanded(child: outputPanel),

          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(
                color: NorythColors.tealLight,
                backgroundColor: Colors.white12,
              ),
            ),

          const SizedBox(height: 8),

          const Text(
            'Noryth SQL Engine • SQLite Investigation',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }
}
