"""Thin Stash GraphQL client for stash-identify."""
import time

from net import post_json

SCENE_FIELDS = """id title code details director date urls studio { id } performers { id }
  tags { id } stash_ids { endpoint stash_id } files { path duration }"""

SCRAPED_FIELDS = """title code details director urls date image duration remote_site_id
  studio { name urls image details aliases remote_site_id parent { name remote_site_id } }
  performers { name disambiguation gender urls birthdate death_date ethnicity country
    eye_color hair_color height weight measurements fake_tits penis_length circumcised
    career_start career_end tattoos piercings aliases details images remote_site_id }
  tags { name stored_id }"""

_IDENTIFY_OPTIONS = """fieldOptions { field strategy createMissing } setCoverImage setOrganized
  includeMalePerformers performerGenders skipMultipleMatches skipMultipleMatchTag
  skipSingleNamePerformers skipSingleNamePerformerTag"""

# Saved task defaults from the Stash UI. The output shapes match the job input types
# field for field, so they pass straight through once nulls are stripped.
DEFAULTS_QUERY = """{ configuration { defaults {
  scan { rescan scanGenerateCovers scanGeneratePreviews scanGenerateImagePreviews
    scanGenerateSprites scanGeneratePhashes scanGenerateImagePhashes scanGenerateThumbnails
    scanGenerateClipPreviews }
  generate { covers sprites previews imagePreviews markers markerImagePreviews
    markerScreenshots transcodes phashes interactiveHeatmapsSpeeds imageThumbnails clipPreviews
    previewOptions { previewSegments previewSegmentDuration previewExcludeStart
      previewExcludeEnd previewPreset } }
  identify { sources { source { scraper_id stash_box_index stash_box_endpoint }
      options { %s } }
    options { %s } } } } }""" % (_IDENTIFY_OPTIONS, _IDENTIFY_OPTIONS)

JOB_INPUT_TYPES = {"metadataScan": "ScanMetadataInput",
                   "metadataGenerate": "GenerateMetadataInput",
                   "metadataIdentify": "IdentifyMetadataInput"}
JOB_TIMEOUT = 6 * 3600
JOB_POLL = 5


class JobFailed(RuntimeError):
    pass


def strip_nulls(v):
    if isinstance(v, dict):
        return {k: strip_nulls(x) for k, x in v.items() if x is not None}
    if isinstance(v, list):
        return [strip_nulls(x) for x in v]
    return v


