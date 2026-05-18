# Falcons Pricing OS — Session Bootstrap Prompt

**Works on any laptop where this OneDrive folder is synced.** Copy-paste the block below as your first message in any new Cowork session.

Your GitHub PAT lives in `.gh-pat` in this same folder — OneDrive syncs it to every device you log into, so the bootstrap prompt finds it automatically without you pasting anything per session.

---

## ONE-TIME SETUP (do once per GitHub account)

1. **Generate a long-lived fine-grained PAT** at https://github.com/settings/personal-access-tokens
   - **Expiration:** "No expiration" or 1 year (your call)
   - **Repository access:** "Only select repositories" → `AbdalrahmanElGazzawi/falcons-pricing-web`
   - **Permissions:**
     - Contents: Read and write
     - Metadata: Read-only
     - Pull requests: Read and write
   - Hit Generate, copy the `ghp_...` token

2. **Save the PAT into this workspace folder:**
   - Open Notepad
   - Paste ONLY the token (no quotes, no newline, no labels)
   - Save as `C:\Users\ASUS\OneDrive\Desktop\falcons-pricing-web\.gh-pat`
   - OneDrive syncs it to all your devices automatically

3. **Make sure it's git-ignored** so it never accidentally ends up on GitHub. Check `.gitignore` includes:
   ```
   .gh-pat
   .env.local
   ```
   (Already done in your repo.)

That's it. Every laptop you log into that has this folder will have the PAT ready.

---

## THE BOOTSTRAP PROMPT — paste this as message #1 in any new Cowork session

```
I'm Koge (Commercial, Team Falcons). Working on the Pricing OS web app.

WORKSPACE
  C:\Users\ASUS\OneDrive\Desktop\falcons-pricing-web (selected in Cowork)

CONNECTED SERVICES — verify access first
  1. Supabase MCP  → project eectdiminjrthbqatwxv (eu-central-1).
     Confirm with: select count(*) from public.players where is_active.
  2. Vercel MCP    → team team_Qv9mvzrn08DIYqEQtuE2ug8B,
                     project falcons-pricing-web (id: prj_KAoVUXAaes93VA8XeJvc20FeGY9n).
     Confirm with: list_deployments returns recent deploys.
  3. GitHub PAT    → already stored in the workspace at .gh-pat. Read it via:
                       cat /sessions/<id>/mnt/falcons-pricing-web/.gh-pat
                     Stash it at outputs/.gh-pat for the session if you prefer.
                     Repo: AbdalrahmanElGazzawi/falcons-pricing-web. Branch: main.
                     The PAT is long-lived and fine-grained — do NOT revoke it,
                     do NOT ask me for a fresh one each session.

READ FIRST — DO NOT SKIP
  1. CLAUDE.md — full bootstrap doc (formula, tier baselines, hard rules).
  2. Falcons-Pricing-SOT-v1.0.md — methodology canon.
  3. supabase/migrations/ — `ls` the directory to find the LATEST file.
     CLAUDE.md does NOT pin a migration number — use the file list +
     supabase_migrations.schema_migrations table as source of truth.
  4. falcons-market-value-reference.xlsx — per-talent state snapshot.

VERIFY ACTUAL STATE — run all of these:
  • Latest migration file:     ls supabase/migrations/ | tail -3
  • Latest applied migration:  Supabase MCP →
      select version, name from supabase_migrations.schema_migrations
      order by version desc limit 1;
  • Latest commit on main:     clone fresh, then git log --oneline -3
  • Vercel deploy status:      list_deployments → state + age of newest
  • Live tier counts:          Supabase MCP →
      select tier_code, count(*) from public.players where is_active
      group by tier_code order by tier_code;
  • Rate-source distribution:  Supabase MCP →
      select rate_source, count(*) from public.players where is_active
      group by rate_source order by 2 desc;

Trust the live state, not the docs, when they conflict.

DEPLOY FLOW (mandatory)
  1. Never push from the OneDrive workspace folder — it drifts.
  2. Clone fresh into /tmp/deploy/repo using the stashed PAT.
  3. Edit in the clone (use OneDrive workspace as REFERENCE only).
  4. git diff and SHOW ME before committing.
  5. After approval: commit, push to main. Vercel auto-deploys (~2 min).

HARD RULES
  • Saudi peg is 3.75 SAR/USD. Locked. No editable FX field anywhere.
  • Never commit secrets to the repo (.gh-pat, .env.local stay local).
  • Never push to main without showing me the diff first.
  • Never apply a Supabase migration without showing me the SQL first.
  • Never overwrite the SOT or audit memos without explicit instruction.
  • If unsure — ask, don't guess.

GIVE ME A 4-LINE STATE SUMMARY BEFORE STARTING ANY WORK
  - Latest migration applied (name + version)
  - Latest commit hash + first line of message
  - Latest Vercel deploy state + age
  - Anything in CLAUDE.md that looks stale

NOW WHAT I WANT YOU TO DO:

  <DESCRIBE THE TASK HERE>
```

