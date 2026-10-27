import 'dart:async';

import 'package:flutter/services.dart';

enum AppErrorCategory {
  authentication,
  permission,
  cameraPermission,
  cameraUnavailable,
  network,
  timeout,
  dataLoad,
  dataSave,
  upload,
  server,
  unknown,
}

class AppUserFacingException implements Exception {
  const AppUserFacingException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppErrorMapper {
  AppErrorMapper._();

  static const invalidCredentials = 'Invalid username or password.';
  static const loginUnavailable =
      'Unable to sign in right now. Please try again.';
  static const authentication =
      'Unable to sign in. Please check your credentials and try again.';
  static const permission = "You don't have permission to perform this action.";
  static const cameraPermission =
      'Camera access is required to use the scanner. Please allow camera access and try again.';
  static const scannerCameraPermission =
      'Camera access is required to scan items. Please allow camera access and try again.';
  static const cameraUnavailable =
      'Camera is unavailable right now. Please try again.';
  static const network =
      'Unable to connect. Check your internet connection and try again.';
  static const timeout = 'The request took too long. Please try again.';
  static const dataLoad = 'Unable to load this information. Please try again.';
  static const dataSave = 'Unable to save your changes. Please try again.';
  static const upload = 'Unable to upload the file. Please try again.';
  static const server =
      'Something went wrong while processing your request. Please try again.';
  static const unknown = 'Something went wrong. Please try again.';

  static String message(
    Object error, {
    AppErrorCategory fallback = AppErrorCategory.unknown,
  }) {
    if (error is AppUserFacingException) return error.message;
    return messageFor(categoryFor(error, fallback: fallback));
  }

  static AppErrorCategory categoryFor(
    Object error, {
    AppErrorCategory fallback = AppErrorCategory.unknown,
  }) {
    if (error is TimeoutException) return AppErrorCategory.timeout;

    final details = '${error.runtimeType} $error'.toLowerCase();
    final isCamera = details.contains('camera');

    if (isCamera &&
        _containsAny(details, const [
          'permission',
          'denied',
          'notallowederror',
          'cameraaccessdenied',
        ])) {
      return AppErrorCategory.cameraPermission;
    }
    if (isCamera ||
        _containsAny(details, const [
          'mobile scanner',
          'mobilescanner',
          'no camera',
        ])) {
      return AppErrorCategory.cameraUnavailable;
    }
    if (error is PlatformException &&
        _containsAny(details, const ['permission', 'denied', 'unauthorized'])) {
      return AppErrorCategory.permission;
    }
    if (_containsAny(details, const [
      'socketexception',
      'clientexception',
      'failed host lookup',
      'network is unreachable',
      'connection refused',
      'connection reset',
      'network request failed',
      'xmlhttprequest error',
      'offline',
    ])) {
      return AppErrorCategory.network;
    }
    if (_containsAny(details, const ['timeout', 'timed out'])) {
      return AppErrorCategory.timeout;
    }
    if (_containsAny(details, const [
      'permission denied',
      'not authorized',
      'unauthorized',
      'forbidden',
      'row-level security',
      'rls',
      '42501',
      '403',
    ])) {
      return AppErrorCategory.permission;
    }
    if (_containsAny(details, const [
      'authexception',
      'invalid login credentials',
      'invalid credentials',
      'authentication',
    ])) {
      return AppErrorCategory.authentication;
    }
    if (_containsAny(details, const [
      'postgrestexception',
      'supabaseexception',
      'storageexception',
      'api exception',
      'http exception',
      'server exception',
      'websocket',
      '500',
      '502',
      '503',
      '504',
    ])) {
      return switch (fallback) {
        AppErrorCategory.dataLoad ||
        AppErrorCategory.dataSave ||
        AppErrorCategory.upload => fallback,
        _ => AppErrorCategory.server,
      };
    }
    return fallback;
  }

  static String messageFor(AppErrorCategory category) => switch (category) {
    AppErrorCategory.authentication => authentication,
    AppErrorCategory.permission => permission,
    AppErrorCategory.cameraPermission => cameraPermission,
    AppErrorCategory.cameraUnavailable => cameraUnavailable,
    AppErrorCategory.network => network,
    AppErrorCategory.timeout => timeout,
    AppErrorCategory.dataLoad => dataLoad,
    AppErrorCategory.dataSave => dataSave,
    AppErrorCategory.upload => upload,
    AppErrorCategory.server => server,
    AppErrorCategory.unknown => unknown,
  };

  static bool _containsAny(String value, List<String> terms) =>
      terms.any(value.contains);
}
