from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import Mock

from app.api.adapters import SupabaseRestClient
from app.api.contracts import AuthenticationError


ROOT = Path(__file__).resolve().parents[2]
RPC_SQL = ROOT / "supabase" / "schemas" / "public" / "functions" / (
    "forecast_daily_demand_v1.sql"
)
DATABASE_SQL = ROOT / "database" / "stage_5a_daily_demand.sql"
FLUTTER_CLIENT = ROOT / "lib" / "services" / "forecasting_api_service.dart"
SESSION_STORAGE = ROOT / "lib" / "login" / "session_storage.dart"
PUBSPEC = ROOT / "pubspec.yaml"
COMPLETION_SQL = ROOT / "supabase" / "schemas" / "public" / "functions" / (
    "complete_customer_order_v1.sql"
)
INTEGRITY_MIGRATION = ROOT / "database" / (
    "stage_6b5_data_integrity_remediation.sql"
)
SECURITY_TARGET = ROOT / "database" / (
    "stage_6b5_security_target_state_isolated.sql"
)
ISOLATED_README = ROOT / "forecasting_backend" / "integration" / "stage6b" / (
    "README.md"
)
SECURE_ACCESS_MIGRATION = ROOT / "database" / (
    "stage_6b6_secure_access_rpcs.sql"
)
SECURE_PRODUCT_MIGRATION = ROOT / "database" / (
    "stage_6b7_product_access_rpcs.sql"
)
INVENTORY_CONTROLLER = ROOT / "lib" / "logic" / "inventory_controller.dart"
AUTH_SERVICE = ROOT / "lib" / "login" / "auth_service.dart"
LOGIN_PAGE = ROOT / "lib" / "ui" / "login_page.dart"


