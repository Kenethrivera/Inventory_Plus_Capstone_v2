import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class GeminiService {
  // The last key that worked — tried first on the next scan so the
  // common case (one healthy key) only ever makes a single request.
  static int _currentKeyIndex = 0;

  // Keys that recently hit a 429 (quota/rate limit) are skipped entirely
  // for a short cooldown window instead of being retried at full cost
  // on every subsequent scan.
  static final Map<int, DateTime> _keyCooldownUntil = {};
  static const _quotaCooldown = Duration(minutes: 2);

  // Per-key request timeout. Reduced from the original 15s — Gemini
  // flash-lite normally answers in a couple of seconds, so a response
  // slower than this is more likely a dead/throttled key than one that
  // just needs more time.
  static const _perKeyTimeout = Duration(seconds: 8);

  // How long to wait for the current key before ALSO starting the next
  // one as a hedge, without cancelling the first. This is the key
  // difference from a plain "race": we only spend a backup key's quota
  // once there's real evidence the current one is slow, not preemptively
  // on every fallback. Each fired-off request still counts against that
  // key's quota even if its response ends up unused (a sent HTTP request
  // can't be "un-consumed"), which is exactly why staggering matters —
  // it keeps that cost rare instead of automatic.
  static const _hedgeDelay = Duration(seconds: 3);

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

    if (keys.isEmpty) {
      print("Error: No GEMINI_API_KEYs found in .env");
      return null;
    }

    final prompt =
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

    final body = jsonEncode({
      "contents": [
        {
          "parts": [
            {"text": prompt},
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
      // Every key is cooling down — try the last-used one anyway rather
      // than giving up outright.
      availableIndices.add(_currentKeyIndex % keys.length);
    }

    // Order: last-known-good key first (fast path for the common case),
    // then the rest in their original order.
    final ordered = [
      if (availableIndices.contains(_currentKeyIndex)) _currentKeyIndex,
      ...availableIndices.where((i) => i != _currentKeyIndex),
    ];

    return _hedgedAttempt(keys, ordered, body);
  }

  /// Fires `ordered[0]` immediately. If it hasn't resolved within
  /// `_hedgeDelay`, fires the next key too — WITHOUT cancelling the
  /// first — and keeps staggering further keys the same way if needed.
  /// First success wins. This only spends extra keys' quota when the
  /// current one is actually slow, rather than always spending all of
  /// them on every fallback.
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
      final idx = ordered[nextCursor];
      nextCursor++;
      active++;
      _tryKey(keys, idx, body)
          .then((result) {
            if (result != null && !completer.isCompleted) {
              _currentKeyIndex = idx;
              completer.complete(result);
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
      launchNext(); // only reached if the previous key(s) are still pending
    });

    return completer.future.whenComplete(() => hedgeTimer?.cancel());
  }

  /// Attempts a single key. Returns null on any failure — including
  /// rate limits, in which case the key is put on cooldown so future
  /// scans don't waste a request on it while it's still throttled.
  static Future<Map<String, dynamic>?> _tryKey(
    List<String> keys,
    int index,
    String body,
  ) async {
    final activeKey = keys[index];
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent?key=$activeKey',
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

        print("${DateTime.now()} - Gemini Result (Key ${index + 1}): $text");
        return jsonDecode(text);
      } else if (response.statusCode == 429) {
        print(
          "${DateTime.now()} - Quota hit on Key ${index + 1} (429). "
          "Cooling down for ${_quotaCooldown.inMinutes}m.",
        );
        _keyCooldownUntil[index] = DateTime.now().add(_quotaCooldown);
        return null;
      } else {
        print(
          "${DateTime.now()} - API Error on Key ${index + 1}: "
          "${response.statusCode} ${response.body}",
        );
        return null;
      }
    } on Exception catch (e) {
      print(
        "${DateTime.now()} - Network Timeout/Error on Key ${index + 1}: $e",
      );
      return null;
    }
  }
}