class Stash:
    def __init__(self, url, api_key=None):
        self.url = url
        self.headers = {"ApiKey": api_key} if api_key else {}

    def gql(self, query, **variables):
        d = post_json(self.url, {"query": query, "variables": variables}, self.headers)
        if d.get("errors"):
            raise RuntimeError(d["errors"])
        return d["data"]

    # --- configuration -------------------------------------------------------

    def defaults(self):
        return strip_nulls(self.gql(DEFAULTS_QUERY)["configuration"]["defaults"])

    def video_extensions(self):
        q = "{ configuration { general { videoExtensions } } }"
        return self.gql(q)["configuration"]["general"]["videoExtensions"]

    # --- jobs ----------------------------------------------------------------

    def _run_job(self, mutation, inp):
        job = self.gql(f"mutation($i: {JOB_INPUT_TYPES[mutation]}!) {{ {mutation}(input: $i) }}",
                       i=inp)[mutation]
        deadline = time.monotonic() + JOB_TIMEOUT
        while time.monotonic() < deadline:
            j = self.gql("query($id: ID!) { findJob(input: {id: $id}) { status error } }",
                         id=job)["findJob"]
            # Finished jobs are pruned from the queue after a grace period.
            if j is None or j["status"] == "FINISHED":
                return
            if j["status"] in ("FAILED", "CANCELLED"):
                raise JobFailed(f"{mutation} job {job}: {j['status']} {j.get('error') or ''}")
            time.sleep(JOB_POLL)
        raise JobFailed(f"{mutation} job {job}: timed out after {JOB_TIMEOUT}s")

    def scan(self, paths, options):
        self._run_job("metadataScan", {**options, **({"paths": paths} if paths else {})})

    def generate(self, scene_ids, options):
        inp = {**options, "overwrite": False}
        if scene_ids is not None:
            inp["sceneIDs"] = scene_ids
        self._run_job("metadataGenerate", inp)

    def identify(self, scene_ids, options):
        self._run_job("metadataIdentify", {**options, "sceneIDs": scene_ids})

    # --- scenes --------------------------------------------------------------

    def max_scene_id(self):
        d = self.gql('{ findScenes(filter: {sort: "id", direction: DESC, per_page: 1}) '
                     '{ scenes { id } } }')["findScenes"]["scenes"]
        return int(d[0]["id"]) if d else 0

    def scene_ids_after(self, scene_id):
        d = self.gql("""query($v: Int!) { findScenes(
              scene_filter: {id: {value: $v, modifier: GREATER_THAN}}, filter: {per_page: -1})
              { scenes { id } } }""", v=scene_id)
        return [s["id"] for s in d["findScenes"]["scenes"]]

    def scenes(self, ids):
        d = self.gql(f"query($ids: [ID!]) {{ findScenes(ids: $ids, filter: {{per_page: -1}}) "
                     f"{{ scenes {{ {SCENE_FIELDS} }} }} }}", ids=ids)
        return d["findScenes"]["scenes"]

    def bare_scenes(self):
        d = self.gql(f'{{ findScenes(scene_filter: {{is_missing: "title"}}, filter: {{per_page: -1}}) '
                     f'{{ scenes {{ {SCENE_FIELDS} }} }} }}')
        return [s for s in d["findScenes"]["scenes"] if not s["studio"] and not s["performers"]]

    def search(self, endpoint, query):
        d = self.gql(f"""query($s: ScraperSourceInput!, $i: ScrapeSingleSceneInput!) {{
              scrapeSingleScene(source: $s, input: $i) {{ {SCRAPED_FIELDS} }} }}""",
                     s={"stash_box_endpoint": endpoint}, i={"query": query})
        return d["scrapeSingleScene"]

    # --- lookups and creates ---------------------------------------------------

    def _by_stash_id(self, kind, endpoint, stash_id):
        d = self.gql(f"""query($e: String!, $s: String!) {{ find{kind}s(
              {kind.lower()}_filter: {{stash_id_endpoint: {{endpoint: $e, stash_id: $s, modifier: EQUALS}}}})
              {{ {kind.lower()}s {{ id }} }} }}""", e=endpoint, s=stash_id)
        hits = d[f"find{kind}s"][f"{kind.lower()}s"]
        return hits[0]["id"] if hits else None

    def performer_by_stash_id(self, endpoint, stash_id):
        return self._by_stash_id("Performer", endpoint, stash_id)

    def studio_by_stash_id(self, endpoint, stash_id):
        return self._by_stash_id("Studio", endpoint, stash_id)

    def performers_like(self, name):
        d = self.gql("""query($q: String!) { findPerformers(filter: {q: $q, per_page: 50})
              { performers { id name alias_list } } }""", q=name)
        return d["findPerformers"]["performers"]

    def studios_like(self, name):
        d = self.gql("""query($q: String!) { findStudios(filter: {q: $q, per_page: 50})
              { studios { id name aliases } } }""", q=name)
        return d["findStudios"]["studios"]

    def tag_id(self, name, create=False):
        d = self.gql("""query($q: String!) { findTags(filter: {q: $q, per_page: 50})
              { tags { id name } } }""", q=name)
        for t in d["findTags"]["tags"]:
            if t["name"] == name:
                return t["id"]
        if not create:
            return None
        return self.gql("mutation($i: TagCreateInput!) { tagCreate(input: $i) { id } }",
                        i={"name": name})["tagCreate"]["id"]

    def create_performer(self, inp):
        return self.gql("mutation($i: PerformerCreateInput!) { performerCreate(input: $i) { id } }",
                        i=inp)["performerCreate"]["id"]

    def create_studio(self, inp):
        return self.gql("mutation($i: StudioCreateInput!) { studioCreate(input: $i) { id } }",
                        i=inp)["studioCreate"]["id"]

    def update_scene(self, inp):
        self.gql("mutation($i: SceneUpdateInput!) { sceneUpdate(input: $i) { id } }", i=inp)
