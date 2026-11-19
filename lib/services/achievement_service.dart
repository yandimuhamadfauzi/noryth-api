
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class AchievementSyncResult {
  final bool success;
  final List<String> unlocked;
  final int total;
  final String message;

  const AchievementSyncResult({
    required this.success,
    required this.unlocked,
    required this.total,
    required this.message,
  });

  factory AchievementSyncResult.fromJson(
    Map<String, dynamic> data,
  ) {
    return AchievementSyncResult(
      success: data['success'] == true,
      unlocked: (data['unlocked'] as List<dynamic>? ?? [])
          .map((item) => item.toString())
          .toList(),
      total: (data['total'] as num?)?.toInt() ?? 0,
      message: data['message']?.toString() ?? '',
    );
  }
}

class AchievementService {
  AchievementService._();

  static const String _baseUrl = String.fromEnvironment(
    'NORYTH_API_BASE_URL',
    defaultValue: 'https://noryth-api.onrender.com',
  );

  static Future<AchievementSyncResult> sync() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw StateError('Silakan login terlebih dahulu.');
    }

    final token = await user.getIdToken();

    if (token == null || token.isEmpty) {
      throw StateError('Token login tidak tersedia.');
    }

    final baseUrl = _baseUrl.replaceFirst(
      RegExp(r'/+$'),
      '',
    );

    final response = await http.post(
      Uri.parse('$baseUrl/api/achievements/sync'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    ).timeout(const Duration(seconds: 30));

    Map<String, dynamic> data;

    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw StateError(
        'Respons server tidak valid '
        '(HTTP ${response.statusCode}).',
      );
    }

    if (response.statusCode != 200) {
      throw StateError(
        data['error']?.toString() ??
            'Gagal sinkronisasi badge '
                '(HTTP ${response.statusCode}).',
      );
    }

    final result = AchievementSyncResult.fromJson(data);

    if (!result.success) {
      throw StateError('Sinkronisasi badge belum berhasil.');
    }

    return result;
  }
}
