"""Regression tests for bounded in-process reliability resources."""

import asyncio
import threading

import pandas as pd

import main
from common.transformations.transformation_history import TransformationHistory


def test_learning_event_queue_drops_optional_telemetry_at_capacity(monkeypatch):
    class NeverScheduled:
        def __call__(self, *args, **kwargs):
            raise AssertionError("create_task must not run at capacity")

    tasks = {object() for _ in range(main._MAX_LEARNING_EVENT_TASKS)}
    monkeypatch.setattr(main, "_LEARNING_EVENT_TASKS", tasks)
    monkeypatch.setattr(asyncio, "create_task", NeverScheduled())

    main._queue_learning_event(
        text="safe query",
        df=pd.DataFrame({"value": [1]}),
        sheets=[],
        result={},
    )

    assert len(main._LEARNING_EVENT_TASKS) == main._MAX_LEARNING_EVENT_TASKS


def test_business_model_warmup_respects_thread_limit(monkeypatch):
    threads = {
        threading.Thread(),
        threading.Thread(),
    }
    monkeypatch.setattr(main, "_BUSINESS_MODEL_WARMUP_THREADS", threads)
    monkeypatch.setattr(main, "_BUSINESS_MODEL_WARMUP_KEYS", set())
    monkeypatch.setattr(main, "_BUSINESS_MODEL_WARMUP_MAX_THREADS", 2)

    def unexpected_thread(*args, **kwargs):
        raise AssertionError("warm-up must not start above the concurrency limit")

    monkeypatch.setattr(threading, "Thread", unexpected_thread)
    main._schedule_business_analysis_model_warmup(
        {"orders": pd.DataFrame({"id": [1]})},
        {"orders": "hash"},
    )

    assert len(main._BUSINESS_MODEL_WARMUP_THREADS) == 2


def test_transformation_history_retains_only_latest_50_undo_entries():
    history = TransformationHistory()
    frame = pd.DataFrame({"value": [0]})

    for value in range(1, 56):
        updated = pd.DataFrame({"value": [value]})
        history.record(
            transformation_name="replace",
            before_df=frame,
            after_df=updated,
            params={"value": value},
            metadata={},
        )
        frame = updated

    assert len(history) == 50
    restored = history.undo()
    assert restored is not None
    restored_df, entry = restored
    assert restored_df.iloc[0]["value"] == 54
    assert entry.params["value"] == 55
