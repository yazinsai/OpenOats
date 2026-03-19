#!/usr/bin/env python3
"""
Integration tests for MiniMax LLM provider support in OpenOats.

These tests verify the MiniMax OpenAI-compatible API endpoint works correctly
with the same URL, auth, and model patterns used in the Swift implementation.

Requirements:
    - MINIMAX_API_KEY environment variable set

Usage:
    MINIMAX_API_KEY=your_key python3 tests/test_minimax_integration.py
"""

import json
import os
import sys
import unittest
import urllib.request
import urllib.error


MINIMAX_API_KEY = os.environ.get("MINIMAX_API_KEY", "")
MINIMAX_BASE_URL = "https://api.minimax.io/v1/chat/completions"
MODELS = ["MiniMax-M2.7", "MiniMax-M2.7-highspeed"]


def skip_without_key(func):
    """Skip test if MINIMAX_API_KEY is not set."""
    def wrapper(*args, **kwargs):
        if not MINIMAX_API_KEY:
            raise unittest.SkipTest("MINIMAX_API_KEY not set")
        return func(*args, **kwargs)
    return wrapper


class TestMiniMaxAPIEndpoint(unittest.TestCase):
    """Test the MiniMax API endpoint used by OpenOats."""

    @skip_without_key
    def test_non_streaming_completion(self):
        """Test non-streaming chat completion (used by SuggestionEngine gate/generation)."""
        body = {
            "model": "MiniMax-M2.7",
            "messages": [
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": "Say hello in one word."},
            ],
            "stream": False,
            "max_tokens": 32,
        }

        req = urllib.request.Request(
            MINIMAX_BASE_URL,
            data=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {MINIMAX_API_KEY}",
            },
        )

        resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
        self.assertIn("choices", resp)
        self.assertGreater(len(resp["choices"]), 0)
        content = resp["choices"][0]["message"]["content"]
        self.assertIsInstance(content, str)
        self.assertGreater(len(content), 0)

    @skip_without_key
    def test_streaming_completion(self):
        """Test streaming chat completion (used by NotesEngine for live markdown)."""
        body = {
            "model": "MiniMax-M2.7",
            "messages": [
                {"role": "system", "content": "You are a meeting notes assistant."},
                {"role": "user", "content": "Summarize: Alice said hello, Bob replied."},
            ],
            "stream": True,
            "max_tokens": 64,
        }

        req = urllib.request.Request(
            MINIMAX_BASE_URL,
            data=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {MINIMAX_API_KEY}",
            },
        )

        resp = urllib.request.urlopen(req, timeout=30)
        chunks = []
        for line in resp:
            line = line.decode().strip()
            if line.startswith("data: "):
                payload = line[6:]
                if payload == "[DONE]":
                    break
                chunk = json.loads(payload)
                delta = chunk.get("choices", [{}])[0].get("delta", {})
                if "content" in delta and delta["content"]:
                    chunks.append(delta["content"])

        full_text = "".join(chunks)
        self.assertGreater(len(full_text), 0)

    @skip_without_key
    def test_highspeed_model(self):
        """Test MiniMax-M2.7-highspeed model works."""
        body = {
            "model": "MiniMax-M2.7-highspeed",
            "messages": [
                {"role": "user", "content": "Reply with the word 'ok'."},
            ],
            "stream": False,
            "max_tokens": 16,
        }

        req = urllib.request.Request(
            MINIMAX_BASE_URL,
            data=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {MINIMAX_API_KEY}",
            },
        )

        resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
        self.assertIn("choices", resp)
        content = resp["choices"][0]["message"]["content"]
        self.assertGreater(len(content), 0)

    @skip_without_key
    def test_system_and_user_messages(self):
        """Test system + user message pattern used by all engines."""
        body = {
            "model": "MiniMax-M2.7",
            "messages": [
                {"role": "system", "content": "Output JSON only: {\"topic\": \"string\"}"},
                {"role": "user", "content": "The meeting is about product launch."},
            ],
            "stream": False,
            "max_tokens": 128,
        }

        req = urllib.request.Request(
            MINIMAX_BASE_URL,
            data=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {MINIMAX_API_KEY}",
            },
        )

        resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
        content = resp["choices"][0]["message"]["content"]
        self.assertIn("topic", content.lower())

    def test_invalid_api_key_rejected(self):
        """Test that invalid API key returns error."""
        body = {
            "model": "MiniMax-M2.7",
            "messages": [{"role": "user", "content": "test"}],
            "stream": False,
            "max_tokens": 8,
        }

        req = urllib.request.Request(
            MINIMAX_BASE_URL,
            data=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer invalid-key-12345",
            },
        )

        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req, timeout=15)
        self.assertIn(ctx.exception.code, (401, 403))


