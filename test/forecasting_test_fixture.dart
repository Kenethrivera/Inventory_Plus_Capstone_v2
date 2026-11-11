Map<String, dynamic> forecastingAnalysisFixture({
  bool noHistory = false,
  String status = 'recommend_order',
  bool synthetic = false,
  bool manualEstimate = false,
  List<String> recommendationWarnings = const <String>[
    'supplier_capacity_review',
  ],
}) => <String, dynamic>{
  'schema_version': 'stage5d-v1',
  'data_adapter': synthetic ? 'synthetic_fixture' : 'supabase_rpc',
  'synthetic': synthetic,
  'authorized_scope': <String, dynamic>{
    'profile_id': 'profile-1',
    'role': 'admin',
    'location_id': 'location-1',
  },
  'product': <String, dynamic>{
    'product_id': 'product-1',
    'location_id': 'location-1',
    'sku': 'HAMMER-01',
    'name': 'Claw Hammer',
    'unit': 'pcs',
  },
  'forecast': <String, dynamic>{
    'model': 'calibrated_blend',
    'version': 'stage5b-blend-v1',
    'provenance': synthetic ? 'synthetic' : 'real',
    'generated_at': '2026-11-04T08:00:00Z',
    'source_data_as_of': '2026-11-04T07:55:00Z',
    'period_start': '2026-11-05',
    'period_end': '2026-12-02',
    'horizon_days': 28,
    'unit': 'pcs',
    'total_quantity': noHistory ? 0.0 : 84.0,
    'daily': List<Map<String, dynamic>>.generate(
      28,
      (index) => <String, dynamic>{
        'date': DateTime.utc(
          2026,
          11,
          5,
        ).add(Duration(days: index)).toIso8601String().split('T').first,
        'quantity': noHistory ? 0.0 : 3.0,
      },
      growable: false,
    ),
    'cold_start': <String, dynamic>{
      'is_cold_start': noHistory,
      'reason': noHistory ? 'no_history' : null,
      'strategy': noHistory ? 'zero_placeholder' : null,
      'zero_is_unknown_demand': noHistory,
    },
    'data_quality': <String, dynamic>{
      'warnings': noHistory ? <String>['no_history'] : <String>[],
    },
  },
  'preliminary_restocking_insight': <String, dynamic>{
    'status': noHistory ? 'limited' : 'available',
    'planning_horizon_days': 28,
    'predicted_demand': noHistory ? null : 84.0,
    'available_inventory': 12.0,
    'suggested_restock_quantity': noHistory ? null : 72.0,
    'inventory_unit': 'pcs',
    'formula': 'max(0, ceiling(predicted demand - available inventory))',
    'forecast_basis': const <String, dynamic>{
      'requested_model': 'lightgbm',
      'model': 'lightgbm',
      'version': '1',
      'history_window_days': 365,
      'uses_experimental_seasonal_forecast': false,
    },
    'assumptions': const <String>[
      'Uses current saleable inventory.',
      'Missing incoming orders or backorders are not interpreted as verified zero.',
    ],
    'limitations': noHistory
        ? const <String>[
            'No sales history is available, so zero model output is unknown demand rather than evidence of zero demand.',
          ]
        : const <String>[],
    'requires_owner_review': true,
    'incoming_and_backorders_treated_as_zero': false,
  },
  'recommendation': <String, dynamic>{
    'status': status,
    'policy_type': 'periodic_review_order_up_to',
    'policy_version': 'stage5c-v1',
    'reorder_alert': <String, dynamic>{
      'status': 'at_or_below_reorder_point',
      'at_or_below_reorder_point': true,
      'message': 'Inventory is at or below the reorder point.',
    },
    'inventory_position': 12.0,
    'reorder_point': 24.0,
    'safety_stock': 3.0,
    'protection_period_days': 14,
    'target_inventory': 45.0,
    'inventory_snapshot': const <String, dynamic>{'saleable_on_hand': 12.0},
    'suggested_quantity': <String, dynamic>{
      'order_units': status == 'needs_review' ? null : 40.0,
      'order_unit': 'pcs',
      'inventory_units': status == 'needs_review' ? null : 40.0,
      'inventory_unit': 'pcs',
    },
    'human_approval_required': true,
    'approved_purchase_decision': false,
    'purchase_order_created': false,
    'manual_demand_estimate': manualEstimate
        ? <String, dynamic>{
            'daily_quantity': 3.0,
            'unit': 'pcs',
            'rationale': 'Opening-week shelf plan',
            'source': 'authenticated_admin_manual_input',
            'staff_confirmed': true,
            'confirmed_by_profile_id': 'profile-1',
            'confirmed_at': '2026-11-04T08:00:00Z',
            'provisional': true,
            'creates_historical_sales': false,
          }
        : null,
    'warnings': recommendationWarnings,
    'explanations': <String>['Known test calculation.'],
  },
  'capabilities': const <String, dynamic>{
    'read_only': true,
    'inventory_mutation': false,
    'purchase_order_creation': false,
  },
};

