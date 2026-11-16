
import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'xp_service.dart';

class NorythCase001Service {
  static const String _baseUrl = String.fromEnvironment(
    'NORYTH_API_BASE_URL',
    defaultValue: 'https://noryth-api.onrender.com',
  );

  static const Duration _timeout = Duration(seconds: 120);

  final FirebaseAuth _auth;
  final http.Client _client;

  NorythCase001Service({
    FirebaseAuth? auth,
    http.Client? client,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _client = client ?? http.Client();

  Future<Map<String, String>> _headers() async {
    final user = _auth.currentUser;

    if (user == null) {
      throw StateError('Silakan login terlebih dahulu.');
    }

    final token = await user.getIdToken();

    if (token == null || token.isEmpty) {
      throw StateError('Token login tidak tersedia.');
    }

    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$_baseUrl$path'),
            headers: await _headers(),
            body: jsonEncode(payload),
          )
          .timeout(_timeout);

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Respons backend tidak valid.',
        );
      }

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw StateError(
          (decoded['error'] ?? 'HTTP ${response.statusCode}')
              .toString(),
        );
      }

      return decoded;
    } on TimeoutException {
      throw StateError(
        'Backend belum merespons. '
        'Periksa koneksi dan coba kembali.',
      );
    }
  }

  Future<void> recordHint() async {
    final data = await _post(
      '/api/cases/001/hint',
      <String, dynamic>{},
    );

    if (data['success'] != true) {
      throw StateError(
        'Penggunaan petunjuk belum berhasil dicatat.',
      );
    }
  }

  Future<MissionRewardResult> claimReward({
    required String query,
  }) async {
    final data = await _post(
      '/api/cases/001/claim',
      {'query': query},
    );

    if (data['success'] != true) {
      throw StateError(
        'Klaim reward belum berhasil.',
      );
    }

    final totalXp = (data['totalXp'] as num).toInt();
    final earnedXp = (data['awardedXp'] as num).toInt();
    final alreadyPaid = data['alreadyPaid'] == true;

    final progress = XpRules.calculate(totalXp);

    return MissionRewardResult(
      newlyAwarded: !alreadyPaid && earnedXp > 0,
      earnedXp: earnedXp,
      totalXp: totalXp,
      level: progress.level,
      rank: progress.rank,
    );
  }

  void dispose() {
    _client.close();
  }
}
