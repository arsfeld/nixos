"""OpenRouter calls: filename parse (chat, JSON mode) and Jev candidate choice."""
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


class OpenRouter:
    def __init__(self, api_key, parse_model, jev_model):
        self.headers = {"Authorization": f"Bearer {api_key}"}
        self.parse_model = parse_model
        self.jev_model = jev_model

    def parse(self, path):
        body = {"model": self.parse_model, "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": PARSE_PROMPT},
                             {"role": "user", "content": path}]}
        for _ in range(2):  # one re-ask on a malformed reply
            d = post_json(CHAT_URL, body, self.headers)
            try:
                out = json.loads(d["choices"][0]["message"]["content"])
            except (json.JSONDecodeError, KeyError, IndexError, TypeError):
                continue
            if isinstance(out, dict):
                return out
        raise ValueError(f"malformed parse reply for {path!r}")

    def choose(self, path, duration, parse, cands):
        state, questions = jev_request(path, duration, parse, cands)
        d = post_json(DECISIONS_URL, {"model": self.jev_model, "state": state,
                                      "questions": questions}, self.headers)
        return d["answers"]["match"]
