-- =========================================================================
-- Schéma Supabase — comptes, KYC, progression, jetons, simulateur boursier
-- À exécuter dans Supabase Dashboard → SQL Editor (une seule fois).
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. Profils (miroir de auth.users + infos KYC personnelles)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  first_name text,
  last_name text,
  dob date,
  address text,
  city text,
  postcode text,
  country text,
  phone text,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);
create policy "profiles_insert_own" on public.profiles
  for insert with check (auth.uid() = id);

-- ---------------------------------------------------------------------
-- 2. Vérification d'identité (KYC)
-- ---------------------------------------------------------------------
create table if not exists public.kyc_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'not_started' check (status in ('not_started','pending','verified','rejected')),
  id_document_front_url text,
  id_document_back_url text,
  selfie_url text,
  provider text default 'stripe_identity',
  provider_reference text,
  verified_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.kyc_verifications enable row level security;

create policy "kyc_select_own" on public.kyc_verifications
  for select using (auth.uid() = user_id);
create policy "kyc_insert_own" on public.kyc_verifications
  for insert with check (auth.uid() = user_id);
-- Pas de policy "update" pour les clients : seul un rôle serveur
-- (service_role, via une Edge Function après webhook Stripe Identity)
-- doit pouvoir faire passer status à 'verified'.

-- ---------------------------------------------------------------------
-- 3. Progression — Daily English
-- ---------------------------------------------------------------------
create table if not exists public.english_progress (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  streak int not null default 1,
  xp int not null default 0,
  lessons_completed int not null default 0,
  correct_total int not null default 0,
  answered_total int not null default 0,
  is_premium boolean not null default false,
  premium_since timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.english_progress enable row level security;

create policy "english_select_own" on public.english_progress
  for select using (auth.uid() = user_id);
create policy "english_update_own_progress" on public.english_progress
  for update using (auth.uid() = user_id);
  -- Remarque : is_premium ne doit être modifié que par le serveur après
  -- confirmation du paiement (webhook Stripe) — filtrer cette colonne
  -- dans une Edge Function plutôt que de laisser le client l'écrire
  -- librement si tu veux une garantie stricte.
create policy "english_insert_own" on public.english_progress
  for insert with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- 4. Portefeuille de jetons — Jeux de Cartes
-- ---------------------------------------------------------------------
create table if not exists public.card_game_wallet (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  chips numeric not null default 5000,
  updated_at timestamptz not null default now()
);

alter table public.card_game_wallet enable row level security;

create policy "wallet_select_own" on public.card_game_wallet
  for select using (auth.uid() = user_id);
create policy "wallet_update_own" on public.card_game_wallet
  for update using (auth.uid() = user_id);
create policy "wallet_insert_own" on public.card_game_wallet
  for insert with check (auth.uid() = user_id);

create table if not exists public.card_game_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null check (type in ('bonus_signup','purchase','bet','payout')),
  amount numeric not null,
  stripe_payment_intent_id text,
  created_at timestamptz not null default now()
);

alter table public.card_game_transactions enable row level security;

create policy "transactions_select_own" on public.card_game_transactions
  for select using (auth.uid() = user_id);
create policy "transactions_insert_own" on public.card_game_transactions
  for insert with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- 5. Simulateur boursier — Bourse Apprentissage
-- ---------------------------------------------------------------------
create table if not exists public.stock_sim_state (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  day int not null default 1,
  cash numeric not null default 5000,
  shares numeric not null default 0,
  history jsonb not null default '[]'::jsonb,
  log jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.stock_sim_state enable row level security;

create policy "stock_select_own" on public.stock_sim_state
  for select using (auth.uid() = user_id);
create policy "stock_update_own" on public.stock_sim_state
  for update using (auth.uid() = user_id);
create policy "stock_insert_own" on public.stock_sim_state
  for insert with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- 6. Trigger : à la création d'un compte (auth.users),
--    initialiser toutes les lignes par défaut (dont les 5000 jetons offerts).
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email);
  insert into public.kyc_verifications (user_id, status) values (new.id, 'not_started');
  insert into public.english_progress (user_id) values (new.id);
  insert into public.card_game_wallet (user_id, chips) values (new.id, 5000);
  insert into public.card_game_transactions (user_id, type, amount)
    values (new.id, 'bonus_signup', 5000);
  insert into public.stock_sim_state (user_id) values (new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------------------------------------------------------------------
-- 7. Stockage des documents KYC (bucket privé)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('kyc-documents', 'kyc-documents', false)
on conflict (id) do nothing;

create policy "kyc_docs_insert_own" on storage.objects
  for insert with check (
    bucket_id = 'kyc-documents' and auth.uid()::text = (storage.foldername(name))[1]
  );
create policy "kyc_docs_select_own" on storage.objects
  for select using (
    bucket_id = 'kyc-documents' and auth.uid()::text = (storage.foldername(name))[1]
  );
-- Convention de chemin recommandée : kyc-documents/<user_id>/front.jpg, back.jpg, selfie.jpg
