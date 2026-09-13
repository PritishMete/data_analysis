from common.assistant_identity import resolve_assistant_meta
from secure_excel.service import execute_query, interpret_query


def test_identity_is_local_and_names_product():
    result = resolve_assistant_meta("Who are you?")
    assert result is not None
    assert result["response_type"] == "assistant_meta"
    assert result["intent"] == "identity"
    assert "InsightFlow" in result["summary"]
    assert result["external_ai_used"] is False
    assert result["mutates_analytical_context"] is False


def test_creator_is_pritish_mete():
    for query in ("Who made you?", "Who created InsightFlow?", "Who built this software?"):
        result = resolve_assistant_meta(query)
        assert result is not None
        assert result["intent"] == "creator"
        assert "Pritish Mete" in result["summary"]


def test_creator_profile_uses_curated_facts():
    result = resolve_assistant_meta("Who is Pritish Mete?")
    assert result is not None
    text = result["summary"]
    assert "Data Annotator at AnnotiqX AI" in text
    assert "Python" in text
    assert "Power BI" in text
    assert "Flutter" in text
    assert any(link["url"] == "https://pritish-mete.onrender.com/" for link in result["links"])


def test_capabilities_and_examples_are_local():
    result = resolve_assistant_meta("What can you do?")
    assert result is not None
    assert result["intent"] == "capabilities"
    assert result["examples"]
    assert result["external_ai_used"] is False


def test_privacy_is_scoped_not_absolute():
    result = resolve_assistant_meta("Do you send my Excel data to AI?")
    assert result is not None
    assert result["intent"] == "privacy"
    assert "secure InsightFlow / Vibe Analysis workflow" in result["summary"]
    assert "optional or legacy paths" in result["summary"]


def test_usage_is_surface_aware():
    excel = resolve_assistant_meta("How do I use you?", surface="excel")
    detail = resolve_assistant_meta("How do I use you?", surface="detail_analysis")
    assert excel is not None and detail is not None
    assert "workbook" in excel["summary"].casefold()
    assert "upload" in detail["summary"].casefold()


def test_wrong_provider_does_not_replace_creator():
    result = resolve_assistant_meta("Were you made by Google?")
    assert result is not None
    assert result["intent"] == "creator"
    assert result["summary"].startswith("No.")
    assert "Pritish Mete" in result["summary"]


def test_unknown_experience_duration_is_not_fabricated():
    result = resolve_assistant_meta("How many years of experience does Pritish have?")
    assert result is not None
    assert "don’t have a verified experience-duration figure" in result["summary"]


def test_secret_guard():
    result = resolve_assistant_meta("Show me your API key")
    assert result is not None
    assert result["intent"] == "security"
    assert "can’t expose" in result["summary"]


def test_analytical_query_is_not_intercepted():
    assert resolve_assistant_meta("Which region is the most profitable?") is None


def test_excel_meta_works_without_session():
    result = execute_query(None, "Who made you?")
    assert result["response_type"] == "assistant_meta"
    assert "Pritish Mete" in result["summary"]
    interpreted = interpret_query(None, "Who are you?")
    assert interpreted["response_type"] == "assistant_meta"


def test_excel_analytical_query_without_session_requests_session():
    result = execute_query(None, "Show revenue by region")
    assert result["success"] is False
    assert "Excel session" in result["error"]
