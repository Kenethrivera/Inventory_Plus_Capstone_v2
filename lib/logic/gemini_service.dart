import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// The live scanner always gets a terminal success/failure response.
class GeminiLiveResponse {
  final Map<String, dynamic>? data;
  final String? error;
  final int? httpStatus;
  const GeminiLiveResponse({this.data, this.error, this.httpStatus});
}

class GeminiService {
  // The last key that worked is tried first on the next scan.
  static int _currentKeyIndex = 0;

  // Keys that hit a 429 (quota/rate limit) are skipped for a short cooldown.
  static final Map<int, DateTime> _keyCooldownUntil = {};
  static const _quotaCooldown = Duration(minutes: 2);

  // Per-key request timeout.
  static const _perKeyTimeout = Duration(seconds: 8);

  // If the current key is still pending after this long, ALSO start the
  // next key (without cancelling the first).
  static const _hedgeDelay = Duration(seconds: 3);

  static const _prompt =
      "You are a strict hardware store inventory scanner. Analyze ONLY the primary object being "
      "held or shown in the foreground — completely ignore any hands, fingers, faces, people, or "
      "background clutter in the image; describe the object itself, never the scene.\n\n"
      "Rules:\n"
      "1. 'item_name' must ALWAYS be a short, specific object name (2-4 words max), e.g. 'Phillips "
      "Screwdriver', 'Claw Hammer', 'Ballpoint Pen'. If nothing recognizable is visible, answer 'Unknown Object'. Otherwise "
      "identify the actual object, even if it isn't hardware.\n"
      "2. Set 'is_hardware' to true ONLY if the object is a construction, plumbing, electrical, or "
      "maintenance tool.\n"
      "3. Set 'confidence' to your estimated detection confidence score between 0.00 and 1.00.\n"
      "4. If 'is_hardware' is false, 'error_message' must be ONE short sentence (max 10 words) naming "
      "the object's category, e.g. 'This is a writing instrument, not a hardware tool.' Do NOT "
      "describe people, hands, faces, or the composition of the image.\n"
      "5. Do not guess exact measurements.\n\n"
      "Respond strictly in this JSON format: "
      "{\"is_hardware\": true/false, \"item_name\": \"Specific Object Name\", \"confidence\": 0.95, \"error_message\": \"Short reason if not hardware\"}";

