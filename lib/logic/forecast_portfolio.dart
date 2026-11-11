import '../data/inventory.dart';
import '../services/forecasting_api_service.dart';

enum ForecastWindow { today, next7Days, next28Days }

extension ForecastWindowLabels on ForecastWindow {
  String get label => switch (this) {
    ForecastWindow.today => 'Today',
    ForecastWindow.next7Days => 'Next 7 days',
    ForecastWindow.next28Days => 'Next 28 days',
  };

  int get days => switch (this) {
    ForecastWindow.today => 1,
    ForecastWindow.next7Days => 7,
    ForecastWindow.next28Days => 28,
  };
}

enum DemandDirection { rising, stable, declining, mixed }

extension DemandDirectionLabels on DemandDirection {
  String get label => switch (this) {
    DemandDirection.rising => 'Rising',
    DemandDirection.stable => 'Stable',
    DemandDirection.declining => 'Declining',
    DemandDirection.mixed => 'Mixed by unit',
  };
}

class UnitDemandForecast {
  const UnitDemandForecast({
    required this.unit,
    required this.daily,
    required this.productCount,
  });

  final String unit;
  final List<ForecastDailyPoint> daily;
  final int productCount;

  double quantityFor(ForecastWindow window) => daily
      .take(window.days)
      .fold<double>(0, (total, point) => total + point.quantity);

  DemandDirection get direction {
    final first = daily
        .take(7)
        .fold<double>(0, (total, point) => total + point.quantity);
    final second = daily
        .skip(7)
        .take(7)
        .fold<double>(0, (total, point) => total + point.quantity);
    if (first == 0) {
      return second > 0 ? DemandDirection.rising : DemandDirection.stable;
    }
    final change = (second - first) / first;
    if (change >= .05) return DemandDirection.rising;
    if (change <= -.05) return DemandDirection.declining;
    return DemandDirection.stable;
  }
}

class CategoryDemandForecast {
  const CategoryDemandForecast({
    required this.category,
    required this.byUnit,
    required this.productCount,
    required this.coldStartProducts,
  });

  final String category;
  final Map<String, UnitDemandForecast> byUnit;
  final int productCount;
  final int coldStartProducts;
}

class ReplenishmentPriority {
  const ReplenishmentPriority({
    required this.productId,
    required this.productName,
    required this.category,
    required this.status,
    required this.inventoryUnit,
    this.suggestedQuantity,
  });

  final String productId;
  final String productName;
  final String category;
  final String status;
  final String inventoryUnit;
  final double? suggestedQuantity;
}

class CategoryDemandHighlight {
  const CategoryDemandHighlight({
    required this.category,
    required this.unit,
    required this.quantity,
  });

  final String category;
  final String unit;
  final double quantity;
}

class PortfolioForecastSnapshot {
  const PortfolioForecastSnapshot({
    required this.byUnit,
    required this.categories,
    required this.priorities,
    required this.totalProducts,
    required this.forecastedProducts,
    required this.coldStartProducts,
    required this.models,
    required this.provenance,
    required this.reliabilityWarnings,
    required this.generatedAt,
  });

  final Map<String, UnitDemandForecast> byUnit;
  final List<CategoryDemandForecast> categories;
  final List<ReplenishmentPriority> priorities;
  final int totalProducts;
  final int forecastedProducts;
  final int coldStartProducts;
  final Set<String> models;
  final Set<String> provenance;
  final List<String> reliabilityWarnings;
  final DateTime generatedAt;

  DemandDirection get overallDirection {
    final directions = byUnit.values.map((value) => value.direction).toSet();
    return directions.length == 1 ? directions.single : DemandDirection.mixed;
  }

  List<CategoryDemandHighlight> highDemandCategories(ForecastWindow window) {
    final units = byUnit.keys.toList()..sort();
    return units
        .map((unit) {
          CategoryDemandForecast? selected;
          var quantity = -1.0;
          for (final category in categories) {
            final candidate = category.byUnit[unit]?.quantityFor(window);
            if (candidate != null && candidate > quantity) {
              selected = category;
              quantity = candidate;
            }
          }
          return CategoryDemandHighlight(
            category: selected?.category ?? 'Unavailable',
            unit: unit,
            quantity: quantity < 0 ? 0 : quantity,
          );
        })
        .toList(growable: false);
  }
}

class PortfolioForecastAggregator {
  const PortfolioForecastAggregator();

