import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../main.dart';
import '../services/python_case_engine.dart';
import '../services/investigation_notes_service.dart';
import '../services/case_003_reward_service.dart';
import '../services/case_003_attempt_service.dart';
import '../services/case_003_submit_service.dart';

class PythonMissionScreen extends StatefulWidget {
  const PythonMissionScreen({super.key});

  @override
  State<PythonMissionScreen> createState() => _PythonMissionScreenState();
}

class _PythonMissionScreenState extends State<PythonMissionScreen> {
  final TextEditingController _editor = TextEditingController();

  PythonRunResult? _result;
  PythonRunResult? _verifiedResult;

  String? _lastSuccessfulCode;
  String? _claimMessage;

  bool _claiming = false;
  bool _savingNote = false;
  bool _claimSucceeded = false;

  int _hintLevel = 0;
  int _attempts = 0;

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _progressStream;

  @override
  void initState() {
    super.initState();

    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid != null) {
      _progressStream = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('missionPractice')
          .doc('case_003')
          .snapshots();
    }
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  void _onCodeChanged(String value) {
    if (_claiming || _savingNote) return;

    setState(() {
      _result = null;
      _verifiedResult = null;
      _lastSuccessfulCode = null;
      _claimMessage = null;
      _claimSucceeded = false;
    });
  }

  
Future<void> _runCode() async {
  if (_claiming || _savingNote) return;

  FocusScope.of(context).unfocus();

  final source = _editor.text.trim();
  final localResult = PythonCaseEngine.evaluate(source);

  setState(() {
    _result = localResult;
    _verifiedResult = null;
    _lastSuccessfulCode = null;
    _claimSucceeded = false;
    _claimMessage = null;
  });

  if (source.isEmpty) return;

  setState(() {
    _claiming = true;
    _claimMessage = 'Memeriksa jawaban di Noryth API...';
  });

  try {
    // Satu request untuk attempt + claim.
    final submission = await Case003SubmitService.submit(
      code: source,
    );

    if (!mounted) return;

    final serverResult = PythonRunResult(
      valid: localResult.valid || submission.correct,
      correct: submission.correct,
      message: submission.correct
          ? 'Investigasi berhasil. '
              'Dua aktivitas penghapusan berisiko tinggi ditemukan.'
          : 'Jawaban belum sesuai dengan kriteria investigasi.',
      rows: localResult.rows,
    );

    if (!submission.correct) {
      setState(() {
        _result = serverResult;
        _attempts = submission.attempts;
        _claimMessage =
            'Percobaan ke-${submission.attempts} tersimpan. '
            'Periksa kembali kondisi kode Python.';
      });

      return;
    }

    final message = submission.alreadyPaid
        ? 'Kasus #003 sudah diselesaikan. '
            'XP tidak diberikan ulang.'
        : 'Investigasi berhasil! '
            '+${submission.awardedXp} XP. '
            'Total XP: ${submission.totalXp}.';

    setState(() {
      _result = serverResult;
      _verifiedResult = serverResult;
      _lastSuccessfulCode = source;
      _claimSucceeded = true;
      _attempts = submission.attempts;
      _claimMessage = message;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: NorythColors.greenSuccess,
        behavior: SnackBarBehavior.floating,
        content: Text(message),
      ),
    );
  } catch (error) {
    if (!mounted) return;

    setState(() {
      _verifiedResult = null;
      _lastSuccessfulCode = null;
      _claimSucceeded = false;
      _claimMessage =
          'Gagal mengirim jawaban ke backend: $error';
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: NorythColors.coralDanger,
        behavior: SnackBarBehavior.floating,
        content: Text(_claimMessage!),
      ),
    );
  } finally {
    if (mounted) {
      setState(() {
        _claiming = false;
      });
    }
  }
}


  void _resetEditor() {
    if (_claiming || _savingNote) return;

    setState(() {
      _editor.clear();
      _result = null;
      _verifiedResult = null;
      _lastSuccessfulCode = null;
      _claimMessage = null;
      _claimSucceeded = false;
    });
  }

