"""Unit tests for the OpenRouter client, with the HTTP call stubbed out."""
import json
import unittest

import llm


class TranslateTest(unittest.TestCase):
    def setUp(self):
        self.replies, self.calls = [], []
        self.orig = llm.post_json

        def fake_post(url, body, headers=None):
            self.calls.append(body["messages"][1]["content"])
            return {"choices": [{"message": {"content": json.dumps(self.replies.pop(0))}}]}
        llm.post_json = fake_post
        self.client = llm.OpenRouter("k", "parse-model", "jev-model")

    def tearDown(self):
        llm.post_json = self.orig

    def test_same_title_translated_once(self):
        # Two parts of one FC2 article share a title and must get the same English one.
        self.replies = [{"title": " First "}, {"title": "Second"}]
        self.assertEqual(self.client.translate_title("金欠"), "First")
        self.assertEqual(self.client.translate_title("金欠"), "First")
        self.assertEqual(self.calls, ["金欠"])

    def test_empty_translation_raises(self):
        self.replies = [{"title": ""}]
        with self.assertRaises(ValueError):
            self.client.translate_title("金欠")