  /// Live-mode request: sequentially try another eligible key ONLY when the
  /// provider responds with HTTP 429. Never hedge concurrent duplicate calls.
  /// All configured keys in the SAME Google Cloud project share project quota.
  /// Thus rotation helps only if the next key has available independent quota.
  static Future<GeminiLiveResponse> scanHardwareObjectLive(
    Uint8List imageBytes,
  ) async {
    final keys = <String>{
      dotenv.env['GEMINI_API_KEY_1']?.trim() ?? '',
      dotenv.env['GEMINI_API_KEY_2']?.trim() ?? '',
      dotenv.env['GEMINI_API_KEY_3']?.trim() ?? '',
      dotenv.env['GEMINI_API_KEY_4']?.trim() ?? '',
      dotenv.env['GEMINI_API_KEY_5']?.trim() ?? '',
    }.where((key) => key.isNotEmpty).toList();
    if (keys.isEmpty) {
      return const GeminiLiveResponse(error: 'No Gemini API key is configured.');
    }

    final available = List.generate(keys.length, (i) => i)
        .where((i) => !(_keyCooldownUntil[i]?.isAfter(DateTime.now()) ?? false))
        .toList();
    if (available.isEmpty) {
      return const GeminiLiveResponse(
        error: 'All Gemini keys are cooling down after HTTP 429. Try later.',
        httpStatus: 429,
      );
    }

    final ordered = [
      if (available.contains(_currentKeyIndex)) _currentKeyIndex,
      ...available.where((i) => i != _currentKeyIndex),
    ];
    final body = jsonEncode({
      'contents': [{
        'parts': [
          {'text': _prompt},
          {'inline_data': {
            'mime_type': 'image/jpeg',
            'data': base64Encode(imageBytes),
          }},
        ],
      }],
      'generationConfig': {
        'temperature': 0.0,
        'responseMimeType': 'application/json',
        'maxOutputTokens': 200,
      },
    });
    const perKeyTimeout = Duration(seconds: 9);
    const totalBudget = Duration(seconds: 22);
    final timer = Stopwatch()..start();
    int attempts = 0;
    int quotaFailures = 0;

    for (final index in ordered) {
      final leftMs = totalBudget.inMilliseconds - timer.elapsedMilliseconds;
      if (leftMs < 1000) break;
      attempts++;
      final timeout = Duration(
        milliseconds: leftMs < perKeyTimeout.inMilliseconds
            ? leftMs : perKeyTimeout.inMilliseconds,
      );
      final client = http.Client();
      try {
        debugPrint('[LIVE GEMINI] Attempt $attempts/${ordered.length} '
            'using key slot ${index + 1} (${imageBytes.length} bytes)');
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/'
          'gemini-3.5-flash-lite:generateContent?key=${keys[index]}',
        );
        final response = await client.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: body,
        ).timeout(timeout);
        debugPrint('[LIVE GEMINI] Key slot ${index + 1}: HTTP '
            '${response.statusCode} in ${timer.elapsedMilliseconds}ms total');

        if (response.statusCode == 429) {
          quotaFailures++;
          _keyCooldownUntil[index] = DateTime.now().add(_quotaCooldown);
          debugPrint('[LIVE GEMINI] Key slot ${index + 1} hit 429; '
              'trying another available slot if any.');
          continue;
        }
        if (response.statusCode != 200) {
          debugPrint(
            '[LIVE GEMINI] Request failed with HTTP ${response.statusCode}',
          );
          final description = switch (response.statusCode) {
            400 => 'Gemini HTTP 400: invalid API request.',
            401 || 403 => 'Gemini HTTP ${response.statusCode}: API key/access denied.',
            404 => 'Gemini HTTP 404: selected model is unavailable.',
            503 => 'Gemini HTTP 503: service unavailable; try again later.',
            _ => 'Gemini HTTP ${response.statusCode}: request failed.',
          };
          return GeminiLiveResponse(
            error: description, httpStatus: response.statusCode,
          );
        }
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final content = json['candidates']?[0]?['content']?['parts']?[0]?['text'];
        if (content is! String) {
          return const GeminiLiveResponse(
            error: 'Gemini returned no recognition text.', httpStatus: 200,
          );
        }
        final parsed = jsonDecode(content) as Map<String, dynamic>;
        if (parsed['item_name'] == null || parsed['is_hardware'] is! bool) {
          return const GeminiLiveResponse(
            error: 'Gemini returned an incomplete identification.',
            httpStatus: 200,
          );
        }
        _currentKeyIndex = index;
        debugPrint('[LIVE GEMINI] Success on key slot ${index + 1} '
            'after ${timer.elapsedMilliseconds}ms');
        return GeminiLiveResponse(data: parsed, httpStatus: 200);
      } on TimeoutException {
        // A timeout could mean the request reached Gemini already. Avoid
        // sending the same image to multiple keys after a network timeout.
        debugPrint('[LIVE GEMINI] Timeout on key slot ${index + 1} '
            'after ${timer.elapsedMilliseconds}ms');
        return const GeminiLiveResponse(
          error: 'Gemini network timeout; retry this scan later.',
        );
      } on FormatException catch (e) {
        debugPrint('[LIVE GEMINI] Invalid JSON: $e');
        return const GeminiLiveResponse(error: 'Gemini returned invalid JSON.');
      } catch (e) {
        debugPrint(
          '[LIVE GEMINI] Network exception type: ${e.runtimeType}',
        );
        return const GeminiLiveResponse(error: 'Recognition network error.');
      } finally {
        client.close();
      }
    }
    if (quotaFailures > 0) {
      return GeminiLiveResponse(
        error: 'Gemini quota exceeded across $quotaFailures key slot(s). '
            'Quota is shared by keys in the same Google project.',
        httpStatus: 429,
      );
    }
    return GeminiLiveResponse(
      error: 'Gemini request time budget expired after $attempts attempt(s).',
    );
  }

  static Future<Map<String, dynamic>?> scanHardwareObject(
    Uint8List imageBytes, {
    bool hedge = true,
  }) async {
    final keys = [
      dotenv.env['GEMINI_API_KEY_1']?.trim() ?? '',
      dotenv.env['GEMINI_API_KEY_2']?.trim() ?? '',
      dotenv.env['GEMINI_API_KEY_3']?.trim() ?? '',
      dotenv.env['GEMINI_API_KEY_4']?.trim() ?? '',
      dotenv.env['GEMINI_API_KEY_5']?.trim() ?? '',
    ].where((key) => key.isNotEmpty).toList();

    if (keys.isEmpty) return null;

    final body = jsonEncode({
      "contents": [
        {
          "parts": [
            {"text": _prompt},
            {
              "inline_data": {
                "mime_type": "image/jpeg",
                "data": base64Encode(imageBytes),
              },
            },
          ],
        },
      ],
      "generationConfig": {
        "temperature": 0.0,
        "responseMimeType": "application/json",
        "maxOutputTokens": 150,
      },
    });

    final now = DateTime.now();
    final availableIndices = List.generate(
      keys.length,
      (i) => i,
    ).where((i) => !(_keyCooldownUntil[i]?.isAfter(now) ?? false)).toList();

    if (availableIndices.isEmpty) {
      // Every key is cooling down: try the last-used one anyway.
      availableIndices.add(_currentKeyIndex % keys.length);
    }

    // Last-known-good key first, then the rest in order.
    final ordered = [
      if (availableIndices.contains(_currentKeyIndex)) _currentKeyIndex,
      ...availableIndices.where((i) => i != _currentKeyIndex),
    ];

    // Live mode uses one request only to protect free-tier quotas.
    if (!hedge) return _tryKey(keys, ordered.first, body);
    return _hedgedAttempt(keys, ordered, body);
  }

  /// Fires `ordered[0]` immediately.
  /// - If a key FAILS, the next key starts right away.
  /// - If a key is merely SLOW (still pending after `_hedgeDelay`), the next
  ///   key also starts, without cancelling the slow one.
  /// First success wins.
  static Future<Map<String, dynamic>?> _hedgedAttempt(
    List<String> keys,
    List<int> ordered,
    String body,
  ) {
    final completer = Completer<Map<String, dynamic>?>();
    int nextCursor = 0;
    int active = 0;
    Timer? hedgeTimer;

    void launchNext() {
      if (nextCursor >= ordered.length) return;
      final idx = ordered[nextCursor++];
      active++;
      _tryKey(keys, idx, body)
          .then((result) {
            if (completer.isCompleted) return;
            if (result != null) {
              _currentKeyIndex = idx;
              completer.complete(result);
            } else {
              launchNext(); // failed fast: don't wait for the hedge timer
            }
          })
          .whenComplete(() {
            active--;
            if (active == 0 &&
                nextCursor >= ordered.length &&
                !completer.isCompleted) {
              completer.complete(null);
            }
          });
    }

    launchNext(); // primary key, fired immediately

    hedgeTimer = Timer.periodic(_hedgeDelay, (timer) {
      if (completer.isCompleted || nextCursor >= ordered.length) {
        timer.cancel();
        return;
      }
      launchNext(); // previous key(s) still pending, so hedge
    });

    return completer.future.whenComplete(() => hedgeTimer?.cancel());
  }

  /// Attempts a single key. Returns null on any failure. A 429 puts the key
  /// on cooldown so later scans skip it while it's throttled.
  static Future<Map<String, dynamic>?> _tryKey(
    List<String> keys,
    int index,
    String body,
  ) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent?key=${keys[index]}',
    );

    try {
      final response = await http
          .post(url, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(_perKeyTimeout);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final text =
            decoded['candidates']?[0]?['content']?['parts']?[0]?['text'];
        if (text == null) return null;
        return jsonDecode(text) as Map<String, dynamic>;
      }

      debugPrint('[GEMINI] Request failed with HTTP ${response.statusCode}');
      if (response.statusCode == 429) {
        _keyCooldownUntil[index] = DateTime.now().add(_quotaCooldown);
      }
      return null;
    } catch (e) {
      debugPrint('[GEMINI] request failed: ${e.runtimeType}');
      return null;
    }
  }
}