---

## Common opening tasks — paste into the last line of the prompt

- `Audit the live roster — flag any UNVERIFIED rate_source rows and any tier mismatches between system tier_code and follower-driven tier.`
- `Show me the latest 10 quotes with their final totals and approval status.`
- `Walk me through how a quote line is priced today, end-to-end, using NiKo CS2 IG Reel as the example. Show the actual math from base rate through final SAR.`
- `Plan and scaffold the activations catalogue: bundles + sub_activations tables + /admin/activations editor + public /activations page reading from DB. Show me the migration SQL diff first.`
- `Migration <N>: <DESCRIPTION>. Show me the SQL diff before applying.`
- `Redesign the quote builder UI per quote-builder-mockup.html — port to Next.js, diff first, push only on my approval.`
- `Build /activations page in production based on bundles-v3-five-models-mockup.html. Phased: schema first, admin editor second, public page third.`
- `Add a tier-recalibration cron job that runs every Monday and flags talents whose follower count moved them into a new tier band.`
- `Add a 'pending changes' admin view that surfaces all rate updates from the last 7 days with old vs new values.`

---

## On another laptop?

1. Log into OneDrive on the new machine. Wait for `falcons-pricing-web` to sync (you'll see `.gh-pat` appear).
2. Open Cowork. Select the `falcons-pricing-web` folder.
3. Paste the prompt block above.
4. Done. The session reads the PAT from the synced folder.

---

## Security tradeoff — what you're accepting

You're storing a long-lived PAT in a file inside an OneDrive folder. The risk surface:

- **OneDrive cloud sync** — if your Microsoft account is compromised, the attacker can read `.gh-pat` from your synced folders.
- **Any device the OneDrive folder reaches** — if you lose / sell / leave a laptop with that folder synced, the PAT is on it.
- **If you ever publicly share or screenshot the folder contents** — the PAT leaks.

The mitigations baked in:
- **Fine-grained, repo-scoped** — even if leaked, the attacker can only read/write THIS repo. They can't touch other repos, can't access your GitHub settings, can't impersonate you elsewhere.
- **`.gitignore`** — the file can't accidentally get pushed to GitHub.
- **2FA on GitHub** — required to generate a new PAT or change account settings, so a stolen PAT can't escalate.

If you ever suspect compromise: go to https://github.com/settings/personal-access-tokens and revoke the token. Generate a new one. Replace `.gh-pat` content. Done in 60 seconds.

---

## Where this file lives

- Local: `C:\Users\ASUS\OneDrive\Desktop\falcons-pricing-web\BOOTSTRAP_PROMPT.md`
- GitHub: https://github.com/AbdalrahmanElGazzawi/falcons-pricing-web/blob/main/BOOTSTRAP_PROMPT.md

If you ever lose the local file, pull it from GitHub. If you ever change the bootstrap process, edit this file in the workspace and push — every laptop gets the update next time it pulls.
