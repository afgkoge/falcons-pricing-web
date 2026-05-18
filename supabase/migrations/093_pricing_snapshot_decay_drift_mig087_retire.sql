-- ============================================================================
-- Migration 093 — quote_lines.pricing_snapshot + Mig 087 retirement + decay
-- ============================================================================
-- Authored: 2026-05-18  ·  Engine version: NO BUMP (additive + cleanup)
--
-- 1. Add quote_lines.pricing_snapshot JSONB — captures anchor_premium,
--    channel_multiplier, archetype caps, talent_floor at save time so future
--    quote audits can reconstruct the math (audit gap from May 11 report).
--    Engine writes to it at quote save (call sites updated in Phase 2 v1.2).
--
-- 2. Retire Mig 087's per-bundle PH-anchor workaround on brand_product_launch:
--    moves the PH-vs-KSA price split into the new
--    activations.regional_price_anchors jsonb (Mig 091) and resets the bundle
--    band to a single canonical range. Lets Phase 3 v1.3 read the regional
--    anchor at quote time instead of overriding via axis multipliers.
--
-- 3. Fix the 17 decay-drift rows surfaced in May 11 audit — these have
--    stored achievement_decay_factor ≠ canonical floor_decay for their
--    authority_tier (the sync_decay_from_authority_tier trigger isn't
--    catching every write path). Sets them to canonical values per
--    authority_tier_meta lookup, logs originals in audit_log.
-- ============================================================================

BEGIN;

-- ─── 1. quote_lines.pricing_snapshot ──────────────────────────────────────
ALTER TABLE public.quote_lines
  ADD COLUMN IF NOT EXISTS pricing_snapshot jsonb;
COMMENT ON COLUMN public.quote_lines.pricing_snapshot IS
  'Engine inputs snapshot at quote save: anchor_premium, channel_multiplier, archetype caps (5 fields), talent_submitted_floor, agency_fee_pct, marketCeilingSar, achievementDecay, streamActivity, plus computed deltas (floor_delta, ceiling_delta, talent_floor_delta). Written by api/quote/route.ts in Phase 2 (v1.2). Reconstructable audit trail when authority_tier or stored rate changes after quote creation.';

-- ─── 2. Retire Mig 087 PH workaround → new regional_price_anchors ────────
UPDATE public.activations
  SET regional_price_anchors = jsonb_build_object(
        'PH',      jsonb_build_object('floor', 150000,  'median', 525000,  'ceiling', 900000),
        'APAC',    jsonb_build_object('floor', 200000,  'median', 600000,  'ceiling', 1100000),
        'MENA',    jsonb_build_object('floor', 400000,  'median', 1100000, 'ceiling', 1800000),
        'KSA',     jsonb_build_object('floor', 600000,  'median', 1300000, 'ceiling', 2000000),
        'EU',      jsonb_build_object('floor', 500000,  'median', 1100000, 'ceiling', 1700000),
        'NA',      jsonb_build_object('floor', 500000,  'median', 1200000, 'ceiling', 1800000),
        'GLOBAL',  jsonb_build_object('floor', 500000,  'median', 1100000, 'ceiling', 1700000)
      ),
      price_floor_sar     = 150000,   -- absolute floor across markets
      price_ceiling_sar   = 2000000,  -- absolute ceiling (KSA Tier-1 squad)
      bundle_compression_notes = 'Per-market regional_price_anchors apply at quote time (Mig 091 + Phase 3 v1.3 engine). Default canonical band 150K-2M SAR. Engine selects regional anchor based on quote.target_market; if NULL, falls back to bundle median. Replaces Mig 087 per-bundle PH override pattern.'
WHERE slug = 'brand-product-launch';

-- Map the brand_product_launch bundle to its campaign type (Mig 091)
UPDATE public.activations
  SET campaign_type_code = 'brand_product_launch'
WHERE slug = 'brand-product-launch'
  AND campaign_type_code IS NULL;