class Stage6BStaticContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sql = RPC_SQL.read_text(encoding="utf-8").lower()
        self.normalized_sql = " ".join(self.sql.split())

    def test_rpc_signature_and_output_contract_match_python_adapter(self) -> None:
        for parameter in (
            "p_session_token text",
            "p_period_start timestamp with time zone",
            "p_period_end timestamp with time zone",
            "p_business_timezone text",
        ):
            self.assertIn(parameter, self.normalized_sql)
        for output in (
            "business_date date",
            "location_id uuid",
            "product_id uuid",
            "sku text",
            "product_name text",
            "unit text",
            "quantity numeric",
            "completed_order_count bigint",
        ):
            self.assertIn(output, self.normalized_sql)

    def test_rpc_is_half_open_manila_scoped_and_fail_closed(self) -> None:
        self.assertIn("completed_at >= p_period_start", self.sql)
        self.assertIn("completed_at < p_period_end", self.sql)
        self.assertIn("at time zone v_timezone", self.sql)
        self.assertIn("lower(trim(history.status)) = 'completed'", self.sql)
        self.assertIn("history.returned_at is null", self.sql)
        self.assertIn("invalid item quantity", self.sql)
        self.assertIn("invalid product identifier", self.sql)
        self.assertIn("history.completed_at is null", self.sql)
        self.assertIn("history.created_at < p_period_end", self.sql)
        self.assertIn("history.snapshot_updated_at >= p_period_start", self.sql)
        self.assertIn("no completion timestamp", self.sql)

    def test_security_definer_boundary_is_explicit(self) -> None:
        self.assertIn("security definer", self.sql)
        self.assertIn(
            "set search_path to 'public', 'private', 'extensions', 'pg_temp'",
            self.sql,
        )
        self.assertIn("private.require_app_session_v1", self.sql)
        self.assertIn("if v_profile.role <> 'admin'", self.sql)
        self.assertIn("from public.order_history", self.sql)
        self.assertIn("left join public.products", self.sql)
        self.assertIn("to anon, service_role, postgres", self.sql)
        self.assertIn("from public, authenticated", self.sql)

    def test_checked_in_sql_copies_have_the_same_contract_markers(self) -> None:
        database_sql = DATABASE_SQL.read_text(encoding="utf-8").lower()
        markers = (
            "forecast_daily_demand_v1",
            "private.require_app_session_v1",
            "completed_at < p_period_end",
            "at time zone v_timezone",
            "completed_order_count bigint",
            "security definer",
        )
        for marker in markers:
            self.assertIn(marker, self.sql)
            self.assertIn(marker, database_sql)

    def test_flutter_forecasting_client_contains_no_privileged_key(self) -> None:
        dart = FLUTTER_CLIENT.read_text(encoding="utf-8").lower()
        self.assertNotIn("service_role", dart)
        self.assertNotIn("supabase_service_role_key", dart)
        self.assertIn("authorization", dart)
        self.assertIn("bearer $sessiontoken", dart)

    def test_completed_order_creation_is_fail_closed(self) -> None:
        completion = COMPLETION_SQL.read_text(encoding="utf-8").lower()
        migration = INTEGRITY_MIGRATION.read_text(encoding="utf-8").lower()
        self.assertIn("order_item_snapshot_invalid", completion)
        self.assertIn("jsonb_array_length(v_order.items) = 0", completion)
        self.assertIn("completed_order_timestamp_required", migration)
        self.assertIn("order_history_validate_completed_snapshot_v1", migration)
        self.assertIn("original_snapshot jsonb not null", migration)

    def test_security_target_requires_isolated_readiness(self) -> None:
        sql = SECURITY_TARGET.read_text(encoding="utf-8").lower()
        self.assertIn("stage6b_isolated_environment", sql)
        self.assertIn("stage6b5_security_readiness", sql)
        self.assertIn("direct_table_calls_migrated", sql)
        self.assertIn("realtime_transport_migrated", sql)
        self.assertNotIn("auth.uid() =", sql)

    def test_isolated_harness_requires_project_identity(self) -> None:
        instructions = ISOLATED_README.read_text(encoding="utf-8").lower()
        self.assertIn("stage6b_test_project_ref", instructions)
        self.assertIn("stage6b_production_project_ref", instructions)
        self.assertIn("stage6b_test_environment_identity_v1", instructions)

    def test_flutter_session_token_uses_secure_storage_contract(self) -> None:
        storage = SESSION_STORAGE.read_text(encoding="utf-8").lower()
        pubspec = PUBSPEC.read_text(encoding="utf-8").lower()
        self.assertIn("flutter_secure_storage", pubspec)
        self.assertIn("fluttersecuresessiontokenstore", storage)
        self.assertIn("await _securetokenstore.write(legacytoken)", storage)
        self.assertIn("await prefs.remove(legacysessiontokenkey)", storage)

    def test_stage6b6_read_interfaces_validate_session_and_scope_location(self) -> None:
        sql = SECURE_ACCESS_MIGRATION.read_text(encoding="utf-8").lower()
        for function_name in (
            "inventory_snapshot_v1",
            "operational_orders_snapshot_v1",
            "current_profile_snapshot_v1",
            "staff_configuration_snapshot_v1",
        ):
            self.assertIn(f"function public.{function_name}", sql)
        self.assertGreaterEqual(sql.count("private.require_app_session_v1"), 9)
        self.assertGreaterEqual(
            sql.count("= v_session.location_id"),
            4,
        )
        self.assertIn("v_session.role <> 'admin'", sql)
        self.assertIn("v_session.role <> 'helper'", sql)
        self.assertIn("password hashes are deliberately excluded", sql)

    def test_stage6b6_helper_order_contract_excludes_payment_fields(self) -> None:
        sql = SECURE_ACCESS_MIGRATION.read_text(encoding="utf-8").lower()
        helper_start = sql.index("case when v_session.role = 'helper'")
        privileged_start = sql.index("else", helper_start)
        helper_contract = sql[helper_start:privileged_start]
        self.assertIn("'items', order_row.items", helper_contract)
        for sensitive_field in (
            "payment_reference",
            "cash_given",
            "change_amount",
            "total_amount",
            "discount_amount",
        ):
            self.assertNotIn(sensitive_field, helper_contract)

    def test_stage6b6_read_migration_is_additive(self) -> None:
        sql = SECURE_ACCESS_MIGRATION.read_text(encoding="utf-8").lower()
        self.assertNotIn("revoke all on table", sql)
        self.assertNotIn("alter table", sql)
        self.assertNotIn("drop table", sql)
        self.assertNotIn("truncate table", sql)

    def test_core_flutter_snapshots_use_session_authorized_rpcs(self) -> None:
        dart = INVENTORY_CONTROLLER.read_text(encoding="utf-8").lower()
        for function_name in (
            "inventory_snapshot_v1",
            "operational_orders_snapshot_v1",
            "current_profile_snapshot_v1",
            "staff_configuration_snapshot_v1",
        ):
            self.assertIn(f"'{function_name}'", dart)
        self.assertIn("inventory_plus_secure_access_v1", dart)
        self.assertIn("defaultvalue: false", dart)

    def test_staff_and_current_profile_mutations_use_authorized_rpcs(self) -> None:
        dart = INVENTORY_CONTROLLER.read_text(encoding="utf-8").lower()
        sql = SECURE_ACCESS_MIGRATION.read_text(encoding="utf-8").lower()
        for function_name in (
            "staff_create_v1",
            "staff_update_role_v1",
            "staff_profile_v1",
            "staff_delete_v1",
            "current_profile_update_v1",
        ):
            self.assertIn(f"'{function_name}'", dart)
            self.assertIn(f"function public.{function_name}", sql)
        self.assertIn("extensions.digest(convert_to(p_password", sql)
        self.assertIn("profile_row.location_id = v_session.location_id", sql)
        self.assertIn("usestage6b6secureaccess", dart)

    def test_stage6b7_product_mutations_are_admin_and_location_scoped(self) -> None:
        sql = SECURE_PRODUCT_MIGRATION.read_text(encoding="utf-8").lower()
        self.assertEqual(sql.count("private.require_app_session_v1"), 6)
        self.assertEqual(sql.count("v_session.role <> 'admin'"), 6)
        self.assertGreaterEqual(sql.count("= v_session.location_id"), 8)
        self.assertIn("forecast_product_snapshot_v1", sql)
        self.assertIn("order_row.status in ('pending', 'prepared', 'solo_picking')", sql)
        self.assertIn("product_must_be_inactive", sql)
        self.assertIn("insert into public.transaction_history", sql)
        self.assertNotIn("revoke all on table", sql)

    def test_flutter_product_mutations_have_default_off_secure_gate(self) -> None:
        dart = INVENTORY_CONTROLLER.read_text(encoding="utf-8").lower()
        self.assertIn("inventory_plus_secure_product_access_v1", dart)
        for function_name in (
            "product_details_update_v1",
            "product_set_active_v1",
            "product_delete_inactive_v1",
            "product_shelf_bin_update_v1",
            "product_map_assignment_v1",
        ):
            self.assertIn(f"'{function_name}'", dart)

    def test_insecure_client_side_password_recovery_is_fail_closed(self) -> None:
        auth = AUTH_SERVICE.read_text(encoding="utf-8").lower()
        login = LOGIN_PAGE.read_text(encoding="utf-8").lower()
        self.assertNotIn(".from('profiles')", auth)
        self.assertNotIn("sendemailjsotp", auth)
        self.assertNotIn("resetpasswordforuser", auth)
        self.assertIn("server-side challenge delivery provider", login)
        self.assertIn("secure self-service recovery is not configured", login)


class AuthenticationErrorSanitizationTests(unittest.TestCase):
    def test_upstream_authentication_detail_is_not_reflected(self) -> None:
        client = SupabaseRestClient(
            url="https://isolated.invalid",
            publishable_key="publishable-test-key",
            timeout_seconds=1,
        )
        response = Mock()
        response.status_code = 400
        response.json.return_value = {
            "message": "upstream echoed bearer secret-session-value"
        }
        client._client = Mock()
        client._client.post.return_value = response

        with self.assertRaisesRegex(
            AuthenticationError, "^Session is invalid or expired$"
        ):
            client.call_rpc(
                "profile_restore_session_v1",
                {"p_session_token": "secret-session-value"},
                authentication_rpc=True,
            )


if __name__ == "__main__":
    unittest.main()
