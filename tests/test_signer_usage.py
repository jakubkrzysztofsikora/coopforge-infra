import json
import os
import sys
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.environ.update({
    "COOPFORGE_API": "https://coopforge.example",
    "COOPFORGE_API_KEY": "test-api-key",
    "COOPFORGE_STATUS_TOKEN": "test-coop-token",
    "COOP_SLUG": "test-coop",
    "LITELLM_URL": "http://127.0.0.1:4000",
    "LITELLM_MASTER_KEY": "test-master",
})

from manifest import signer


class DailyActivityTests(unittest.TestCase):
    def test_paginates_past_nonempty_pages_without_aliases(self):
        pages = [
            {"results": [{"date": "2026-10-20", "breakdown": {"api_keys": {"h1": {"metadata": {}, "metrics": {}}}}}]},
            {"results": [{"date": "2026-10-21", "breakdown": {"api_keys": {"h2": {
                "metadata": {"key_alias": "coop-test-coop-a1b2"},
                "metrics": {"prompt_tokens": 10, "completion_tokens": 3, "api_requests": 2},
            }}}}]},
            {"results": []},
        ]
        with patch.object(signer, "litellm", side_effect=pages) as request:
            rows, complete = signer.fetch_daily_activity("2026-10-20", "2026-10-21")

        self.assertTrue(complete)
        self.assertEqual(rows, [{
            "day": "2026-10-21",
            "alias": "coop-test-coop-a1b2",
            "prompt": 10,
            "completion": 3,
            "requests": 2,
        }])
        self.assertEqual(request.call_count, 3)
    def test_reports_incomplete_after_page_cap(self):
        page = {"results": [{"date": "2026-10-20", "breakdown": {"api_keys": {"h": {"metadata": {}, "metrics": {}}}}}]}
        with patch.object(signer, "litellm", return_value=page) as request:
            rows, complete = signer.fetch_daily_activity("2026-10-20", "2026-10-20")

        self.assertFalse(complete)
        self.assertEqual(rows, [])
        self.assertEqual(request.call_count, 30)

    def test_rejects_malformed_activity_response(self):
        with self.assertRaises(ValueError):
            signer.parse_daily_activity({"results": None})
    def test_chunks_reports_below_platform_row_limit(self):
        rows = [{"day": "2026-10-22", "alias": "a", "prompt": 1, "completion": 0, "requests": 1}] * 1001
        sizes = []

        class Response:
            def __init__(self, payload):
                self.payload = payload

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return json.dumps(self.payload).encode()

        def open_request(request, timeout):
            payload = json.loads(request.data)
            sizes.append(len(payload["usage"]))
            return Response({"written": len(payload["usage"]), "ignored": 0})

        with patch.object(signer.urllib.request, "urlopen", side_effect=open_request):
            result = signer.report_usage(rows, "rid_1")

        self.assertEqual(sizes, [1000, 1])
        self.assertEqual(result, {"written": 1001, "ignored": 0})

    def test_closeout_retry_skips_aliases_already_revoked(self):
        alias = "coop-test-coop-a1b2"
        coop = {"coop_id": "coop_1", "status": "closing", "members": [{"key_id": alias}]}
        finalize = patch.object(
            signer,
            "finalize_closeout",
            side_effect=[RuntimeError("release pending"), {"completed": True}],
        )
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(signer, "USAGE_STATE", Path(directory) / "usage.json"), \
                 patch.object(signer, "fetch_daily_activity", return_value=([], True)), \
                 patch.object(signer, "report_usage", return_value={}), \
                 patch.object(signer, "litellm", return_value={}) as gateway, finalize:
                with self.assertRaisesRegex(RuntimeError, "release pending"):
                    signer.sync_usage("rid_1", coop, {alias: "sk-test"})
                signer.sync_usage("rid_2", coop, {alias: "sk-test"})

        gateway.assert_called_once_with("POST", "/key/delete", {"key_aliases": [alias]})

    def test_closeout_uploads_usage_before_revoking_keys(self):
        alias = "coop-test-coop-a1b2"
        events = []
        coop = {
            "coop_id": "coop_1",
            "coop_slug": "test-coop",
            "status": "closing",
            "closeout_reason": "archived",
            "members": [{"key_id": alias}],
        }
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(signer, "USAGE_STATE", Path(directory) / "usage.json"), \
                 patch.object(signer, "fetch_daily_activity", return_value=([{"day": "2026-10-22", "alias": alias, "prompt": 5, "completion": 2, "requests": 1}], True)), \
                 patch.object(signer, "report_usage", side_effect=lambda rows, rid: events.append(("usage", rows)) or {}), \
                 patch.object(signer, "litellm", side_effect=lambda method, path, body: events.append(("revoke", body)) or {}), \
                 patch.object(signer, "finalize_closeout", side_effect=lambda row, rid, aliases: events.append(("closeout", aliases)) or {"completed": True}):
                signer.sync_usage("rid_1", coop, {alias: "sk-test"})

        self.assertEqual([event[0] for event in events], ["usage", "revoke", "closeout"])
        self.assertEqual(events[0][1][0]["prompt"], 5)
        self.assertEqual(events[1][1]["key_aliases"], [alias])
        self.assertEqual(events[2][1], [alias])

    def test_does_not_revoke_if_final_usage_upload_fails(self):
        alias = "coop-test-coop-a1b2"
        coop = {"status": "closing", "coop_id": "coop_1", "members": [{"key_id": alias}]}
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(signer, "USAGE_STATE", Path(directory) / "usage.json"), \
                 patch.object(signer, "fetch_daily_activity", return_value=([], True)), \
                 patch.object(signer, "report_usage", side_effect=RuntimeError("upload failed")), \
                 patch.object(signer, "litellm") as gateway:
                with self.assertRaisesRegex(RuntimeError, "upload failed"):
                    signer.sync_usage("rid_1", coop, {alias: "sk-test"})
        gateway.assert_not_called()

class MemberRevocationTests(unittest.TestCase):
    def test_revokes_terminal_member_key_and_acknowledges_cleared_alias(self):
        alias = signer.member_key_id("test-coop", "member_1")
        seen = {alias: "sk-test"}
        acknowledgements = []
        with patch.object(signer, "litellm", return_value={}) as gateway, \
             patch.object(signer, "report_revoked_key", side_effect=lambda member_id, key_id, rid: acknowledgements.append((member_id, key_id, rid)), create=True):
            signer.revoke_member_key(
                {"id": "member_1", "status": "cancelled", "key_id": alias},
                "test-coop",
                seen,
                "rid_1",
            )

        gateway.assert_called_once_with("POST", "/key/delete", {"key_aliases": [alias]})
        self.assertEqual(acknowledgements, [("member_1", alias, "rid_1")])
        self.assertEqual(seen, {})

    def test_keeps_local_key_when_revocation_acknowledgement_fails(self):
        alias = signer.member_key_id("test-coop", "member_1")
        seen = {alias: "sk-test"}
        with patch.object(signer, "litellm", return_value={}), \
             patch.object(signer, "report_revoked_key", side_effect=RuntimeError("ack failed"), create=True):
            with self.assertRaisesRegex(RuntimeError, "ack failed"):
                signer.revoke_member_key(
                    {"id": "member_1", "status": "refunded", "key_id": alias},
                    "test-coop",
                    seen,
                    "rid_1",
                )

        self.assertEqual(seen, {alias: "sk-test"})

if __name__ == "__main__":
    unittest.main()
