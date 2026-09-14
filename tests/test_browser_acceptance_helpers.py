from tools.final_windows_browser_acceptance import _expected_token_present


def test_browser_numeric_evidence_accepts_grouping_and_float_precision():
    assert _expected_token_present("3,860,365.74", "Revenue 3860365.739999998")
    assert _expected_token_present("23.90%", "Margin 0.239 or 23.9%")


def test_browser_numeric_evidence_rejects_nearby_but_different_value():
    assert not _expected_token_present("3,860,365.74", "Revenue 3860365.70")


def test_browser_text_evidence_keeps_identifier_tokens_exact():
    assert _expected_token_present("P0098", "Top product: P0098")
    assert not _expected_token_present("P0098", "Top product: P0099")
