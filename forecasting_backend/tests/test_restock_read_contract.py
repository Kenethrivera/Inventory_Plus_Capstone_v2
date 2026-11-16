import copy
import unittest
from unittest.mock import Mock
from fastapi.testclient import TestClient
from app.api.main import create_app
from app.api.settings import ApiSettings
from app.api.adapters import SyntheticDevelopmentAdapter
from app.api.contracts import DataUnavailableError
from app.api.restock_records import validate_restock_rows
from tests.restock_contract_support import fixture_rows, check_actual_dart_parser

class RestockReadContractTests(unittest.TestCase):
    def setUp(self):
        self.rows = fixture_rows()

    def test_four_cases_and_nulls_validate_without_changes(self):
        self.assertIs(validate_restock_rows(self.rows),self.rows)

    def test_existing_deployed_read_contract_remains_compatible(self):
        legacy = copy.deepcopy(self.rows[1])
        for key in ("signed_quantity_difference", "absolute_difference", "reliability"):
            legacy.pop(key)
        self.assertEqual(validate_restock_rows([legacy]), [legacy])

    def test_nested_payload_in_assumptions_rejected(self):
        self.rows[0]["assumptions"].append({"predicted_demand":72.71923863537})
        with self.assertRaises(DataUnavailableError): validate_restock_rows(self.rows)

    def test_duplicate_transaction_rejected(self):
        with self.assertRaises(DataUnavailableError): validate_restock_rows(self.rows+[self.rows[0]])

    def test_nonfinite_number_rejected(self):
        self.rows[0]["predicted_demand"] = "NaN"
        with self.assertRaises(DataUnavailableError): validate_restock_rows(self.rows)

    def test_actual_dart_parser(self):
        print(check_actual_dart_parser(self.rows))

    def test_http_read_authorization_serialization_and_no_model_execution(self):
        settings = ApiSettings(mode="synthetic",supabase_url=None,supabase_publishable_key=None,
            request_timeout_seconds=1,review_period_days=7,policy_version="restock-test",
            synthetic_session_token="fixture-admin",deployment_environment="test",synthetic_mode_enabled=True)
        adapter = SyntheticDevelopmentAdapter(settings)
        adapter.load_applied_restocks = Mock(return_value=self.rows)
        adapter.load_analysis_context = Mock(side_effect=AssertionError("read must not load model inputs"))
        app = create_app(settings=settings,adapter=adapter)
        with TestClient(app) as client:
            path = "/v1/forecasting/restock-records?product_id="+self.rows[0]["product_id_snapshot"]
            response = client.get(path,headers={"Authorization":"Bearer fixture-admin"})
            self.assertEqual(response.status_code,200,response.text)
            self.assertTrue(response.json()["read_only"])
            self.assertEqual(response.json()["items"],self.rows)
            print(check_actual_dart_parser(response.json()["items"]))
            self.assertEqual(client.get(path,headers={"Authorization":"Bearer expired"}).status_code,401)
            self.assertEqual(client.get(path+"&location_id=22222222-2222-2222-2222-222222222222",
                headers={"Authorization":"Bearer fixture-admin"}).status_code,403)
            adapter.load_analysis_context.assert_not_called()
            adapter.load_applied_restocks.assert_called_once()
