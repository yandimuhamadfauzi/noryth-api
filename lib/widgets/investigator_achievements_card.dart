
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../main.dart';
import '../services/achievement_service.dart';

class _BadgeDefinition {
  final String id;
  final String name;
  final String description;
  final IconData icon;

  const _BadgeDefinition(
    this.id,
    this.name,
    this.description,
    this.icon,
  );
}

class InvestigatorAchievementsCard extends StatefulWidget {
  const InvestigatorAchievementsCard({super.key});

  @override
  State<InvestigatorAchievementsCard> createState() =>
      _InvestigatorAchievementsCardState();
}

class _InvestigatorAchievementsCardState
    extends State<InvestigatorAchievementsCard> {
  static const _badges = [
    _BadgeDefinition(
      'code_breaker',
      'Pemecah Kode',
      'Selesaikan Kasus #001 SQL',
      Icons.storage_rounded,
    ),
    _BadgeDefinition(
      'pattern_hunter',
      'Pemburu Pola',
      'Selesaikan Kasus #002 JavaScript',
      Icons.code_rounded,
    ),
    _BadgeDefinition(
      'forensic_analyst',
      'Analis Forensik',
      'Selesaikan Kasus #003 Python',
      Icons.terminal_rounded,
    ),
    _BadgeDefinition(
      'master_investigator',
      'Master Investigator',
      'Selesaikan ketiga kasus',
      Icons.military_tech_rounded,
    ),
  ];

  Stream<QuerySnapshot<Map<String, dynamic>>>? _stream;

  bool _syncing = false;
  String? _syncError;

  @override
  void initState() {
    super.initState();

    final uid = FirebaseAuth.instance.currentUser?.uid;

    if (uid != null) {
      _stream = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('achievements')
          .snapshots();

      _sync();
    }
  }

  Future<void> _sync() async {
    if (_syncing) return;

    setState(() {
      _syncing = true;
      _syncError = null;
    });

    try {
      await AchievementService.sync();
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _syncError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  String _formatDate(dynamic value) {
    if (value is! Timestamp) {
      return 'Tanggal belum tersedia';
    }

    final date = value.toDate().toLocal();

    String two(int n) => n.toString().padLeft(2, '0');

    return '${two(date.day)}/${two(date.month)}/${date.year}'
        ' • ${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: NorythColors.borderSoft,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.workspace_premium_outlined,
                color: NorythColors.tealPrimary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Koleksi Badge Investigator',
                  style: GoogleFonts.poppins(
                    color: NorythColors.navyDark,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Sinkronkan Badge',
                onPressed: _syncing ? null : _sync,
                icon: _syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.sync_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Badge diperoleh dengan menyelesaikan '
            'investigasi dan diverifikasi backend.',
            style: TextStyle(
              color: NorythColors.textMuted,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          if (_syncError != null) ...[
            const SizedBox(height: 12),
            Text(
              'Sinkronisasi gagal: $_syncError',
              style: const TextStyle(
                color: NorythColors.coralDanger,
                fontSize: 12,
              ),
            ),
            TextButton(
              onPressed: _syncing ? null : _sync,
              child: const Text('Coba Lagi'),
            ),
          ],
          const SizedBox(height: 16),
          if (_stream == null)
            const Text('Silakan login terlebih dahulu.')
          else
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(
                    'Gagal membaca badge: ${snapshot.error}',
                    style: const TextStyle(
                      color: NorythColors.coralDanger,
                    ),
                  );
                }

                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                final unlocked = {
                  for (final doc in snapshot.data!.docs)
                    if (doc.data()['unlocked'] == true)
                      doc.id: doc.data(),
                };

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${unlocked.length} dari ${_badges.length} '
                      'badge diperoleh',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: NorythColors.navyDark,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        final columns = width >= 580 ? 2 : 1;

                        return GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _badges.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            mainAxisExtent: 154,
                          ),
                          itemBuilder: (context, index) {
                            final badge = _badges[index];
                            final data = unlocked[badge.id];

                            return _badgeTile(
                              badge,
                              unlocked: data != null,
                              unlockedAt: data?['unlockedAt'],
                            );
                          },
                        );
                      },
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _badgeTile(
    _BadgeDefinition badge, {
    required bool unlocked,
    required dynamic unlockedAt,
  }) {
    final color = unlocked
        ? NorythColors.tealPrimary
        : NorythColors.textMuted;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: unlocked
            ? const Color(0xFFF0F9FB)
            : const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: unlocked
              ? NorythColors.tealPrimary.withValues(alpha: 0.25)
              : NorythColors.borderSoft,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 39,
                height: 39,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(badge.icon, color: color),
              ),
              const Spacer(),
              Icon(
                unlocked
                    ? Icons.verified_rounded
                    : Icons.lock_outline_rounded,
                color: unlocked
                    ? NorythColors.greenSuccess
                    : NorythColors.textMuted,
                size: 19,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            badge.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: unlocked
                  ? NorythColors.navyDark
                  : NorythColors.textMuted,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            badge.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: NorythColors.textMuted,
            ),
          ),
          const Spacer(),
          Text(
            unlocked
                ? 'Diperoleh: ${_formatDate(unlockedAt)}'
                : 'Belum terbuka',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: unlocked
                  ? NorythColors.greenSuccess
                  : NorythColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
