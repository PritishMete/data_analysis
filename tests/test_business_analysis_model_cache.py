import threading

import pandas as pd

import main


def _clean_table(name):
    return {"name": name, "columns": ["id"], "rows": [{"id": 1}]}


def test_business_model_cache_reuses_only_identical_source_hashes(monkeypatch):
    calls = {"fact": 0, "customer": 0, "product": 0, "date": 0}

    def clean_fact(tables, source_hashes=None):
        calls["fact"] += 1
        return {
            "status": "READY",
            "cleaned_table": _clean_table("fact_orders"),
            "event_key": {"column": "order_id"},
            "relationships": [],
        }

    def clean_customer(_tables):
        calls["customer"] += 1
        return {"cleaned_table": _clean_table("dim_customer")}

    def clean_product(_tables):
        calls["product"] += 1
        return {"cleaned_table": _clean_table("dim_product")}

    def clean_date(_fact):
        calls["date"] += 1
        return {"cleaned_table": _clean_table("dim_date")}

    monkeypatch.setattr(main, "clean_order_fact", clean_fact)
    monkeypatch.setattr(main, "clean_customer_dimension", clean_customer)
    monkeypatch.setattr(main, "clean_product_dimension", clean_product)
    monkeypatch.setattr(main, "create_date_dimension", clean_date)
    monkeypatch.setattr(main, "_BUSINESS_MODEL_CACHE", None)

    tables = {"regions_raw": pd.DataFrame({"region_id": [1], "region": ["North"]})}
    hashes = {"orders_raw.csv": "sha-a"}
    first, first_error = main._business_analysis_model(tables, hashes)
    second, second_error = main._business_analysis_model(tables, hashes)

    assert first_error is None and second_error is None
    assert first is second
    assert calls == {"fact": 1, "customer": 1, "product": 1, "date": 1}

    changed, changed_error = main._business_analysis_model(
        tables, {"orders_raw.csv": "sha-b"}
    )
    assert changed_error is None
    assert changed is not first
    assert calls == {"fact": 2, "customer": 2, "product": 2, "date": 2}


def test_business_model_cache_preserves_blocked_fact_response(monkeypatch):
    blocked_fact = {"status": "BLOCKED", "reason": "required input is missing"}
    monkeypatch.setattr(
        main, "clean_order_fact", lambda *_args, **_kwargs: blocked_fact
    )
    monkeypatch.setattr(main, "_BUSINESS_MODEL_CACHE", None)

    model, error = main._business_analysis_model(
        {"regions_raw": pd.DataFrame({"region": ["North"]})},
        {"orders_raw.csv": "sha-blocked"},
    )

    assert model is None
    assert error == {
        "success": False,
        "error": "Clean analytical model is required before Chapter 6.",
        "fact_result": blocked_fact,
    }


def test_business_model_warmup_runs_without_changing_the_detail_result(monkeypatch):
    calls = []
    monkeypatch.setattr(
        main,
        "_business_analysis_model",
        lambda tables, hashes: calls.append((tables, hashes)),
    )
    tables = {"regions_raw": pd.DataFrame({"region": ["North"]})}
    hashes = {"regions_raw.csv": "sha"}

    main._warm_business_analysis_model(tables, hashes)

    assert len(calls) == 1
    assert calls[0][0] is tables
    assert calls[0][1] == hashes


def test_business_model_warmup_is_scheduled_immediately_on_a_worker(monkeypatch):
    completed = threading.Event()
    observed = {}

    def build(tables, hashes):
        observed["tables"] = tables
        observed["hashes"] = hashes
        completed.set()
        return None, None

    monkeypatch.setattr(main, "_business_analysis_model", build)
    tables = {"regions_raw": pd.DataFrame({"region": ["North"]})}
    hashes = {"regions_raw.csv": "sha"}

    main._schedule_business_analysis_model_warmup(tables, hashes)

    assert completed.wait(timeout=2)
    assert observed["tables"] is tables
    assert observed["hashes"] == hashes
