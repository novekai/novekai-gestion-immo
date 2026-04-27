# novekai-immo-test

Pipeline automatisé qui surveille une boîte Gmail, capte les notifications des portails immobiliers belges (Immoweb, Immovlan), extrait les informations du prospect via un LLM, stocke le résultat dans Supabase, et prépare automatiquement un brouillon de réponse HTML stylé directement dans le thread Gmail original.

**Stack** : n8n (orchestration) · OpenAI gpt-4o avec JSON mode natif (extraction JSON + rédaction HTML) · Supabase PostgreSQL (persistance).

**Test technique — Développeur IA — Avril 2026.**

---

## Workflow

[Export JSON](./workflow/novek-immo-2.json)

15 nœuds, principalement `Code` + `HTTP Request` côté logique custom, avec un `Gmail Trigger` natif pour le déclenchement. Le workflow appelle directement l'API REST de Supabase (PostgREST), l'API Chat Completions d'OpenAI et l'API Drafts de Gmail plutôt que de passer par les connecteurs natifs — choix volontaire pour garder le contrôle total sur les payloads et démontrer la maîtrise des APIs sous-jacentes. Crée un brouillon Gmail HTML stylé dans le thread d'origine.

---

## Setup (< 5 minutes)

### Pré-requis

- Compte Gmail sur lequel reçoivent les notifications Immoweb/Immovlan
- Projet Supabase
- Clé API OpenAI (https://platform.openai.com/api-keys)
- Instance n8n (self-hosted ou Cloud)

### Étape 1 — Cloner et configurer

```bash
git clone https://github.com/<ton-compte>/novekai-immo-test.git
cd novekai-immo-test
cp .env.example .env
# éditer .env avec les vraies valeurs
```

### Étape 2 — Créer le schéma Supabase

Dans le dashboard Supabase → `SQL Editor` → coller `supabase/schema.sql` → `Run`. Le script est idempotent, on peut le rejouer sans casser.

Vérification :
```sql
select table_name from information_schema.tables
where table_schema = 'public'
  and table_name in ('leads', 'processing_log', 'incomplete_leads_log');
```
Doit renvoyer 3 lignes.

### Étape 3 — Créer les credentials n8n

Dans n8n → `Credentials` → `New` :

| Credential | Type | Configuration |
|---|---|---|
| `Gmail account novekai` | Gmail OAuth2 | Suivre le flow OAuth2 Google. **Scope requis** : `gmail.modify` (pour créer des brouillons) |
| `OpenAI API` | HTTP Header Auth | `Name: Authorization` / `Value: Bearer <OPENAI_API_KEY>` |
| `Supabase Novekai` | Supabase API | `Host: <SUPABASE_URL>` / `Service Role Secret: <SUPABASE_SERVICE_ROLE_KEY>` |

### Étape 4 — Importer le workflow

`Workflows` → `Import from File` → sélectionner `workflow/novek-immo-2.json`. Sur chaque nœud flagué "credentials missing", sélectionner la credential correspondante créée à l'étape 3.

### Étape 5 — Activer et tester

Toggle `Active` en haut à droite du workflow. Envoyer l'un des emails de `tests/email-0X.txt` à l'adresse Gmail surveillée (le plus simple : copier-coller dans un nouveau mail). Le workflow déclenche dans la minute.

Vérifier dans Supabase :
```sql
select id, prospect_nom, prospect_email, type_demande, langue, score_confiance, draft_reply, created_at
from leads order by created_at desc limit 4;
```

Vérifier dans Gmail : ouvrir le thread du mail entrant — un brouillon de réponse HTML stylé apparaît directement sous l'email d'origine, prêt à éditer/envoyer.

---

## Architecture

```
Gmail Trigger ─▶ Filter & Normalize (Code) ─▶ OpenAI Extract (HTTP) ─▶ Parse & Validate (Code)
                                            ─▶ Check Duplicate (HTTP REST)
                                            ─▶ Decide Route (Code)
                                                 ├─▶ Filter: Insert ─▶ Insert Lead (HTTP REST) ─┬─▶ Filter: Low Confidence ─▶ Log Incomplete
                                                 │                                              └─▶ Filter: Has Draft ─▶ Build RFC822 ─▶ Create Gmail Draft
                                                 └─▶ Filter: Duplicate ─▶ Log Duplicate
```

### Principes de design

- **Filtrer tôt** : filtre Gmail côté serveur (économise tokens et runs) + Code node `Filter & Normalize` qui rejette les expéditeurs non reconnus avant tout appel coûteux.
- **Valider après** : Code node `Parse & Validate` parse le JSON dans un try/catch, valide les enums via `Set.has()`, clamp le score sur [0, 1], retombe gracieusement sur null si parse échoue. **Jamais de throw — le workflow ne plante jamais.**
- **Dédup double filet** : pré-check applicatif (HTTP GET sur Supabase) + index unique partiel en base. L'index est partiel (`where prospect_email is not null and bien_reference is not null`) pour ne pas bloquer les emails tronqués.
- **Idempotence** : Gmail marque les emails "lus" après lecture par l'API ; le `readStatus: unread` filter garantit qu'on ne traite chaque mail qu'une seule fois.
- **Routing par filtres Code** plutôt que IF nodes — chaque filtre `Filter: X` retourne `[]` quand sa condition n'est pas remplie, ce qui stoppe naturellement la branche downstream.

Détails complets dans [`docs/architecture.md`](./docs/architecture.md).

---

## Choix techniques

### Pourquoi OpenAI gpt-4o

Trois raisons défendables :

1. **JSON mode natif** via `response_format: { type: "json_object" }`. La sortie est garantie parseable au niveau API, pas seulement par discipline du prompt. Élimine ~99 % des cas de markdown parasite sans nécessiter un fallback complexe côté Parse & Validate.
2. **Multilingue FR / NL / EN robuste** — testé sur les 4 emails du brief sans drift. Sur l'email NL (Thomas De Smedt) le brouillon est généré en néerlandais avec la signature locale "Het Novekai team".
3. **Gestion propre des champs manquants** : sur l'Email 4 tronqué (`Contact : 0487...`), gpt-4o met `null` plutôt que d'inventer un téléphone fictif. Les règles "ne devine jamais" du prompt sont respectées.

Alternatives écartées : `gpt-4o-mini` (~20× moins cher mais drift parfois sur l'edge case Email 4), `Claude Sonnet 4.6` (équivalent qualité, sans mode JSON natif au niveau API), `Gemini 2.0 Flash` (moins constant sur le néerlandais).

Prompt système complet versionné dans [`prompts/extraction-system-prompt.md`](./prompts/extraction-system-prompt.md).

### Pourquoi appeler Supabase et OpenAI en HTTP raw

Les nodes natifs n8n sont confortables mais opaques. En passant par HTTP Request direct vers les APIs (PostgREST pour Supabase, `/v1/chat/completions` pour OpenAI, `/gmail/v1/users/me/drafts` pour Gmail), on garde un contrôle total sur les payloads, on peut ajuster `temperature`, `response_format`, ou changer de modèle en modifiant un seul mot du body. C'est aussi plus stable dans le temps : les nodes natifs évoluent et cassent parfois la rétrocompatibilité, les endpoints HTTP non.

### Pourquoi le brouillon HTML dans le thread Gmail

Stocker `draft_reply` en DB n'est utile que si l'agent fait du copier-coller. Créer un vrai brouillon Gmail attaché au thread d'origine permet à l'agent d'ouvrir Gmail, voir le brouillon directement sous l'email du prospect, l'éditer si besoin, cliquer "Envoyer". Friction réduite à zéro.

Le HTML utilise du CSS inline uniquement (`font-family`, `color`, `border-top` orange #f97316 pour la signature) — compatible avec tous les clients email modernes. Polices système modernes (-apple-system / Segoe UI / Helvetica). Largeur max 600px (mobile-friendly).

---

## Schéma Supabase — 3 tables

| Table | Rôle | Volume relatif |
|---|---|---|
| `leads` | Source de vérité métier — l'agent immo la consulte tous les matins | 100 % des emails valides |
| `processing_log` | Audit technique : trace toutes les décisions du pipeline (`inserted`, `skipped_duplicate`, `parse_error`, `unknown_sender`) | 100 % des événements |
| `incomplete_leads_log` | File de retraitement humain pour `score_confiance < 0.3` | 5-10 % des leads |

### Choix de design

- **`numeric(3,2)`** pour `score_confiance` — précis, borné par CHECK, pas de float imprécis.
- **`CHECK` sur les enums** (`type_demande`, `langue`, `action`) — un LLM qui hallucine un enum hors liste se fait rejeter en base. Triple filet : LLM + Code + DB.
- **`raw_email text not null`** — traçabilité totale, sans limite de taille.
- **Index unique partiel `leads_dedup_idx`** sur `(prospect_email, bien_reference, email_date)` — n'applique la contrainte que si les deux clés sont présentes. Filet contre les race conditions.
- **Colonne `email_date date default current_date`** matérialisée pour l'index — le cast `timestamptz::date` est marqué STABLE par Postgres, interdit dans une expression d'index. La colonne dérivée contourne la limite proprement.
- **RLS activé sur les 3 tables**, sans policies → tout accès via `anon key` est refusé, seul `service_role` (utilisé par n8n) peut écrire/lire. Hygiène pour future exposition front-end.

DDL complet dans [`supabase/schema.sql`](./supabase/schema.sql).

---

## Bonus implémentés

Les **3 bonus listés dans le brief** sont tous implémentés :

✅ **Déduplication** (email + bien + jour) — index unique partiel + pré-check applicatif. Si le même prospect écrit 2 fois pour le même bien le même jour, la 2e exécution route vers `processing_log` avec `action = 'skipped_duplicate'`.

✅ **Brouillon de réponse adapté au type+langue** — champ `draft_reply` généré par GPT-4o dans la même requête que l'extraction. Adapté au `type_demande` :
- `visite` → propose 2 créneaux concrets, demande confirmation
- `candidature` → accuse réception du dossier, indique délai 48-72h
- `info` → réponse générique sans inventer de faits, invite à visite
- `autre` → accusé de réception poli

Signature localisée (`L'équipe Novekai` / `Het Novekai team` / `The Novekai team`). HTML stylé avec CSS inline. `null` si `score < 0.3` (on ne répond pas à un email qu'on ne comprend pas).

✅ **Logs / observabilité** — `processing_log` pour l'audit complet du pipeline, `incomplete_leads_log` pour les emails à faible confiance qui méritent une revue humaine.

**Bonus en plus du brief** : création automatique du brouillon dans Gmail attaché au thread original, prêt à éditer/envoyer. L'agent n'a plus aucun copier-coller à faire.

Extension prévue mais non implémentée :
- Webhook d'alerte externe (Slack / Discord) sur les emails à `score < 0.3`. Variable `ALERT_WEBHOOK_URL` prévue dans `.env.example`.

---

## Sécurité (critère éliminatoire)

**Aucune clé n'est commitée dans le repo.**

- `.env` exclu via `.gitignore`
- Workflow JSON exporté avec credentials vidés (placeholders `REPLACE_WITH_YOUR_..._CREDENTIAL_ID`). Les vraies credentials vivent dans la base n8n locale, chiffrées par n8n.
- `SUPABASE_SERVICE_ROLE_KEY` documentée comme "côté serveur uniquement" — bypass RLS, ne jamais exposer côté client.
- RLS activé par défaut sur les 3 tables Supabase.

Vérification post-clone :
```bash
git grep -n "sk-proj-"
git grep -n "sk-ant-"
git grep -n "eyJhbGciOi"
```
Doit ne rien renvoyer.

---

## Les 4 emails de test

| Email | Langue | Cas | Attendu |
|---|---|---|---|
| 01 — Sophie Marchal (Immoweb) | fr | Visite standard | Tous champs remplis, `type=visite`, score ≥ 0.9, brouillon FR avec créneaux |
| 02 — Thomas De Smedt (Immoweb) | nl | Questions multiples (charges, parking, animaux, dispo) | `langue=nl`, `type=info`, brouillon NL signé "Het Novekai team" |
| 03 — Léa Fontaine (Immovlan) | fr | Candidature complète avec garant | `type=candidature` (priorité sur info), brouillon FR avec délai 48-72h |
| 04 — Email tronqué | fr | Robustesse | JSON partiel avec nulls, `type=autre`, `score < 0.3`, log dans `incomplete_leads_log`, **pas de brouillon** |

Sources : [`tests/email-01-immoweb-fr.txt`](./tests/email-01-immoweb-fr.txt) … [`tests/email-04-incomplete.txt`](./tests/email-04-incomplete.txt).
Sortie attendue : [`tests/expected-outputs.json`](./tests/expected-outputs.json) (tolérance ±0.1 sur le score, formulation libre sur les textes).

---

## Process de développement

(Section dédiée au Bloc 4 de la grille d'évaluation — le Loom dérive de cette structure.)

**Outils utilisés** :
- **n8n self-hosted** Novekai pour l'orchestration
- **OpenAI gpt-4o** pour l'extraction et la rédaction (justifié plus haut)
- **Supabase** pour la persistance (Postgres + PostgREST + RLS)
- **Figma / FigJam** pour le diagramme de logique du workflow et la documentation visuelle
- **Postman / curl** pour tester les endpoints REST en isolation avant intégration

**Ce qui a bien marché du premier coup** :
- La discipline JSON par prompt strict + le `Parse & Validate` Code node en filet de sécurité éliminent quasiment tous les cas d'erreur de parsing — pas besoin d'ajouter une boucle de retry sur le LLM.
- Le pattern 3 tables Supabase (vérité / audit / queue) rend chaque requête naturelle : `select * from incomplete_leads_log` pour la revue humaine, `select * from processing_log where action = 'skipped_duplicate'` pour l'audit dédup. Pas de filtres complexes.
- La logique de filtres en Code node (`return $input.all().filter(...)`) plutôt qu'IF natifs : plus lisible quand on lit le workflow, et zéro problème de routing en mode test.

**Ce qu'il a fallu retravailler** :
- **Index unique sur la dédup** : Postgres a refusé `(prospect_email, bien_reference, (created_at::date))` parce que le cast `timestamptz::date` est marqué STABLE pas IMMUTABLE. Résolu en matérialisant une colonne `email_date date default current_date` qu'on indexe directement.
- **Pré-check de dédup qui s'arrête sans output** : la requête HTTP GET vers PostgREST renvoie un tableau `[]` quand rien n'est trouvé, ce qui peut bloquer le flow downstream. Fixé en activant `fullResponse: true` sur le HTTP node : la réponse est wrappée dans `{body, headers, statusCode}`, donc 1 item garanti même quand `body` est vide.
- **Bug subtil de batch processing avec `.first()`** : les Code nodes utilisaient `$('NodeName').first()` qui retourne TOUJOURS le premier item, ignorant le tracking par paire entre items. En batch multi-emails, tous les leads se retrouvaient avec les données du premier mail. Refactor en accès indexé via `pairedItem.item` pour respecter la pairing n8n.
- **Colonne `draft_reply` ajoutée à chaud** : ajout du bonus brouillon en cours de route. L'erreur `PGRST204 Could not find the 'draft_reply' column` a forcé un `notify pgrst, 'reload schema'` pour rafraîchir le cache PostgREST — détail Supabase à connaître.
- **Format du brouillon Gmail** : initialement `text/plain`, switché à `text/html` pour permettre du style. Une ligne dans le builder RFC822, mais ça a aussi nécessité d'étendre les règles de génération du `draft_reply` pour produire du HTML inline-CSS valide compatible avec tous les clients email (pas de `<style>`, pas de class, pas de polices custom).
- **Encodage RFC822 pour Gmail Drafts API** : l'API exige du base64url (variante de base64 avec `+` → `-`, `/` → `_`, padding `=` strippé). Pas évident au premier coup d'œil, mais c'est documenté dans la doc Gmail API. Code de 3 lignes une fois compris.

---

## Structure du repo

```
novekai-immo-test/
├── README.md                          # Ce fichier
├── .env.example                       # Variables à renseigner
├── .gitignore                         # Exclut .env et tout credential
├── workflow/
│   └── novek-immo-2.json              # Workflow n8n exporté (credentials vidés)
├── supabase/
│   └── schema.sql                     # DDL idempotent : 3 tables + index dédup + RLS
├── prompts/
│   └── extraction-system-prompt.md    # Prompt OpenAI versionné hors JSON n8n
├── tests/
│   ├── email-01-immoweb-fr.txt
│   ├── email-02-immoweb-nl.txt
│   ├── email-03-immovlan-fr.txt
│   ├── email-04-incomplete.txt
│   └── expected-outputs.json          # JSON attendus pour vérification manuelle
└── docs/
    └── architecture.md                # Décisions techniques détaillées
```

---

## Robustesse / error handling

Tous les nœuds critiques ont un **retry + error output** branché vers la table `processing_log` :

| Nœud | Retry | Error handler |
|---|---|---|
| OpenAI Extract | 3 essais, backoff 5s | `Log OpenAI Failure` → `processing_log` |
| Insert Lead (REST) | 3 essais, backoff 3s | `Log Insert Failure` → `processing_log` |
| Create Gmail Draft | 2 essais, backoff 5s | `Log Draft Failure` → `processing_log` |

Pour le filet de sécurité ultime, un workflow séparé **`Error Handler — Novek immo`** (ID `DWWTNDsNPYCztTDb`) capte tous les crashes non gérés via un `Error Trigger` et les log dans `processing_log` avec contexte (workflow, nœud, message d'erreur, exec id). À configurer comme Error Workflow de Novek immo2 dans Settings → Error Workflow.

Le `Decide Route` a aussi des **gardes défensives** : si `prospect_email` est null ou si Supabase REST renvoie un statusCode ≥ 400, on route vers `insert` (mieux un doublon potentiel qu'un lead perdu). Le `Filter: Low Confidence` extrait le `lead_id` de manière défensive (`Array.isArray(body) ? body[0].id : body.id`) pour gérer les variations de réponse PostgREST.

## Limitations connues / améliorations futures

- **Tests automatisés