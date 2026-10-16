// lib/login/auth_service.dart
import 'package:flutter_dotenv/flutter_dotenv.dart'; // Add this import

import 'package:http/http.dart' as http;

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

class AuthService {
  final _supabase = Supabase.instance.client;

  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  Future<Map<String, dynamic>?> login(String username, String password) async {
    final hashedPassword = _hashPassword(password);
    return await _supabase
        .from('profiles')
        .select()
        .eq('username', username)
        .eq('password', hashedPassword)
        .maybeSingle();
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
        debugPrint("EmailJS Failed: ${response.statusCode} - ${response.body}");
        throw Exception("Failed to send email: ${response.body}");
      }
    } catch (e) {
      debugPrint("EmailJS Error: $e");
      throw Exception(e.toString());
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
      throw Exception('Email not found.');
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
