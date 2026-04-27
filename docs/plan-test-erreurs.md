# Plan de test des erreurs — Novek immo2

Plan de tests pour valider que tous les error handlers fonctionnent comme prévu, après correction des sorties d'erreur.

## Préalables

Avant de lancer les tests, prépare :

- 1 email immo réel prêt à envoyer depuis ton Gmail perso (`badoumodeste957@gmail.com` → `novekai.team@gmail.com`) avec un sujet immo classique.
- Onglets ouverts :
  - n8n → onglet Executions de Novek immo2
  - Gmail novekai.team (Inbox + Brouillons)
  - Supabase Table Editor (`leads`, `processing_log`, `incomplete_leads_log`)
- Notepad pour copier/coller les credentials OpenAI et Supabase actuels (pour les remettre après les tests T2-T4).

Pour chaque test : note ✅ ou ❌ dans la colonne Résultat.

---

## T1 — Happy path (baseline)

| | |
|---|---|
| **Objectif** | Vérifier qu'un email normal traverse tout sans déclencher AUCUN log d'erreur |
| **Action** | Envoie 1 email Immoweb-style avec nom + email + tel + bien_reference + message clair |
| **Attendu** | • 1 ligne dans `leads` (score ≥ 0.6, draft_reply non null)<br>• 1 brouillon HTML stylé dans Gmail Brouillons<br>• `processing_log` : aucune nouvelle entrée<br>• `incomplete_leads_log` : aucune nouvelle entrée<br>• Aucun email "ALERTE" dans novekai.team |
| **Résultat** | ☐ |

C'est le test qui confirme que la correction du bug a bien fonctionné. Si tu reçois encore "ALERTE Brouillon Gmail rate" ici → la correction n'est pas appliquée.

---

## T2 — OpenAI Extract failure (clé invalide)

| | |
|---|---|
| **Objectif** | Vérifier que le retry + Log OpenAI Failure fonctionne |
| **Action** | 1. Va dans Credentials → "OpenAI HTTP Header Auth" → édite la valeur du header Authorization → remplace par `Bearer sk-FAKE`<br>2. Sauvegarde<br>3. Envoie 1 email immo |
| **Attendu** | • Dans Executions : OpenAI Extract montre 3 essais (retry x3) en rouge<br>• L'execution est marquée Success (pas Failed) car onError continueErrorOutput<br>• `processing_log` : nouvelle ligne avec `action='parse_error'`, `notes='OpenAI Extract failed after 3 retries'`<br>• `leads` : aucune nouvelle ligne<br>• Aucun brouillon créé |
| **Cleanup** | Remets la vraie clé OpenAI |
| **Résultat** | ☐ |

---

## T3 — Insert Lead failure (Supabase down)