  Future<void> _saveEvidence() async {
    if (_savingNote || _claiming) return;

    final result = _verifiedResult;
    final source = _lastSuccessfulCode;

    if (!_claimSucceeded ||
        result == null ||
        !result.correct ||
        source == null ||
        source.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Verifikasi jawaban melalui backend terlebih dahulu.'),
        ),
      );
      return;
    }

    setState(() => _savingNote = true);

    try {
      final evidence = result.rows
          .map((log) {
            return '${log.id} | ${log.actor} | '
                '${log.action} | Risk ${log.riskScore}';
          })
          .join('\n');

      final content =
          '''
KASUS #003 — JEJAK PENGHAPUSAN TERSEMBUNYI

BAHASA: PYTHON

KODE INVESTIGASI:
$source

HASIL BARANG BUKTI:
$evidence

KESIMPULAN:
Ditemukan aktivitas penghapusan berisiko tinggi.
Bukti mengarah pada akun yang melakukan penghapusan berulang.

STATUS:
Jawaban telah diverifikasi oleh Noryth API.
''';

      await InvestigationNotesService.createNote(
        title: 'Barang Bukti Python — Kasus #003',
        content: content,
        category: 'Bukti',
        missionId: 'case_003',
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: NorythColors.greenSuccess,
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Barang bukti Python berhasil disimpan '
            'ke Detective Notebook.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: NorythColors.coralDanger,
          content: Text('Gagal menyimpan barang bukti: $error'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _savingNote = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _claiming || _savingNote;

    return Scaffold(
      backgroundColor: NorythColors.bgSoft,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: NorythColors.navyDark,
        title: const Text(
          'Kasus #003',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Reset Editor',
            onPressed: busy ? null : _resetEditor,
            icon: const Icon(Icons.restart_alt_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              padding: const EdgeInsets.all(18),
              children: [
                _header(),
                const SizedBox(height: 16),
                _statusCard(),
                const SizedBox(height: 16),
                _briefingCard(),
                const SizedBox(height: 16),
                _evidenceCard(),
                const SizedBox(height: 16),
                _editorCard(),
                if (_result != null) ...[
                  const SizedBox(height: 16),
                  _resultCard(_result!),
                ],
                const SizedBox(height: 16),
                _hintCard(),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.all(21),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [NorythColors.navyDark, Color(0xFF0F5672)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'KASUS #003 • PYTHON',
            style: TextStyle(
              color: NorythColors.amberAccent,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Jejak Penghapusan Tersembunyi',
            style: GoogleFonts.merriweather(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Sebuah sistem arsip digital menunjukkan '
            'penghapusan sejumlah file sensitif. '
            'Temukan aktivitas yang paling berisiko '
            'menggunakan Python.',
            style: TextStyle(color: Colors.white70, height: 1.6, fontSize: 13),
          ),
          const SizedBox(height: 15),
          const Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Chip(
                label: Text('Python'),
                avatar: Icon(Icons.code_rounded, size: 17),
              ),
              Chip(label: Text('Menengah')),
              Chip(label: Text('Backend Verified')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusCard() {
    if (_progressStream == null) {
      return _panel(
        title: 'Progres Investigator',
        icon: Icons.shield_outlined,
        child: const Text('Silakan login terlebih dahulu.'),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _progressStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _panel(
            title: 'Progres Investigator',
            icon: Icons.cloud_off_outlined,
            child: const Text('Gagal memuat progres dari Firestore.'),
          );
        }

        if (!snapshot.hasData) {
          return _panel(
            title: 'Progres Investigator',
            icon: Icons.sync_rounded,
            child: const LinearProgressIndicator(),
          );
        }

        final data = snapshot.data?.data() ?? <String, dynamic>{};

        final completed = data['practiceCompleted'] == true;

        final xpAwarded = data['xpAwarded'] == true;

        final earnedXp = (data['xpEarned'] as num?)?.toInt() ?? 0;

        final savedAttempts = (data['attempts'] as num?)?.toInt() ?? 0;

        return _panel(
          title: 'Progres Investigator',
          icon: Icons.shield_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    completed
                        ? Icons.check_circle_rounded
                        : Icons.pending_outlined,
                    color: completed
                        ? NorythColors.greenSuccess
                        : NorythColors.amberAccent,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      completed
                          ? 'Investigasi telah diselesaikan'
                          : 'Investigasi berlangsung',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: NorythColors.navyDark,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Percobaan terakhir tercatat: $_attempts',
                style: const TextStyle(
                  color: NorythColors.textMuted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Percobaan tersimpan: $savedAttempts',
                style: const TextStyle(
                  color: NorythColors.textMuted,
                  fontSize: 12,
                ),
              ),
              if (xpAwarded) ...[
                const SizedBox(height: 10),
                Text(
                  '+$earnedXp XP telah diberikan',
                  style: const TextStyle(
                    color: NorythColors.greenSuccess,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              if (!completed) ...[
                const SizedBox(height: 10),
                const Text(
                  'Selesaikan investigasi untuk '
                  'mendapatkan reward dari backend Go.',
                  style: TextStyle(
                    color: NorythColors.textMuted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _briefingCard() {
    return _panel(
      title: 'Briefing Investigasi',
      icon: Icons.menu_book_outlined,
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tim forensik menemukan enam aktivitas '
            'pada sistem arsip digital.',
            style: TextStyle(fontSize: 13, height: 1.6),
          ),
          SizedBox(height: 12),
          Text(
            'MISI AGEN',
            style: TextStyle(
              color: NorythColors.tealPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Gunakan list comprehension untuk '
            'memilih log dengan risk_score >= 80 '
            'dan action == "deleted".',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Simpan hasil ke variabel, kemudian '
            'tampilkan menggunakan print().',
            style: TextStyle(color: NorythColors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _evidenceCard() {
    return _panel(
      title: 'Arsip Barang Bukti',
      icon: Icons.table_chart_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Dataset tersedia sebagai list bernama logs.',
            style: TextStyle(color: NorythColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 18,
              columns: const [
                DataColumn(label: Text('ID')),
                DataColumn(label: Text('Akun')),
                DataColumn(label: Text('Waktu')),
                DataColumn(label: Text('File')),
                DataColumn(label: Text('Action')),
                DataColumn(label: Text('Risk')),
              ],
              rows: PythonCaseEngine.logs.map((log) {
                return DataRow(
                  cells: [
                    DataCell(Text(log.id)),
                    DataCell(Text(log.actor)),
                    DataCell(Text(log.time)),
                    DataCell(Text(log.resource)),
                    DataCell(Text(log.action)),
                    DataCell(Text('${log.riskScore}')),
                  ],
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorCard() {
    final busy = _claiming || _savingNote;

    return _panel(
      title: 'Python Editor',
      icon: Icons.terminal_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tulis kode Python untuk menyaring log.',
            style: TextStyle(color: NorythColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(16),
            ),
            child: TextField(
              controller: _editor,
              onChanged: _onCodeChanged,
              enabled: !busy,
              minLines: 8,
              maxLines: 16,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              cursorColor: NorythColors.tealPrimary,
              cursorWidth: 2,
              style: const TextStyle(
                color: Color(0xFF14213D),
                fontFamily: 'monospace',
                fontSize: 14,
                height: 1.6,
              ),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                hintText: '# Ketik kode Python di sini...',
                hintStyle: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontFamily: 'monospace',
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(
                    color: NorythColors.tealPrimary,
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _resetEditor,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reset'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : _runCode,
                  style: FilledButton.styleFrom(
                    backgroundColor: NorythColors.tealPrimary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: _claiming
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(_claiming ? 'Memverifikasi...' : 'Jalankan Kode'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultCard(PythonRunResult result) {
    final color = result.correct
        ? NorythColors.greenSuccess
        : result.valid
        ? NorythColors.amberAccent
        : NorythColors.coralDanger;

    final verified =
        _claimSucceeded &&
        _lastSuccessfulCode != null &&
        _verifiedResult != null &&
        result.correct;

    return _panel(
      title: 'Hasil Investigasi',
      icon: Icons.fact_check_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.correct
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.correct
                      ? 'BUKTI DITEMUKAN'
                      : result.valid
                      ? 'HASIL BELUM SESUAI'
                      : 'KODE BELUM VALID',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            result.message,
            style: const TextStyle(fontSize: 12, height: 1.5),
          ),
          if (result.valid) ...[
            const SizedBox(height: 12),
            Text(
              '${result.rows.length} log ditemukan',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (result.rows.isEmpty) const Text('[]'),
            for (final log in result.rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Text(
                  '${log.id} • ${log.actor} • '
                  '${log.action} • Risk ${log.riskScore}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
          ],
          if (_claiming) ...[
            const SizedBox(height: 14),
            const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: NorythColors.tealPrimary,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Menunggu konfirmasi Noryth API...',
                    style: TextStyle(
                      color: NorythColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_claimMessage != null) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: verified
                    ? const Color(0xFFECFDF3)
                    : const Color(0xFFFFF1F0),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _claimMessage!,
                style: TextStyle(
                  color: verified
                      ? NorythColors.greenSuccess
                      : NorythColors.coralDanger,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.5,
                ),
              ),
            ),
          ],
          if (verified) ...[
            const SizedBox(height: 16),
            const Text(
              'Jawaban telah diverifikasi oleh backend. '
              'Barang bukti dapat disimpan.',
              style: TextStyle(color: NorythColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: (_savingNote || _claiming) ? null : _saveEvidence,
                icon: _savingNote
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bookmark_add_outlined),
                label: Text(
                  _savingNote ? 'Menyimpan Bukti...' : 'Simpan ke Catatan',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hintCard() {
    return _panel(
      title: 'Petunjuk Investigator',
      icon: Icons.lightbulb_outline_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Gunakan petunjuk secara bertahap.',
            style: TextStyle(color: NorythColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (_hintLevel >= 1)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Petunjuk 1: Gunakan pola '
                '[log for log in logs if ...].',
              ),
            ),
          if (_hintLevel >= 2)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Petunjuk 2: Gunakan field risk_score '
                'dan operator >= 80.',
              ),
            ),
          if (_hintLevel >= 3)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Petunjuk 3: Tambahkan '
                'and log["action"] == "deleted".',
              ),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _hintLevel >= 3
                ? null
                : () {
                    setState(() => _hintLevel++);
                  },
            icon: const Icon(Icons.tips_and_updates_outlined),
            label: Text(
              _hintLevel == 0
                  ? 'Lihat Petunjuk 1'
                  : _hintLevel < 3
                  ? 'Petunjuk Berikutnya'
                  : 'Semua Petunjuk Terbuka',
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NorythColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: NorythColors.tealPrimary),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.bold,
                    color: NorythColors.navyDark,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
