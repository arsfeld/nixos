import type { Status, Topic } from './types';

/** A status badge's text. */
export function statusText(s: Status): string {
  switch (s.kind) {
    case 'queued':
      return 'queued';
    case 'downloading':
      return `downloading ${s.percent}%`;
    case 'added':
      return 'added';
    case 'inStash':
      return 'in Stash';
    case 'identified':
      return s.label + (s.more > 0 ? ` +${s.more}` : '') + (s.guess ? ' (guess)' : '');
    case 'failed':
      return `failed: ${s.reason}`;
  }
}

export const STATUS_COLOR: Record<Status['kind'], string> = {
  queued: 'badge-warning',
  downloading: 'badge-info',
  added: 'badge-ghost',
  inStash: 'badge-neutral',
  identified: 'badge-success',
  failed: 'badge-error',
};

/** Whether plab has, or is getting, a card's scene: any of its releases queued or added,
 * or a download of it through another release. Nothing on the card is then addable, so
 * one scene is never downloaded twice. */
export function sceneTaken(t: Topic): boolean {
  return t.ownedBy != null || t.state !== '' || (t.also ?? []).some((a) => a.state !== '');
}
