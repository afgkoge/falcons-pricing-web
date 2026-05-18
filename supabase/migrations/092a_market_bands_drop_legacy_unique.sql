-- Migration 092a — Drop legacy market_bands_active_unique index
-- Applied 2026-05-18 via Supabase MCP.
--
-- Mig 092 introduced uq_mb_live_key (broader: includes archetype + org).
-- The legacy market_bands_active_unique (tier × game × market × platform)
-- prevented per-org rows from coexisting with industry_generic rows at
-- the same key. Dropping it unblocks the comp-set seed.

DROP INDEX IF EXISTS public.market_bands_active_unique;

-- Re-run the falcons_internal + comp-set seeds that ON CONFLICT'd against
-- the legacy index. See Migration 092 body for the full insert list.
