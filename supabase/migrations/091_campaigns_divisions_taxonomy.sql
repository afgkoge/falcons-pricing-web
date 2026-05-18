-- ============================================================================
-- Migration 091 — Campaign × Division × Activation taxonomy (Phase 1B)
-- ============================================================================
-- Authored: 2026-05-18  ·  Engine version: NO BUMP (pure additive)
--
-- Establishes the campaign-taxonomy spine that Phase 2 (v1.2) + Phase 3 (v1.3)
-- engine bumps build on. No engine math changes here. No call site touches.
--
-- Schema:
--   campaign_types          — 76-row taxonomy (58 from glossary + 18 Falcons-specific)
--                             seeded with priority 40 here; remainder in 091a follow-up
--   divisions               — 8 talent divisions (world_class_pros, lifestyle_creators, etc.)
--   campaign_division_fit   — campaign × division × role matrix (seeded ~60 priority rows)
--   activations.campaign_type_code     — FK to campaign_types
--   activations.regional_price_anchors — jsonb per-market floor/median/ceiling
--                                        (replaces Mig 087 per-bundle PH/KSA workaround)
--   quotes.campaign_type_code          — FK to campaign_types
--   quotes.funnel_stage                — denormalized for analytics
--   quotes.target_market               — KSA / MENA / NA / EU / APAC / GLOBAL
--
-- Sources: Marketing_Esports_Glossary_EN_AR.xlsx (sheets 09-13, 16)
--          + Falcons commercial input on missing categories
-- ============================================================================

BEGIN;

