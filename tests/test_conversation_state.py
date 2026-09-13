from common.conversation_state import STORE, build_session_summary, generate_suggestions


def _sid(name: str) -> str:
    sid = f"test-{name}"
    STORE._states.pop(sid, None)
    return sid


def test_region_suggestions_are_context_aware():
    sid = _sid("region")
    STORE.record_success(sid, {"query": "Which region is most profitable?", "current_scope": "North", "selected_entity": "North", "selected_entity_type": "business_region", "current_metric": "profit", "analysis": {"type": "ranking", "scope": "global", "grain": "business_region", "metric": "profit", "selected_entity": "North"}})
    queries = [item["query"] for item in generate_suggestions(sid)]
    assert any("North" in query and "2025" in query for query in queries)
    assert any("categories" in query.casefold() for query in queries)


def test_product_suggestions():
    sid = _sid("product")
    STORE.record_success(sid, {"selected_entity": "Kids Product 98", "selected_entity_type": "product", "current_scope": "Kids Product 98"})
    queries = [item["query"] for item in generate_suggestions(sid)]
    assert "How profitable is it?" in queries
    assert "What about in 2025?" in queries


def test_comparison_suggestions():
    sid = _sid("comparison")
    STORE.record_success(sid, {"comparison_entities": ["North", "South"]})
    queries = [item["query"] for item in generate_suggestions(sid, {"intent": "comparison"})]
    assert "Which one has the better margin?" in queries
    assert any("month by month" in query for query in queries)


def test_quality_suggestions():
    sid = _sid("quality")
    queries = [item["query"] for item in generate_suggestions(sid, {"intent": "data_quality_analysis"})]
    assert "Which issues materially affect business KPIs?" in queries


def test_suggestion_deduplication_and_recent_query_suppression():
    sid = _sid("dedupe")
    STORE.record_success(sid, {"query": "How did North perform in 2025?", "selected_entity": "North", "selected_entity_type": "region"})
    first = generate_suggestions(sid)
    second = generate_suggestions(sid)
    assert "How did North perform in 2025?" not in [item["query"] for item in first]
    assert not {x["query"] for x in first} & {x["query"] for x in second}


def test_session_summary_and_report_history():
    sid = _sid("summary")
    STORE.record_success(sid, {"current_scope": "North", "active_filters": {"year": 2025, "region": "North"}, "selected_entity": "North", "selected_entity_type": "business_region", "current_metric": "profit", "analysis": {"type": "business_analysis", "scope": "North", "metric": "profit", "summary": "North 2025 performance"}, "report": {"filename": "Vibe_Analysis_North_2025.pdf", "report_type": "detailed", "scope": "North / 2025", "generated_at": "2026-09-13T00:00:00Z"}})
    summary = build_session_summary(sid)
    assert summary["current_scope"] == "North"
    assert summary["active_filters"]["year"] == 2025
    assert summary["selected_entity"] == "North"
    assert summary["generated_reports"][0]["filename"] == "Vibe_Analysis_North_2025.pdf"
    assert summary["privacy"]["external_ai_used"] is False


def test_reset_keeps_history_but_clears_active_scope():
    sid = _sid("reset")
    STORE.record_success(sid, {"current_scope": "North", "active_filters": {"year": 2025}, "selected_entity": "North", "selected_entity_type": "region", "analysis": {"type": "ranking", "scope": "global", "selected_entity": "North"}})
    state = STORE.reset_active_scope(sid)
    assert state.current_scope == "global"
    assert state.active_filters == {}
    assert state.selected_entity is None
    assert len(state.recent_analyses) == 1


def test_snapshot_restore_preserves_last_good_state():
    sid = _sid("rollback")
    STORE.record_success(sid, {"current_scope": "North", "selected_entity": "North", "selected_entity_type": "region"})
    snap = STORE.snapshot(sid)
    STORE.record_success(sid, {"current_scope": "broken", "selected_entity": "wrong"})
    restored = STORE.restore(sid, snap)
    assert restored.current_scope == "North"
    assert restored.selected_entity == "North"


def test_meta_context_has_no_suggestions():
    sid = _sid("meta")
    assert generate_suggestions(sid, {"intent": "assistant_meta"}) == []


def test_history_is_bounded():
    sid = _sid("bounded")
    for idx in range(30):
        STORE.record_success(sid, {"query": f"q{idx}", "analysis": {"type": "test", "summary": str(idx)}})
    state = STORE.get(sid)
    assert len(state.recent_queries) == 20
    assert len(state.recent_analyses) == 20
