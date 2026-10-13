"""Tags, quality, studio and category read from a release title. Pure."""
import re

from forums import category

_GROUP = re.compile(r"\[([^\[\]]*)\]")
_DATE = re.compile(r"\d{4}(\s*г\.?)?|\d{1,2}[./-]\d{1,2}[./-]\d{4}|\d{4}[./-]\d{1,2}[./-]\d{1,2}")
_RES = re.compile(r"\d{3,4}p")
_UHD = ("4k", "uhd")


def _quality(token):
    if _RES.fullmatch(token):
        return token
    return "2160p" if token in _UHD else None


def labels(title, forum):
    tags, quality = [], None
    title = title.lstrip()
    # The leading bracket is the studio, not a tag list, even if it holds a comma.
    commas = [m.group(1) for m in _GROUP.finditer(title) if "," in m.group(1) and m.start() != 0]
    for raw in commas[-1].split(",") if commas else ():
        token = raw.strip().lower()
        if not token or _DATE.fullmatch(token):
            continue
        q = _quality(token)
        if q:
            quality = quality or q
        elif token not in tags:
            tags.append(token)
    studio = None
    if title.startswith("["):
        m = _GROUP.match(title)
        first = m and m.group(1).split(" / ")[0].strip()
        studio = first if first and "." in first else None
    return {"tags": tags, "quality": quality, "studio": studio, "category": category(forum)}


CURATED_STUDIOS = {
    "lustery": "Lustery",
    "joybear": "Joybear",
    "erika lust": "Erika Lust",
    "erikalust": "Erika Lust",
    "xconfessions": "XConfessions",
    "lust cinema": "Lust Cinema",
    "lustcinema": "Lust Cinema",
    "frolicme": "FrolicMe",
    "sssh": "Sssh",
    "x-art": "X-Art",
    "xart": "X-Art",
    "colette": "Colette",
    "viv thomas": "Viv Thomas",
    "vivthomas": "Viv Thomas",
    "bellesa": "Bellesa",
    "metart": "MetArt",
}

CURATED_KEYWORDS = {
    "real couple": "Real Couple",
    "amateur couple": "Amateur Couple",
    "romantic": "Romantic",
    "sensual": "Sensual",
    "homemade couple": "Homemade Couple",
}

CURATED_STUDIO_PREFIXES = tuple(CURATED_STUDIOS.keys())


def curated_reason(title, studio=None, tags=None):
    """The matched reason/term (e.g. 'Lustery', 'Real Couple') if curated, else None."""
    if studio:
        s = studio.lower()
        for prefix, name in CURATED_STUDIOS.items():
            if prefix in s:
                return name
    if tags:
        for t in tags:
            tl = t.lower()
            for k, name in CURATED_KEYWORDS.items():
                if k in tl:
                    return name
    tl = title.lower()
    for prefix, name in CURATED_STUDIOS.items():
        if prefix in tl:
            return name
    for k, name in CURATED_KEYWORDS.items():
        if k in tl:
            return name
    return None


def is_curated(title, studio=None, tags=None):
    """True if release matches indie/romantic couples studios, tags or title keywords."""
    return curated_reason(title, studio, tags) is not None