-- ─── 1. campaign_types ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.campaign_types (
  code             text PRIMARY KEY,
  name_en          text NOT NULL,
  name_ar          text,
  sponsor_type     text NOT NULL CHECK (sponsor_type IN ('endemic','non_endemic','hybrid')),
  activation_type  text NOT NULL CHECK (activation_type IN ('digital','on_ground','hybrid')),
  funnel_stage     text NOT NULL CHECK (funnel_stage IN ('awareness','engagement','conversion','loyalty','earned')),
  sub_category     text,
  description_en   text NOT NULL,
  description_ar   text,
  best_practice_en text,
  example_en       text,
  primary_kpi      text,
  typical_lead_time_days  smallint,
  typical_duration_days   smallint,
  default_compression_factor numeric(4,3) DEFAULT 1.000 CHECK (default_compression_factor BETWEEN 0.300 AND 1.500),
  is_active        boolean NOT NULL DEFAULT true,
  sort_order       smallint,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ct_sponsor_funnel ON public.campaign_types (sponsor_type, funnel_stage) WHERE is_active;
COMMENT ON TABLE  public.campaign_types IS 'Master taxonomy of campaign types. 2-axis (sponsor × activation) × funnel-stage. Drives bundle defaults, division fit matrix, and (Phase 3) engine axis defaults.';
COMMENT ON COLUMN public.campaign_types.default_compression_factor IS 'Default bundle compression applied when this campaign type drives a multi-talent quote. Engine reads at quote time (Phase 3 v1.3). 1.000 = no compression.';

-- ─── 2. divisions ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.divisions (
  code            text PRIMARY KEY,
  name_en         text NOT NULL,
  name_ar         text,
  description     text,
  typical_archetypes      text[] NOT NULL DEFAULT '{}',
  typical_authority_tiers text[] NOT NULL DEFAULT '{}',
  sort_order      smallint,
  is_active       boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE public.divisions IS 'Talent groupings used to bundle quotes by archetype + authority. A talent can belong to multiple divisions via talent_division_membership.';

-- ─── 3. talent_division_membership ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.talent_division_membership (
  talent_id       integer NOT NULL REFERENCES public.players(id) ON DELETE CASCADE,
  division_code   text    NOT NULL REFERENCES public.divisions(code),
  is_primary      boolean NOT NULL DEFAULT false,
  assigned_at     timestamptz NOT NULL DEFAULT now(),
  assigned_by     text,
  PRIMARY KEY (talent_id, division_code)
);
CREATE INDEX IF NOT EXISTS idx_tdm_division ON public.talent_division_membership (division_code);

-- ─── 4. campaign_division_fit ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.campaign_division_fit (
  campaign_type_code text NOT NULL REFERENCES public.campaign_types(code) ON DELETE CASCADE,
  division_code      text NOT NULL REFERENCES public.divisions(code),
  role               text NOT NULL CHECK (role IN ('hero','support','amplifier','optional')),
  min_count          smallint NOT NULL DEFAULT 0,
  max_count          smallint NOT NULL DEFAULT 5,
  typical_deliverables text[] NOT NULL DEFAULT '{}',
  notes              text,
  PRIMARY KEY (campaign_type_code, division_code)
);

-- ─── 5. Extend activations ─────────────────────────────────────────────────
ALTER TABLE public.activations
  ADD COLUMN IF NOT EXISTS campaign_type_code       text REFERENCES public.campaign_types(code),
  ADD COLUMN IF NOT EXISTS regional_price_anchors   jsonb;
COMMENT ON COLUMN public.activations.regional_price_anchors IS
  'Per-audience-market floor/median/ceiling SAR. Replaces Mig 087 per-bundle PH/KSA workaround. Engine reads at quote time (Phase 3 v1.3). Shape: {"KSA":{"floor":..., "median":..., "ceiling":...}, "PH":{...}, ...}';

-- ─── 6. Extend quotes ──────────────────────────────────────────────────────
ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS campaign_type_code text REFERENCES public.campaign_types(code),
  ADD COLUMN IF NOT EXISTS funnel_stage       text CHECK (funnel_stage IS NULL OR funnel_stage IN ('awareness','engagement','conversion','loyalty','earned')),
  ADD COLUMN IF NOT EXISTS target_market      text CHECK (target_market IS NULL OR target_market IN ('KSA','MENA','NA','EU','APAC','LATAM','GLOBAL'));
COMMENT ON COLUMN public.quotes.target_market IS 'Brand''s campaign target market. Engine reads at quote time (Phase 3 v1.3) to compute campaignTargetMarketLift × talent.audience_market.';

-- ─── 7. Seed divisions (8 rows) ────────────────────────────────────────────
INSERT INTO public.divisions (code, name_en, name_ar, description, typical_archetypes, typical_authority_tiers, sort_order) VALUES
  ('world_class_pros',    'World-Class Pros',     'محترفون عالميون',  'Global-elite competitive pros — NiKo / m0NESY / Cellium / FlapTzy / Vejrgang',                    ARRAY['world_class_pro'],                              ARRAY['AT-1','AT-2','AT-3'], 10),
  ('established_pros',    'Established Pros',     'محترفون راسخون',   'Tier-1 active competitors with championship pedigree',                                            ARRAY['established_pro','regional_pro'],               ARRAY['AT-2','AT-3','AT-4'], 20),
  ('emerging_pros',       'Emerging Pros',        'محترفون صاعدون',   'Tier-2/3 active competitors building name + audience',                                            ARRAY['regional_pro','grassroots_competitor'],         ARRAY['AT-4','AT-5'],         30),
  ('staff_personalities', 'Esports Personalities','شخصيات إسبورتس',   'Coaches, analysts, managers, casters — non-playing talent with name recognition',                ARRAY['esports_personality','tournament_athlete'],     ARRAY['AT-0','AT-1','AT-2','AT-3'], 40),
  ('lifestyle_creators',  'Lifestyle Creators',   'صانعو محتوى لايف ستايل','Hybrid + pure lifestyle creators — BanderitaX / oPiiLz / 9leeh',                              ARRAY['hybrid_lifestyle','pure_lifestyle'],            ARRAY['AT-0'],                50),
  ('streamer_pros',       'Streamer-Pros',        'محترفون بثيون',    'Pros with significant streaming activity (>40h/30d) — overlap division with world_class_pros',  ARRAY['world_class_pro','hybrid_lifestyle'],           ARRAY['AT-1','AT-2','AT-3'], 60),
  ('tournament_athletes', 'Tournament Athletes',  'رياضيو بطولات',    'Single-game globally-elite athletes (e.g. Hikaru Nakamura) — high authority, low social',        ARRAY['tournament_athlete'],                           ARRAY['AT-1','AT-2','AT-3'], 70),
  ('team_brand',          'Team Channels',        'قنوات الفريق',     'Falcons-owned channels (IG / TikTok / YT / X / Twitch) — brand-tier amplification',              ARRAY[]::text[],                                       ARRAY[]::text[],              80)
ON CONFLICT (code) DO NOTHING;

-- ─── 8. Seed campaign_types — priority 40 (rest in follow-up 091a) ─────────
-- Endemic Digital (10)
INSERT INTO public.campaign_types (code, name_en, name_ar, sponsor_type, activation_type, funnel_stage, sub_category, description_en, best_practice_en, example_en, primary_kpi, typical_lead_time_days, typical_duration_days, default_compression_factor, sort_order) VALUES
  ('gear_hero_film',              'Gear Hero Film',              'فيلم تجريبي للأجهزة',  'endemic','digital','awareness','Film',
    'Endemic gear brand co-produces a cinematic hero film with the team, featuring the product in real competitive context.',
    'Product is the hero, not a placement. Let pros explain why this gear matters in their game. Shoot bespoke; never rely on stock.',
    'Razer x Falcons CS hero film during pre-EWC build.', 'reach + brand_recall', 42, 14, 0.850, 110),
  ('sponsored_player_stream',     'Sponsored Player Stream',     'بث لاعب مدعوم',         'endemic','digital','engagement','Broadcast',
    'Brand sponsors a player''s regular stream with branded overlays, gear reveals, and segments.',
    'Integrate into existing content rhythm; don''t disrupt. Sustained cadence beats one-time mentions.',
    'HyperX-presented weekly Twitch stream of a Falcons star.', 'live_hours + er', 14, 90, 0.950, 120),
  ('in_game_skin',                'In-Game Item / Skin',         'عنصر داخل اللعبة',     'endemic','digital','conversion','Product',
    'Game publisher co-creates an in-game cosmetic tied to the team. Tier-1 endemic deal.',
    'Reserved for top partnerships. 6+ months lead time. Drives long-tail awareness across the game''s player base.',
    'Riot x Falcons Valorant team capsule tied to a championship.', 'cosmetic_sales + impressions', 180, 60, 0.900, 130),
  ('pro_gear_endorsement',        'Pro Gear Endorsement',        'تعاقد لاعب لأجهزة',     'endemic','digital','awareness','Endorsement',
    'Player signs as ambassador for a peripheral brand; launches with hero shoot and content series.',
    'Multi-year deal preferred. Players move careers — build the personal kit identity to outlast the org tenure.',
    'Falcons star x Logitech 24-month deal with launch film.', 'brand_lift + media_value', 60, 730, 0.950, 140),
  ('setup_battlestation_reveal',  'Setup / Battlestation Reveal','جولة في إعدادات اللاعب','endemic','digital','engagement','Content series',
    'Tour of a player''s gaming setup featuring all sponsor gear in their natural habitat.',
    'Personalize each tour. Show why each piece matters to that player. High-performing format on YouTube.',
    'Inside the Falcons captain''s training room.', 'views + watch_time', 21, 7, 0.950, 150),
  ('community_hardware_seeding',  'Community Hardware Seeding',  'توزيع أجهزة للمجتمع',   'endemic','digital','loyalty','Community',
    'Brand seeds product to creators or fans through the org''s community.',
    'Integrate giveaway mechanic into a sustained content arc — not one-and-done. Gate via fan-club tier or challenge.',
    'Razer seeds 100 mice to top Falcons Discord members.', 'er + sign_ups', 14, 30, 0.900, 160),
  ('early_access_game_seeding',   'Early-Access Game Seeding',   'وصول مبكر للعبة',      'endemic','digital','awareness','Content',
    'Game publisher gives team early access; team produces first-reaction and pre-launch content.',
    'Player-led reactions outperform polished announces. Capture authentic first impressions, including the messy parts.',
    'Falcons CS roster gets new map 48h before public.', 'views + earned_media', 7, 5, 0.900, 170),
  ('co_branded_broadcast_graphics','Co-Branded Broadcast Graphics','رسوميات بث مشتركة',  'endemic','digital','awareness','Broadcast',
    'Sponsor presents team broadcast lower-thirds, score bugs, and break interstitials.',
    'Design these inside the brand system, not as logo dumps. Treat broadcast graphics as premium brand real estate.',
    'All Falcons-broadcast scores presented by [brand].', 'impressions', 21, 180, 1.000, 180),
  ('tournament_gear_partner',     'Tournament Gear Partner',     'شريك أجهزة البطولة',   'endemic','digital','awareness','Partnership',
    'Brand becomes official peripheral, PC, or internet partner of the team across all rosters.',
    'Always activate beyond the logo: dressing room shots, broadcast inserts, co-content. Logo-only deals underperform.',
    'Intel as exclusive CPU partner for all Falcons rosters.', 'brand_recall + media_value', 60, 365, 0.900, 190),
  ('energy_drink_ritual',         'Energy-Drink Ritual',         'مشروب الطاقة قبل المباراة','endemic','digital','engagement','Integration',
    'Energy drink integrated into player''s authentic pre-match ritual content.',
    'Authenticity rules. Players visibly use it because they use it. Forced placement is the fastest way to lose audience trust.',
    'Red Bull as pre-match drink in roster vlogs.', 'er + brand_consideration', 30, 90, 0.950, 200);

-- Non-Endemic Digital (10)
INSERT INTO public.campaign_types (code, name_en, name_ar, sponsor_type, activation_type, funnel_stage, sub_category, description_en, best_practice_en, example_en, primary_kpi, typical_lead_time_days, typical_duration_days, default_compression_factor, sort_order) VALUES
  ('brand_purpose_film',          'Brand Purpose Film',          'فيلم قيم العلامة',     'non_endemic','digital','awareness','Film',
    'Co-produced anthem-style film articulating shared values between non-endemic brand and the org.',
    'Anchor in a real audience-overlap insight, not generic ''youth'' tropes. Co-direct, don''t rubber-stamp the brand''s film team.',
    'Saudia Airlines x Falcons ''Fly to win'' anthem film.', 'brand_lift + earned_media', 60, 21, 0.850, 210),
  ('co_branded_capsule',          'Co-Branded Limited Capsule',  'كبسولة محدودة مشتركة', 'non_endemic','digital','conversion','Product',
    'Limited-edition merch drop combining brand identities and design DNA.',
    'Lock visual hierarchy in pre-production. Treat as a fashion collab — pre-order, scarcity, drop windows. Quality > quantity.',
    'Falcons x Adidas 5,000-unit capsule, 72-hour pre-order.', 'sell_through + pre_orders', 90, 14, 0.850, 220),
  ('cultural_moment',             'Cultural Moment Partnership', 'شراكة لحظة ثقافية',    'non_endemic','digital','engagement','Cultural',
    'Brand + org collaborate on Ramadan, National Day, or Founding Day content.',
    'Brief 6+ weeks before. Find authentic gaming-culture overlap; don''t force-fit. Lead with cultural respect, then brand.',
    'Bank x Falcons Founding Day capsule + film.', 'engagement_rate + sentiment', 42, 21, 0.800, 230),
  ('financial_co_product',        'Financial Co-Product',        'منتج مالي مشترك',       'non_endemic','digital','loyalty','Financial',
    'Co-branded card, app integration, or financial offer for fans with real utility.',
    'Real super-fan utility. Cashback on merch, ticket priority, exclusive content. Avoid surface-level co-branding.',
    'Falcons x Riyad Bank co-branded card with merch cashback.', 'sign_ups + activation_rate', 90, 365, 1.000, 240),
  ('telco_super_fan_plan',        'Telco Super-Fan Plan',        'باقة جوال للمعجبين',   'non_endemic','digital','loyalty','Telco',
    'Mobile carrier offers a fan plan with content/data bundles tied to team''s calendar.',
    'Sell against a specific use case: ''follow the season uninterrupted.'' Tie to event windows for urgency.',
    'STC x Falcons unlimited streaming plan for EWC season.', 'plan_sign_ups + arpu', 60, 180, 0.950, 250),
  ('brand_product_launch',        'Brand Product Launch',        'إطلاق منتج العلامة',   'non_endemic','digital','awareness','Launch',
    '2-4 squad + 1 hybrid-lifestyle creator running teaser → launch-day → afterglow cadence. Designed for phone/peripheral/energy-drink/apparel SKUs.',
    'Lock visual hierarchy + creative direction 4 weeks pre-launch. Plan UTM + discount code per talent for attribution.',
    'Realme B4 launch — June 2026, PH-anchored band.', 'reach + sell_through + search_lift', 28, 42, 0.900, 260),
  ('ugc_contest',                 'UGC Contest',                 'مسابقة محتوى من المعجبين','non_endemic','digital','engagement','Contest',
    'Fans submit content under a sponsored hashtag for prizes/feature.',
    'Set submission rules, content rights, and judging criteria up front. Feature winners — don''t just announce them.',
    '#FalconsClutch — top 10 clips reposted across team channels.', 'submissions + reach', 14, 21, 0.900, 270),
  ('ar_filter_lens',              'AR Filter / Snap Lens',       'فلتر واقع معزز',       'non_endemic','digital','engagement','AR',
    'Branded AR effect on IG, Snapchat, or TikTok used by fans.',
    'Simple, fun, share-worthy. Integrate brand subtly — heavy logos kill organic use.',
    '''Wear the Falcons jersey'' AR try-on lens.', 'opens + shares', 21, 30, 0.950, 280),
  ('fan_club_loyalty_tier',       'Fan-Club Loyalty Tier',       'فئة ولاء للمعجبين',     'non_endemic','digital','loyalty','Membership',
    'Sponsor-presented loyalty tier with real benefits for super-fans.',
    'Benefits beat points. Behind-the-scenes, first access, in-person — not ''spend $1, get 1 point.''',
    '''Falcons Inner Circle'' presented by sponsor — gated content + early jersey access.', 'tier_sign_ups + retention', 60, 365, 1.000, 290),
  ('player_vlog_series_sponsored','Sponsored Player Vlog Series', 'سلسلة مدونات اللاعب', 'non_endemic','digital','engagement','Content series',
    'Multi-episode player vlog series sponsored end-to-end by one brand.',
    'Integrate brand into the player''s actual day, not a forced segment. Trust the player''s voice.',
    'Captain''s 6-episode ''Road to EWC'' series, sponsored by airline.', 'views + watch_time + er', 30, 90, 0.900, 300);

-- Endemic + Non-Endemic On-Ground (10)
INSERT INTO public.campaign_types (code, name_en, name_ar, sponsor_type, activation_type, funnel_stage, sub_category, description_en, best_practice_en, example_en, primary_kpi, typical_lead_time_days, typical_duration_days, default_compression_factor, sort_order) VALUES
  ('watch_party',                 'Watch Party',                 'حفل مشاهدة',           'non_endemic','on_ground','engagement','Community',
    'Public live viewing of a match with sponsor experience and content capture.',
    'Plan 8 weeks out. Site, talent, F&B, sponsor zone, content unit. Tomorrow''s social = today''s watch party content.',
    'Falcons watch party at Boulevard, 5,000 attendees, EWC final.', 'attendance + content_units', 56, 1, 0.800, 310),
  ('fan_zone_arena',              'Fan Zone at Arena',           'منطقة المعجبين',       'non_endemic','on_ground','engagement','Experiential',
    'Branded experiential space at an event with photo moments, games, giveaways.',
    'Three things minimum: photo moment, interactive game, free thing. Design for content capture, not just footfall.',
    'Falcons fan zone at EWC: meet & greet, photo wall, prize wheel.', 'footfall + content_units', 42, 7, 0.850, 320),
  ('meet_and_greet',              'Meet & Greet',                'لقاء معجبين',          'hybrid','on_ground','loyalty','Community',
    'In-person fan access to players with photo + signature.',
    'Cap volume to protect quality. 30 seconds + photo + signature. Timed entry. Never oversell.',
    '200 fans, timed slots over 4 hours, signed jerseys + photo.', 'slot_fill + sentiment', 28, 1, 0.850, 330),
  ('pop_up_retail',               'Pop-Up Retail / Merch Drop',  'متجر مؤقت',            'non_endemic','on_ground','conversion','Retail',
    'Temporary physical store or booth tied to a moment.',
    'Surprise locations + short windows = hype. Pair with player surprise visits.',
    '72-hour Falcons pop-up at Riyadh Park during EWC week.', 'footfall + sell_through', 42, 3, 0.800, 340),
  ('mall_takeover',               'Mall / Public Space Takeover','استحواذ على فضاء عام', 'non_endemic','on_ground','awareness','Reach',
    'Brand + team co-takeover of a high-traffic location.',
    'Combine retail, content, photo moments, player visits. Measure footfall delta vs typical day.',
    'Riyadh Park or Boulevard Falcons takeover with player appearances.', 'footfall_delta + ugc', 56, 3, 0.750, 350),
  ('bootcamp_open_day',           'Bootcamp Open Day',           'يوم مفتوح في المعسكر', 'endemic','on_ground','loyalty','Community',
    'Limited fan invite to the team''s training facility.',
    'Carefully scoped — protect player focus. 60-minute window, max 50 fans. Sponsor often funds it.',
    '50 super-fans tour the Falcons bootcamp facility.', 'attendance + content_units', 30, 1, 0.900, 360),
  ('charity_community_match',     'Charity / Community Match',   'مباراة خيرية',         'hybrid','on_ground','earned','Community',
    'Players play with/for fans or a cause.',
    'Real cause + real engagement. Document fully — charity content drives ER + brand love.',
    'Falcons charity match benefitting youth-gaming education.', 'funds_raised + sentiment', 42, 1, 0.850, 370),
  ('trophy_tour',                 'Trophy Tour',                 'جولة الكأس',           'hybrid','on_ground','earned','Earned',
    'Multi-city tour after a championship with photo moments and signings.',
    '4-8 cities. Sponsor each city differently. Photo + signing + retail tie-in at each stop.',
    'Falcons EWC trophy tour — 6 KSA cities.', 'city_attendance + earned_media', 14, 21, 0.700, 380),
  ('press_media_day',             'Press / Media Day',           'يوم إعلامي',           'hybrid','on_ground','earned','Earned',
    'Organized day for journalists, creators, and sponsors to access players.',
    'Hold during off-event week. Strict rules to protect player time. Hand-pick attendees.',
    'Annual Falcons press day with quarterly themes.', 'coverage + media_value', 30, 1, 0.900, 390),
  ('auto_reveal',                 'Auto Reveal at Esports Event','إطلاق سيارة في حدث',   'non_endemic','on_ground','awareness','Reveal',
    'Car brand reveals a new model in an esports environment with team integration.',
    'Anchor on a shared attribute — performance, precision, engineering. Avoid generic ''fast-paced gaming.''',
    'Aston Martin x Falcons reveal at EWC entrance.', 'reveal_reach + earned_media', 90, 1, 0.800, 400);

-- Falcons-specific lifecycle + cultural (10)
INSERT INTO public.campaign_types (code, name_en, name_ar, sponsor_type, activation_type, funnel_stage, sub_category, description_en, best_practice_en, example_en, primary_kpi, typical_lead_time_days, typical_duration_days, default_compression_factor, sort_order) VALUES
  ('player_signing_reveal',       'Player Signing Reveal',       'إعلان توقيع لاعب',     'hybrid','digital','awareness','Lifecycle',
    'New player announcement film + 24h content arc across team channels.',
    'Lock the announce video, social rollout, and player-side cross-post 48h before. Surprise the audience, not internal teams.',
    'Falcons signs world-champion CS pro — anthem film + arrival vlog + Discord drop.', 'reach + er + earned_media', 21, 3, 0.700, 410),
  ('roster_annual_reveal',        'Annual Roster Reveal',        'إطلاق التشكيلة السنوية','hybrid','digital','awareness','Lifecycle',
    'Pre-season roster drop with jersey reveal and full-squad content sweep.',
    'Tease, reveal, capsule, vlog — sequence over 7-10 days. Co-brand jersey reveal with apparel partner.',
    'Pre-EWC 2026 roster anthem + jersey drop + per-player intro vlog.', 'reach + jersey_sell_through', 60, 14, 0.550, 420),
  ('sponsor_partnership_announce','Sponsor Partnership Announce','إعلان شراكة راعٍ',     'hybrid','digital','awareness','Lifecycle',
    'When a new sponsor lands, the announcement is its own campaign.',
    'Lead with the why, not the logo. One hero asset, three sustain posts, sponsor cross-post.',
    'Aramco x Falcons partnership reveal.', 'reach + earned_media', 30, 7, 0.900, 430),
  ('multi_game_crossover',        'Multi-Game Crossover',        'تعاون متعدد الألعاب',  'non_endemic','digital','awareness','Brand',
    'Same brand activates across multiple games on roster.',
    'Anchor on a unifying creative idea — not 5 separate vertical executions. One brief, multiple expressions.',
    'Sponsor x Falcons CS + Valorant + EAFC content arc.', 'reach + cost_per_audience', 60, 30, 0.650, 440),
  ('org_collab_scrim',            'Org Collab Scrim',            'مباراة ودية بين منظمتين','endemic','digital','engagement','Content',
    'Falcons × FaZe / T1 / NaVi scrim content series.',
    'Cast for chemistry between rosters. Stream live + clip for short-form afterglow. Capture talent banter.',
    'Falcons CS vs FaZe scrim livestream.', 'live_viewers + er', 21, 1, 0.850, 450),
  ('saudi_national_day',          'Saudi National Day',          'اليوم الوطني',         'hybrid','hybrid','engagement','Cultural',
    'Sep 23 anchor moment with content + on-ground capsule.',
    'Lead with national identity, then team. Brand sponsor lands as supporter, not center. Plan 8 weeks ahead.',
    'Falcons National Day green-jersey capsule + Riyadh activation.', 'sentiment + reach', 60, 7, 0.700, 460),
  ('founding_day',                'Founding Day',                'يوم التأسيس',          'hybrid','hybrid','engagement','Cultural',
    'Feb 22 anchor moment.',
    'Earlier and quieter than National Day — pair with heritage storytelling.',
    'Falcons Founding Day heritage content + jersey capsule.', 'sentiment + reach', 60, 7, 0.700, 470),
  ('ramadan_series',              'Ramadan Series',              'سلسلة رمضان',          'hybrid','digital','engagement','Cultural',
    '30-day Ramadan content arc — iftar moments, ghada, family content.',
    'Slow down editorial pace. Lead with player humanity, not competitive content. Sponsor lands as enabler.',
    'Ramadan iftar series with full roster across 30 days.', 'er + sentiment + watch_time', 56, 30, 0.750, 480),
  ('pre_event_hype_arc',          'Pre-Event Hype Arc',          'حملة ما قبل البطولة',  'hybrid','digital','awareness','Tournament',
    '4-week pre-EWC (or other major) content build with full squad.',
    'Anchor on a single narrative — comeback / first-time / defending. Pace 3 content beats per week.',
    'Falcons Road to EWC 2026 — 28-day content build.', 'reach + er', 28, 28, 0.550, 490),
  ('championship_celebration',    'Championship Celebration',    'احتفال البطولة',       'hybrid','hybrid','earned','Tournament',
    'Post-win content sweep — vlog, parade, trophy tour kickoff.',
    'Win-night vlog within 24h. Sponsor pre-positioned to capture this moment if it lands.',
    'Falcons EWC win celebration content sweep + parade.', 'reach + earned_media + sentiment', 7, 14, 0.650, 500);

-- ─── 9. Seed campaign_division_fit — priority pairings (50 rows) ───────────
-- Format: (campaign, division, role, min, max, deliverables, notes)
INSERT INTO public.campaign_division_fit (campaign_type_code, division_code, role, min_count, max_count, typical_deliverables, notes) VALUES
  -- Gear Hero Film: world_class hero + streamer support + team amplify
  ('gear_hero_film',        'world_class_pros',     'hero',      1, 2, ARRAY['hero_film','ig_reel','yt_short'],          'Pro is the face of the gear story.'),
  ('gear_hero_film',        'streamer_pros',        'support',   0, 1, ARRAY['twitch_integ','yt_short','ig_reel'],        'Streamer demos the gear in action.'),
  ('gear_hero_film',        'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video','x_post'],          'Team channels x-post hero asset.'),
  -- Sponsored player stream
  ('sponsored_player_stream','streamer_pros',       'hero',      1, 1, ARRAY['twitch_stream','twitch_integ'],            'Primary streamer for sustained presence.'),
  ('sponsored_player_stream','team_brand',          'amplifier', 0, 1, ARRAY['ig_story','x_post'],                       'Optional team announce + sustain.'),
  -- In-game skin
  ('in_game_skin',          'world_class_pros',     'hero',      1, 3, ARRAY['ig_reel','tiktok_video','yt_short'],        'Whichever players the skin features.'),
  ('in_game_skin',          'team_brand',           'support',   1, 1, ARRAY['ig_reel','x_post','yt_short'],              'Team announce + drop content.'),
  -- Brand Product Launch (Realme-shape)
  ('brand_product_launch',  'lifestyle_creators',   'hero',      1, 1, ARRAY['ig_reel','tiktok_video','yt_full'],         'Brand-story lens. Owns the launch hero.'),
  ('brand_product_launch',  'world_class_pros',     'support',   1, 2, ARRAY['ig_reel','tiktok_video','irl'],             'In-game proof point. Mobile + PC pros.'),
  ('brand_product_launch',  'streamer_pros',        'amplifier', 0, 1, ARRAY['twitch_stream','tiktok_video'],             'Launch-day live + reaction.'),
  ('brand_product_launch',  'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video','x_post'],          'Team channels x-post.'),
  -- Brand Purpose Film
  ('brand_purpose_film',    'world_class_pros',     'hero',      1, 3, ARRAY['hero_film','ig_reel'],                      'Featured talent for the anthem.'),
  ('brand_purpose_film',    'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video','yt_full'],         'Team channel premiere.'),
  -- Co-Branded Capsule
  ('co_branded_capsule',    'lifestyle_creators',   'hero',      1, 1, ARRAY['ig_reel','ig_static','tiktok_video'],       'Capsule reveal + try-on.'),
  ('co_branded_capsule',    'world_class_pros',     'support',   1, 3, ARRAY['ig_static','ig_story'],                     'Roster wears the capsule.'),
  ('co_branded_capsule',    'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video'],                   'Drop announcement.'),
  -- Cultural Moment
  ('cultural_moment',       'lifestyle_creators',   'hero',      1, 1, ARRAY['ig_reel','tiktok_video','yt_full'],         'Lifestyle creator owns cultural lens.'),
  ('cultural_moment',       'established_pros',     'support',   1, 3, ARRAY['ig_reel','ig_story'],                       'Squad participation.'),
  ('cultural_moment',       'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video'],                   'Cultural-anchor team post.'),
  -- Telco Super-Fan Plan (loyalty + lifecycle)
  ('telco_super_fan_plan',  'team_brand',           'hero',      1, 1, ARRAY['ig_reel','tiktok_video','yt_short'],        'Brand-product launch via team.'),
  ('telco_super_fan_plan',  'world_class_pros',     'support',   1, 3, ARRAY['ig_reel','ig_story'],                       'Stars front the plan benefits.'),
  -- Watch Party (on-ground)
  ('watch_party',           'team_brand',           'hero',      1, 1, ARRAY['event_attendance','ig_reel'],               'Team channel content unit.'),
  ('watch_party',           'established_pros',     'support',   2, 3, ARRAY['event_attendance','ig_story'],              'Squad presence drives footfall.'),
  ('watch_party',           'lifestyle_creators',   'amplifier', 0, 1, ARRAY['ig_reel','tiktok_video'],                   'Creator cross-post to broaden reach.'),
  -- Fan Zone at Arena
  ('fan_zone_arena',        'established_pros',     'hero',      1, 3, ARRAY['event_attendance','ig_story'],              'Player appearances drive zone traffic.'),
  ('fan_zone_arena',        'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video'],                   'Content from the zone.'),
  -- Meet & Greet
  ('meet_and_greet',        'world_class_pros',     'hero',      1, 3, ARRAY['event_attendance'],                         'Pulls fan demand.'),
  ('meet_and_greet',        'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video'],                   'Highlights reel post-event.'),
  -- Trophy Tour
  ('trophy_tour',           'world_class_pros',     'hero',      2, 5, ARRAY['event_attendance','ig_reel','ig_story'],    'Championship squad fronts the tour.'),
  ('trophy_tour',           'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video','yt_short'],        'Per-city content unit.'),
  -- Bootcamp Open Day
  ('bootcamp_open_day',     'established_pros',     'hero',      2, 4, ARRAY['event_attendance','ig_story'],              'Pros host fans on facility tour.'),
  ('bootcamp_open_day',     'staff_personalities',  'support',   1, 1, ARRAY['event_attendance'],                         'Coach/manager Q&A segment.'),
  ('bootcamp_open_day',     'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video'],                   'Open-day recap content.'),
  -- Charity / Community Match
  ('charity_community_match','established_pros',    'hero',      3, 5, ARRAY['event_attendance','twitch_stream'],         'Players for the match.'),
  ('charity_community_match','lifestyle_creators',  'support',   1, 2, ARRAY['event_attendance','ig_reel'],               'Creators as community face.'),
  ('charity_community_match','team_brand',          'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video','yt_full'],         'Charity content full-length.'),
  -- Player Signing Reveal
  ('player_signing_reveal', 'world_class_pros',     'hero',      1, 1, ARRAY['hero_film','ig_reel','tiktok_video'],       'The new signing IS the hero.'),
  ('player_signing_reveal', 'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video','x_post','yt_short'],'Team channel announce sweep.'),
  -- Annual Roster Reveal
  ('roster_annual_reveal',  'world_class_pros',     'hero',      3, 5, ARRAY['hero_film','ig_reel','tiktok_video'],       'Full active squad fronts the reveal.'),
  ('roster_annual_reveal',  'established_pros',     'support',   3, 8, ARRAY['ig_reel','ig_static'],                      'Per-player intro vlogs.'),
  ('roster_annual_reveal',  'staff_personalities',  'support',   1, 3, ARRAY['ig_reel','ig_static'],                      'Coach/analyst intros.'),
  ('roster_annual_reveal',  'team_brand',           'amplifier', 1, 1, ARRAY['hero_film','ig_reel','tiktok_video','yt_full'],'Team channel premieres + sweep.'),
  -- Pre-Event Hype Arc
  ('pre_event_hype_arc',    'world_class_pros',     'hero',      3, 5, ARRAY['ig_reel','tiktok_video','yt_short'],        'Squad content per week.'),
  ('pre_event_hype_arc',    'staff_personalities',  'support',   1, 2, ARRAY['ig_reel','yt_full'],                        'Coach/analyst tactical posts.'),
  ('pre_event_hype_arc',    'lifestyle_creators',   'amplifier', 0, 1, ARRAY['ig_reel','tiktok_video'],                   'Lifestyle cross-post for reach.'),
  ('pre_event_hype_arc',    'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video','yt_full'],         'Anchor narrative on team channels.'),
  -- Championship Celebration
  ('championship_celebration','world_class_pros',   'hero',      3, 5, ARRAY['hero_film','ig_reel','tiktok_video','irl'], 'The winning squad.'),
  ('championship_celebration','team_brand',         'amplifier', 1, 1, ARRAY['hero_film','ig_reel','tiktok_video','yt_full'],'Win-night content sweep.'),
  ('championship_celebration','lifestyle_creators', 'amplifier', 0, 1, ARRAY['ig_reel','tiktok_video'],                   'Cross-post for casual audience reach.'),
  -- Ramadan Series
  ('ramadan_series',        'lifestyle_creators',   'hero',      1, 2, ARRAY['ig_reel','tiktok_video','yt_full'],         'Lifestyle creator owns daily content.'),
  ('ramadan_series',        'established_pros',     'support',   2, 5, ARRAY['ig_reel','ig_story'],                       'Squad iftar/family moments.'),
  ('ramadan_series',        'staff_personalities',  'support',   1, 2, ARRAY['ig_reel','ig_story'],                       'Coaches in human moments.'),
  ('ramadan_series',        'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video'],                   '30-day sustain.'),
  -- Saudi National Day
  ('saudi_national_day',    'world_class_pros',     'hero',      2, 5, ARRAY['ig_reel','tiktok_video','event_attendance'],'Squad fronts national pride moment.'),
  ('saudi_national_day',    'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video','yt_short'],        'National Day content sweep.'),
  -- Founding Day
  ('founding_day',          'world_class_pros',     'hero',      2, 4, ARRAY['ig_reel','event_attendance'],               'Heritage storytelling lead.'),
  ('founding_day',          'team_brand',           'amplifier', 1, 1, ARRAY['ig_reel','tiktok_video'],                   'Heritage content unit.');

COMMIT;

-- ============================================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================================
-- select count(*) campaign_types_total from public.campaign_types;
-- → expect 40
-- select count(*) divisions_total from public.divisions;
-- → expect 8
-- select count(*) fit_rows_total from public.campaign_division_fit;
-- → expect ~58
-- select count(*) activations_with_campaign_type from public.activations where campaign_type_code is not null;
-- → expect 0 (backfill in follow-up migration after Koge maps the 6 canonical bundles to campaign types)
