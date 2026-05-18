-- ============================================================================
-- Migration 092 — market_bands: org dimension + dedup + comp set seed
-- ============================================================================
-- Authored: 2026-05-18  ·  Engine version: NO BUMP (pure data + schema)
--
-- Fixes audit CRITICAL #4 (18 duplicate keys → pickBand non-deterministic
-- by up to 10-15% on KSA/MENA tier bands).
-- Adds CRITICAL #5 prep: org dimension so comp set (FaZe / Cloud9 / T1 /
-- NRG / 100T) lives in market_bands instead of SOT.md only.
--
-- DEDUP RULE (highest priority wins, others soft-deleted via effective_to):
--   1. source='manual_override'             (explicit commercial call)
--   2. source='methodology_v2_baseline'     (SOT-derived)
--   3. source='modeled_regional_v1_2026'    (modeled fallback)
--
-- Effective_to is set rather than deleting — preserves history for audit.
-- ============================================================================

BEGIN;

-- ─── 1. Add org column ────────────────────────────────────────────────────
ALTER TABLE public.market_bands
  ADD COLUMN IF NOT EXISTS org text NOT NULL DEFAULT 'industry_generic'
  CHECK (org IN ('industry_generic','falcons_internal','FaZe','Cloud9','T1','NRG','100T','Karmine','NaVi','Fnatic','Vitality','G2','EG','TSM'));
CREATE INDEX IF NOT EXISTS idx_mb_org ON public.market_bands (org) WHERE effective_to IS NULL;
COMMENT ON COLUMN public.market_bands.org IS 'Reference org for this band. industry_generic = aggregated across orgs (SOT Section 13 mid). Per-org rows enable comp-set comparisons in QuoteBuilder + F/A/S/C panel.';

-- ─── 2. Dedup — soft-delete losers via effective_to ───────────────────────
-- Identifies rows that share (tier_code, platform, audience_market, archetype, org)
-- and aren't the highest-priority source. Sets effective_to=current_date on losers.
WITH ranked AS (
  SELECT id, tier_code, platform, audience_market, archetype, org, source,
         ROW_NUMBER() OVER (
           PARTITION BY tier_code, platform, audience_market, archetype, org
           ORDER BY CASE source
                      WHEN 'manual_override'           THEN 1
                      WHEN 'methodology_v2_baseline'   THEN 2
                      WHEN 'modeled_regional_v1_2026'  THEN 3
                      ELSE 4
                    END,
                    effective_from DESC
         ) AS rk
  FROM public.market_bands
  WHERE effective_to IS NULL
),
losers AS (
  SELECT id FROM ranked WHERE rk > 1
)
UPDATE public.market_bands mb
  SET effective_to = current_date,
      notes        = COALESCE(notes,'') || ' [superseded by Mig 092 dedup ' || current_date::text || ']'
  FROM losers
 WHERE mb.id = losers.id;

-- ─── 3. Add unique constraint (only for live rows) ────────────────────────
-- Partial unique index so live (effective_to IS NULL) rows are unique
-- per (tier × platform × market × archetype × org), and historical rows
-- can keep their multiplicity.
CREATE UNIQUE INDEX IF NOT EXISTS uq_mb_live_key
  ON public.market_bands (tier_code, platform, audience_market, COALESCE(archetype,''), org)
  WHERE effective_to IS NULL;

-- ─── 4. Seed Falcons internal floor as own org ────────────────────────────
-- This makes our own internal SOT-canonical baselines explicit as a comp-set
-- reference (alongside FaZe / Cloud9 etc.). The Tier S = 28K / Tier 1 = 18K /
-- Tier 2 = 11K / Tier 3 = 6.5K / Tier 4 = 3.5K SOT canon, scaled per region.
-- Only IG Reel + IRL seeded here as anchor surfaces — other platforms derive
-- from ratios in src/lib/pricing.ts:CHANNEL_RATIOS via the F/A/S/C panel.
INSERT INTO public.market_bands (tier_code, audience_market, platform, org, min_sar, median_sar, max_sar, source, source_notes, effective_from)
VALUES
  -- Falcons internal SOT-canonical (KSA-anchored, scales down for other markets)
  ('Tier S', 'KSA',    'rate_ig_reel', 'falcons_internal',  22400, 28000, 35000, 'methodology_v2_baseline', 'SOT v1.0 Tier S IG Reel baseline · KSA anchor', '2026-05-18'),
  ('Tier 1', 'KSA',    'rate_ig_reel', 'falcons_internal',  14400, 18000, 22500, 'methodology_v2_baseline', 'SOT v1.0 Tier 1 IG Reel baseline · KSA anchor', '2026-05-18'),
  ('Tier 2', 'KSA',    'rate_ig_reel', 'falcons_internal',   8800, 11000, 13750, 'methodology_v2_baseline', 'SOT v1.0 Tier 2 IG Reel baseline · KSA anchor', '2026-05-18'),
  ('Tier 3', 'KSA',    'rate_ig_reel', 'falcons_internal',   5200,  6500,  8125, 'methodology_v2_baseline', 'SOT v1.0 Tier 3 IG Reel baseline · KSA anchor', '2026-05-18'),
  ('Tier 4', 'KSA',    'rate_ig_reel', 'falcons_internal',   2800,  3500,  4375, 'methodology_v2_baseline', 'SOT v1.0 Tier 4 IG Reel baseline · KSA anchor', '2026-05-18')
