// The server's JSON, as packages/plab/src/api.rs and events.rs shape it (their tests pin
// these shapes). The jobs entry keeps the jobs spec's snake_case keys.

export type Section = 'video' | 'games';
export type TopicState = '' | 'queued' | 'added';

export type Status =
  | { kind: 'queued' }
  | { kind: 'downloading'; percent: number }
  | { kind: 'added' }
  | { kind: 'inStash'; link: string | null }
  | { kind: 'identified'; label: string; more: number; guess: boolean; link: string | null }
  | { kind: 'failed'; reason: 'download' | 'identify' | 'lost'; detail: string };

export interface Topic {
  id: number;
  title: string;
  name: string;
  studio: string | null;
  quality: string | null;
  category: string;
  production: 'amateur' | 'artistic' | 'industrial' | null;
  tags: string[];
  filters: string[];
  size: number;
  seeders: number;
  leechers: number;
  added: number;
  /** null: a live search result, whose images come through /api/thumb. */
  images: string[] | null;
  state: TopicState;
  status: Status | null;
  /** The indexer of a release from another indexer; null for the tracker's own. */
  source: string | null;
  /** That release's page; null for the tracker's own. */
  link: string | null;
}

export interface List {
  now: number;
  section: Section;
  updated: number;
  topicUrl: string;
  curatedFilters: string[];
  pending: number;
  topics: Topic[];
  /** Search replies only. */
  query?: string;
  error?: string | null;
}

export interface Grab {
  studio: string | null;
  title: string;
  addedAt: number | null;
  status: Status;
}

export interface Line {
  at: number;
  level: string;
  msg: string;
}

export interface JobRun {
  started: number;
  finished: number | null;
  ok: boolean | null;
  error: string | null;
}

export interface Job {
  name: string;
  state: 'idle' | 'running' | 'watching' | 'restarting';
  since: number | null;
  pending: number | null;
  restart_at: number | null;
  next: number | null;
  step: Line | null;
  progress: [number, number] | null;
  lines: Line[];
  runs: JobRun[];
}

export interface AddReply {
  ok: boolean;
  queued?: boolean;
  name?: string;
  message?: string;
  error?: string;
}

export type ServerEvent =
  | { type: 'topicState'; id: number; state: TopicState }
  | { type: 'topicStatus'; id: number; status: Status | null }
  | ({ type: 'job' } & Job)
  | { type: 'listing'; section: Section }
  | { type: 'resync' };

export interface StreamFile {
  index: number;
  name: string;
  length: number;
}

export interface Stats {
  progress: number;
  total: number;
  finished: boolean;
  mbps: number;
  peers: number;
  state: string;
  error?: string | null;
}
