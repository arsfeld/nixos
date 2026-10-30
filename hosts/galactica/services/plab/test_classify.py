import unittest

import classify


class FakePost:
    def __init__(self, answer):
        self.answer = answer
        self.calls = []

    def __call__(self, url, body, headers):
        self.calls.append((url, body, headers))
        return {"answers": {"production": self.answer}}


class Classify(unittest.TestCase):
    def test_request(self):
        post = FakePost({"choice": "amateur", "confidence": 0.9})
        classify.Classifier("sk-key", post=post).classify("[OnlyFans.com] Couple - Morning", "Clips and siterips")
        url, body, headers = post.calls[0]
        self.assertEqual(url, "https://openrouter.ai/api/alpha/decisions")
        self.assertEqual(headers, {"Authorization": "Bearer sk-key"})
        self.assertEqual(body["model"], "typesafe/jev-1.13")
        self.assertEqual(body["state"], {"title": "[OnlyFans.com] Couple - Morning",
                                         "category": "Clips and siterips"})
        question = body["questions"]["production"]
        self.assertEqual(question["type"], "choice")
        self.assertTrue(question["instructions"])
        self.assertEqual(set(question["criteria"]), {"industrial", "pro_artistic", "amateur"})

    def test_model_override(self):
        post = FakePost({"choice": "industrial"})
        classify.Classifier("k", model="other/model", post=post).classify("t", "c")
        self.assertEqual(post.calls[0][1]["model"], "other/model")

    def test_answer(self):
        post = FakePost({"choice": "pro_artistic", "confidence": "high"})
        out = classify.Classifier("k", post=post).classify("[X-Art.com] A - B", "Clips and siterips")
        self.assertEqual(out, {"class": "pro_artistic", "confidence": "high"})

    def test_missing_confidence_is_none(self):
        out = classify.Classifier("k", post=FakePost({"choice": "industrial"})).classify("t", "c")
        self.assertEqual(out, {"class": "industrial", "confidence": None})

    def test_unknown_choice_raises(self):
        with self.assertRaises(ValueError):
            classify.Classifier("k", post=FakePost({"choice": "none"})).classify("t", "c")


if __name__ == "__main__":
    unittest.main()
