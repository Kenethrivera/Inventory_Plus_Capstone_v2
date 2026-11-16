"""Shared HTTP/Dart fixture contract; optionally fed actual isolated RPC rows."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def fixture_rows():
    base = dict(product_id_snapshot="00000000-0000-4000-8000-000000000010",product_name_snapshot="Fixture Hammer",
                product_sku_snapshot="",inventory_unit="pcs",recommendation_date="2026-11-16T03:00:00+00:00",
                recommendation_id=None,forecast_period_start=None,forecast_period_end=None,predicted_demand=None,
                available_inventory=None,suggested_quantity=None,forecast_model=None,forecast_version=None,
                training_history_days=None,signed_quantity_difference=None,absolute_difference=None,reliability=None,
                evaluation_status="applied",matched_received_quantity=5,receipt_count=1,assumptions=["Not recorded"])
    evidence = dict(base,transaction_id="00000000-0000-4000-8000-000000000101",predicted_demand=72.71923863537,
                    available_inventory=44,suggested_quantity=29,signed_quantity_difference=-24,absolute_difference=24,
                    forecast_period_start="2026-11-16",forecast_period_end="2026-12-13",forecast_model="LightGBM",
                    forecast_version="1",training_history_days=365,reliability="normal",
                    evidence_source="historical_preliminary_match",assumptions=["Reconstructed historical estimate"])
    missing = dict(base,transaction_id="00000000-0000-4000-8000-000000000102",matched_received_quantity=10)
    snapshot = dict(evidence,transaction_id="00000000-0000-4000-8000-000000000103",recommendation_id=1,
                    suggested_quantity=31,evidence_source="approval_snapshot",reliability=None)
    both = dict(snapshot,transaction_id="00000000-0000-4000-8000-000000000104",recommendation_id=2,suggested_quantity=36)
    return [evidence,missing,snapshot,both]


def check_actual_dart_parser(rows):
    # Direct Dart SDK executable: never invokes flutter.bat, dart.bat, analyzer or Flutter tests.
    exe = Path(os.environ.get("RESTOCK_DART_EXE", "C:/Users/USER/flutter/bin/cache/dart-sdk/bin/dart.exe"))
    if not exe.is_file():
        raise FileNotFoundError("Direct Dart SDK unavailable; set RESTOCK_DART_EXE")
    source = (ROOT/"lib/services/forecasting_api_service.dart").read_text(encoding="utf-8")
    model = source[source.index("class RecommendationTrackingItem {"):source.index("class ForecastPerformanceReport {")]
    helpers = source[source.index("String _text(Object? value, String field)"):]
    main = r"""
void check(bool valid, String message) { if (!valid) throw StateError(message); }
void main(List<String> args) {
 final rows = (jsonDecode(File(args[0]).readAsStringSync()) as List)
   .map((x) => RecommendationTrackingItem.fromJson(Map<String,dynamic>.from(x))).toList();
 check(rows.length == 4, 'four read cases');
 final e = rows.firstWhere((r) => r.recordKey.endsWith('101'));
 check((e.predictedDemand! - 72.71923863537).abs() < 1e-9, 'top-level demand');
 check(e.availableInventory == 44 && e.suggestedQuantity == 29, 'historical quantities');
 check(e.signedQuantityDifference == -24 && e.absoluteDifference == 24, 'difference');
 check(e.recommendationId == null && e.isReconstructed, 'evidence identity');
 check(e.evidenceLabel == 'Reconstructed historical estimate', 'explicit provenance');
 check(e.productSku == '', 'empty SKU is valid');
 final missing = rows.firstWhere((r) => r.recordKey.endsWith('102'));
 check(missing.predictedDemand == null && missing.suggestedQuantity == null, 'null not zero');
 check(missing.forecastLabel == 'Not recorded', 'missing model');
 check(rows.firstWhere((r) => r.recordKey.endsWith('103')).suggestedQuantity == 31, 'snapshot only');
 check(rows.firstWhere((r) => r.recordKey.endsWith('104')).suggestedQuantity == 36, 'snapshot precedence');
 bool rejected = false;
 try { _restockAssumptions([{'suggested_quantity':29}]); } on FormatException { rejected = true; }
 check(rejected, 'nested evidence payload must be rejected');
 print('PASS: actual Dart tracking parser, four cases, nulls, SKU, provenance and quantities');
}
"""
    with tempfile.TemporaryDirectory() as directory:
        script = Path(directory)/"contract.dart"; data = Path(directory)/"rows.json"
        script.write_text("import 'dart:convert';\nimport 'dart:io';\n"+model+helpers+main,encoding="utf-8")
        data.write_text(json.dumps(rows),encoding="utf-8")
        run = subprocess.run([str(exe),str(script),str(data)],capture_output=True,text=True,timeout=45)
        if run.returncode:
            raise AssertionError(run.stderr)
        return run.stdout.strip()
