// lib/login/auth_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

class LoginRateLimitedException implements Exception {
  const LoginRateLimitedException({required this.retryAfterSeconds});

  final int? retryAfterSeconds;
}

class AuthService {
  final _supabase = Supabase.instance.client;

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
}