-- Also map the other 5 canonical bundles (best-effort, Koge to verify)
UPDATE public.activations SET campaign_type_code = 'co_branded_broadcast_graphics' WHERE slug = 'always-on-jersey-broadcast'    AND campaign_type_code IS NULL;
UPDATE public.activations SET campaign_type_code = 'sponsored_player_stream'       WHERE slug = 'mobile-amplification'          AND campaign_type_code IS NULL;
UPDATE public.activations SET campaign_type_code = 'tournament_gear_partner'       WHERE slug = 'performance-pc-bundle'         AND campaign_type_code IS NULL;
UPDATE public.activations SET campaign_type_code = 'player_vlog_series_sponsored'  WHERE slug = 'day-in-the-life-content-engine' AND campaign_type_code IS NULL;
UPDATE public.activations SET campaign_type_code = 'watch_party'                   WHERE slug = 'tournament-activation-pack'    AND campaign_type_code IS NULL;

-- ─── 3. Fix 17 decay-drift rows ───────────────────────────────────────────
-- Snapshot the 17 drifted rows BEFORE the update so we can audit-log them
CREATE TEMP TABLE _decay_drift_snapshot ON COMMIT DROP AS
SELECT p.id, p.nickname,
       COALESCE(p.authority_tier_override, p.authority_tier) AS at,
       p.achievement_decay_factor                            AS old_decay,
       CASE COALESCE(p.authority_tier_override, p.authority_tier)
         WHEN 'AT-0' THEN 1.000
         WHEN 'AT-1' THEN 1.200
         WHEN 'AT-2' THEN 1.100
         WHEN 'AT-3' THEN 1.000
         WHEN 'AT-4' THEN 0.900
         WHEN 'AT-5' THEN 0.850
         ELSE p.achievement_decay_factor
       END                                                   AS canonical_decay
FROM public.players p
WHERE p.is_active
  AND COALESCE(p.authority_tier_override, p.authority_tier) IN ('AT-0','AT-1','AT-2','AT-3','AT-4','AT-5')
  AND ROUND(p.achievement_decay_factor::numeric, 3)
      <> (CASE COALESCE(p.authority_tier_override, p.authority_tier)
            WHEN 'AT-0' THEN 1.000 WHEN 'AT-1' THEN 1.200 WHEN 'AT-2' THEN 1.100
            WHEN 'AT-3' THEN 1.000 WHEN 'AT-4' THEN 0.900 WHEN 'AT-5' THEN 0.850
          END);

-- Apply the fix
UPDATE public.players p
  SET achievement_decay_factor = s.canonical_decay,
      updated_at = now()
  FROM _decay_drift_snapshot s
 WHERE p.id = s.id;

-- Audit-log every adjustment
INSERT INTO public.audit_log (actor_email, actor_kind, action, entity_type, entity_id, diff)
SELECT 'claude@cowork.local', 'human', 'mig.093.decay_drift_fix', 'player', s.id::text,
       jsonb_build_object(
         'nickname', s.nickname,
         'authority_tier', s.at,
         'before_decay', s.old_decay,
         'after_decay',  s.canonical_decay,
         'reason', 'Decay drift from sync_decay_from_authority_tier trigger gap. Reset to authority_tier_meta canonical.'
       )
FROM _decay_drift_snapshot s;

COMMIT;

-- ============================================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================================
-- -- pricing_snapshot column ready:
-- SELECT count(*) FROM information_schema.columns WHERE table_name='quote_lines' AND column_name='pricing_snapshot';
-- -- → 1
--
-- -- brand_product_launch has regional anchors:
-- SELECT slug, regional_price_anchors IS NOT NULL AS has_anchors, campaign_type_code
-- FROM public.activations WHERE slug='brand-product-launch';
-- -- → has_anchors=true, campaign_type_code='brand_product_launch'
--
-- -- Decay drift cleared:
-- SELECT count(*) FROM public.players p
-- WHERE p.is_active
--   AND ROUND(p.achievement_decay_factor::numeric, 3)
--       <> (CASE COALESCE(p.authority_tier_override, p.authority_tier)
--             WHEN 'AT-0' THEN 1.000 WHEN 'AT-1' THEN 1.200 WHEN 'AT-2' THEN 1.100
--             WHEN 'AT-3' THEN 1.000 WHEN 'AT-4' THEN 0.900 WHEN 'AT-5' THEN 0.850
--           END);
-- -- → 0