ON CONFLICT DO NOTHING;

-- ─── 5. Seed comp set (FaZe / Cloud9 / T1 / NRG / 100T) per SOT §13 ───────
-- USD ranges from SOT §13 Tier 1 IG Reel table, converted at 3.75 SAR/USD.
-- Tier 2 ranges also from SOT §13. NA-anchored (where orgs are HQ'd) +
-- GLOBAL row for T1 (Korean/global org). All as 'reach_calibrated' source
-- so the F/A/S/C panel knows this is benchmark data, not internal pricing.
INSERT INTO public.market_bands (tier_code, audience_market, platform, org, min_sar, median_sar, max_sar, source, source_notes, source_url, effective_from)
VALUES
  -- Tier 1 IG Reel (Tier 1 = 500K-5M followers)
  ('Tier 1', 'NA',     'rate_ig_reel', 'FaZe',       45000,  78750, 112500, 'reach_calibrated', 'SOT §13 · FaZe Tier 1 IG Reel $12K-$30K USD @ 3.75', 'https://newzoo.com/reports/2025-global-esports', '2026-05-18'),
  ('Tier 1', 'NA',     'rate_ig_reel', 'Cloud9',     30000,  52500,  75000, 'reach_calibrated', 'SOT §13 · Cloud9 Tier 1 IG Reel $8K-$20K USD @ 3.75',  'https://nielsen.com/esports',                   '2026-05-18'),
  ('Tier 1', 'NA',     'rate_ig_reel', '100T',       37500,  65625,  93750, 'reach_calibrated', 'SOT §13 · 100T Tier 1 IG Reel $10K-$25K USD @ 3.75',  'https://porterwills.com',                       '2026-05-18'),
  ('Tier 1', 'NA',     'rate_ig_reel', 'NRG',        22500,  39375,  56250, 'reach_calibrated', 'SOT §13 · NRG Tier 1 IG Reel $6K-$15K USD @ 3.75',   'https://porterwills.com',                       '2026-05-18'),
  ('Tier 1', 'GLOBAL', 'rate_ig_reel', 'T1',         56250, 121875, 187500, 'reach_calibrated', 'SOT §13 · T1 Tier 1 IG Reel $15K-$50K USD @ 3.75',   'https://newzoo.com/reports/2025-global-esports','2026-05-18'),
  ('Tier 1', 'EU',     'rate_ig_reel', 'Karmine',    20062,  37617,  56250, 'reach_calibrated', 'SOT §13 · Karmine Tier 1 IG Reel €5K-€15K @ 3.95',   NULL,                                            '2026-05-18'),
  -- Tier 2 IG Reel (Tier 2 = 100K-500K followers)
  ('Tier 2', 'NA',     'rate_ig_reel', 'FaZe',        9375,  15937,  22500, 'reach_calibrated', 'SOT §13 · FaZe Tier 2 IG Reel $2.5K-$6K USD @ 3.75',   NULL, '2026-05-18'),
  ('Tier 2', 'NA',     'rate_ig_reel', 'Cloud9',      7500,  13125,  18750, 'reach_calibrated', 'SOT §13 · Cloud9 Tier 2 IG Reel $2K-$5K USD @ 3.75',  NULL, '2026-05-18'),
  ('Tier 2', 'NA',     'rate_ig_reel', '100T',        9375,  15937,  22500, 'reach_calibrated', 'SOT §13 · 100T Tier 2 IG Reel $2.5K-$6K USD @ 3.75',  NULL, '2026-05-18'),
  ('Tier 2', 'NA',     'rate_ig_reel', 'NRG',         5625,   9843,  15000, 'reach_calibrated', 'SOT §13 · NRG Tier 2 IG Reel $1.5K-$4K USD @ 3.75',  NULL, '2026-05-18'),
  ('Tier 2', 'GLOBAL', 'rate_ig_reel', 'T1',         11250,  20625,  30000, 'reach_calibrated', 'SOT §13 · T1 Tier 2 IG Reel $3K-$8K USD @ 3.75',     NULL, '2026-05-18')
ON CONFLICT DO NOTHING;

COMMIT;

-- ============================================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================================
-- -- Dedup worked:
-- SELECT count(*) FROM public.market_bands WHERE effective_to IS NULL;
-- -- Should now match unique-key count (350 - duplicates removed)
--
-- -- No more dup keys among live rows:
-- SELECT tier_code, platform, audience_market, COALESCE(archetype,''), org, count(*)
-- FROM public.market_bands WHERE effective_to IS NULL
-- GROUP BY 1,2,3,4,5 HAVING count(*) > 1;
-- -- Should return 0 rows
--
-- -- Comp set live:
-- SELECT org, count(*) FROM public.market_bands WHERE effective_to IS NULL GROUP BY 1 ORDER BY 2 DESC;
-- -- Should show industry_generic (~340), falcons_internal (5), FaZe (2), Cloud9 (2), 100T (2), NRG (2), T1 (2), Karmine (1)
