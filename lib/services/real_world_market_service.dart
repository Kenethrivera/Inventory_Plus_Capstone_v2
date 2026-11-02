import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class RealWorldMarketService {
  /// 1. Fetches live weather data from OpenWeatherMap
  static Future fetchLiveWeatherData() async {
    try {
      final apiKey = dotenv.env['WEATHER_API_KEY'];
      if (apiKey == null || apiKey.isEmpty) {
        return {'condition': 'Fair Weather (Default)', 'multiplier': 1.0};
      }

      const String city = 'Manila';
      final url = Uri.parse(
        'https://api.openweathermap.org/data/2.5/weather?q=$city&units=metric&appid=$apiKey',
      );

      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final weatherList = data['weather'] as List?;
        if (weatherList == null || weatherList.isEmpty) {
          return {'condition': 'Fair Weather', 'multiplier': 1.0};
        }

        final mainCondition = weatherList[0]['main'].toString();
        final description = weatherList[0]['description'].toString();
        final conditionString = '$mainCondition ($description)';

        double multiplier = 1.0;
        final lowerMain = mainCondition.toLowerCase();
        final lowerDesc = description.toLowerCase();

        if (lowerMain.contains('rain') || 
            lowerMain.contains('thunderstorm') || 
            lowerDesc.contains('heavy') ||
            lowerDesc.contains('storm')) {
          multiplier = 1.35; 
        } else if (lowerMain.contains('drizzle') || lowerMain.contains('clouds')) {
          multiplier = 1.15;
        }

        return {'condition': conditionString, 'multiplier': multiplier};
      }
    } catch (e) {
      debugPrint('[RealWorldMarketService] Weather API error: $e');
    }
    return {'condition': 'Fair Weather (Fallback)', 'multiplier': 1.0};
  }

  /// 2. Fetches macroeconomic oil/fuel crisis multiplier
  static Future fetchLiveCrisisAndToolInflation() async {
  double crisisMultiplier = 1.0;
  String inflationReason = 'Stable FX & Domestic Transport';

  try {
    final url = Uri.parse('https://open.er-api.com/v6/latest/USD');
    final response = await http.get(url);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final phpRate = data['rates']['PHP'] as num?;

      if (phpRate != null) {
        if (phpRate > 58.0) {
          crisisMultiplier = 1.25; // 25% inflation pressure on imported power tools & freight
          inflationReason = 'Severe PHP weakening ($phpRate PHP/USD) & global freight surge';
        } else if (phpRate > 56.0) {
          crisisMultiplier = 1.15; // 15% inflation pressure
          inflationReason = 'Moderate import cost inflation ($phpRate PHP/USD) affecting imported power tool stocks';
        }
      }
    }
  } catch (e) {
    debugPrint('[RealWorldMarketService] Inflation/Crisis API error: $e');
  }

  return {
    'multiplier': crisisMultiplier,
    'reason': inflationReason,
  };
}

  /// 3. Dynamically checks online search trends & news in the Philippines for hardware/construction
  static Future<List<String>> fetchIndustryDemandTrends() async {
  try {
    final apiKey = dotenv.env['NEWS_API_KEY'] ?? '';
    
    // NewsAPI.org endpoint targeting Philippine construction and hardware market news
    final url = Uri.parse(
      'https://newsapi.org/v2/everything?q=philippines+AND+(hardware+OR+construction+OR+infrastructure)&language=en&sortBy=publishedAt&pageSize=5&apiKey=$apiKey'
    );

    final response = await http.get(url);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final articles = data['articles'] as List<dynamic>?;

      if (articles != null && articles.isNotEmpty) {
        List<String> liveTrends = [];
        for (var article in articles) {
          final title = article['title'] as String?;
          if (title != null && title.isNotEmpty && title != '[Removed]') {
            liveTrends.add(title);
          }
        }

        if (liveTrends.isNotEmpty) {
          debugPrint('[RealWorldMarketService] Successfully fetched ${liveTrends.length} live trends via NewsAPI.org!');
          return liveTrends;
        }
      }
    } else {
      debugPrint('[RealWorldMarketService] NewsAPI returned status: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('[RealWorldMarketService] NewsAPI fetch error (falling back to baseline): $e');
  }

  // Guaranteed fallback hardware industry baseline for defense stability
  return [
    'DPWH infrastructure rollout driving high regional demand for structural steel rebars and cement',
    'Weatherproofing sealants and uPVC materials surging due to seasonal storm preparations',
    'Solar panel inverters and electrical components seeing rising commercial inquiries',
    'PVC drainage pipes and heavy hardware experiencing steady contractor utilization',
  ];
}
}