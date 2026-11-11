import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_logger.dart';

class LoginRateLimitedException implements Exception {
  const LoginRateLimitedException({required this.retryAfterSeconds});

  final int? retryAfterSeconds;
}

class AuthService {
  final _supabase = Supabase.instance.client;

  String _hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  Future<Map<String, dynamic>?> login(String username, String password) async {
    final response = await _supabase.rpc(
      'profile_login_v1',
      params: {'p_username': username, 'p_password': password},
    );
    if (response is Map &&
        (response['rate_limited'] == true ||
            response['status'] == 'rate_limited')) {
      final rawRetryAfter = response['retry_after_seconds'];
      final parsedRetryAfter = rawRetryAfter is num
          ? rawRetryAfter.ceil()
          : int.tryParse(rawRetryAfter?.toString() ?? '');
      throw LoginRateLimitedException(
        retryAfterSeconds: parsedRetryAfter != null && parsedRetryAfter > 0
            ? parsedRetryAfter
            : null,
      );
    }
    return _profileFromSessionPayload(response);
  }

  Future<Map<String, dynamic>?> restoreSession(String sessionToken) async {
    final response = await _supabase.rpc(
      'profile_restore_session_v1',
      params: {'p_session_token': sessionToken},
    );
    if (response == null) return null;
    final profile = _profileFromSessionPayload(
      response,
      existingSessionToken: sessionToken,
    );
    if (profile == null) {
      throw const FormatException('Invalid session restoration response.');
    }
    return profile;
  }

  Future<void> logout(String sessionToken) async {
    await _supabase.rpc(
      'profile_logout_v1',
      params: {'p_session_token': sessionToken},
    );
  }

  Map<String, dynamic>? _profileFromSessionPayload(
    dynamic response, {
    String? existingSessionToken,
  }) {
    if (response == null || response is! Map) return null;
    final payload = Map<String, dynamic>.from(response);
    final rawProfile = payload['profile'];
    if (rawProfile is! Map) return null;
    final profile = Map<String, dynamic>.from(rawProfile);
    final token = existingSessionToken ?? payload['session_token']?.toString();
    if (token == null || token.isEmpty) return null;
    profile['session_token'] = token;
    profile['session_expires_at'] = payload['expires_at'];
    return profile;
  }

  Future<String?> getEmailFromUsername(String username) async {
    final response = await _supabase
        .from('profiles')
        .select('email')
        .eq('username', username)
        .maybeSingle();
    return response?['email'];
  }

  Future<bool> isAdminUser(String username) async {
    final response = await _supabase
        .from('profiles')
        .select('role')
        .eq('username', username)
        .maybeSingle();
    return response?['role']?.toString().toLowerCase() == 'admin';
  }

  Future<bool> sendEmailJsOtp(String email, String code) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'service_id': dotenv.env['EMAILJS_SERVICE_ID'],
          'template_id': dotenv.env['EMAILJS_TEMPLATE_ID'],
          'user_id': dotenv.env['EMAILJS_PUBLIC_KEY'],
          'template_params': {'email': email, 'otp_code': code},
        }),
      );
      if (response.statusCode == 200) return true;
      throw Exception('Password reset email request failed.');
    } catch (error, stackTrace) {
      AppLogger.error(
        'Password reset email request failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw Exception('Password reset email request failed.');
    }
  }

  Future<bool> resetPasswordForUser(String email, String newPassword) async {
    try {
      await _supabase
          .from('profiles')
          .update({'password': _hashPassword(newPassword)})
          .eq('email', email);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> requestPasswordRecovery(
    String username,
    String channel,
  ) async {
    final response = await _supabase.functions.invoke(
      'password-recovery',
      body: {'action': 'request', 'username': username, 'channel': channel},
    );
    final data = response.data;
    final challengeId = data is Map ? data['challengeId']?.toString() : null;
    if (challengeId == null || challengeId.isEmpty) {
      throw StateError('Password recovery is unavailable. Please try again.');
    }
    return challengeId;
  }

  Future<String?> verifyPasswordRecovery(
    String challengeId,
    String code,
  ) async {
    final response = await _supabase.functions.invoke(
      'password-recovery',
      body: {'action': 'verify', 'challengeId': challengeId, 'code': code},
    );
    final data = response.data;
    return data is Map ? data['resetToken']?.toString() : null;
  }

  Future<bool> completePasswordRecovery(
    String resetToken,
    String password,
  ) async {
    final response = await _supabase.functions.invoke(
      'password-recovery',
      body: {
        'action': 'complete',
        'resetToken': resetToken,
        'password': password,
      },
    );
    final data = response.data;
    return data is Map && data['success'] == true;
  }
}
