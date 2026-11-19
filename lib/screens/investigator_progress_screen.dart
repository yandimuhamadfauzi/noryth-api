import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../main.dart';
import '../widgets/investigator_achievements_card.dart';

class InvestigatorProgressScreen extends StatefulWidget {
  const InvestigatorProgressScreen({super.key});

  @override
  State<InvestigatorProgressScreen> createState() =>
      _InvestigatorProgressScreenState();
}

class _InvestigatorProgressScreenState
    extends State<InvestigatorProgressScreen> {
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userStream;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _practiceStream;
  Stream<QuerySnapshot<Map<String, dynamic>>>? _historyStream;

  @override
  void initState() {
    super.initState();

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);

    _userStream = userRef.snapshots();

    _practiceStream = userRef.collection('missionPractice').snapshots();

    _historyStream = userRef
        .collection('missionPractice')
        .doc('case_003')
        .collection('attemptHistory')
        .orderBy('createdAt', descending: true)
        .limit(100)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NorythColors.bgSoft,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: NorythColors.navyDark,
        title: const Text(
          'Progres Investigator',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      body:
          _userStream == null ||
              _practiceStream == null ||
              _historyStream == null
          ? const Center(child: Text('Silakan login terlebih dahulu.'))
          : StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _userStream,
              builder: (context, userSnapshot) {
                if (userSnapshot.hasError) {
                  return _error('Gagal membaca profil investigator.');
                }

                if (!userSnapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (!userSnapshot.data!.exists) {
                  return _error('Profil investigator tidak ditemukan.');
                }

                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _practiceStream,
                  builder: (context, practiceSnapshot) {
                    if (practiceSnapshot.hasError) {
                      return _error('Gagal membaca progres kasus.');
                    }

                    if (!practiceSnapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _historyStream,
                      builder: (context, historySnapshot) {
                        final historyError = historySnapshot.hasError;

                        final historyDocs =
                            historySnapshot.data?.docs ??
                            <QueryDocumentSnapshot<Map<String, dynamic>>>[];

                        return _dashboard(
                          userSnapshot.data!.data()!,
                          practiceSnapshot.data!.docs,
                          historyDocs,
                          historyLoading:
                              !historyError && !historySnapshot.hasData,
                          historyError: historyError,
                        );
                      },
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _dashboard(
    Map<String, dynamic> user,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> practiceDocs,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> historyDocs, {
    required bool historyLoading,
    required bool historyError,
  }) {
    final practices = {for (final doc in practiceDocs) doc.id: doc.data()};

    final case001 = practices['case_001'] ?? <String, dynamic>{};

    final case002 = practices['case_002'] ?? <String, dynamic>{};

    final case003 = practices['case_003'] ?? <String, dynamic>{};

    final completed001 = case001['practiceCompleted'] == true;

    final completed002 = case002['practiceCompleted'] == true;

    final completed003 = case003['practiceCompleted'] == true;

    final completedCount = [
      completed001,
      completed002,
      completed003,
    ].where((completed) => completed).length;

    final xp = (user['xp'] as num?)?.toInt() ?? 0;
    final level = (user['level'] as num?)?.toInt() ?? 1;

    final rank = user['rank']?.toString() ?? 'Investigator';

    final name = user['displayName']?.toString() ?? 'Investigator';

    final attempts003 = (case003['attempts'] as num?)?.toInt() ?? 0;

    final recordedCount = historyDocs.length;

    final correctCount = historyDocs
        .where((doc) => doc.data()['correct'] == true)
        .length;

    final accuracy = recordedCount == 0
        ? 0.0
        : correctCount / recordedCount * 100;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            _profileHeader(name, rank, level),
            const SizedBox(height: 16),

            _statistics(xp, level, completedCount),
            const SizedBox(height: 16),

            _completionCard(completedCount),
            const SizedBox(height: 16),

            _panel(
              'Progres Seluruh Kasus',
              Icons.folder_open_rounded,
              Column(
                children: [
                  _caseRow(
                    'Kasus #001',
                    'Investigasi SQL',
                    Icons.storage_rounded,
                    completed001,
                  ),
                  const Divider(height: 24),
                  _caseRow(
                    'Kasus #002',
                    'Investigasi JavaScript',
                    Icons.code_rounded,
                    completed002,
                  ),
                  const Divider(height: 24),
                  _caseRow(
                    'Kasus #003',
                    'Investigasi Python',
                    Icons.data_object_rounded,
                    completed003,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            _panel(
              'Analitik Investigasi Python',
              Icons.analytics_outlined,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _metricRow('Total percobaan Python', '$attempts003'),
                  const SizedBox(height: 10),
                  _metricRow('Riwayat yang dianalisis', '$recordedCount'),
                  const SizedBox(height: 10),
                  _metricRow('Jawaban benar dalam riwayat', '$correctCount'),
                  const Divider(height: 28),

                  if (historyError)
                    const Text(
                      'Riwayat belum dapat dibaca.',
                      style: TextStyle(color: NorythColors.coralDanger),
                    )
                  else if (historyLoading)
                    const LinearProgressIndicator()
                  else ...[
                    Text(
                      'Akurasi riwayat: '
                      '${accuracy.toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: NorythColors.navyDark,
                      ),
                    ),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: accuracy / 100,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(10),
                      backgroundColor: NorythColors.borderSoft,
                      color: NorythColors.tealPrimary,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Akurasi dihitung dari maksimal '
                      '100 riwayat Python terbaru. '
                      'Percobaan sebelum fitur riwayat '
                      'diterapkan tidak ikut dihitung.',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: NorythColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),

            const InvestigatorAchievementsCard(),

            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }

  Widget _profileHeader(String name, String rank, int level) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [NorythColors.navyDark, Color(0xFF0F5672)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 30,
            backgroundColor: Colors.white24,
            child: Icon(Icons.shield_outlined, color: Colors.white, size: 31),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: GoogleFonts.poppins(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$rank • Level $level',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statistics(int xp, int level, int completed) {
    return Row(
      children: [
        Expanded(child: _statTile('Total XP', '$xp', Icons.bolt_rounded)),
        const SizedBox(width: 10),
        Expanded(
          child: _statTile('Level', '$level', Icons.trending_up_rounded),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _statTile('Kasus', '$completed/3', Icons.fact_check_outlined),
        ),
      ],
    );
  }

  Widget _statTile(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NorythColors.borderSoft),
      ),
      child: Column(
        children: [
          Icon(icon, color: NorythColors.tealPrimary),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 22,
              color: NorythColors.navyDark,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: NorythColors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _completionCard(int completed) {
    return _panel(
      'Penyelesaian Investigasi',
      Icons.flag_outlined,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$completed dari 3 kasus selesai',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: completed / 3,
            minHeight: 9,
            borderRadius: BorderRadius.circular(10),
            color: NorythColors.tealPrimary,
            backgroundColor: NorythColors.borderSoft,
          ),
        ],
      ),
    );
  }

  Widget _caseRow(
    String title,
    String subtitle,
    IconData icon,
    bool completed,
  ) {
    return Row(
      children: [
        Icon(icon, color: NorythColors.tealPrimary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: NorythColors.navyDark,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  color: NorythColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        Icon(
          completed
              ? Icons.check_circle_rounded
              : Icons.radio_button_unchecked_rounded,
          color: completed ? NorythColors.greenSuccess : NorythColors.textMuted,
        ),
      ],
    );
  }

  Widget _metricRow(String label, String value) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: NorythColors.navyDark),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: NorythColors.navyDark,
          ),
        ),
      ],
    );
  }

  Widget _panel(String title, IconData icon, Widget child) {
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
                    fontSize: 15,
                    color: NorythColors.navyDark,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _error(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: NorythColors.coralDanger),
        ),
      ),
    );
  }
}
