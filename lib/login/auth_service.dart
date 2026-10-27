// lib/login/auth_service.dart
import 'package:flutter_dotenv/flutter_dotenv.dart'; // Add this import

import 'package:http/http.dart' as http;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../services/app_logger.dart';

class AuthService {
  final _supabase = Supabase.instance.client;

  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  Future<Map<String, dynamic>?> login(String username, String password) async {
    final response = await _supabase.rpc(
      'profile_login_v1',
      params: {'p_username': username, 'p_password': password},
    );
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

  Future<bool> sendEmailJsOtp(String email, String otpCode) async {
    try {
      final response = await http.post(
        Uri.parse('https://api.emailjs.com/api/v1.0/email/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'service_id': dotenv.env['EMAILJS_SERVICE_ID'],
          'template_id': dotenv.env['EMAILJS_TEMPLATE_ID'],
          'user_id': dotenv.env['EMAILJS_PUBLIC_KEY'],
          'template_params': {'email': email, 'otp_code': otpCode},
        }),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        AppLogger.error(
          'Password reset email request failed with status ${response.statusCode}',
        );
        throw Exception('Password reset email request failed.');
      }
    } catch (e, stackTrace) {
      AppLogger.error(
        'Password reset email request failed',
        error: e,
        stackTrace: stackTrace,
      );
      throw Exception('Password reset email request failed.');
    }
  }

  Future<bool> resetPasswordForUser(String email, String newPassword) async {
    try {
      final hashedNewPassword = _hashPassword(newPassword);
      await _supabase
          .from('profiles')
          .update({'password': hashedNewPassword})
          .eq('email', email);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> requestPasswordReset(String email) async {
    // This is a placeholder. The logic in ForgotPasswordPage seems to handle this.
    // For now, we can check if the user exists.
    final user = await _supabase
        .from('profiles')
        .select('id')
        .eq('email', email)
        .maybeSingle();
    if (user == null) {
      throw Exception('Password reset request could not be completed.');
    }
  }

  Future<bool> isAdminUser(String username) async {
    final response = await _supabase
        .from('profiles')
        .select('role')
        .eq('username', username)
        .maybeSingle();
    return response?['role']?.toString().toLowerCase() == 'admin';
  }
}
