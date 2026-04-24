-- =============================================================================
-- novekai-immo-test — Schéma Supabase
-- =============================================================================
-- Pipeline : Gmail → Claude (extraction JSON) → Supabase
-- Tables   : leads, processing_log, incomplete_leads_log
--
-- Exécution : copier-coller l'intégralité dans
--   Supabase Dashboard → SQL Editor → New query → Run
-- Le script est idempotent (IF NOT EXISTS / DROP IF EXISTS pour les index
-- non-IF-NOT-EXISTS), on peut le relancer sans tout casser.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Table principale : leads
-- -----------------------------------------------------------------------------
-- Contient les leads extraits avec succès par le LLM.
-- Les champs correspondent 1:1 au JSON de sortie défini dans le test technique,
-- auxquels on ajoute `raw_email` (obligatoire par l'énoncé) et `created_at`.

create table if not exists public.leads (
  id               uuid primary key default gen_random_uuid(),

  -- Prospect
  prospect_nom     text,
  prospect_email   text,
  prospect_tel     text,

  -- Bien
  bien_reference   text,
  bien_adresse     text,

  -- Classification
  type_demande     text check (type_demande in ('visite','info','candidature','autre')),
  langue           text check (langue in ('fr','nl','en')),

  -- Contenu
  message_prospect text,
  score_confiance  numeric(3,2) check (score_confiance >= 0 and score_confiance <= 1),

  -- Brouillon de réponse généré par le LLM (bonus)
  -- Texte pré-rédigé dans la langue du prospect, adapté au type_demande.
  -- À valider/éditer par l'agent avant envoi — jamais envoyé auto.
  draft_reply      text,

  -- Traçabilité (requis par l'énoncé)
  raw_email        text not null,
  created_at       timestamptz not null default now(),

  -- Date calendaire pour la dédup (voir index plus bas).
  -- On la matérialise comme colonne `date` plutôt que de la calculer dans
  -- l'index : le cast `timestamptz -> date` est STABLE (dépend du fuseau
  -- de session), donc interdit dans une expression d'index.
  -- `default current_date` est évalué à l'insert — OK même si STABLE.
  email_date       date not null default current_date
);

-- Ajout de la colonne si la table existait déjà (idempotent)
alter table public.leads
  add column if not exists draft_reply text;

comment on table  public.leads                 is 'Leads Immoweb/Immovlan extraits par le pipeline n8n + Claude.';
comment on column public.leads.score_confiance is 'Score 0–1 produit par le LLM. < 0.3 = email incomplet, à relire.';
comment on column public.leads.raw_email       is 'Email brut complet, conservé pour audit et relance LLM si besoin.';
comment on column public.leads.email_date      is 'Date calendaire d''insertion, utilisée pour la déduplication (email+bien+jour).';


-- Si la table existait déjà d'un premier run partiel, on ajoute la colonne.
alter table public.leads
  add column if not exists email_date date not null default current_date;


-- -----------------------------------------------------------------------------
-- 2. Index de déduplication (bonus)
-- -----------------------------------------------------------------------------
-- Règle : même prospect_email + même bien_reference + même jour = doublon.
-- Index partiel : ne s'applique que si les deux clés sont présentes.
-- Un email incomplet sans référence n'est donc jamais bloqué par la contrainte.

drop index if exists public.leads_dedup_idx;

create unique index leads_dedup_idx
  on public.leads (prospect_email, bien_reference, email_date)
  where prospect_email is not null
    and bien_reference is not null;


-- -----------------------------------------------------------------------------
-- 3. Table d'audit : processing_log
-- -----------------------------------------------------------------------------
-- Journal de ce que le pipeline a fait pour chaque email entrant.
-- Utile pour répondre à "pourquoi cet email n'est pas dans leads ?".

create table if not exists public.processing_log (
  id          uuid primary key default gen_random_uuid(),
  action      text not null check (action in (
                'inserted',           -- inséré dans leads
                'skipped_duplicate',  -- doublon détecté (email+bien+jour)
                'parse_error',        -- JSON invalide retourné par le LLM
                'unknown_sender'      -- expéditeur filtré avant LLM
              )),
  lead_id     uuid references public.leads(id) on delete set null,
  raw_email   text,
  notes       text,
  created_at  timestamptz not null default now()
);

create index if not exists processing_log_action_idx
  on public.processing_log (action, created_at desc);


-- -----------------------------------------------------------------------------
-- 4. Observabilité : incomplete_leads_log
-- -----------------------------------------------------------------------------
-- Capture les emails à score_confiance < 0.3 pour revue humaine.
-- On n'empêche PAS l'insertion dans `leads` (l'énoncé demande qu'Email 4
-- produise un JSON partiel), mais on les duplique ici pour qu'une personne
-- puisse les filtrer facilement.

create table if not exists public.incomplete_leads_log (
  id              uuid primary key default gen_random_uuid(),
  lead_id         uuid references public.leads(id) on delete cascade,
  raw_email       text not null,
  partial_json    jsonb,
  score_confiance numeric(3,2),
  created_at      timestamptz not null default now()
);

create index if not exists incomplete_leads_log_created_idx
  on public.incomplete_leads_log (created_at desc);


-- -----------------------------------------------------------------------------
-- 5. Politique RLS (recommandé)
-- -----------------------------------------------------------------------------
-- On active RLS pour respecter les bonnes pratiques Supabase.
-- Le workflow n8n utilise la SERVICE_ROLE_KEY, qui bypass RLS.
-- Les éventuels front-ends publics ne pourront rien lire sans policy explicite.

alter table public.leads                enable row level security;
alter table public.processing_log       enable row level security;
alter table public.incomplete_leads_log enable row level security;

-- Aucune policy par défaut : accès uniquement via service role.
-- Pour exposer un tableau de bord côté client plus tard, créer des policies
-- dédiées (ex : select where agency_id = auth.uid() si multi-tenant).


-- -----------------------------------------------------------------------------
-- 6. Vérifications rapides
-- -----------------------------------------------------------------------------
-- Après exécution, ces requêtes doivent renvoyer les 3 tables et 1 index.

-- select table_name from information_schema.tables
--   where table_schema = 'public'
--     and table_name in ('leads','processing_log','incomplete_leads_log');

-- select indexname from pg_indexes
--   where schemaname = 'public' and tablename = 'leads';
