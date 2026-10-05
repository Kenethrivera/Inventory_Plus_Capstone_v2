import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AIInsightsService {
  // Read the GEMINI_API_KEY from your .env file
  final String apiKey = dotenv.env['GEMINI_API_KEY'] ?? '';

  

  // 1. TOP RIGHT CARD: Immediate Restocking Recommendations
  Future<String> getRestockRecommendations(String criticalItems, String deadItems) async {
    debugPrint(
      'Key loaded: ${apiKey.isEmpty ? "EMPTY" : "ends with ${apiKey.substring(apiKey.length - 4)}"}',
    );
    try {
      final model = GenerativeModel(
        model: 'gemini-3.6-flash', 
        apiKey: apiKey,
      );

      final prompt = """
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
      return response.text ?? 'No recommendations available.';
    } catch (e) {
      debugPrint('Gemini error: $e');
      return 'Error: $e';
    }
  }

  // 2. BOTTOM LEFT CARD: Live Demand Forecasting
  Future<String> getDemandForecast(String timeframe, List<Map<String, dynamic>> salesData) async {
    try {
      final model = GenerativeModel(
        model: 'gemini-3.6-flash', 
        apiKey: apiKey,
      );

      final prompt = '''
You are an inventory optimization AI.
Timeframe selected: $timeframe
Here is the sales and inventory data for this period:
${salesData.toString()}

Based on this data, provide a concise 3-bullet summary:
1. Top Performers: Identify the highest valued sales and the fastest-selling items.
2. Restock Heavily: Recommend which items to restock aggressively and why.
3. Restock Least: Recommend which slow-moving or low-value items to hold off on restocking.
Keep it direct, professional, and actionable.
''';

      final response = await model.generateContent([Content.text(prompt)]);
      return response.text ?? 'No forecast available for this period.';
    } catch (e) {
      debugPrint('Gemini error: $e');
      return 'Error: $e';
    }
  }
}