  PortfolioForecastSnapshot aggregate({
    required List<InventoryItem> products,
    required Map<String, ForecastAnalysis> analyses,
    required DateTime generatedAt,
  }) {
    final productsById = <String, InventoryItem>{
      for (final product in products) product.id: product,
    };
    final portfolioSeries = <String, Map<DateTime, double>>{};
    final portfolioCounts = <String, int>{};
    final categorySeries = <String, Map<String, Map<DateTime, double>>>{};
    final categoryCounts = <String, int>{};
    final categoryColdStarts = <String, int>{};
    final priorities = <ReplenishmentPriority>[];
    final models = <String>{};
    final provenance = <String>{};
    final reliabilityWarnings = <String>{};
    var coldStarts = 0;
    var forecasted = 0;

    for (final entry in analyses.entries) {
      final product = productsById[entry.key];
      final analysis = entry.value;
      if (product == null || analysis.product.productId != product.id) continue;
      final category = _normalizedCategory(product.category);
      categoryCounts[category] = (categoryCounts[category] ?? 0) + 1;
      models.add(analysis.forecast.model);
      provenance.add(analysis.forecast.provenance);
      reliabilityWarnings.addAll(analysis.forecast.warnings);
      reliabilityWarnings.addAll(analysis.recommendation.warnings);

      if (analysis.forecast.isColdStart) {
        coldStarts++;
        categoryColdStarts[category] = (categoryColdStarts[category] ?? 0) + 1;
      } else {
        forecasted++;
        final unit = analysis.forecast.unit.trim().toLowerCase();
        final canonicalUnit = unit.isEmpty ? 'unknown unit' : unit;
        portfolioCounts[canonicalUnit] =
            (portfolioCounts[canonicalUnit] ?? 0) + 1;
        final portfolio = portfolioSeries.putIfAbsent(
          canonicalUnit,
          () => <DateTime, double>{},
        );
        final categoryUnit = categorySeries
            .putIfAbsent(category, () => <String, Map<DateTime, double>>{})
            .putIfAbsent(canonicalUnit, () => <DateTime, double>{});
        for (final point in analysis.forecast.daily.take(28)) {
          final date = DateTime.utc(
            point.date.year,
            point.date.month,
            point.date.day,
          );
          portfolio[date] = (portfolio[date] ?? 0) + point.quantity;
          categoryUnit[date] = (categoryUnit[date] ?? 0) + point.quantity;
        }
      }

      final recommendation = analysis.recommendation;
      if (recommendation.status != 'sufficient_inventory') {
        priorities.add(
          ReplenishmentPriority(
            productId: product.id,
            productName: product.name,
            category: category,
            status: recommendation.status,
            inventoryUnit: recommendation.inventoryUnit ?? product.unit,
            suggestedQuantity: recommendation.suggestedInventoryQuantity,
          ),
        );
      }
    }

    priorities.sort((left, right) {
      final leftRank = left.status == 'recommend_order' ? 0 : 1;
      final rightRank = right.status == 'recommend_order' ? 0 : 1;
      final rank = leftRank.compareTo(rightRank);
      return rank != 0 ? rank : left.productName.compareTo(right.productName);
    });

    return PortfolioForecastSnapshot(
      byUnit: {
        for (final entry in portfolioSeries.entries)
          entry.key: UnitDemandForecast(
            unit: entry.key,
            daily: _points(entry.value),
            productCount: portfolioCounts[entry.key] ?? 0,
          ),
      },
      categories:
          categoryCounts.keys
              .map((category) {
                final units = categorySeries[category] ?? const {};
                return CategoryDemandForecast(
                  category: category,
                  byUnit: {
                    for (final entry in units.entries)
                      entry.key: UnitDemandForecast(
                        unit: entry.key,
                        daily: _points(entry.value),
                        productCount: 0,
                      ),
                  },
                  productCount: categoryCounts[category] ?? 0,
                  coldStartProducts: categoryColdStarts[category] ?? 0,
                );
              })
              .toList(growable: false)
            ..sort((left, right) => left.category.compareTo(right.category)),
      priorities: priorities,
      totalProducts: products.length,
      forecastedProducts: forecasted,
      coldStartProducts: coldStarts,
      models: models,
      provenance: provenance,
      reliabilityWarnings: reliabilityWarnings.toList(growable: false)..sort(),
      generatedAt: generatedAt,
    );
  }

  static List<ForecastDailyPoint> _points(Map<DateTime, double> values) {
    final dates = values.keys.toList()..sort();
    return dates
        .take(28)
        .map((date) => ForecastDailyPoint(date: date, quantity: values[date]!))
        .toList(growable: false);
  }

  static String _normalizedCategory(String value) {
    final category = value.trim();
    if (category.isEmpty) return 'Uncategorized';
    final normalized = category.toLowerCase();
    if (normalized.contains('plumb') || normalized.contains('pipe')) {
      return 'Plumbing';
    }
    if (normalized.contains('electric') || normalized.contains('lighting')) {
      return 'Electrical';
    }
    if (normalized.contains('paint') || normalized.contains('coating')) {
      return 'Paints and coatings';
    }
    if (normalized.contains('tool')) return 'Tools';
    if (normalized.contains('building') ||
        normalized.contains('construction') ||
        normalized.contains('cement') ||
        normalized.contains('lumber') ||
        normalized.contains('steel') ||
        normalized.contains('masonry') ||
        normalized.contains('roof')) {
      return 'Building materials';
    }
    return category;
  }
}
