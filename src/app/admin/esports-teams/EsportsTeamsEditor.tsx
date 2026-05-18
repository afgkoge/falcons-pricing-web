'use client';
import { useState } from 'react';
import { Save, Instagram, Twitter, Youtube, Twitch, ExternalLink, Facebook } from 'lucide-react';
import type { EsportsTeam } from '@/lib/types';

function fmtFollow(n: number | null | undefined) {
  const v = Number(n || 0);
  if (v >= 1_000_000) return (v / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M';
  if (v >= 1_000)     return (v / 1_000).toFixed(1).replace(/\.0$/, '') + 'K';
  return v.toLocaleString('en-US');
}

// ─── handleOf: tolerate dirty data (full URLs, stray @, /videos tails)
// Returns the bare handle no matter what got pasted into the DB.
function handleOf(raw: string | null | undefined, kind: 'ig' | 'x' | 'tiktok' | 'yt' | 'twitch' | 'kick' | 'fb'): string | null {
  if (!raw) return null;
  let s = String(raw).trim().split('?')[0];
  const patterns: Record<string, RegExp> = {
    ig:    /^https?:\/\/(www\.)?instagram\.com\//i,
    x:     /^https?:\/\/(www\.)?(twitter|x)\.com\/@?/i,
    tiktok:/^https?:\/\/(www\.)?(vm\.|m\.)?tiktok\.com\/@?/i,
    yt:    /^https?:\/\/(www\.|m\.)?youtube\.com\/(@|c\/|channel\/|user\/)?/i,
    twitch:/^https?:\/\/(www\.)?twitch\.tv\//i,
    kick:  /^https?:\/\/(www\.)?kick\.com\//i,
    fb:    /^https?:\/\/(www\.|m\.)?facebook\.com\//i,
  };
  s = s.replace(patterns[kind], '');
  s = s.replace(/^@/, '').replace(/\/$/, '').replace(/\/videos$/, '');
  return s || null;
}

function urlFor(kind: 'ig' | 'x' | 'tiktok' | 'yt' | 'twitch' | 'kick' | 'fb', h: string | null): string | null {
  if (!h) return null;
  switch (kind) {
    case 'ig':     return `https://instagram.com/${h}`;
    case 'x':      return `https://x.com/${h}`;
    case 'tiktok': return `https://tiktok.com/@${h}`;
    case 'yt':     return `https://youtube.com/@${h}`;
    case 'twitch': return `https://twitch.tv/${h}`;
    case 'kick':   return `https://kick.com/${h}`;
    case 'fb':     return `https://facebook.com/${h}`;
  }
}

export function EsportsTeamsEditor({ initial }: { initial: EsportsTeam[] }) {
  const [rows, setRows] = useState(initial);
  const [editing, setEditing] = useState<number | null>(null);
  const [draft, setDraft] = useState<Partial<EsportsTeam>>({});
  const [saving, setSaving] = useState(false);
  // Hide inactive / unpopulated team rows by default — the legacy game roster
  // auto-imported 22 placeholder rows that we don't operate channels for.
  const [showInactive, setShowInactive] = useState(false);
  const inactiveCount = rows.filter(r => !r.is_active).length;
  const visibleRows = showInactive ? rows : rows.filter(r => r.is_active);

  function start(t: EsportsTeam) {
    setEditing(t.id); setDraft({ ...t });
  }
  function update<K extends keyof EsportsTeam>(k: K, v: any) {
    setDraft(s => ({ ...s, [k]: v }));
  }
  async function save() {
    if (!editing) return;
    setSaving(true);
    const res = await fetch(`/api/admin/esports-teams/${editing}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(draft),
    });
    setSaving(false);
    if (!res.ok) { alert('Save failed'); return; }
    const data = await res.json();
    setRows(prev => prev.map(r => r.id === data.id ? data : r));
    setEditing(null); setDraft({});
  }

  const totalFollowers = rows.reduce((s, r) =>
    s + Number(r.followers_ig||0) + Number(r.followers_x||0) + Number(r.followers_tiktok||0) +
        Number(r.subscribers_yt||0) + Number(r.followers_twitch||0) + Number((r as any).followers_fb||0), 0);

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <Kpi label="Active brand accounts" value={rows.filter(r => r.is_active).length.toString()} />
        <Kpi label="Channels populated" value={rows.filter(r => r.is_active && (r.handle_ig || r.handle_x || r.handle_tiktok || r.handle_yt || r.handle_twitch || (r as any).handle_fb)).length.toString()} />
        <Kpi label="Total reach" value={fmtFollow(totalFollowers)} accent />
        <Kpi label="Inactive / legacy" value={inactiveCount.toString()} />
      </div>

      {/* Show-inactive toggle */}
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div className="text-xs text-mute">
          {visibleRows.length} of {rows.length} teams shown — {showInactive
            ? <>inactive included.</>
            : <>{inactiveCount} inactive/legacy rows hidden.</>}
        </div>
        <button
          type="button"
          onClick={() => setShowInactive(v => !v)}
          className="btn btn-ghost text-xs"
        >
          {showInactive ? `Hide inactive (${inactiveCount})` : `Show inactive (${inactiveCount})`}
        </button>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
        {visibleRows.map(t => {
          const isEdit = editing === t.id;
          const cur = isEdit ? { ...t, ...draft } as EsportsTeam : t;
          const reach = Number(cur.followers_ig||0) + Number(cur.followers_x||0) + Number(cur.followers_tiktok||0) +
                        Number(cur.subscribers_yt||0) + Number(cur.followers_twitch||0);
          const channelCount = [cur.handle_ig, cur.handle_x, cur.handle_tiktok, cur.handle_yt, cur.handle_twitch, (cur as any).handle_fb].filter(Boolean).length;

          return (
            <div key={t.id} className={['card overflow-hidden', isEdit ? 'ring-2 ring-green' : ''].join(' ')}>
              <div className="p-4 border-b border-line bg-gradient-to-br from-navy/5 to-transparent">
                <div className="flex items-start gap-3">
                  <div className="w-12 h-12 rounded-lg bg-navy text-white grid place-items-center font-bold text-sm flex-shrink-0">
                    {t.game.split(' ').map(s => s[0]).slice(0, 2).join('').toUpperCase()}
                  </div>
                  <div className="min-w-0 flex-1">
                    {isEdit ? (
                      <input value={cur.team_name} onChange={e => update('team_name', e.target.value)}
                        className="input !py-1 text-sm font-semibold mb-1" />
                    ) : (
                      <div className="font-semibold text-ink truncate">{cur.team_name}</div>
                    )}
                    <div className="text-xs text-mute truncate">{t.game}</div>
                  </div>
                </div>
                <div className="flex items-center justify-between mt-3 text-xs">
                  <span className="text-label">{channelCount}/6 channels</span>
                  <span className="font-semibold text-greenDark tabular-nums">{fmtFollow(reach)} reach</span>
                </div>
              </div>

              <div className="p-3 space-y-2 text-xs">
                <SocialRow icon={Instagram} label="Instagram" prefix="@"
                  handle={cur.handle_ig} followers={cur.followers_ig}
                  onHandle={isEdit ? v => update('handle_ig', v) : null}
                  onFollowers={isEdit ? v => update('followers_ig', v) : null}
                  url={urlFor('ig', handleOf(cur.handle_ig, 'ig'))} cleanHandle={handleOf(cur.handle_ig, 'ig')}
                />
                <SocialRow icon={Twitter} label="X / Twitter" prefix="@"
                  handle={cur.handle_x} followers={cur.followers_x}
                  onHandle={isEdit ? v => update('handle_x', v) : null}
                  onFollowers={isEdit ? v => update('followers_x', v) : null}
                  url={urlFor('x', handleOf(cur.handle_x, 'x'))} cleanHandle={handleOf(cur.handle_x, 'x')}
                />
                <SocialRow icon={() => <span className="text-xs font-bold">TT</span>} label="TikTok" prefix="@"
                  handle={cur.handle_tiktok} followers={cur.followers_tiktok}
                  onHandle={isEdit ? v => update('handle_tiktok', v) : null}
                  onFollowers={isEdit ? v => update('followers_tiktok', v) : null}
                  url={urlFor('tiktok', handleOf(cur.handle_tiktok, 'tiktok'))} cleanHandle={handleOf(cur.handle_tiktok, 'tiktok')}
                />
                <SocialRow icon={Youtube} label="YouTube" prefix="@"
                  handle={cur.handle_yt} followers={cur.subscribers_yt}
                  onHandle={isEdit ? v => update('handle_yt', v) : null}
                  onFollowers={isEdit ? v => update('subscribers_yt', v) : null}
                  url={urlFor('yt', handleOf(cur.handle_yt, 'yt'))} cleanHandle={handleOf(cur.handle_yt, 'yt')}
                />
                <SocialRow icon={Twitch} label="Twitch" prefix=""
                  handle={cur.handle_twitch} followers={cur.followers_twitch}
                  onHandle={isEdit ? v => update('handle_twitch', v) : null}
                  onFollowers={isEdit ? v => update('followers_twitch', v) : null}
                  url={urlFor('twitch', handleOf(cur.handle_twitch, 'twitch'))} cleanHandle={handleOf(cur.handle_twitch, 'twitch')}
                />
                <SocialRow icon={Facebook} label="Facebook" prefix=""
                  handle={(cur as any).handle_fb} followers={(cur as any).followers_fb}
                  onHandle={isEdit ? v => update('handle_fb' as any, v) : null}
                  onFollowers={isEdit ? v => update('followers_fb' as any, v) : null}
                  url={urlFor('fb', handleOf((cur as any).handle_fb, 'fb'))} cleanHandle={handleOf((cur as any).handle_fb, 'fb')}
                />
              </div>

              <div className="px-3 py-2 border-t border-line bg-bg flex items-center justify-end gap-2">
                {isEdit ? (
                  <>
                    <button onClick={() => { setEditing(null); setDraft({}); }} className="btn btn-ghost !py-1 !px-2 text-xs">Cancel</button>
                    <button onClick={save} disabled={saving} className="btn btn-primary !py-1 !px-2 text-xs">
                      <Save size={11} /> {saving ? 'Saving…' : 'Save'}
                    </button>
                  </>
                ) : (
                  <button onClick={() => start(t)} className="btn btn-ghost !py-1 !px-2 text-xs">Edit channels</button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function Kpi({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="card card-p">
      <div className="text-[10px] uppercase tracking-wider text-label font-semibold mb-1">{label}</div>
      <div className={`text-xl font-bold tabular-nums ${accent ? 'text-greenDark' : 'text-ink'}`}>{value}</div>
    </div>
  );
}

function SocialRow({
  icon: Icon, label, prefix, handle, followers, onHandle, onFollowers, url, cleanHandle,
}: {
  icon: any; label: string; prefix: string;
  handle: string | null; followers: number;
  onHandle: ((v: string) => void) | null;
  onFollowers: ((v: number) => void) | null;
  url: string | null;
  cleanHandle?: string | null;
}) {
  const editing = !!onHandle;
  return (
    <div className="flex items-center gap-2">
      <div className="w-6 h-6 rounded grid place-items-center text-label flex-shrink-0">
        <Icon size={14} />
      </div>
      <div className="flex-1 min-w-0">
        {editing ? (
          <input
            value={handle ?? ''}
            onChange={e => onHandle!(e.target.value)}
            placeholder={`${prefix}handle`}
            className="input !py-0.5 !px-1.5 text-xs w-full"
          />
        ) : cleanHandle ? (
          <a href={url ?? '#'} target="_blank" rel="noreferrer" className="text-ink hover:text-greenDark truncate flex items-center gap-1">
            {prefix}{cleanHandle}<ExternalLink size={10} />
          </a>
        ) : (
          <span className="text-mute italic">{label} —</span>
        )}
      </div>
      {editing ? (
        <input
          type="number"
          value={followers ?? 0}
          onChange={e => onFollowers!(Number(e.target.value))}
          className="input !py-0.5 !px-1.5 text-xs w-20 text-right"
        />
      ) : (
        <span className="text-mute tabular-nums whitespace-nowrap">{followers ? fmtFollow(followers) : '—'}</span>
      )}
    </div>
  );
}
