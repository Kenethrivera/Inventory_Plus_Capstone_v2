"""Seed and exercise a disposable Inventory Plus forecasting database.

Run from forecasting_backend with ``python simulation_one_run.py --preflight`` or
``python simulation_one_run.py --apply``. See SIMULATION_ONE_RUN.md.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import random
import re
import sys
from pathlib import Path
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from uuid import UUID, uuid5
from zoneinfo import ZoneInfo

import httpx

from app.api.main import create_app
from app.data.models import DailyDemand
from app.forecasting import ForecastProduct, HistoricalDemandDataset, LightGBMForecaster
from app.recommendations import DemandForecastSnapshot, InventoryBalanceBasis, InventorySnapshot
from app.recommendations.preliminary import PreliminaryRestockingInsightCalculator
from app.worker.repository import SupabaseWorkerRepository
from app.worker.runtime import ForecastJobWorker


NAMESPACE = UUID("ff1ab3fd-793e-4aef-bb17-e9227ff7ef90")
LOCATION_ID = uuid5(NAMESPACE, "location")
MANILA = ZoneInfo("Asia/Manila")
PRODUCTS = (
    ("steady", "General", 12),
    ("increasing", "Hand Tools", 2),
    ("decreasing", "Plumbing", 3),
    ("intermittent", "Power Tools", 1),
    ("high", "Fasteners", 5),
    ("low", "Safety", 30),
    ("weekend", "Paint", 4),
    ("seasonal", "Electrical", 6),
    ("lumpy", "Hardware", 2),
    ("stable_high_stock", "Hardware", 500),
    ("recent", "Tools", 4),
    ("no_history", "Tools", 2),
)
MODELS = ("mean28", "lightgbm", "blend", "seasonal_experimental")
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lXcAAAAASUVORK5CYII="
)


def ident(kind: str, value: object) -> UUID:
    return uuid5(NAMESPACE, f"{kind}:{value}")


def check(condition: bool, stage: str, message: str) -> None:
    if not condition:
        raise RuntimeError(f"{stage}: {message}")


def scalar(connection, statement: str, params: tuple = ()):
    with connection.cursor() as cursor:
        cursor.execute(statement, params)
        row = cursor.fetchone()
        return row[0] if row else None


def rows(connection, statement: str, params: tuple = ()):
    with connection.cursor() as cursor:
        cursor.execute(statement, params)
        return cursor.fetchall()


def required_environment() -> dict[str, str]:
    names = (
        "DATABASE_URL", "SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY",
        "SUPABASE_SECRET_KEY", "SIM_ADMIN_PASSWORD", "SIM_STAFF_PASSWORD",
        "SIM_PROJECT_REF", "FORECAST_API_URL", "SIM_BACKUP_DIR",
    )
    missing = [name for name in names if not os.environ.get(name, "").strip()]
    check(not missing, "configuration", "missing " + ", ".join(missing))
    return {name: os.environ[name].strip() for name in names}


def preflight(connection, config: dict[str, str]) -> dict:
    project_ref = config["SIM_PROJECT_REF"]
    check(bool(re.fullmatch(r"[a-z0-9]{20}", project_ref)), "scope", "invalid project ref")
    check(
        config["SUPABASE_URL"].rstrip("/") == f"https://{project_ref}.supabase.co",
        "scope", "Supabase URL and project ref differ",
    )
    check(config["FORECAST_API_URL"].startswith("https://"), "scope", "forecast API URL must use HTTPS")
    db_host = connection.info.host or ""
    db_user = connection.info.user or ""
    check(project_ref in db_host or project_ref in db_user, "scope", "database connection does not identify the same Supabase project")
    check(connection.info.dbname == "postgres", "scope", "unexpected database name")
    check(scalar(connection, "select current_setting('transaction_read_only')") == "off",
          "database", "database connection is read only")
    expected = (
        "public.locations", "public.profiles", "public.products", "public.orders",
        "public.order_history", "public.transaction_history",
        "public.forecast_replenishment_configs", "public.approval_requests",
        "public.forecast_recommendation_snapshots",
        "public.forecast_recommendation_receipt_allocations",
        "public.forecast_recommendation_reconciliations",
        "private.forecast_jobs", "private.forecast_execution_results",
        "private.forecast_input_revisions",
    )
    missing = [name for name in expected if scalar(connection, "select to_regclass(%s)", (name,)) is None]
    check(not missing, "schema", "missing tables " + ", ".join(missing))
    functions = (
        "public.profile_login_v1(text,text)",
        "public.forecast_daily_demand_v1(text,timestamptz,timestamptz,text)",
        "public.prepare_inventory_approval_evidence_v2(text,text,text,text)",
        "public.create_inventory_approval_request_v2(text,text,text,uuid,numeric,text,text,text,text,text)",
        "public.approve_inventory_approval_request_v1(text,uuid,text)",
        "public.match_forecast_recommendation_receipt_v1(text,bigint,uuid,numeric)",
        "public.reconcile_forecast_recommendation_v1(text,uuid,bigint,boolean,text)",
        "public.forecast_snapshot_page_v2(uuid,uuid,text,integer,integer,text,text,boolean,text,uuid)",
        "public.publish_forecast_execution_result_v1(uuid,uuid,jsonb)",
    )
    missing = [name for name in functions if scalar(connection, "select to_regprocedure(%s)", (name,)) is None]
    check(not missing, "schema", "missing functions " + ", ".join(missing))
    critical_columns = {
        "public.locations": {"id", "store_key", "layout_data"},
        "public.profiles": {"id", "username", "password", "role", "location_id"},
        "public.products": {"id", "sku", "product_name", "product_quantity", "location_id", "unit"},
        "public.orders": {"id", "status", "items", "location_id", "completed_at"},
        "public.order_history": {"order_id", "status", "items", "location_id", "completed_at"},
        "public.transaction_history": {"id", "product_id", "location_id", "transaction_type", "quantity_change"},
        "public.forecast_recommendation_snapshots": {"request_id", "created_at", "forecast_generated_at", "forecast_period_start", "forecast_period_end", "predicted_demand", "recommended_restock_quantity", "request_payload_sha256"},
        "private.forecast_execution_results": {"id", "job_id", "location_id", "product_id", "output_bundle"},
    }
    for table, required in critical_columns.items():
        schema, name = table.split(".")
        present = {column[0] for column in rows(connection,
            "select column_name from information_schema.columns where table_schema=%s and table_name=%s",
            (schema, name))}
        check(required <= present, "schema", f"{table} missing columns {sorted(required - present)}")
    required_triggers = {
        ("public.orders", "orders_sync_order_history_v1"),
        ("public.order_history", "order_history_forecast_demand_revision_v1"),
        ("public.forecast_recommendation_snapshots", "forecast_recommendation_snapshots_immutable_v1"),
    }
    for table, trigger in required_triggers:
        check(scalar(connection,
            "select 1 from pg_trigger where tgrelid=%s::regclass and tgname=%s and tgenabled<>'D'",
            (table, trigger)) == 1, "schema", f"required trigger {trigger} is unavailable")
    check(scalar(connection, "select 1 from storage.buckets where id='approval_evidence'") == 1,
          "schema", "approval_evidence storage bucket is missing")
    for function in (
        "public.forecast_daily_demand_v1(text,timestamptz,timestamptz,text)",
        "public.claim_forecast_job_v1(text,integer,uuid)",
        "public.save_forecast_recommendation_snapshot_v1(text,uuid,uuid,text,text,integer,boolean,timestamptz,timestamptz,integer,date,date,numeric,numeric,text,jsonb)",
    ):
        check(scalar(connection, "select has_function_privilege('service_role',%s,'EXECUTE')", (function,)),
              "permissions", f"service_role cannot execute {function}")
    existing = scalar(connection, "select store_key from public.locations where id = %s", (LOCATION_ID,))
    check(existing in (None, "SIM-FORECAST-ONE-RUN"), "scope", "simulation location identity is occupied")
    check(scalar(connection, "select count(*) from public.products where location_id=%s and id <> all(%s::uuid[])",
                 (LOCATION_ID, [ident("product", index) for index in range(len(PRODUCTS))])) == 0,
          "scope", "simulation location contains an unrecognized product")
    check(scalar(connection, "select count(*) from public.profiles where location_id=%s and username <> all(%s::text[])",
                 (LOCATION_ID, ["sim_forecast_admin", "sim_forecast_staff"])) == 0,
          "scope", "simulation location contains an unrecognized profile")
    for index in range(len(PRODUCTS)):
        product_id = ident("product", index)
        occupied = rows(connection, "select location_id,sku from public.products where id=%s or sku=%s",
                        (product_id, f"SIM-FC-{index:02d}"))
        check(all(row == (LOCATION_ID, f"SIM-FC-{index:02d}") for row in occupied),
              "scope", f"simulation product identity {index} is occupied")
    for role in ("admin", "staff"):
        occupied = rows(connection, "select location_id,role from public.profiles where username=%s",
                        (f"sim_forecast_{role}",))
        check(all(row == (LOCATION_ID, role) for row in occupied),
              "scope", f"simulation {role} username is occupied")
    check(scalar(connection, "select current_user") == "postgres", "permissions",
          "a postgres database role is required for simulation fixtures")
    return {"project_ref": project_ref, "database": connection.info.dbname,
            "location_id": str(LOCATION_ID), "existing_simulation": existing is not None,
            "cleanup_policy": "additive; no deletion or replacement of operational or immutable rows"}


def backup_simulation_scope(connection, config: dict[str, str]) -> dict:
    """Archive exact pre-existing simulation rows before any write.

    The archive is an audit artifact. Immutable rows cannot be restored through
    ordinary DML, so the runner never deletes or replaces them.
    """
    tables = (
        ("public.locations", "id=%s"), ("public.profiles", "location_id=%s"),
        ("public.products", "location_id=%s"), ("public.orders", "location_id=%s"),
        ("public.order_history", "location_id=%s"),
        ("public.transaction_history", "location_id=%s"),
        ("public.approval_requests", "location_id=%s"),
        ("public.forecast_replenishment_configs", "location_id=%s"),
        ("public.forecast_recommendation_snapshots", "location_id_snapshot=%s"),
        ("public.forecast_recommendation_reconciliations", "location_id_snapshot=%s"),
        ("private.forecast_input_revisions", "location_id=%s"),
        ("private.forecast_jobs", "location_id=%s"),
        ("private.forecast_execution_results", "location_id=%s"),
        ("private.approval_evidence_uploads", "location_id=%s"),
    )
    archive = {"project_ref": config["SIM_PROJECT_REF"], "location_id": str(LOCATION_ID), "tables": {}}
    for table, condition in tables:
        archive["tables"][table] = [row[0] for row in rows(connection,
            f"select to_jsonb(t) from {table} t where {condition}", (LOCATION_ID,))]
    archive["tables"]["public.forecast_recommendation_receipt_allocations"] = [row[0] for row in rows(connection,
        "select to_jsonb(a) from public.forecast_recommendation_receipt_allocations a "
        "join public.forecast_recommendation_snapshots s on s.id=a.recommendation_id "
        "where s.location_id_snapshot=%s", (LOCATION_ID,))]
    archive["tables"]["private.app_sessions"] = [row[0] for row in rows(connection,
        "select to_jsonb(s) from private.app_sessions s join public.profiles p on p.id=s.profile_id "
        "where p.location_id=%s", (LOCATION_ID,))]
    archive["tables"]["storage.objects"] = [row[0] for row in rows(connection,
        "select to_jsonb(o) from storage.objects o where o.bucket_id='approval_evidence' and o.name like %s",
        (f"{LOCATION_ID}/%",))]
    backup_dir = Path(config["SIM_BACKUP_DIR"]).expanduser().resolve()
    check(backup_dir.is_dir(), "backup", "SIM_BACKUP_DIR must be an existing directory")
    target = backup_dir / f"forecast-simulation-{config['SIM_PROJECT_REF']}-{datetime.now(MANILA).strftime('%Y%m%dT%H%M%S%f')}.json"
    payload = json.dumps(archive, indent=2, default=str)
    with target.open("x", encoding="utf-8") as output:
        output.write(payload)
    check(json.loads(target.read_text(encoding="utf-8")) == json.loads(payload),
          "backup", "scope archive verification failed")
    return {"path": str(target), "sha256": hashlib.sha256(payload.encode()).hexdigest(),
            "row_counts": {table: len(values) for table, values in archive["tables"].items()}}


def seed_database(connection, start: date, today: date, config: dict[str, str]) -> tuple[int, int, int]:
    rng = random.Random(26061121)
    with connection.transaction():
        with connection.cursor() as cursor:
            cursor.execute(
                "insert into public.locations(id,location_name,store_key,address,layout_data) "
                "values (%s,%s,%s,%s,%s::jsonb) on conflict(id) do nothing",
                (LOCATION_ID, "Forecast Simulation", "SIM-FORECAST-ONE-RUN",
                 "Synthetic test store", json.dumps({"simulation_anchor_date": today.isoformat()})),
            )
            actors = []
            for role in ("admin", "staff"):
                username = f"sim_forecast_{role}"
                password = config[f"SIM_{role.upper()}_PASSWORD"]
                cursor.execute(
                    """insert into public.profiles(name,username,password,role,location_id,is_active,must_change_password)
                    values (%s,%s,encode(extensions.digest(convert_to(%s,'UTF8'),'sha256'),'hex'),%s,%s,true,false)
                    on conflict(username) do nothing""",
                    (f"Forecast Simulation {role}", username, password, role, LOCATION_ID),
                )
                cursor.execute("select id,location_id,role from public.profiles where username=%s", (username,))
                actor = cursor.fetchone()
                check(actor is not None and actor[1] == LOCATION_ID and actor[2] == role, "seed", f"{username} is outside scope")
                actors.append(actor[0])
            admin_id, staff_id = actors
            for index, (pattern, category, stock) in enumerate(PRODUCTS):
                product_id = ident("product", index)
                cursor.execute(
                    """insert into public.products(id,sku,product_name,category,product_price,product_quantity,
                        location_id,unit,max_quantity,is_active,description)
                    values (%s,%s,%s,%s,%s,%s,%s,'pcs',1000,true,%s) on conflict(id) do nothing""",
                    (product_id, f"SIM-FC-{index:02d}", f"Simulation {pattern.replace('_', ' ').title()}", category,
                     Decimal("25") + index, stock, LOCATION_ID, "Synthetic forecast fixture"),
                )
            generated = 0
            movements: list[tuple[date, int, int, UUID]] = []
            sold_by_product = [0] * len(PRODUCTS)
            for day_offset in range(180):
                business_date = start + timedelta(days=day_offset)
                for index, (pattern, _, _) in enumerate(PRODUCTS):
                    quantity = demand_quantity(pattern, day_offset, business_date, rng)
                    if pattern == "recent" and day_offset < 166:
                        quantity = 0
                    if pattern == "no_history" or quantity == 0:
                        continue
                    generated += 1
                    order_id = ident("order", f"{business_date}:{index}")
                    sold_by_product[index] += quantity
                    movements.append((business_date, index, quantity, order_id))
                    completed = datetime.combine(business_date, time(13), MANILA)
                    item = {"product_id": str(ident("product", index)), "product_name": f"Simulation {pattern.replace('_', ' ').title()}",
                            "unit": "pcs", "quantity": quantity, "price": 25 + index}
                    cursor.execute(
                        """insert into public.orders(id,status,items,location_id,created_by,created_at,
                            completed_at,total_amount,discount_amount,payment_mode,completed_by_id,completed_by_name)
                        values (%s,'completed',%s::jsonb,%s,%s,%s,%s,%s,0,'Cash',%s,%s)
                        on conflict(id) do nothing""",
                        (order_id, json.dumps([item]), LOCATION_ID, staff_id, completed - timedelta(minutes=20),
                         completed, quantity * (25 + index), str(staff_id), "Forecast Simulation staff"),
                    )
            check(1000 <= generated <= 2000, "seed", f"generated {generated} orders, expected 1000-2000")
            remaining = [sold_by_product[i] + PRODUCTS[i][2] for i in range(len(PRODUCTS))]
            for business_date, index, quantity, order_id in movements:
                remaining[index] -= quantity
                cursor.execute(
                    """insert into public.transaction_history(id,created_at,product_id,user_id,user_name,
                        transaction_type,quantity_change,new_quantity,location_id,note,operation_id,operation_scope)
                    values (%s,%s,%s,%s,'Forecast Simulation staff','checkout',%s,%s,%s,%s,%s,%s)
                    on conflict(id) do nothing""",
                    (ident("checkout_movement", order_id), datetime.combine(business_date, time(13), MANILA),
                     ident("product", index), staff_id, -quantity, remaining[index], LOCATION_ID,
                     "Synthetic completed order", str(order_id), "simulation_checkout"),
                )
            check(all(remaining[i] == PRODUCTS[i][2] for i in range(len(PRODUCTS))),
                  "seed", "historical movement balances do not reconcile")
    count = scalar(connection, "select count(*) from public.order_history where location_id=%s and status='completed'", (LOCATION_ID,))
    check(count == generated, "seed", f"order history has {count} of {generated} expected snapshots")
    movement_count = scalar(connection,
        "select count(*) from public.transaction_history where location_id=%s and operation_scope='simulation_checkout'",
        (LOCATION_ID,))
    check(movement_count == generated, "seed", "checkout movement count does not match completed orders")
    return admin_id, staff_id, generated


def demand_quantity(pattern: str, offset: int, day: date, rng: random.Random) -> int:
    chance = {
        "steady": .86, "increasing": .83, "decreasing": .81, "intermittent": .30,
        "high": .96, "low": .63, "weekend": .80, "seasonal": .82,
        "lumpy": .48, "stable_high_stock": .86, "recent": .80,
    }.get(pattern, 0)
    if rng.random() > chance:
        return 0
    base = {
        "steady": 3, "increasing": 1 + offset // 38, "decreasing": max(1, 6 - offset // 38),
        "intermittent": 1, "high": 10, "low": 1, "weekend": 6 if day.weekday() >= 5 else 2,
        "seasonal": 5 if day.month in (11, 12, 3, 4) else 2,
        "lumpy": 8 if rng.random() < .22 else 1, "stable_high_stock": 3, "recent": 2,
    }[pattern]
    return max(1, base + rng.choice((-1, 0, 0, 1)))


def login(connection, role: str, password: str) -> str:
    result = scalar(connection, "select public.profile_login_v1(%s,%s)", (f"sim_forecast_{role}", password))
    check(isinstance(result, dict) and isinstance(result.get("session_token"), str), "auth", f"{role} login failed")
    return result["session_token"]


def request(client, method: str, path: str, token: str, payload=None):
    response = client.request(method, path, headers={"Authorization": f"Bearer {token}"}, json=payload)
    check(response.status_code < 400, "api", f"{method} {path} returned {response.status_code}: {response.text[:500]}")
    return response.json()


def historical_accuracy(connection, admin_id: int, admin_token: str, start: date, today: date) -> int:
    """Calculate point-in-time fixtures from the canonical demand RPC.

    This is intentionally a direct simulation-only insert because the production
    snapshot RPC refuses historical timestamps. Its use is disclosed in the report.
    """
    forecaster = LightGBMForecaster()
    calculator = PreliminaryRestockingInsightCalculator()
    saved = 0
    for origin_days_ago in (65, 35):
        origin = today - timedelta(days=origin_days_ago)
        origin_at = datetime.combine(origin, time.min, MANILA)
        demand = rows(
            connection,
            "select * from public.forecast_daily_demand_v1(%s,%s,%s,%s)",
            (admin_token, datetime.combine(start, time.min, MANILA), origin_at, "Asia/Manila"),
        )
        # The RPC shape is business_date, location_id, product_id, sku, name,
        # unit, quantity, completed_order_count.
        for index in (0, 1, 4, 7):
            product_id = ident("product", index)
            product = ForecastProduct(str(LOCATION_ID), str(product_id),
                                      f"Simulation {PRODUCTS[index][0].replace('_', ' ').title()}", "pcs",
                                      f"SIM-FC-{index:02d}")
            observations = [DailyDemand(value[0], str(value[1]), str(value[2]), value[4], value[5],
                                        Decimal(str(value[6])), int(value[7]), value[3])
                            for value in demand if value[2] == product_id]
            history = HistoricalDemandDataset.from_synthetic_observations(
                product=product, history_start=start, history_end=origin - timedelta(days=1), observations=observations
            )
            forecast = tuple(forecaster.forecast(history, horizon_days=28))
            check(forecast[0].metadata.model_name == forecaster.MODEL_NAME, "history", "LightGBM fallback at historical origin")
            inventory = InventorySnapshot(str(LOCATION_ID), str(product_id), "pcs", Decimal("2"), None, None,
                                          None, Decimal("1000"), InventoryBalanceBasis.NET_OF_RESERVATIONS, origin_at)
            insight = calculator.calculate(forecast=DemandForecastSnapshot(forecast, origin_at, origin_at), inventory=inventory)
            check(insight.predicted_demand is not None and insight.suggested_restock_quantity is not None,
                  "history", "historical insight unavailable")
            recommendation_id = ident("historical_recommendation", f"{origin}:{index}")
            hash_payload = {
                "product_id": str(product_id), "origin": origin.isoformat(),
                "predicted_demand": str(insight.predicted_demand),
                "available_inventory": str(insight.available_inventory),
                "recommended_restock_quantity": str(insight.suggested_restock_quantity),
            }
            payload_sha256 = hashlib.sha256(json.dumps(hash_payload, sort_keys=True).encode()).hexdigest()
            with connection.transaction():
                with connection.cursor() as cursor:
                    cursor.execute(
                        """insert into public.forecast_recommendation_snapshots(
                            request_id,created_at,location_id_snapshot,product_id_snapshot,product_name_snapshot,
                            product_sku_snapshot,inventory_unit_snapshot,saved_by_profile_id_snapshot,saved_by_name_snapshot,
                            forecast_model,forecast_version,training_history_days,experimental_model,
                            forecast_generated_at,forecast_source_data_as_of,planning_horizon_days,
                            forecast_period_start,forecast_period_end,predicted_demand,available_inventory,
                            recommended_restock_quantity,assumptions,request_payload_sha256)
                        values (%s,%s,%s,%s,%s,%s,'pcs',%s,'Forecast Simulation admin','lightgbm','1',365,false,
                            %s,%s,28,%s,%s,%s,%s,%s,%s::jsonb,%s)
                        on conflict(location_id_snapshot,request_id) do nothing""",
                        (recommendation_id, origin_at, LOCATION_ID, product_id, product.product_name, product.sku,
                         admin_id, origin_at, origin_at, forecast[0].forecast_date, forecast[-1].forecast_date,
                         insight.predicted_demand, insight.available_inventory, insight.suggested_restock_quantity,
                         json.dumps([*insight.assumptions, "synthetic_simulation_history", f"point_in_time_origin:{origin}"]),
                         payload_sha256),
                    )
                    if cursor.rowcount == 0:
                        cursor.execute(
                            "select request_payload_sha256 from public.forecast_recommendation_snapshots "
                            "where location_id_snapshot=%s and request_id=%s",
                            (LOCATION_ID, recommendation_id),
                        )
                        existing_hash = cursor.fetchone()
                        check(existing_hash is not None and existing_hash[0] == payload_sha256,
                              "history", "historical forecast identity conflicts with an existing result")
            saved += 1
    return saved


def run(config: dict[str, str], connection, report: dict) -> None:
    anchor = scalar(connection, "select layout_data->>'simulation_anchor_date' from public.locations where id=%s", (LOCATION_ID,))
    today = date.fromisoformat(anchor) if anchor else datetime.now(MANILA).date()
    start = today - timedelta(days=180)
    if scalar(connection,
              "select count(*) from public.forecast_recommendation_reconciliations where location_id_snapshot=%s",
              (LOCATION_ID,)):
        sales = scalar(connection, "select count(*) from public.order_history where location_id=%s and status='completed'", (LOCATION_ID,))
        history = scalar(connection, "select count(*) from public.forecast_recommendation_snapshots where location_id_snapshot=%s and forecast_period_end<%s", (LOCATION_ID, datetime.now(MANILA).date()))
        results = scalar(connection, "select count(*) from private.forecast_execution_results where location_id=%s", (LOCATION_ID,))
        check(1000 <= sales <= 2000 and history >= 8 and results >= 12,
              "replay", "existing simulation is incomplete")
        admin_token = login(connection, "admin", config["SIM_ADMIN_PASSWORD"])
        remote = httpx.get(f"{config['FORECAST_API_URL'].rstrip('/')}/v1/forecasting/forecast-performance",
                           params={"product_id": str(ident("product", 0)), "location_id": str(LOCATION_ID)},
                           headers={"Authorization": f"Bearer {admin_token}"}, timeout=45)
        check(remote.status_code == 200 and remote.json().get("summaries_by_unit"),
              "replay", "deployed API cannot read existing simulation accuracy")
        report["stages"]["replay"] = {"status": "PASS", "sales": sales, "matured_snapshots": history}
        return
    report["active_stage"] = "sales_seed"
    admin_id, _, generated = seed_database(connection, start, today, config)
    report["stages"]["sales"] = {"status": "PASS", "orders": generated}
    report["active_stage"] = "authentication"
    admin_token = login(connection, "admin", config["SIM_ADMIN_PASSWORD"])
    staff_token = login(connection, "staff", config["SIM_STAFF_PASSWORD"])
    os.environ.update({
        "FORECAST_API_MODE": "supabase", "FORECAST_DEPLOYMENT_ENV": "test",
        "FORECAST_REVIEW_PERIOD_DAYS": "7", "FORECAST_JOB_MATERIALIZATION_ENABLED": "true",
        "FORECAST_SNAPSHOT_READS_ENABLED": "true", "FORECAST_RECOMMENDATION_PERSISTENCE_ENABLED": "true",
    })
    from fastapi.testclient import TestClient
    with TestClient(create_app()) as client:
        report["active_stage"] = "replenishment_configuration"
        for index in range(12):
            product_id = str(ident("product", index))
            payload = {
                "location_id": str(LOCATION_ID), "supplier_lead_time_days": 5 + index % 4,
                "review_period_days": 7, "safety_stock": 2 + index % 3,
                "minimum_order_quantity": 1, "supplier_pack_size": 1, "supplier_order_unit": "pcs",
                "unit_conversion_factor": 1, "supplier_availability": "available",
                "data_source": "admin_estimate", "source_captured_at": datetime.now(MANILA).isoformat(),
                "rationale": "Synthetic simulation assumption",
            }
            request(client, "PUT", f"/v1/forecasting/products/{product_id}/replenishment-config", admin_token, payload)
        report["stages"]["configuration"] = {"status": "PASS", "products": 12}

        # Current API analysis and current durable snapshots use the normal paths.
        report["active_stage"] = "model_analysis"
        analyses = {}
        for index in range(12):
            product_id = str(ident("product", index))
            for model in (MODELS if index == 0 else ("blend",)):
                result = request(client, "POST", f"/v1/forecasting/products/{product_id}/analysis", admin_token,
                                 {"location_id": str(LOCATION_ID), "model": model, "horizon_days": 28})
                check(result["product"]["product_id"] == product_id, "analysis", "product identity mismatch")
                check(len(result["forecast"]["daily"]) == 28, "analysis", "forecast horizon mismatch")
                analyses[(index, model)] = result
        check(analyses[(9, "blend")]["preliminary_restocking_insight"]["suggested_restock_quantity"] == 0,
              "analysis", "adequately stocked product has a preliminary restock quantity")
        check(analyses[(10, "blend")]["forecast"]["cold_start"]["reason"] == "insufficient_history",
              "analysis", "recent product did not report insufficient history")
        check(analyses[(11, "blend")]["forecast"]["cold_start"]["reason"] == "no_history",
              "analysis", "no-history product did not report no history")
        check(analyses[(0, "blend")]["actual_sales"], "analysis", "product actual sales missing")
        report["stages"]["analysis"] = {"status": "PASS", "requests": len(analyses),
                                         "models": {model: analyses[(0, model)]["forecast"]["model"] for model in MODELS}}

        # Matured recommendations are calculated with the real forecaster and
        # preliminary engine from canonical demand bounded before each origin.
        report["active_stage"] = "historical_forecasts"
        count = historical_accuracy(connection, admin_id, admin_token, start, today)
        report["stages"]["historical_accuracy_fixtures"] = {"status": "PASS", "snapshots": count,
            "writer": "isolated simulation insert; production historical save RPC rejects backdated dates"}

        report["active_stage"] = "job_materialization"
        job_ids = []
        for index in range(12):
            product_id = str(ident("product", index))
            for model in (MODELS if index == 0 else ("blend",)):
                result = request(client, "POST",
                                 f"/v1/forecasting/jobs/bootstrap?product_id={product_id}&model={model}", admin_token)
                for item in result.get("jobs", []):
                    job_id = item.get("job_id")
                    if job_id and item.get("status") != "succeeded":
                        job_ids.append(str(job_id))
        report["active_stage"] = "worker_publication"
        repository = SupabaseWorkerRepository(url=config["SUPABASE_URL"], secret_key=config["SUPABASE_SECRET_KEY"], timeout_seconds=30)
        try:
            from threading import Event
            worker = ForecastJobWorker(repository, concurrency=1)
            for job_id in dict.fromkeys(job_ids):
                outcome = worker.run(shutdown=Event(), job_id=job_id)
                check(outcome["succeeded"] == 1, "worker", f"job {job_id} outcome {outcome}")
        finally:
            repository.close()
        report["stages"]["worker"] = {"status": "PASS", "jobs": len(set(job_ids))}

        report["active_stage"] = "overview_api"
        overview = request(client, "GET", f"/v1/forecasting/snapshots/overview?location_id={LOCATION_ID}&page=1&page_size=50", admin_token)
        check(overview.get("items"), "overview", "no saved forecast snapshots")
        check(overview.get("actual_sales_by_product", {}).get(str(ident("product", 0))),
              "overview", "saved overview actual sales missing")
        for model in MODELS:
            detail = request(client, "GET",
                f"/v1/forecasting/products/{ident('product', 0)}/snapshot?location_id={LOCATION_ID}&model={model}",
                admin_token)
            check(detail.get("status") == "completed", "overview", f"{model} product snapshot is unavailable")
        report["stages"]["overview"] = {"status": "PASS", "items": len(overview["items"])}

        # Save one current trusted recommendation via FastAPI, then use the
        # existing evidence, approval, receipt matching and reconciliation RPCs.
        report["active_stage"] = "restock_workflow"
        low_product = str(ident("product", 1))
        analysis = analyses[(1, "blend")]
        prelim = analysis["preliminary_restocking_insight"]
        forecast = analysis["forecast"]
        request_id = ident("current_recommendation", today)
        current = rows(connection,
            "select id,recommended_restock_quantity from public.forecast_recommendation_snapshots "
            "where location_id_snapshot=%s and request_id=%s", (LOCATION_ID, request_id))
        if current:
            recommendation_id, quantity = current[0]
        else:
            quantity = prelim["suggested_restock_quantity"]
            check(quantity is not None and quantity > 0, "restock", "low-stock product has no preliminary quantity")
            saved = request(client, "POST", f"/v1/forecasting/products/{low_product}/recommendation-snapshots",
                            admin_token, {"request_id": str(request_id), "location_id": str(LOCATION_ID),
                            "forecast_model": "lightgbm", "forecast_version": "1", "training_history_days": 365,
                            "experimental_model": False, "forecast_generated_at": prelim["forecast_generated_at"],
                            "forecast_source_data_as_of": prelim["forecast_source_data_as_of"],
                            "planning_horizon_days": 28, "forecast_period_start": forecast["period_start"],
                            "forecast_period_end": forecast["period_end"], "predicted_demand": prelim["predicted_demand"],
                            "available_inventory": prelim["available_inventory"],
                            "recommended_restock_quantity": quantity, "inventory_unit": "pcs"})
            recommendation_id = int(saved["recommendation_id"])
        operation_id = str(ident("approval_operation", today))
        prior_approval = rows(connection,
            "select id,status,transaction_id from public.approval_requests where location_id=%s and submission_operation_id=%s",
            (LOCATION_ID, operation_id))
        if prior_approval:
            approval_id, approval_status, receipt_id = prior_approval[0]
        else:
            evidence = scalar(connection, "select public.prepare_inventory_approval_evidence_v2(%s,%s,%s,%s)",
                              (staff_token, operation_id, "simulation-proof.png", "image/png"))
            path = evidence["storage_path"]
            upload_headers = {"apikey": config["SUPABASE_SECRET_KEY"],
                              "Content-Type": "image/png", "x-upsert": "true"}
            if not config["SUPABASE_SECRET_KEY"].startswith("sb_secret_"):
                upload_headers["Authorization"] = f"Bearer {config['SUPABASE_SECRET_KEY']}"
            upload = httpx.post(f"{config['SUPABASE_URL']}/storage/v1/object/approval_evidence/{path}",
                                headers=upload_headers, content=PNG, timeout=30)
            check(upload.status_code < 400, "evidence", f"storage upload failed {upload.status_code}: {upload.text[:300]}")
            approval = scalar(connection,
                "select public.create_inventory_approval_request_v2(%s,%s,'restock',%s,%s,%s,%s,%s,%s,%s)",
                (staff_token, operation_id, UUID(low_product), Decimal(str(quantity)),
                 "Simulation recommendation", "Synthetic scenario", path, "simulation-proof.png", "image/png"))
            approval_id = UUID(str(approval["id"]))
            approval_status, receipt_id = "pending", None
        if approval_status == "pending":
            approved = scalar(connection, "select public.approve_inventory_approval_request_v1(%s,%s,%s)",
                              (admin_token, approval_id, "Synthetic simulation approval"))
            receipt_id = UUID(str(approved["transaction_id"]))
        check(approval_status in ("pending", "approved") and receipt_id is not None,
              "restock", "approval is not usable")
        allocated = request(client, "POST", f"/v1/forecasting/recommendations/{recommendation_id}/receipt-allocations",
                            admin_token, {"location_id": str(LOCATION_ID), "transaction_history_id": str(receipt_id),
                                          "allocated_inventory_quantity": str(quantity)})
        reconciled = request(client, "POST", f"/v1/forecasting/recommendations/{recommendation_id}/reconcile",
                             admin_token, {"request_id": str(approval_id), "location_id": str(LOCATION_ID),
                                           "confirm_no_receipts": False, "confirmation_note": "Synthetic simulation receipt"})
        check(allocated and reconciled, "restock", "receipt allocation or reconciliation is empty")
        stock_after = scalar(connection, "select product_quantity from public.products where id=%s and location_id=%s",
                             (UUID(low_product), LOCATION_ID))
        check(stock_after == Decimal(str(prelim["available_inventory"])) + Decimal(str(quantity)),
              "restock", "approved receipt did not update inventory")
        refreshed = request(client, "POST", f"/v1/forecasting/products/{low_product}/analysis",
                            admin_token, {"location_id": str(LOCATION_ID), "model": "blend", "horizon_days": 28})
        check(Decimal(str(refreshed["preliminary_restocking_insight"]["available_inventory"])) == stock_after,
              "restock", "forecast guidance did not reflect the new inventory")
        report["stages"]["restock"] = {"status": "PASS", "recommendation_id": recommendation_id,
                                        "approval_id": str(approval_id), "receipt_id": str(receipt_id)}

        report["active_stage"] = "accuracy_api"
        performance = request(client, "GET",
                              f"/v1/forecasting/forecast-performance?product_id={ident('product', 0)}&location_id={LOCATION_ID}",
                              admin_token)
        summaries = performance.get("summaries_by_unit", [])
        check(summaries and summaries[0].get("wape") is not None and summaries[0].get("forecast_bias") is not None,
              "accuracy", "no matured WAPE and bias from API")
        report["stages"]["accuracy"] = {"status": "PASS", "evaluation_count": summaries[0]["evaluation_count"],
                                         "wape": summaries[0]["wape"], "bias": summaries[0]["forecast_bias"]}

        report["active_stage"] = "deployed_api"
        remote_url = config["FORECAST_API_URL"].rstrip("/")
        remote = httpx.get(f"{remote_url}/v1/forecasting/forecast-performance",
                           params={"product_id": str(ident("product", 0)), "location_id": str(LOCATION_ID)},
                           headers={"Authorization": f"Bearer {admin_token}"}, timeout=45)
        check(remote.status_code == 200, "azure", f"deployed API returned {remote.status_code}: {remote.text[:300]}")
        remote_report = remote.json()
        check(remote_report.get("summaries_by_unit") and
              remote_report["summaries_by_unit"][0].get("wape") is not None,
              "azure", "deployed API did not return matured simulation accuracy")
        report["stages"]["azure"] = {"status": "PASS", "api_url": remote_url}


def main() -> int:
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--preflight", action="store_true")
    action.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    report = {"status": "FAIL", "stages": {}}
    stage = "configuration"
    try:
        config = required_environment()
        if args.apply:
            check(os.getenv("SIM_APPLY_ACK") == f"APPLY:{config['SIM_PROJECT_REF']}", "authorization",
                  "set SIM_APPLY_ACK=APPLY:<SIM_PROJECT_REF>")
        import psycopg
        with psycopg.connect(config["DATABASE_URL"], autocommit=True) as connection:
            stage = "preflight"
            report["stages"]["preflight"] = {"status": "PASS", **preflight(connection, config)}
            if args.apply:
                stage = "backup"
                report["stages"]["backup"] = {"status": "PASS", **backup_simulation_scope(connection, config)}
                stage = "simulation"
                run(config, connection, report)
        report.pop("active_stage", None)
        report["status"] = "PASS"
        return_code = 0
    except Exception as error:
        report["failed_stage"] = report.pop("active_stage", stage)
        report["error"] = str(error)
        return_code = 1
    print(json.dumps(report, indent=2, default=str))
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
