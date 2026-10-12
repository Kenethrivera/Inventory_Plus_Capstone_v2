import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
      "Screwdriver', 'Claw Hammer', 'Ballpoint Pen'. NEVER output 'unknown' or a vague label — "
      "identify the actual object, even if it isn't hardware.\n"
      "2. Set 'is_hardware' to true ONLY if the object is a construction, plumbing, electrical, or "
      "maintenance tool.\n"
      "3. If 'is_hardware' is false, 'error_message' must be ONE short sentence (max 10 words) naming "
      "the object's category, e.g. 'This is a writing instrument, not a hardware tool.' Do NOT "
      "describe people, hands, faces, or the composition of the image.\n"
      "4. Do not guess exact measurements.\n\n"
      "Respond strictly in this JSON format: "
      "{\"is_hardware\": true/false, \"item_name\": \"Specific Object Name\", \"error_message\": \"Short reason if not hardware\"}";

  static Future<Map<String, dynamic>?> scanHardwareObject(
    Uint8List imageBytes,
  ) async {
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

      if (response.statusCode == 429) {
        _keyCooldownUntil[index] = DateTime.now().add(_quotaCooldown);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
