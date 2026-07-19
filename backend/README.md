# Handoff : Backend Supabase (comptes, KYC, jetons, progression)

## Vue d'ensemble
Le site comprend 4 expériences front-end prototypées en HTML : authentification/KYC, un jeu d'apprentissage de l'anglais, un jeu de bourse éducatif, et des jeux de cartes (blackjack/vidéo-poker) avec une monnaie virtuelle. Actuellement, **toutes les données (progression, jetons, statut premium, statut KYC) sont stockées en `localStorage`**, donc propres à un seul navigateur/appareil. L'objectif de ce chantier : brancher un vrai backend Supabase (Auth + Postgres) pour que chaque membre retrouve ses données peu importe l'appareil utilisé.

## À propos des fichiers de design
Les fichiers `.dc.html` inclus sont des **références de design** — des prototypes fonctionnels en HTML/JS montrant l'apparence, les écrans et le comportement attendu, pas du code à réutiliser tel quel en production. La tâche consiste à recréer ces écrans dans l'environnement cible choisi (recommandé : n'importe quel framework front avec le client JS `@supabase/supabase-js` — React/Next.js est un choix naturel si aucune stack n'est déjà en place), et à remplacer chaque accès `localStorage` par des appels Supabase.

## Fidélité
**Haute fidélité (hifi)** pour le visuel (couleurs, typographie, espacements, composants) — à reproduire fidèlement. La logique JS dans les fichiers, elle, est un prototype (état en mémoire + `localStorage`) à remplacer par de vrais appels réseau.

## Écrans concernés
1. **Authentification & KYC** (`Authentification - KYC.dc.html`) — inscription/connexion, hub post-connexion, formulaire d'infos personnelles, upload de pièce d'identité + selfie, écran d'attente, écran de confirmation.
2. **Daily English** (`Apprendre Anglais - Jeu.dc.html`) — leçons quotidiennes, XP, série (streak), paywall premium.
3. **Bourse — Apprentissage** (`Bourse - Apprentissage.dc.html`) — simulateur boursier (gratuit), portefeuille, journal.
4. **Jeux de Cartes** (`Jeux de Cartes.dc.html`) — blackjack + vidéo-poker, solde de jetons virtuels.

## Modèle de données Supabase (Postgres)

### `profiles`
| colonne | type | notes |
|---|---|---|
| id | uuid (PK, = auth.users.id) | |
| email | text | miroir de auth.users pour requêtes faciles |
| first_name, last_name | text | |
| dob | date | |
| address, city, postcode, country | text | |
| phone | text | |
| created_at | timestamptz | default now() |

### `kyc_verifications`
| colonne | type | notes |
|---|---|---|
| id | uuid PK | |
| user_id | uuid FK -> profiles.id | |
| status | text | `not_started` \| `pending` \| `verified` \| `rejected` |
| id_document_front_url, id_document_back_url, selfie_url | text | stockés dans Supabase Storage (bucket privé `kyc-documents`), jamais publics |
| verified_at | timestamptz | null tant que non vérifié |
| provider | text | ex: `stripe_identity` |
| provider_reference | text | id de session Stripe Identity |

⚠️ Les documents d'identité sont des données sensibles : bucket Storage **privé**, RLS stricte (un utilisateur ne peut lire que ses propres fichiers), et envisager le chiffrement/rétention limitée selon la réglementation applicable (KYC/AML).

### `english_progress`
| colonne | type |
|---|---|
| user_id | uuid FK |
| streak | int, default 1 |
| xp | int, default 0 |
| lessons_completed | int, default 0 |
| correct_total, answered_total | int |
| is_premium | boolean, default false |
| premium_since | timestamptz null |

### `card_game_wallet`
| colonne | type |
|---|---|
| user_id | uuid FK |
| chips | numeric, default 5000 — **5000 jetons offerts à la création du compte** (trigger côté serveur, pas côté client) |
| updated_at | timestamptz |

### `card_game_transactions` (journal des recharges/paris, pour audit)
| colonne | type |
|---|---|
| id | uuid PK |
| user_id | uuid FK |
| type | `bonus_signup` \| `purchase` \| `bet` \| `payout` |
| amount | numeric (peut être négatif) |
| stripe_payment_intent_id | text null |
| created_at | timestamptz |

