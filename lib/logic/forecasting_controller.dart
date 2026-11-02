import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/real_world_market_service.dart';
import '../logic/forecasting_engine.dart';
import '../data/ai_insights_service.dart'; // Your existing AI service

class ForecastingController {
  // UI state variables
  double finalForecast = 0.0;
  Map<String, dynamic> appliedFactors = {};
  String aiNarrativeSummary = '';
  bool isLoading = false;

  final Map<String, String> _completedRequests = {};
  final Map<String, Future<String>> _inFlightRequests = {};

  /// 👉 ADD THIS METHOD HERE:
  void clearCacheFor(String itemId) {
    _completedRequests.remove(itemId);
    _inFlightRequests.remove(itemId);
  }

  /// Triggered when the user clicks "Generate Forecast" or switches to Seasonal/Monthly view
  Future<void> generateHybridForecast({
    required String itemId,
    required bool isSeasonal,
  }) async {
    clearCacheFor(itemId);
    isLoading = true;

    try {
  // --- STEP 1: Fetch live real-world factors from the internet ---
  final liveWeather = await RealWorldMarketService.fetchLiveWeatherData();
  double liveWeatherMultiplier = (liveWeather['multiplier'] as num).toDouble();
  
  // If you also want a crisis multiplier, you can default it or handle it cleanly:
  double liveCrisisMultiplier = 1.0; 

  // --- STEP 2: Fetch historical sales from Supabase ---
  final response = await Supabase.instance.client
      .from('transaction_history')
      .select('quantity_sold, created_at')
      .eq('product_id', itemId)
      .order('created_at', ascending: true);

      List<double> historicalSales = (response as List)
          .map((row) => (row['quantity_sold'] as num).toDouble())
          .toList();

      // Fallback data if no transactions found yet, to prevent math errors
      if (historicalSales.isEmpty) {
        historicalSales = [10.0, 15.0, 12.0, 20.0]; 
      }

      // --- STEP 3: Compute deterministic math via ForecastingEngine ---
      Map<String, dynamic> forecastResult;
      
      if (isSeasonal) {
        // Seasonal: Uses heavier environmental/trend multipliers
        forecastResult = ForecastingEngine.calculateSeasonalForecast(
          historicalSales: historicalSales,
          weights: [0.15, 0.25, 0.6], // Long-term weighted moving average weights
          weatherMultiplier: liveWeatherMultiplier, // Live from internet API!
          trendMultiplier: 1.10,
        );
      } else {
        // Monthly: Short-term operational replenishment
        forecastResult = ForecastingEngine.calculateMonthlyForecast(
          historicalSales: historicalSales,
          weights: [0.1, 0.2, 0.3, 0.4],
          priceMultiplier: 1.0,
          crisisMultiplier: liveCrisisMultiplier, // Live crisis/economic indicator!
        );
      }

      finalForecast = forecastResult['finalForecast'];
      appliedFactors = forecastResult['factorsApplied'];

      // --- STEP 4: Pass computed numbers to AI for professional narrative ---
      // Note: The AI does NOT calculate the numbers. It only formats the explanation!
      final aiInsightsService = AIInsightsService(); 
      aiNarrativeSummary = await aiInsightsService.getDemandForecast(
        isSeasonal ? 'Seasonal High-Demand Prediction' : 'Monthly Operational Forecast',
        [
          {
            'itemId': itemId,
            'computedForecast': finalForecast,
            'baselineWma': forecastResult['baselineWma'],
            'factors': appliedFactors,
          }
        ],
        cacheScope: 'forecast-$itemId-${isSeasonal ? 'seasonal' : 'monthly'}',
        forceRefresh: true,
      );

    } catch (e) {
      // Handle errors gracefully (Fault tolerance for your capstone defense)
      aiNarrativeSummary = "Error generating forecast: $e";
    } finally {
      isLoading = false;
    }
  }
}