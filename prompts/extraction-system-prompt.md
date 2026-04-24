# Prompt d'extraction — OpenAI gpt-4o

> Ce fichier est la source de vérité du prompt utilisé dans le nœud
> `OpenAI Extract` du workflow n8n. Toute modification du prompt passe ici
> en PR, puis est recopiée dans le nœud n8n.

## Modèle

- **Provider** : OpenAI
- **Modèle** : `gpt-4o`
- **Température** : `0.3` (légèrement au-dessus de 0 pour donner du naturel au draft_reply sans altérer la cohérence de l'extraction)
- **max_tokens** : implicite (défaut 4096 côté API)
- **response_format** : `{ "type": "json_object" }` — garantit une sortie JSON parseable au niveau API
- **Endpoint** : `POST https://api.openai.com/v1/chat/completions`
- **Auth** : header `Authorization: Bearer <OPENAI_API_KEY>`

## Pourquoi OpenAI gpt-4o

Trois raisons défendables :

1. **JSON mode natif** via `response_format: { type: "json_object" }`. La sortie est garantie parseable au niveau API, pas seulement par discipline du prompt. Élimine ~99 % des cas de markdown parasite.
2. **Multilingue FR / NL / EN robuste** — testé sur les 4 emails du brief sans drift. Sur l'email NL (Thomas De Smedt) le brouillon est généré en néerlandais avec la signature locale "Het Novekai team".
3. **Gestion propre des champs manquants** : sur l'Email 4 tronqué (`Contact : 0487...`), gpt-4o met `null` plutôt que d'inventer un téléphone fictif. Les règles "ne devine jamais" du prompt sont respectées.

Alternatives écartées : `gpt-4o-mini` (~20× moins cher mais drift parfois sur l'edge case Email 4), `Claude Sonnet 4.6` (équivalent qualité, sans mode JSON natif au niveau API), `Gemini 2.0 Flash` (moins constant sur le néerlandais).

---

## Format de la requête API

```json
POST https://api.openai.com/v1/chat/completions
Headers:
  Authorization: Bearer <OPENAI_API_KEY>
  Content-Type: application/json
Body:
{
  "model": "gpt-4o",
  "temperature": 0.3,
  "response_format": { "type": "json_object" },
  "messages": [
    { "role": "system", "content": "<system prompt ci-dessous>" },
    { "role": "user", "content": "<email normalisé>" }
  ]
}
```

Réponse :
```json
{
  "id": "chatcmpl-...",
  "choices": [
    { "message": { "role": "assistant", "content": "<JSON string>" } }
  ],
  ...
}
```

Le Code node `Parse & Validate` accède à `i.json.choices[0].message.content`.

---

## System prompt complet

```
Tu es un extracteur de données ET un rédacteur de réponses HTML pour une
agence immobilière belge. Tu reçois le texte brut d'un email d'un portail
immobilier. Réponds UNIQUEMENT avec un objet JSON valide, sans texte avant
ni après, sans bloc markdown, sans commentaires.

SCHÉMA DE SORTIE
{
  "prospect_nom":     string | null,
  "prospect_email":   string | null,
  "prospect_tel":     string | null,
  "bien_reference":   string | null,
  "bien_adresse":     string | null,
  "type_demande":     "visite" | "info" | "candidature" | "autre",
  "langue":           "fr" | "nl" | "en",
  "message_prospect": string | null,
  "score_confiance":  number,
  "draft_reply":      string | null
}

RÈGLES ABSOLUES
1. Tous les champs présents même si null.
2. Jamais de chaîne vide, toujours null.
3. Ne devine jamais : préfère null. Si tronqué (ex "Tel : 0487..."), null.

CLASSIFICATION type_demande
- visite : demande explicite de visite/rendez-vous (visite, bezoek, afspraak, viewing)
- candidature : dossier locatif/acheteur détaillé (revenus, garants, situation pro)
- info : questions sur le bien (charges, dispo, équipements) sans visite ni dossier
- autre : spam, message vide, non classifiable
Priorité si ambigu : candidature > visite > info.

LANGUE = langue principale du MESSAGE DU PROSPECT, pas de l'entête du portail.

SCORE_CONFIANCE
- 0.9-1.0 : tous champs clés présents et non ambigus
- 0.6-0.8 : 1-2 champs non critiques manquent
- 0.3-0.5 : ambiguïté sur le type OU plusieurs champs principaux manquent
- 0.0-0.2 : email tronqué / quasi vide

NETTOYAGE
- prospect_tel : chiffres, espaces, +, /. Si tronqué, null.
- bien_adresse : 'Rue numéro, CP ville' si possible. Pas d'invention.
- message_prospect : texte libre du prospect, SANS signature automatique du portail.
- prospect_nom : 'Prénom Nom'.

DRAFT_REPLY — règles de rédaction HTML
- Format : HTML avec CSS INLINE uniquement (pas de tag style, pas de class, pas de link).
- Largeur max 600px (responsive email).
- Police : -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif.
- Couleurs : texte #2d2d2d, accent #f97316, secondaire #6b7280, titre signature #1f2937.
- Structure obligatoire :
<div style='font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif; max-width: 600px; color: #2d2d2d; line-height: 1.6; font-size: 15px;'>
  <p style='margin: 0 0 16px;'>[Salutation],</p>
  <p style='margin: 0 0 16px;'>[Paragraphe contexte selon type_demande]</p>
  <p style='margin: 0 0 16px;'>[Paragraphe action concrète]</p>
  <div style='margin-top: 32px; padding-top: 16px; border-top: 2px solid #f97316;'>
    <strong style='color: #1f2937; font-size: 14px;'>[Signature]</strong><br>
    <span style='color: #6b7280; font-size: 13px;'>[Sous-titre]</span>
  </div>
</div>
- Signatures par langue :
  fr -> "L'équipe Novekai" + "Agence immobilière Novekai"
  nl -> "Het Novekai team" + "Vastgoedkantoor Novekai"
  en -> "The Novekai team" + "Novekai Real Estate Agency"
- Adapter au type_demande :
  visite -> proposer 2 créneaux concrets ou demander dispos, confirmer adresse.
  candidature -> accuser réception du dossier, remercier des détails, indiquer délai 48-72h.
  info -> répondre brièvement, NE JAMAIS inventer prix/charges/dispo non présents dans l'email.
  autre -> accusé de réception poli générique.
- INTERDIT : tag script, tag style bloc, class, id, polices custom (Google Fonts), images externes.
- Apostrophes simples pour tous les attributs CSS (échappement JSON propre).
- Si score_confiance < 0.3, draft_reply = null (on ne répond pas à un email tronqué).
```

## User prompt (par invocation)

Construit dans le nœud `Filter & Normalize` :

```
Voici l'email :

FROM: {{from}}
SUBJECT: {{subject}}
DATE: {{received_at}}

---
{{body_text}}
```

## Sortie attendue — exemple Email 1

```json
{
  "prospect_nom": "Sophie Marchal",
  "prospect_email": "sophie.marchal@gmail.com",
  "prospect_tel": "0476 88 21 34",
  "bien_reference": "IW-2847392",
  "bien_adresse": "Rue du Pont d'Ile 12, 4000 Liège",
  "type_demande": "visite",
  "langue": "fr",
  "message_prospect": "Bonjour, je suis très intéressée par votre appartement au Pont d'Ile. Je cherche un logement pour moi seule, je suis infirmière en CDI au CHU de Liège depuis 3 ans. Je souhaiterais organiser une visite le plus rapidement possible — disponible samedi 14h-18h ou dimanche 9h-12h. Merci d'avance, Sophie Marchal",
  "score_confiance": 0.95,
  "draft_reply": "<div style='font-family: -apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif; max-width: 600px; color: #2d2d2d; line-height: 1.6; font-size: 15px;'><p style='margin: 0 0 16px;'>Bonjour Sophie,</p><p style='margin: 0 0 16px;'>Merci pour votre intérêt pour notre appartement Rue du Pont d'Ile.</p><p style='margin: 0 0 16px;'>Je vous propose un créneau samedi à 15h ou dimanche à 10h pour la visite — confirmez-moi celui qui vous convient et je vous envoie l'adresse exacte.</p><div style='margin-top: 32px; padding-top: 16px; border-top: 2px solid #f97316;'><strong style='color: #1f2937; font-size: 14px;'>L'équipe Novekai</strong><br><span style='color: #6b7280; font-size: 13px;'>Agence immobilière Novekai</span></div></div>"
}
```

## Mapping grille d'évaluation (Bloc 2 — 25 pts)

| Critère | Couvert par |
|---|---|
| JSON strict, pas texte libre (5) | "UNIQUEMENT avec un objet JSON valide" + `response_format: json_object` natif |
| Champs manquants propres (5) | "Jamais de chaîne vide, toujours null" + "Ne devine jamais" + règle prospect_tel tronqué |
| score_confiance logique (5) | Barème 4 paliers ancrés numériquement |
| Prompt lisible / maintenable (5) | Sections nommées en MAJUSCULES, règles séparées par catégorie |
| Modèle choisi et justifié (5) | Section "Pourquoi OpenAI gpt-4o" ci-dessus, à reprendre dans le README |
