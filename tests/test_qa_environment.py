import pytest

from core.qa_environment import QAEnvironmentError, validate_qa_environment


QA_DATABASE_HOST = "db.xcnjauxmofqkwnpdazpj.supabase.co"
PRODUCTION_DATABASE_HOST = "db.zfdgwnipdyrpbardqoql.supabase.co"


def valid_env():
    return {
        "INSIGHTFLOW_ENV": "qa",
        "SUPABASE_PROJECT_REF": "xcnjauxmofqkwnpdazpj",
        "SUPABASE_URL": "https://xcnjauxmofqkwnpdazpj.supabase.co",
        "DATABASE_URL": f"postgresql+psycopg://qa:secret@{QA_DATABASE_HOST}:5432/insightflow",
        "INSIGHTFLOW_QA_DATABASE_HOST": QA_DATABASE_HOST,
        "AUTHN_PROVIDER_MODE": "supabase",
        "AUTHZ_PERSISTENCE_PROVIDER": "supabase",
    }


def test_valid_qa_identity_is_accepted():
    result = validate_qa_environment(valid_env())
    assert result.project_ref == "xcnjauxmofqkwnpdazpj"
    assert result.database_host == QA_DATABASE_HOST


def test_non_qa_environment_is_unchanged():
    env = valid_env()
    env["INSIGHTFLOW_ENV"] = "production"
    assert validate_qa_environment(env) is None


def test_rejects_production_database_even_when_allowlist_is_changed_to_match():
    env = valid_env()
    env["DATABASE_URL"] = (
        f"postgresql+psycopg://qa:secret@{PRODUCTION_DATABASE_HOST}:5432/insightflow"
    )
    env["INSIGHTFLOW_QA_DATABASE_HOST"] = PRODUCTION_DATABASE_HOST
    with pytest.raises(QAEnvironmentError):
        validate_qa_environment(env)


def test_rejects_arbitrary_database_even_when_self_allowlisted():
    env = valid_env()
    env["DATABASE_URL"] = "postgresql+psycopg://qa:secret@qa-db.internal:5432/insightflow"
    env["INSIGHTFLOW_QA_DATABASE_HOST"] = "qa-db.internal"
    with pytest.raises(QAEnvironmentError):
        validate_qa_environment(env)


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("SUPABASE_PROJECT_REF", "zfdgwnipdyrpbardqoql"),
        ("SUPABASE_PROJECT_REF", "other-project"),
        ("SUPABASE_URL", "https://zfdgwnipdyrpbardqoql.supabase.co"),
        ("SUPABASE_URL", "http://xcnjauxmofqkwnpdazpj.supabase.co"),
        ("DATABASE_URL", "sqlite:///qa.db"),
        ("DATABASE_URL", "postgresql://qa-db.internal/qa"),
        ("DATABASE_URL", f"postgresql://qa:z@{PRODUCTION_DATABASE_HOST}/qa"),
        ("INSIGHTFLOW_QA_DATABASE_HOST", ""),
        ("INSIGHTFLOW_QA_DATABASE_HOST", PRODUCTION_DATABASE_HOST),
        ("AUTHN_PROVIDER_MODE", "firebase"),
        ("AUTHZ_PERSISTENCE_PROVIDER", "firebase"),
    ],
)
def test_rejects_unsafe_or_ambiguous_configuration(key, value):
    env = valid_env()
    env[key] = value
    with pytest.raises(QAEnvironmentError):
        validate_qa_environment(env)


@pytest.mark.parametrize(
    "key",
    [
        "SUPABASE_PROJECT_REF",
        "SUPABASE_URL",
        "DATABASE_URL",
        "INSIGHTFLOW_QA_DATABASE_HOST",
        "AUTHN_PROVIDER_MODE",
        "AUTHZ_PERSISTENCE_PROVIDER",
    ],
)
def test_rejects_missing_required_configuration(key):
    env = valid_env()
    env.pop(key)
    with pytest.raises(QAEnvironmentError):
        validate_qa_environment(env)