### `stock_sim_state`
| colonne | type |
|---|---|
| user_id | uuid FK |
| day | int |
| cash | numeric |
| shares | numeric |
| history | jsonb (tableau de chandeliers {open,high,low,close}) |
| log | jsonb |

## Authentification
Remplacer le formulaire maison par `supabase.auth.signUp({ email, password })` et `supabase.auth.signInWithPassword(...)`. À la création du compte (trigger Postgres `on auth.users insert` ou hook côté serveur) :
1. Créer la ligne `profiles`.
2. Créer `card_game_wallet` avec `chips = 5000`.
3. Créer `english_progress` avec valeurs par défaut.
4. Créer `kyc_verifications` avec `status = 'not_started'`.

## Flux KYC déclenché à l'achat
Comportement actuel (prototype) : les boutons de paiement vérifient un flag local `kyc_verified` ; si absent, redirection vers la page KYC avec `?verify=1&return=<url_stripe>`, puis redirection vers Stripe une fois "vérifié".

À reproduire côté serveur :
1. Avant d'autoriser la redirection vers un lien de paiement Stripe, vérifier `kyc_verifications.status === 'verified'` pour l'utilisateur connecté (requête Supabase, pas juste un flag local).
2. Si non vérifié : rediriger vers le flux KYC (formulaire infos + upload documents → upload vers Supabase Storage → appel à Stripe Identity pour la vérification réelle → webhook Stripe Identity met à jour `kyc_verifications.status`).
3. Une fois vérifié, rediriger l'utilisateur vers l'URL Stripe Payment Link d'origine (le paramètre `return` est déjà transmis dans le prototype).

## Intégration Stripe (paiements)
Les 4 liens Stripe Payment Links actuels sont codés en dur dans le HTML (usage prototype). En production :
- Configurer un **webhook Stripe** (`checkout.session.completed` / `payment_intent.succeeded`) pointant vers une fonction serveur (Supabase Edge Function recommandée).
- Selon le produit acheté (identifiable via `price_id` ou métadonnées du Payment Link) :
  - Abonnement mensuel Anglais → mettre à jour `english_progress.is_premium = true` (et gérer le renouvellement/annulation via les événements `customer.subscription.*`).
  - Certificat / Cours à la carte → enregistrer l'achat (table `purchases` à créer si besoin de plus de granularité).
  - Recharge de jetons → incrémenter `card_game_wallet.chips` selon le montant payé (0,01 $/jeton) et logguer dans `card_game_transactions`.
- Ne jamais faire confiance à un flag client (`isPremium`, `chips`) pour déverrouiller du contenu payant — toujours vérifier côté serveur (RLS + policies Supabase, ou vérification dans une Edge Function) que l'état en base reflète un paiement confirmé par le webhook.

## Migration depuis localStorage
Les clés actuellement utilisées en local (à migrer) :
- `daily-english-progress-v1` → table `english_progress`
- `card-games-chips-v1` → table `card_game_wallet` + `card_game_transactions`
- `bourse-apprentissage-v1` → table `stock_sim_state`
- `site_authed`, `kyc_verified` (flags bruts) → remplacés par une vraie session Supabase Auth + lecture de `kyc_verifications.status`

## Design tokens (référence visuelle — voir aussi `styles.css` joint si disponible)
- Fond : `#161826` · Surface : `#232532` · Texte : `#e9e9ed`
- Accent (blurple) : `#9184d9`
- Police : Inter (400/500/600)
- Rayon de bordure : 8px (`--radius-md`), 14px (`--radius-lg`)
- Densité d'espacement : échelle compacte (~0.7×)

## Assets
- `favicon.png` (icône du site)
- Pas d'images/photos externes utilisées ; les zones d'upload KYC utilisent le composant `<image-slot>` (placeholder drag-and-drop) à remplacer par un vrai composant d'upload vers Supabase Storage.

## Fichiers inclus
- `Authentification - KYC.dc.html`
- `Apprendre Anglais - Jeu.dc.html`
- `Jeux de Cartes.dc.html`
- `Bourse - Apprentissage.dc.html`
