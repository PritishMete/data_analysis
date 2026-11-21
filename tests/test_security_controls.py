from security_controls import validate_outbound_url, validate_upload_filename


def test_upload_filename_rejects_path_traversal_and_scripts():
    for name in ("../secret.csv", "report.csv.exe", "report<script>.csv", "report\x00.csv"):
        try:
            validate_upload_filename(name)
        except ValueError:
            pass
        else:
            raise AssertionError(f"unsafe filename accepted: {name!r}")


def test_upload_filename_accepts_supported_basename():
    assert validate_upload_filename("sales.csv") == "sales.csv"


def test_outbound_url_requires_allowlisted_https_host():
    try:
        validate_outbound_url("http://127.0.0.1/admin", allowed_hosts={"127.0.0.1"})
    except ValueError:
        pass
    else:
        raise AssertionError("insecure/private URL accepted")
