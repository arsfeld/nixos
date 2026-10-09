"""OpenRouter calls: filename parse and title translation (chat, JSON mode), and Jev
candidate choice."""
import json

from match import jev_request
from net import post_json

CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"
DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions"

PARSE_PROMPT = """You identify adult video scenes from their file path. Return JSON:
{"studio": str|null, "title": str|null, "performers": [str], "date": "YYYY-MM-DD"|null,
 "time": "HH:MM"|null, "series": str|null, "clip_id": str|null, "query": str}
"studio" is the production studio/site (e.g. "Lustery", "TripForFuck"), or the creator's
handle for OnlyFans/amateur content. Use folder names as context. Expand dotted/abbreviated
release names into proper words. "title" must be a real, specific scene title actually
present in the file path -- never just the studio, creator, or series name repeated; use
null when the path has no real title. "time" is the clip's time of day, if the filename
carries one. "series" is a series/collection/folder name (e.g. "College Fun 2004") when
the path names one, distinct from the studio. "clip_id" is a short distinguishing token
from the filename for telling same-series clips apart when there's no real title -- e.g.
"2508-02" -- not a long numeric upload/asset ID like "3998694437" when a date is already
available. "query" is the best short search string for a scene database (studio +
performers + title keywords). Use null / [] rather than guessing."""

TRANSLATE_PROMPT = """Translate this Japanese adult video title into natural English, as
a title. Drop store promotions that aren't part of the title: sale deadlines, prices and
point offers, "bonus included" and the like. Return JSON: {"title": str}"""


class OpenRouter:
    def __init__(self, api_key, parse_model, jev_model):
        self.headers = {"Authorization": f"Bearer {api_key}"}
        self.parse_model = parse_model
        self.jev_model = jev_model
        # By original title, so the parts of a multi-part FC2 article (one title) get one
        # English title rather than a fresh rewording each.
        self.translations = {}

    def _json(self, prompt, text):
        body = {"model": self.parse_model, "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": prompt},
                             {"role": "user", "content": text}]}
        for _ in range(2):  # one re-ask on a malformed reply
            d = post_json(CHAT_URL, body, self.headers)
            try:
                out = json.loads(d["choices"][0]["message"]["content"])
            except (json.JSONDecodeError, KeyError, IndexError, TypeError):
                continue
            if isinstance(out, dict):
                return out
        raise ValueError(f"malformed reply for {text!r}")

    def parse(self, path):
        return self._json(PARSE_PROMPT, path)

    def translate_title(self, title):
        if title not in self.translations:
            out = self._json(TRANSLATE_PROMPT, title).get("title")
            if not isinstance(out, str) or not out.strip():
                raise ValueError(f"no translation for {title!r}")
            self.translations[title] = out.strip()
        return self.translations[title]

    def choose(self, path, duration, parse, cands):
        state, questions = jev_request(path, duration, parse, cands)
        d = post_json(DECISIONS_URL, {"model": self.jev_model, "state": state,
                                      "questions": questions}, self.headers)
        return d["answers"]["match"]
