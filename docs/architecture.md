# Architecture — novekai-immo-test

Document technique : décisions, schémas, gestion d'erreurs.
Le README reste le point d'entrée. Ici, on va dans le détail.

---

## Vue d'ensemble

```
Gmail ─▶ [1] Gmail Trigger
           │
           ▼
        [2] IF Sender Allowed ──── non ──▶ fin silencieuse
           │ oui
           ▼
        [3] Normalize Email
           │
           ▼
        [4] Extract with OpenAI (HTTP Request → OpenAI API)
           │
           ▼
        [5] Parse & Validate (Code JS)
           │
           ▼
        [6] Check Duplicate (Supabase select)
           │
           ▼
        [7] IF Not Duplicate ─── non ──▶ [8b] Log Duplicate
           │ oui                             (processing_log)
           ▼
        [8a] Insert Lead (Supabase insert → leads)
           │
           ▼
        [9] IF Low Confidence (score < 0.3)
           │ oui
           ▼
        [10] Log Incomplete (Supabase insert → incomplete_leads_log)
```

---

## 1. Gmail Trigger

- **Type** : `n8n-nodes-base.gmailTrigger`
- **Authentification** : Gmail OAuth2 (créée dans n8n, pas dans `.env`).
- **Polling** : toutes les 60 secondes.
- **Filtre côté Gmail** :
  `from:(noreply@immoweb.be OR notifications@immovlan.be OR no-reply@immovlan.be) newer_than:1d`

**Pourquoi filtrer côté Gmail plutôt que tout récupérer ?** Coût et
robustesse. Gmail fait le pré-filtrage gratuitement — on n'instancie pas
un workflow n8n (et on n'appelle pas Claude) pour un email de spam.
L'IF en sortie est un deuxième filet si Gmail envoie du bruit.

---

## 2. IF Sender Allowed

- **Type** : `n8n-nodes-base.if`
- **Condition** : `from CONTAINS "immoweb.be"` OR `from CONTAINS "immovlan.be"`
- **Branche false** : pas connectée → fin silencieuse, pas d'erreur.

C'est un "belt and suspenders". Le filtre Gmail peut laisser passer un
forward, un `Reply-To` différent, etc. L'IF attrape ça.

---

## 3. Normalize Email

- **Type** : `n8n-nodes-base.set`
- **Sortie** (schéma) :

```ts
{
  from: string,         // adresse expéditeur résolue
  subject: string,      // objet ou "(sans objet)" si absent
  received_at: string,  // ISO timestamp
  body_text: string,    // body HTML-stripped, trimmed
  raw_email: string,    // concaténation complète pour audit Supabase
}
```

Le strip HTML est minimal (`replace(/<[^>]+>/g, '')`). Ça suffit pour des
emails transactionnels simples comme ceux d'Immoweb/Immovlan. Si un jour
on tombe sur des templates avec inline CSS / images base64, on passera
par `html-to-text` dans un Code node.

---

## 4. Extract with OpenAI

- **Type** : `n8n-nodes-base.httpRequest`
- **Auth** : `httpHeaderAuth` avec header `Authorization` = `Bearer <OPENAI_API_KEY>`
- **Body JSON** :

```json
{
  "model": "gpt-4o",
  "temperature": 0,
  "response_format": { "type": "json_object" },
  "messages": [
    { "role": "system", "content": "<voir prompts/extraction-system-prompt.md>" },
    { "role": "user", "content": "<email normalisé>" }
  ]
}
```

- **Options** : timeout 30 s.

**Pourquoi un HTTP Request et pas le nœud OpenAI natif ?** Contrôle total
sur le payload (on peut ajuster `temperature`, `response_format`, passer
à gpt-4o-mini sans toucher à la glue), et compatibilité avec toutes les
versions d'n8n. Le nœud natif évolue et parfois casse rétro-compatibilité.

**Pourquoi `response_format: json_object` ?** OpenAI force la sortie à être
un JSON parseable au niveau API, ce qui supprime les cas "le modèle a
ajouté du markdown ou une explication". Le Code node de validation reste
en filet de sécurité au cas où.

---

## 5. Parse & Validate

- **Type** : `n8n-nodes-base.code` (JavaScript)

Logique :

1. Récupérer `choices[0].message.content` de la réponse OpenAI.
2. `try/catch` un `JSON.parse` — avec fallback : si le modèle a entouré de
   ` ```json ... ``` ` (edge case très rare avec `response_format` activé,
   mais on reste défensif), on retire les fences.
3. Normaliser : forcer la présence des 10 champs, clamp `score_confiance`
   à `[0,1]`, rejeter les valeurs d'enum hors liste en retombant sur
   `autre` / `fr`.
4. Si parse échoue ou si `content` absent : retourner un objet vide
   (tous nulls, score 0) avec un champ `_parse_error` pour l'audit.
   **Pas de throw** — le workflow ne doit jamais s'arrêter en erreur dure.

Pourquoi en Code plutôt qu'en Set/IF : la logique de validation est
verbose (plusieurs champs, enums), Code est beaucoup plus lisible qu'une
chaîne de 10 Set/IF.

---

## 6. Check Duplicate

- **Type** : `n8n-nodes-base.supabase` (operation `getAll`)
- **Table** : `leads`
- **Filtres** (AND) :
  - `prospect_email = {{ $json.prospect_email }}`
  - `bien_reference = {{ $json.bien_reference }}`
  - `email_date = {{ today }}`
- **Limit** : 1, returnAll false.

Si `prospect_email` ou `bien_reference` est null, ce select ne matchera
jamais (égalité à NULL en SQL standard = false). L'IF suivant route donc
vers "Insert Lead", et l'index unique partiel en base ne s'applique pas
non plus (clause `where prospect_email is not null and bien_reference is
not null`). Comportement cohérent : un email incomplet n'est pas considéré
comme doublon.

`alwaysOutputData: true` pour que l'IF reçoive bien un item même si la
query ne matche rien (évite les "no data to process").

---

## 7-8. IF Not Duplicate → Insert Lead / Log Duplicate

Simple routage. Si `Check Duplicate` renvoie un item avec un `id` non vide
→ doublon, on passe à `Log Duplicate`. Sinon, `Insert Lead`.

Champs insérés dans `leads` : les 10 du JSON + `raw_email`. Pas besoin de
préciser `created_at` ni `email_date` — les DEFAULT en SQL s'en occupent.

---

## 9-10. IF Low Confidence → Log Incomplete

Si `score_confiance < 0.3`, on ajoute une ligne dans `incomplete_leads_log`
avec le JSON partiel sérialisé en `jsonb`. Le lead est quand même dans
`leads` (l'énoncé demande qu'Email 4 produise un JSON partiel dans la
sortie du workflow), mais on le flagge pour revue humaine.

---

## Gestion d'erreurs — récap

| Scénario | Comportement |
|----------|-------------|
| Email d'un sender non prévu | Filtre Gmail + IF → fin silencieuse, pas d'appel LLM |
| OpenAI API 5xx / timeout | Timeout 30 s, n8n marque l'exécution en erreur (retry à configurer selon besoin) |
| OpenAI renvoie non-JSON | Très rare avec `response_format: json_object`. Code `Parse & Validate` → fallback objet null, pas de throw |
| OpenAI invente un enum (ex: `type_demande = "demande"`) | Code retombe sur `autre` ; si ça passait, CHECK Supabase rejetterait |
| Doublon (email+bien+jour) | Pré-check SELECT → branche `Log Duplicate`. Filet : index unique partiel |
| Tous les champs à null (email 4 tronqué) | Insert dans `leads` quand même + log séparé dans `incomplete_leads_log` |
| Supabase 5xx | Pas de retry configuré — le workflow remonte l'erreur et n8n log l'échec. À ajuster si la base est flaky. |

---

## Schéma Supabase — justifications

### Table `leads`

- `id uuid` avec `default gen_random_uuid()` : pas de dépendance à une séquence, génère côté DB.
- `score_confiance numeric(3,2)` : précis, borné par CHECK, pas de float imprécis.
- `type_demande`, `langue` : CHECK enum → refuse les hallucinations LLM.
- `raw_email text not null` : obligatoire par l'énoncé, taille non bornée (on n'a pas besoin de VARCHAR(N)).
- `created_at timestamptz default now()` : UTC, pas de timezone locale.
- `email_date date default current_date` : colonne matérialisée utilisée par l'index unique.
  Pourquoi pas `(created_at::date)` directement ? Parce que ce cast est
  marqué STABLE en PostgreSQL (dépend du fuseau de session), donc interdit
  dans une expression d'index. `current_date` dans un DEFAULT est évalué
  à l'insert, ce qui est OK.

