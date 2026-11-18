
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class Case003SubmitResult {
  final bool success;
  final bool correct;
  final bool completed;
  final bool alreadyPaid;
  final int attempts;
  final int awardedXp;
  final int totalXp;
  final String message;

  const Case003SubmitResult({
    required this.success,
    required this.correct,
    required this.completed,
    required this.alreadyPaid,
    required this.attempts,
    required this.awardedXp,
    required this.totalXp,
    required this.message,
  });

  factory Case003SubmitResult.fromJson(
    Map<String, dynamic> json,
  ) {
    return Case003SubmitResult(
      success: json['success'] == true,
      correct: json['correct'] == true,
      completed: json['completed'] == true,
      alreadyPaid: json['alreadyPaid'] == true,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      awardedXp: (json['awardedXp'] as num?)?.toInt() ?? 0,
      totalXp: (json['totalXp'] as num?)?.toInt() ?? 0,
      message: json['message'] as String? ?? '',
    );
  }
}

class Case003SubmitService {
  Case003SubmitService._();

  static const String _baseUrl = String.fromEnvironment(
    'NORYTH_API_BASE_URL',
    defaultValue: 'https://noryth-api.onrender.com',
  );

  static Future<Case003SubmitResult> submit({
    required String code,
  }) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw StateError('Silakan login terlebih dahulu.');
    }

    final token = await user.getIdToken();

    if (token == null || token.isEmpty) {
      throw StateError(
        'Token login tidak tersedia.',
      );
    }

    final baseUrl = _baseUrl.replaceFirst(
      RegExp(r'/+$'),
      '',
    );

    final url = Uri.parse(
      '$baseUrl/api/cases/003/submit',
    );

    final response = await http
        .post(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'code': code,
          }),
        )
        .timeout(const Duration(seconds: 45));

    Map<String, dynamic> data;

    try {
      data = jsonDecode(response.body)
          as Map<String, dynamic>;
    } catch (_) {
      throw StateError(
        'Respons backend tidak valid '
        '(HTTP ${response.statusCode}).',
      );
    }

    if (response.statusCode != 200) {
      throw StateError(
        data['error']?.toString() ??
            'Gagal mengirim jawaban '
                '(HTTP ${response.statusCode}).',
      );
    }

    final result = Case003SubmitResult.fromJson(data);

    if (!result.success) {
      throw StateError(
        'Backend belum menerima jawaban.',
      );
    }

    return result;
  }
}
