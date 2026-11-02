class ForecastingEngine {
  /// Deterministic Math: Weighted Moving Average (WMA)
  static double calculateWMA(List<double> salesData, List<double> weights) {
    if (salesData.isEmpty || salesData.length != weights.length) {
      return 0.0;
    }
    double weightedSum = 0.0;
    double weightSum = 0.0;
    
    for (int i = 0; i < salesData.length; i++) {
      weightedSum += salesData[i] * weights[i];
      weightSum += weights[i];
    }
    
    return weightSum == 0 ? 0.0 : weightedSum / weightSum;
  }

  /// 1. MONTHLY FORECASTING: Short-term operational planning
  static Map<String, dynamic> calculateMonthlyForecast({
    required List<double> historicalSales, // e.g., last 3-4 months of data
    required List<double> weights,         // e.g., [0.1, 0.2, 0.3, 0.4]
    double priceMultiplier = 1.0,          // Short-term inflation/price adjustment
    double crisisMultiplier = 1.0,         // Immediate economic/supply shock
  }) {
    final double baselineWma = calculateWMA(historicalSales, weights);
    final double finalForecast = baselineWma * priceMultiplier * crisisMultiplier;

    return {
      'forecastType': 'Monthly',
      'baselineWma': double.parse(baselineWma.toStringAsFixed(2)),
      'finalForecast': double.parse(finalForecast < 0 ? '0' : finalForecast.toStringAsFixed(2)),
      'factorsApplied': {
        'priceMultiplier': priceMultiplier,
        'crisisMultiplier': crisisMultiplier,
      },
    };
  }

  /// 2. SEASONAL FORECASTING: Long-term cyclical/environmental planning
  static Map<String, dynamic> calculateSeasonalForecast({
    required List<double> historicalSales, // e.g., historical matching period last year
    required List<double> weights,
    required double weatherMultiplier,     // e.g., 1.30 for rainy season / typhoon prep
    required double trendMultiplier,       // e.g., 1.15 for industry-wide material trends
  }) {
    final double baselineWma = calculateWMA(historicalSales, weights);
    final double finalForecast = baselineWma * weatherMultiplier * trendMultiplier;

    return {
      'forecastType': 'Seasonal',
      'baselineWma': double.parse(baselineWma.toStringAsFixed(2)),
      'finalForecast': double.parse(finalForecast < 0 ? '0' : finalForecast.toStringAsFixed(2)),
      'factorsApplied': {
        'weatherMultiplier': weatherMultiplier,
        'trendMultiplier': trendMultiplier,
      },
    };
  }
}