### Index `leads_dedup_idx`

- `unique index (prospect_email, bien_reference, email_date) where prospect_email is not null and bien_reference is not null`
- Partiel : ne s'applique que si les deux clés sont présentes. Un email
  incomplet ne bloquera jamais une autre insertion.

### Table `processing_log`

- `action text check (action in (...))` — enum strict des actions possibles.
- `lead_id uuid references leads(id) on delete set null` — on garde la
  trace même si le lead est supprimé plus tard.
- Index `(action, created_at desc)` pour répondre rapidement à
  "les 20 derniers doublons" / "les parse_error des dernières 24h".

### Table `incomplete_leads_log`

- `lead_id uuid references leads(id) on delete cascade` : si on purge le
  lead, on purge le log. Le lead original reste dans `leads` (avec le
  `raw_email`) donc pas de perte d'information.
- `partial_json jsonb` : permet des requêtes type
  `select * where partial_json->>'type_demande' = 'visite'`.

### RLS

Activé sur les 3 tables, aucune policy par défaut. Seul le service_role
(utilisé par n8n) peut y accéder. Si on veut exposer un dashboard front-end
plus tard, on ajoute des policies explicites (ex : multi-tenant par
`agency_id`).

---

## Ce qui manque (et ce qu'on ferait ensuite)

- **Tests automatisés** : aujourd'hui le `tests/expected-outputs.json` est
  une référence pour vérif manuelle. Prochain pas : un script Node qui
  balance les 4 emails à un webhook n8n et compare la sortie JSON avec
  tolérance.
- **Brouillon de réponse** : bonus non retenu dans le scope. Extension
  naturelle — ajouter un second appel OpenAI après `Insert Lead` qui génère
  un draft selon `type_demande` et `langue`, stocké dans un champ
  `draft_reply` de `leads`.
- **Alerting externe** : variable `ALERT_WEBHOOK_URL` déjà dans `.env.example`,
  nœud HTTP à connecter après `Log Incomplete` pour pinger Slack / Discord
  sur les emails à score < 0.3.
- **Rate limiting** : à volume réel, probablement besoin d'un nœud de
  throttling avant l'appel OpenAI pour rester dans les quotas.
- **Observabilité** : aujourd'hui on a les logs n8n + les tables Supabase.
  Prochain pas : export metrics Prometheus ou une simple dashboard
  Grafana sur `processing_log`.
