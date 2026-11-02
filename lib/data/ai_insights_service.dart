import 'dart:convert';

import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/app_logger.dart';
import '../services/real_world_market_service.dart';

class AIInsightsService {
  static const int _cacheLimit = 24;

  // Read the GEMINI_API_KEY from your .env file
  String get apiKey => dotenv.env['GEMINI_API_KEY'] ?? '';
  final Map<String, String> _completedRequests = <String, String>{};
  final Map<String, Future<String>> _inFlightRequests =
      <String, Future<String>>{};

  // 1. TOP RIGHT CARD: Immediate Restocking Recommendations
  Future<String> getRestockRecommendations(
    String criticalItems,
    String deadItems, {
    required String cacheScope,
    bool forceRefresh = false,
  }) {
    final key = jsonEncode(<Object?>[
      'restock-v1',
      cacheScope,
      criticalItems,
      deadItems,
    ]);
    return _cachedRequest(
      key: key,
      forceRefresh: forceRefresh,
      load: () => _generateRestockRecommendations(criticalItems, deadItems),
    );
  }

  Future<String> _generateRestockRecommendations(
    String criticalItems,
    String deadItems,
  ) async {
    try {
      final model = GenerativeModel(model: 'gemini-3.6-flash', apiKey: apiKey);

      final prompt =
          """
I manage a hardware store. Here is my internal inventory data:
Out-of-stock items: ${deadItems.isEmpty ? 'None' : deadItems}. 
Critical Stock (under 10% capacity) items: ${criticalItems.isEmpty ? 'None' : criticalItems}.

Provide a strict INTERNAL restocking action plan.
Follow these strict rules:
1. Use the '•' symbol for bullet points.
2. Write specific ITEM NAMES in ALL CAPS. DO NOT use markdown formatting like asterisks (**).
3. Create a single section titled "URGENT REPLENISH".
4. List each item in this format:
    1. [ITEM NAME]
      - [Brief 1-sentence reason for urgency]
      - [Recommended replenishment quantity]
5. End the message with a single paragraph of justification explaining why these specific items were prioritized to maximize store revenue and customer satisfaction.
6. Keep it extremely brief. No conversational filler.
""";

      final response = await model.generateContent([Content.text(prompt)]);
      return _requireContent(response.text);
    } catch (e, stackTrace) {
      AppLogger.error(
        'AI restocking request failed',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // 2. BOTTOM LEFT CARD: Live Demand Forecasting
  Future<String> getDemandForecast(
    String timeframe,
    List<Map<String, dynamic>> salesData, {
    required String cacheScope,
    bool forceRefresh = false,
  }) {
    final key = jsonEncode(<Object?>[
      'forecast-v1',
      cacheScope,
      timeframe,
      salesData,
    ]);
    return _cachedRequest(
      key: key,
      forceRefresh: forceRefresh,
      load: () => _generateDemandForecast(timeframe, salesData),
    );
  }

  Future<String> _generateDemandForecast(
    String timeframe,
    List<Map<String, dynamic>> salesData,
  ) async {
    try {
      final liveWeather = await RealWorldMarketService.fetchLiveWeatherData();
      final String weatherCondition = liveWeather['condition'] as String;
      final double weatherMultiplier = (liveWeather['multiplier'] as num).toDouble();

      final crisisData = await RealWorldMarketService.fetchLiveCrisisAndToolInflation();
      final double crisisMultiplier = (crisisData['multiplier'] as num).toDouble();
      final String inflationReason = crisisData['reason'] as String;

      final String crisisStatus = crisisMultiplier > 1.0 
    ? 'Active Fuel/Supply Chain Inflation & Tool Price Surcharge (${crisisMultiplier}x Cost Impact): $inflationReason' 
    : 'Stable Macroeconomic Conditions (1.0x Baseline)';

    final List<String> industryTrends = await RealWorldMarketService.fetchIndustryDemandTrends();
    final String industryTrendsFormatted = industryTrends.map((t) => "- $t").join('\n');

      final model = GenerativeModel(model: 'gemini-3.6-flash', apiKey: apiKey);
              final bool isSeasonal = timeframe.toLowerCase().contains('seasonal');

          final String prompt;

          if (isSeasonal) {
            // --- 🌤️ SEASONAL FORECAST PROMPT ---
            prompt = 
            '''
You are an expert inventory optimization AI for "Inventory Plus", a smart hardware retail decision support system in the Philippines.

CRITICAL DATA FEEDS:
1. Live Weather API Feed: $weatherCondition (Multiplier: ${weatherMultiplier}x)
2. Macroeconomic & Oil/Tool Crisis Status: $crisisStatus
3. Live Industry Trends & Demand Headlines (Philippines):
$industryTrendsFormatted
4. Raw Store Sales & Inventory Dataset:
${salesData.toString()}

MANDATED INSTRUCTIONS:
You MUST generate a report with EXACTLY 4 distinct bullet points. Every bullet point MUST explicitly reference and synthesize the data above:

- **Macro-Environmental & Crisis Impact Report:** Analyze how the crisis status ($crisisStatus) and fuel/tool price inflation impact transport overhead and wholesale hardware costs in the Philippines.
- **Industry Demand & Market Benchmarking:** Compare store category performance directly against live Philippine industry trends ($industryTrendsFormatted). Highlight which high-demand industry sectors the store needs to align with.
- **Strategic Category Replenishment & Buffer Guidelines:** Provide macro-level purchasing guidelines for major hardware categories, factoring in weather ($weatherCondition at ${weatherMultiplier}x) and general supplier lead times without citing individual low-stock quantities.
- **Capital Protection & Cost Mitigation:** Give clear instructions on locking in prices for high-inflation tools/materials before expected distributor price hikes, and freeze acquisition on overstocked items to preserve cash flow.
''';
      } else {
        // --- 📅 MONTHLY FORECAST PROMPT ---
        prompt = '''
You are an expert inventory optimization AI for "Inventory Plus", a smart hardware retail decision support system in the Philippines.

CRITICAL DATA FEEDS:
1. Live Short-Term Weather Factor: $weatherCondition (Multiplier: ${weatherMultiplier}x)
2. Macroeconomic, Fuel & Tool Inflation Status: $crisisStatus
3. Live Industry Trends & Demand Headlines (Philippines):
$industryTrendsFormatted
4. Calculated Monthly Inventory Dataset:
${salesData.toString()}

MANDATED INSTRUCTIONS:
You MUST generate a report with EXACTLY 4 distinct bullet points. Every bullet point MUST explicitly reference and synthesize the data above:

- **Macro Crisis & Tool Price Inflation Status:** Explicitly state the active macroeconomic impact ($crisisStatus), explaining how current fuel, FX, and tool import price surcharges affect general category restocking costs this month.
- **Industry Trend Alignment:** Cross-reference store categories with live Philippine industry demand headlines ($industryTrendsFormatted). Name specific high-demand industry categories that the store should prioritize stocking.
- **Monthly Procurement Strategy:** Outline general monthly purchasing priorities based on broader market velocity and weather conditions, avoiding individual item stock alerts.
- **Inventory Efficiency & Cash Flow:** Identify general overstocked or slow-moving categories where purchasing must be frozen, and recommend promotional strategies to free up operating capital.
''';
          }

      final response = await model.generateContent([Content.text(prompt)]);
      return _requireContent(response.text);
    } catch (e, stackTrace) {
      AppLogger.error(
        'AI forecast request failed',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<String> _cachedRequest({
    required String key,
    required bool forceRefresh,
    required Future<String> Function() load,
  }) {
    final inFlight = _inFlightRequests[key];
    if (inFlight != null) return inFlight;

    final cached = _completedRequests[key];
    if (!forceRefresh && cached != null) {
      _completedRequests.remove(key);
      _completedRequests[key] = cached;
      return Future<String>.value(cached);
    }

    late final Future<String> request;
    request = load()
        .then((result) {
          _completedRequests.remove(key);
          _completedRequests[key] = result;
          while (_completedRequests.length > _cacheLimit) {
            _completedRequests.remove(_completedRequests.keys.first);
          }
          return result;
        })
        .whenComplete(() {
          if (identical(_inFlightRequests[key], request)) {
            _inFlightRequests.remove(key);
          }
        });
    _inFlightRequests[key] = request;
    return request;
  }

  String _requireContent(String? content) {
    final value = content?.trim() ?? '';
    if (value.isEmpty ||
        RegExp(
          r'^(error|exception|api error)\s*:',
          caseSensitive: false,
        ).hasMatch(value)) {
      throw const FormatException('AI provider returned an invalid response.');
    }
    return value;
  }
}
