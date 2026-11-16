import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_error_mapper.dart';

class LoginRateLimitedException implements Exception {
  const LoginRateLimitedException({required this.retryAfterSeconds});

  final int? retryAfterSeconds;
}

class RecoveryQuestionChallenge {
  const RecoveryQuestionChallenge(this.challengeId, this.questionIds);
  final String challengeId;
  final List<String> questionIds;
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

  Future<String> requestPasswordRecovery(
    String username,
    String channel,
  ) async {
    late final FunctionResponse response;
    try {
      response = await _supabase.functions.invoke(
        'password-recovery',
        body: {'action': 'request', 'username': username, 'channel': channel},
      );
    } on FunctionException catch (error) {
      if (channel == 'email' && error.status >= 400) {
        final details = error.details;
        final serverError = details is Map
            ? details['error']?.toString()
            : null;
        if (serverError == 'Invalid channel') {
          throw const AppUserFacingException(
            'Email recovery needs a server update. Use SMS or security questions for now.',
          );
        }
        if (serverError == 'Email recovery is not configured') {
          throw const AppUserFacingException(
            'Email recovery needs EmailJS server settings. Use SMS or security questions for now.',
          );
        }
        throw const AppUserFacingException(
          'Email recovery is unavailable right now. Use SMS or security questions.',
        );
      }
      rethrow;
    }
    final data = response.data;
    final challengeId = data is Map ? data['challengeId']?.toString() : null;
    if (challengeId == null || challengeId.isEmpty) {
      throw const AppUserFacingException(
        'No code was sent. Staff should ask their administrator to reset their password. Admins can check their username or try later.',
      );
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

  Future<RecoveryQuestionChallenge> beginQuestionRecovery(
    String username,
  ) async {
    final response = await _supabase.functions.invoke(
      'password-recovery',
      body: {'action': 'questions-begin', 'username': username},
    );
    final data = response.data;
    if (data is! Map || data['questionIds'] is! List) {
      throw StateError('Password recovery is unavailable. Please try again.');
    }
    final ids = (data['questionIds'] as List)
        .map((id) => id.toString())
        .toList();
    final challengeId = data['challengeId']?.toString() ?? '';
    if (ids.isEmpty) {
      throw const AppUserFacingException(
        'Security question verification could not start. Check the Admin username and saved setup, or try again later.',
      );
    }
    if (challengeId.isEmpty || ids.length != 3) {
      throw StateError('Password recovery is unavailable. Please try again.');
    }
    return RecoveryQuestionChallenge(challengeId, ids);
  }

  Future<String?> verifyQuestionRecovery(
    String challengeId,
    List<String> answers,
  ) async {
    final response = await _supabase.functions.invoke(
      'password-recovery',
      body: {
        'action': 'questions-verify',
        'challengeId': challengeId,
        'answers': answers,
      },
    );
    final data = response.data;
    return data is Map ? data['resetToken']?.toString() : null;
  }

  Future<bool> completePasswordRecovery(
    String resetToken,
    String password, {
    bool securityQuestions = false,
  }) async {
    final response = await _supabase.functions.invoke(
      'password-recovery',
      body: {
        'action': 'complete',
        'resetToken': resetToken,
        'password': password,
        'method': securityQuestions ? 'questions' : 'code',
      },
    );
    final data = response.data;
    return data is Map && data['success'] == true;
  }
}