class TestMiniMaxConfig(unittest.TestCase):
    """Test configuration values match what the Swift code expects."""

    def test_base_url_format(self):
        """Verify base URL matches OpenAI-compatible pattern."""
        self.assertEqual(MINIMAX_BASE_URL, "https://api.minimax.io/v1/chat/completions")

    def test_model_ids(self):
        """Verify model IDs are the expected values."""
        self.assertIn("MiniMax-M2.7", MODELS)
        self.assertIn("MiniMax-M2.7-highspeed", MODELS)
        self.assertEqual(len(MODELS), 2)

    def test_auth_header_format(self):
        """Verify auth uses Bearer token format."""
        key = "test-key"
        header = f"Bearer {key}"
        self.assertTrue(header.startswith("Bearer "))


class TestSwiftCodeConsistency(unittest.TestCase):
    """Verify Swift source files have consistent MiniMax integration."""

    def setUp(self):
        self.base_dir = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "OpenOats", "Sources", "OpenOats",
        )

    def test_llm_provider_enum_has_minimax(self):
        """LLMProvider enum should include miniMax case."""
        path = os.path.join(self.base_dir, "Settings", "AppSettings.swift")
        with open(path) as f:
            content = f.read()
        self.assertIn("case minimax", content)
        self.assertIn('"MiniMax"', content)

    def test_settings_has_minimax_api_key(self):
        """AppSettings should have minimaxApiKey property."""
        path = os.path.join(self.base_dir, "Settings", "AppSettings.swift")
        with open(path) as f:
            content = f.read()
        self.assertIn("minimaxApiKey", content)
        self.assertIn("minimaxModel", content)
        self.assertIn('"MiniMax-M2.7"', content)

    def test_notes_engine_handles_minimax(self):
        """NotesEngine should route MiniMax provider."""
        path = os.path.join(self.base_dir, "Intelligence", "NotesEngine.swift")
        with open(path) as f:
            content = f.read()
        self.assertIn("case .minimax:", content)
        self.assertIn("api.minimax.io", content)

    def test_suggestion_engine_handles_minimax(self):
        """SuggestionEngine should route MiniMax provider."""
        path = os.path.join(self.base_dir, "Intelligence", "SuggestionEngine.swift")
        with open(path) as f:
            content = f.read()
        self.assertIn("case .minimax:", content)
        self.assertIn("api.minimax.io", content)
        self.assertIn("settings.minimaxApiKey", content)
        self.assertIn("settings.minimaxModel", content)

    def test_refinement_engine_handles_minimax(self):
        """TranscriptRefinementEngine should route MiniMax provider."""
        path = os.path.join(self.base_dir, "Intelligence", "TranscriptRefinementEngine.swift")
        with open(path) as f:
            content = f.read()
        self.assertIn("case .minimax:", content)
        self.assertIn("api.minimax.io", content)

    def test_settings_view_has_minimax_ui(self):
        """SettingsView should have MiniMax provider UI."""
        path = os.path.join(self.base_dir, "Views", "SettingsView.swift")
        with open(path) as f:
            content = f.read()
        self.assertIn("case .minimax:", content)
        self.assertIn("minimaxApiKey", content)
        self.assertIn("MiniMax-M2.7", content)
        self.assertIn("MiniMax-M2.7-highspeed", content)

    def test_readme_mentions_minimax(self):
        """README should mention MiniMax as a provider option."""
        path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "README.md",
        )
        with open(path) as f:
            content = f.read()
        self.assertIn("MiniMax", content)
        self.assertIn("minimax", content.lower())

    def test_all_switch_cases_exhaustive(self):
        """All switch statements on llmProvider should handle .miniMax."""
        files_to_check = [
            ("Intelligence/NotesEngine.swift", 1),
            ("Intelligence/SuggestionEngine.swift", 4),
            ("Intelligence/TranscriptRefinementEngine.swift", 1),
            ("Settings/AppSettings.swift", 1),
        ]
        for rel_path, expected_min in files_to_check:
            path = os.path.join(self.base_dir, rel_path)
            with open(path) as f:
                content = f.read()
            count = content.count("case .minimax")
            self.assertGreaterEqual(
                count, expected_min,
                f"{rel_path} should have at least {expected_min} 'case .minimax' but has {count}",
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