Map<String, dynamic> seasonalLearningLabFixture({
  bool complete = true,
  List<String> warnings = const <String>[],
}) {
  const skus = <String>[
    'SIM-SUM-01',
    'SIM-SUM-02',
    'SIM-SUM-03',
    'SIM-SUM-04',
    'SIM-SUM-05',
    'SIM-SUM-06',
    'SIM-SUM-07',
    'SIM-SUM-08',
    'SIM-RAIN-01',
    'SIM-RAIN-02',
    'SIM-RAIN-03',
    'SIM-RAIN-04',
    'SIM-RAIN-05',
    'SIM-RAIN-06',
    'SIM-RAIN-07',
    'SIM-RAIN-08',
    'SIM-NEU-01',
    'SIM-NEU-02',
    'SIM-NEU-03',
    'SIM-NEU-04',
    'SIM-NEU-05',
    'SIM-NEU-06',
    'SIM-NEU-07',
    'SIM-NEU-08',
  ];
  final products = <Map<String, dynamic>>[
    for (var index = 0; index < skus.length; index++)
      <String, dynamic>{
        'product_id': 'sim-product-${index + 1}',
        'sku': skus[index],
        'product_name': index == 0
            ? 'Concrete Hollow Blocks'
            : 'Simulation Product ${index + 1}',
        'is_simulation': true,
        'frozen_simulation_label': index < 8
            ? 'SUMMER'
            : index < 16
            ? 'RAINY'
            : 'NEUTRAL',
        'original_discovered': index.isEven ? 'UNKNOWN' : 'SUMMER',
        'baseline_discovered': index < 8
            ? 'SUMMER'
            : index < 16
            ? 'RAINY'
            : 'NEUTRAL',
        'refined_discovered': const <int>{2, 10, 18}.contains(index)
            ? 'UNKNOWN'
            : index < 8
            ? 'SUMMER'
            : index < 16
            ? 'RAINY'
            : 'NEUTRAL',
      },
  ];
  Map<String, dynamic> classificationSummary({
    required double accuracy,
    required double coverage,
    required double coveredAccuracy,
    required double unknownRate,
    required int tested,
    required int confirmed,
  }) => <String, dynamic>{
    'classification_metrics': <String, dynamic>{
      'accuracy': accuracy,
      'coverage': coverage,
      'covered_accuracy': coveredAccuracy,
      'unknown_rate': unknownRate,
      'seasonal_precision': coveredAccuracy,
      'false_seasonal_assignments': 0,
    },
    'fourth_year_confirmation': <String, dynamic>{
      'tested_seasonal_classifications': tested,
      'confirmed': confirmed,
      'confirmation_rate': tested == 0 ? null : confirmed / tested,
    },
  };

  return <String, dynamic>{
    'schema_version': 'seasonal-learning-lab-v1',
    'available': true,
    'complete': complete,
    'read_only': true,
    'warnings': warnings,
    'artifacts': <Map<String, dynamic>>[
      for (final stage in <String>['stage26', 'stage27', 'stage27b'])
        <String, dynamic>{
          'stage': stage,
          'status': 'available',
          'stale': false,
          'modified_at': '2026-11-10T02:00:00Z',
        },
    ],
    'stage26': <String, dynamic>{
      'decision': 'PASS',
      'database_verification': 'PASS',
      'history_start': '2022-11-09',
      'history_end': '2026-11-08',
      'metrics': <Map<String, dynamic>>[
        for (final horizon in <int>[7, 28])
          for (final model in <String>[
            'mean28',
            'existing_lightgbm',
            'matched_nonseasonal_ablation',
            'product_specific_seasonal_lightgbm',
          ])
            <String, dynamic>{
              'horizon_days': horizon,
              'model': model,
              'mae': model == 'product_specific_seasonal_lightgbm'
                  ? 0.812
                  : 1.024,
              'wape': model == 'product_specific_seasonal_lightgbm'
                  ? 0.1842
                  : 0.2311,
              'bias': model == 'product_specific_seasonal_lightgbm'
                  ? -0.012
                  : 0.021,
              'actual_total': 1400.0,
              'predicted_total': 1383.2,
            },
      ],
      'replay': <String, dynamic>{
        'rows': <Map<String, dynamic>>[
          for (var period = 1; period <= 3; period++)
            <String, dynamic>{
              'sku': 'SIM-SUM-01',
              'product_name': 'Concrete Hollow Blocks',
              'seasonal_group': 'SUMMER',
              'period': period,
              'origin':
                  '2026-02-${period == 1
                      ? '01'
                      : period == 2
                      ? '08'
                      : '15'}',
              'forecast_total': 20.0 - period,
              'actual_total': 5.0 + period,
              'signed_error': 15.0 - (period * 2),
              'absolute_error': 15.0 - (period * 2),
            },
        ],
      },
    },
    'stage27': <String, dynamic>{'decision': 'REVISE'},
    'stage27b': <String, dynamic>{
      'decision': 'REVISE',
      'selected_policy': 'direction_neutral_split_v1',
      'genuinely_better_than_baseline': false,
      'conclusion':
          'The refined method improves coverage but does not beat the simple baseline.',
      'final_comparison': <String, dynamic>{
        'original_evidence_gated': classificationSummary(
          accuracy: 0.625,
          coverage: 0.625,
          coveredAccuracy: 1.0,
          unknownRate: 0.375,
          tested: 15,
          confirmed: 14,
        ),
        'simple_baseline': classificationSummary(
          accuracy: 0.9167,
          coverage: 1.0,
          coveredAccuracy: 0.9167,
          unknownRate: 0.0,
          tested: 16,
          confirmed: 15,
        ),
        'refined': classificationSummary(
          accuracy: 0.875,
          coverage: 0.875,
          coveredAccuracy: 1.0,
          unknownRate: 0.125,
          tested: 14,
          confirmed: 13,
        ),
      },
      'chronological_comparison': <Map<String, dynamic>>[
        for (final months in <int>[6, 12, 24, 36])
          <String, dynamic>{
            'window_months': months,
            'model': 'refined',
            'accuracy': months < 24 ? 0.0 : 0.875,
            'coverage': months < 24 ? 0.0 : 0.875,
            'covered_accuracy': months < 24 ? null : 1.0,
            'unknown_rate': months < 24 ? 1.0 : 0.125,
            'seasonal_precision': months < 24 ? null : 1.0,
            'false_seasonal_assignments': 0,
          },
      ],
    },
    'products': products,
    'selected_product_id': 'sim-product-1',
    'forecast_vs_actual': <String, dynamic>{
      'leakage_check': 'PASS: every displayed date is after its origin',
      'points': <Map<String, dynamic>>[
        for (final model in <String>[
          'mean28',
          'existing_lightgbm',
          'matched_nonseasonal_ablation',
          'product_specific_seasonal_lightgbm',
        ])
          for (var day = 1; day <= 4; day++)
            <String, dynamic>{
              'origin': '2026-03-31',
              'forecast_date': '2026-04-0$day',
              'model': model,
              'actual': 2.0 + day,
              'predicted': 1.5 + day,
              'signed_error': -0.5,
              'unit': 'pcs',
            },
      ],
    },
    'provenance_guide': const <String, dynamic>{
      'live_forecast': 'Authenticated Supabase-backed API execution.',
      'frozen_label': 'Synthetic evaluation hypothesis only.',
      'sales_discovery': 'Offline report output only.',
    },
  };
}
