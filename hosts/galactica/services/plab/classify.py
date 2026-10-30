"""Jev's verdict on how a release was produced, judged from its title; the page ranks by it.

One OpenRouter decisions call per release, made once: refresh stores the answer in
cache.json. Design: docs/superpowers/specs/2026-10-30-plab-production-ranking-design.md
"""
import json
import urllib.request

DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"
MODEL = "typesafe/jev-1.13"

INSTRUCTIONS = (
    "How was this adult video release produced? Judge from the release title: a leading "
    "[bracket] usually names the studio or site, a trailing [bracket] lists tags, and the "
    "category is the tracker forum group it was posted in."
)

# The examples come from what was actually added from plab versus what was skipped.
CRITERIA = {
    "industrial": (
        "Mass-produced commercial porn: gonzo, anal-focused, taboo/family-roleplay or casting "
        "studios and networks, e.g. LegalPorno/AnalVids/PornBox, Tushy, Woodman Casting, "
        "TeamSkeet, Family Therapy, Backroom Casting Couch, Brazzers."
    ),
    "pro_artistic": (
        "Professionally produced but intimate, romantic or artistic, e.g. Erika Lust, X-Art, "
        "SexArt/MetArt, Bellesa, Frolicme, Viv Thomas."
    ),
    "amateur": (
        "Homemade or creator-run: real couples, amateurs, OnlyFans/ManyVids/Pornhub creators "
        "filming themselves, home or archive footage."
    ),
}


def post_json(url, body, headers, timeout=120):
    req = urllib.request.Request(
        url, json.dumps(body).encode(), {"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


class Classifier:
    def __init__(self, api_key, model=MODEL, post=post_json):
        self.headers = {"Authorization": f"Bearer {api_key}"}
        self.model = model
        self.post = post

    def classify(self, title, category):
        """{"class": one of CRITERIA, "confidence": Jev's, or None}. Raises on a bad reply."""
        d = self.post(DECISIONS_URL, {
            "model": self.model,
            "state": {"title": title, "category": category},
            "questions": {"production": {"type": "choice", "instructions": INSTRUCTIONS,
                                         "criteria": CRITERIA}},
        }, self.headers)
        answer = d["answers"]["production"]
        if answer.get("choice") not in CRITERIA:
            raise ValueError(f"unexpected production choice: {answer.get('choice')!r}")
        return {"class": answer["choice"], "confidence": answer.get("confidence")}