| | |
|---|---|
| **Objectif** | Vérifier le retry + Log Insert Failure |
| **Action** | 1. Va dans Credentials → "Supabase Novekai" → modifie la Service Role Key (ajoute "X" à la fin)<br>2. Sauvegarde<br>3. Envoie 1 email immo |
| **Attendu** | • OpenAI Extract OK<br>• Check Duplicate (REST) montre une 401 mais continue (neverError true)<br>• Insert Lead (REST) : 3 retries en rouge<br>• `processing_log` : nouvelle ligne `notes='Insert Lead failed after 3 retries'` (mais attention : Supabase étant down, le log lui-même va échouer aussi — c'est un cas connu, accepté)<br>• Aucun lead inséré, aucun brouillon |
| **Cleanup** | Remets la vraie Service Role Key |
| **Résultat** | ☐ |

---

## T4 — Create Gmail Draft failure (le test le plus important)

| | |
|---|---|
| **Objectif** | Vérifier que Notify Draft Failure n'envoie l'email QUE quand le brouillon plante vraiment |
| **Action** | 1. Va dans Credentials → "Gmail account novekai" → Disconnect (ou révoque le token OAuth)<br>2. Sauvegarde<br>3. Envoie 1 email immo |
| **Attendu** | • Lead bien inséré dans `leads`<br>• Create Gmail Draft : 2 retries en rouge<br>• `processing_log` : nouvelle ligne `notes='Gmail Draft failed after 2 retries'`<br>• 1 email "ALERTE Brouillon Gmail rate pour [prospect@email]" reçu dans novekai.team@gmail.com<br>• Le contenu de l'email mentionne le bon prospect et le bon sujet |
| **Cleanup** | Reconnecte Gmail OAuth2 |
| **Résultat** | ☐ |

---

## T5 — Parse error (OpenAI renvoie du non-JSON)

| | |
|---|---|
| **Objectif** | Vérifier la branche Filter: Parse Errors |
| **Action** | Difficile à provoquer en prod (OpenAI en mode JSON renvoie quasi toujours du JSON valide). Test via SDK : déjà validé par mes tests automatisés (Test 2/7 PASSED, exec 2594) |
| **Attendu** | • `processing_log` : `action='parse_error'`, `notes='Parse failed: parse_err'`<br>• Aucun lead inséré |
| **Résultat** | ✅ (déjà validé en test SDK) |

---

## T6 — Low confidence (email tronqué)

| | |
|---|---|
| **Objectif** | Vérifier le bonus "logs pour mails incomplets" |
| **Action** | Envoie 1 email immo avec le minimum : "Bonjour, je suis intéressé. Cordialement" (pas de nom, pas d'email, pas de bien) |
| **Attendu** | • `leads` : 1 ligne avec `score_confiance < 0.3`, `draft_reply=null`<br>• `incomplete_leads_log` : 1 ligne reliée au lead, avec le score<br>• Aucun brouillon créé (Filter: Has Draft bloque parce que draft_reply est null) |
| **Résultat** | ☐ |

---

## T7 — Doublon (déduplication)

| | |
|---|---|
| **Objectif** | Vérifier le bonus dédup email + bien + jour |
| **Action** | 1. Envoie 1 email immo "Jean Dupont, IW-12345"<br>2. Attends qu'il soit traité<br>3. Renvoie le même email (même prospect_email + même bien_reference) |
| **Attendu** | • 1er traitement : insert + brouillon<br>• 2e traitement : `processing_log` avec `action='skipped_duplicate'`, `notes` mentionnant le prospect + bien<br>• `leads` : toujours 1 seule ligne (pas de doublon)<br>• Aucun 2e brouillon créé |
| **Résultat** | ☐ |

---

## T8 — Error Workflow global (Error Handler)

| | |
|---|---|
| **Objectif** | Vérifier que le workflow d'erreur global capte les crashes non gérés |
| **Préalable** | Settings → Error Workflow de Novek immo2 = `Error Handler — Novek immo` (à configurer si pas fait) |
| **Action** | 1. Désactive temporairement `retryOnFail` sur OpenAI Extract (édite le node)<br>2. Casse la clé OpenAI (comme T2)<br>3. Envoie 1 email immo |
| **Attendu** | • Novek immo2 : execution Failed (pas Success)<br>• Error Handler : 1 nouvelle execution déclenchée automatiquement<br>• Email "[ALERTE n8n] Novek immo2 - crash OpenAI Extract" reçu dans novekai.team<br>• `processing_log` : 1 ligne avec `notes` mentionnant le node et l'erreur |
| **Cleanup** | Remets retryOnFail=true sur OpenAI Extract et la vraie clé OpenAI |
| **Résultat** | ☐ |

---

## T9 — Heartbeat alert (workflow silencieux)

| | |
|---|---|
| **Objectif** | Vérifier que le sentinel détecte un polling Gmail en panne |
| **Action** | 1. Désactive Novek immo2 (toggle Active → off)<br>2. Attends >2h sans aucune execution OU triche en éditant la clause "h > 2" en "h > 0" temporairement dans Check Freshness pour avoir le résultat tout de suite<br>3. Lance Heartbeat manuellement (Execute workflow) |
| **Attendu** | • Email "ALERTE Novek immo2 polling KO" reçu dans novekai.team<br>• Le corps mentionne `hours_since`, raison `stale` ou `no_exec`, dernière exec<br>• L'email liste les choses à vérifier (token OAuth, quota, workflow actif) |
| **Cleanup** | Réactive Novek immo2, remets le seuil à 2 dans Check Freshness |
| **Résultat** | ☐ |

---

## T10 — Heartbeat OK (pas de fausse alerte)

| | |
|---|---|
| **Objectif** | Vérifier que Heartbeat NE déclenche PAS d'alerte quand tout va bien |
| **Action** | 1. Avec Novek immo2 actif, envoie 1 email immo (pour avoir une exec récente)<br>2. Attends que l'exec soit Success<br>3. Dans la minute, lance Heartbeat manuellement |
| **Attendu** | • Aucun email "ALERTE polling KO"<br>• Dans Executions du Heartbeat : Filter Alert Needed → 0 items, Send Heartbeat Alert non exécuté |
| **Résultat** | ☐ |

---

## Récap : que faut-il avoir à la fin ?

Tableau de synthèse à remplir après tous les tests :

| Test | Status | Notes |
|---|---|---|
| T1 Happy path | ☐ | |
| T2 OpenAI down | ☐ | |
| T3 Supabase down | ☐ | |
| T4 Gmail Draft fail | ☐ | |
| T5 Parse error | ✅ | déjà validé en SDK |
| T6 Low confidence | ☐ | |
| T7 Duplicate | ☐ | |
| T8 Error Workflow | ☐ | |
| T9 Heartbeat alert | ☐ | |
| T10 Heartbeat OK | ☐ | |

Si T1, T2, T3, T4 passent → la correction des sorties d'erreur est validée et le système est robuste.
Si T8 passe → le filet de sécurité global fonctionne.
Si T9 passe → le sentinel de surveillance est opérationnel.

---

## Ordre recommandé

1. **D'abord T1** (rapide, prouve que la correction du bug Notify Draft Failure tient)
2. Puis **T6 + T7** (bonus, pas besoin de casser de credentials)
3. Puis **T2, T3, T4** dans la foulée (chacun avec son propre rollback de credential)
4. Puis **T9 + T10** (Heartbeat)
5. **T8 en dernier** (le plus invasif : modifie la config du node OpenAI Extract)

Total temps estimé : 30-40 minutes pour tout faire de bout en bout.
