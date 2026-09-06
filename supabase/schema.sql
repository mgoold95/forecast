-- Forecast's private play-money domain. Safe to run repeatedly.

create extension if not exists pgcrypto;

create table if not exists public.forecast_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  email text not null,
  avatar_url text,
  credits integer not null default 10000 check (credits >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.forecast_groups (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  description text not null default '',
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.forecast_group_members (
  group_id uuid not null references public.forecast_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table if not exists public.forecast_markets (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.forecast_groups(id) on delete cascade,
  creator_id uuid not null references public.forecast_profiles(id) on delete cascade,
  question text not null,
  description text not null,
  category text not null default 'other',
  status text not null default 'open' check (status in ('open', 'closed', 'resolved')),
  closes_at timestamptz not null,
  yes_credits integer not null default 0 check (yes_credits >= 0),
  no_credits integer not null default 0 check (no_credits >= 0),
  resolved_side text check (resolved_side in ('yes', 'no')),
  created_at timestamptz not null default now()
);

create table if not exists public.forecast_positions (
  id uuid primary key default gen_random_uuid(),
  market_id uuid not null references public.forecast_markets(id) on delete cascade,
  user_id uuid not null references public.forecast_profiles(id) on delete cascade,
  side text not null check (side in ('yes', 'no')),
  amount integer not null check (amount > 0),
  created_at timestamptz not null default now()
);

create table if not exists public.forecast_activity (
  id uuid primary key default gen_random_uuid(),
  group_id uuid references public.forecast_groups(id) on delete cascade,
  market_id uuid references public.forecast_markets(id) on delete cascade,
  user_id uuid references public.forecast_profiles(id) on delete cascade,
  action text not null,
  amount integer not null default 0,
  side text check (side in ('yes', 'no')),
  created_at timestamptz not null default now()
);

-- Upgrade projects that previously ran an earlier Forecast schema.
alter table public.forecast_profiles
  add column if not exists avatar_url text;

do $$
begin
  if exists (
    select 1 from pg_constraint
    where conname = 'forecast_markets_creator_id_fkey'
      and conrelid = 'public.forecast_markets'::regclass
  ) then
    alter table public.forecast_markets drop constraint forecast_markets_creator_id_fkey;
  end if;
  alter table public.forecast_markets
    add constraint forecast_markets_creator_id_fkey
    foreign key (creator_id) references public.forecast_profiles(id) on delete cascade;

  if exists (
    select 1 from pg_constraint
    where conname = 'forecast_positions_user_id_fkey'
      and conrelid = 'public.forecast_positions'::regclass
  ) then
    alter table public.forecast_positions drop constraint forecast_positions_user_id_fkey;
  end if;
  alter table public.forecast_positions
    add constraint forecast_positions_user_id_fkey
    foreign key (user_id) references public.forecast_profiles(id) on delete cascade;

  if exists (
    select 1 from pg_constraint
    where conname = 'forecast_activity_user_id_fkey'
      and conrelid = 'public.forecast_activity'::regclass
  ) then
    alter table public.forecast_activity drop constraint forecast_activity_user_id_fkey;
  end if;
  alter table public.forecast_activity
    add constraint forecast_activity_user_id_fkey
    foreign key (user_id) references public.forecast_profiles(id) on delete cascade;
end $$;

create index if not exists forecast_members_user_idx on public.forecast_group_members(user_id);
create index if not exists forecast_markets_group_idx on public.forecast_markets(group_id);
create index if not exists forecast_positions_user_idx on public.forecast_positions(user_id);
create index if not exists forecast_positions_market_idx on public.forecast_positions(market_id);
create index if not exists forecast_activity_group_created_idx on public.forecast_activity(group_id, created_at desc);

alter table public.forecast_profiles enable row level security;
alter table public.forecast_groups enable row level security;
alter table public.forecast_group_members enable row level security;
alter table public.forecast_markets enable row level security;
alter table public.forecast_positions enable row level security;
alter table public.forecast_activity enable row level security;

drop policy if exists "profiles are private to their owner" on public.forecast_profiles;
drop policy if exists "groups are visible to members" on public.forecast_groups;
drop policy if exists "owners can manage groups" on public.forecast_groups;
drop policy if exists "members can read markets" on public.forecast_markets;
drop policy if exists "members can create markets" on public.forecast_markets;
drop policy if exists "members can read positions" on public.forecast_positions;
drop policy if exists "users can create their positions" on public.forecast_positions;
drop policy if exists "members can read activity" on public.forecast_activity;

create or replace function public.forecast_is_group_member(p_group_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.forecast_group_members
  where group_id = p_group_id and user_id = p_user_id
) $$;

revoke all on function public.forecast_is_group_member(uuid, uuid) from public;
grant execute on function public.forecast_is_group_member(uuid, uuid) to authenticated;

drop policy if exists "profiles are visible to group peers" on public.forecast_profiles;
create policy "profiles are visible to group peers" on public.forecast_profiles for select
using (
  id = auth.uid() or exists (
    select 1
    from public.forecast_group_members mine
    join public.forecast_group_members theirs on theirs.group_id = mine.group_id
    where mine.user_id = auth.uid() and theirs.user_id = forecast_profiles.id
  )
);
drop policy if exists "users create their profile" on public.forecast_profiles;
create policy "users create their profile" on public.forecast_profiles for insert with check (id = auth.uid());
drop policy if exists "users update their profile" on public.forecast_profiles;

create or replace function public.forecast_update_profile(p_name text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_profile public.forecast_profiles;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if length(trim(p_name)) < 2 or length(trim(p_name)) > 80 then
    raise exception 'Display name must be between 2 and 80 characters';
  end if;

  update public.forecast_profiles
  set name = trim(p_name)
  where id = v_user
  returning * into v_profile;

  if not found then raise exception 'Profile not found'; end if;

  return jsonb_build_object(
    'id', v_profile.id,
    'name', v_profile.name,
    'email', v_profile.email,
    'avatarUrl', v_profile.avatar_url,
    'credits', v_profile.credits,
    'rank', 0
  );
end $$;

revoke all on function public.forecast_update_profile(text) from public;
grant execute on function public.forecast_update_profile(text) to authenticated;

drop policy if exists "members read groups" on public.forecast_groups;
create policy "members read groups" on public.forecast_groups for select
using (public.forecast_is_group_member(id, auth.uid()));
drop policy if exists "owners update groups" on public.forecast_groups;
create policy "owners update groups" on public.forecast_groups for update
using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "members read memberships" on public.forecast_group_members;
create policy "members read memberships" on public.forecast_group_members for select
using (public.forecast_is_group_member(group_id, auth.uid()));

drop policy if exists "members read markets" on public.forecast_markets;
create policy "members read markets" on public.forecast_markets for select
using (public.forecast_is_group_member(group_id, auth.uid()));
drop policy if exists "members create markets" on public.forecast_markets;
create policy "members create markets" on public.forecast_markets for insert
with check (creator_id = auth.uid() and public.forecast_is_group_member(group_id, auth.uid()));

drop policy if exists "members read group positions" on public.forecast_positions;
create policy "members read group positions" on public.forecast_positions for select
using (
  exists (
    select 1 from public.forecast_markets m
    where m.id = market_id and public.forecast_is_group_member(m.group_id, auth.uid())
  )
);

drop policy if exists "members read group activity" on public.forecast_activity;
create policy "members read group activity" on public.forecast_activity for select
using (group_id is not null and public.forecast_is_group_member(group_id, auth.uid()));
drop policy if exists "members create activity" on public.forecast_activity;
create policy "members create activity" on public.forecast_activity for insert
with check (user_id = auth.uid() and public.forecast_is_group_member(group_id, auth.uid()));

create or replace function public.forecast_create_group(p_name text, p_description text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_group public.forecast_groups;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  insert into public.forecast_groups(owner_id, name, description, invite_code)
  values (v_user, trim(p_name), coalesce(p_description, ''), upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 10)))
  returning * into v_group;
  insert into public.forecast_group_members(group_id, user_id, role)
  values (v_group.id, v_user, 'owner');
  return jsonb_build_object(
    'id', v_group.id, 'name', v_group.name, 'description', v_group.description,
    'inviteCode', v_group.invite_code, 'memberCount', 1, 'marketCount', 0, 'role', 'owner'
  );
end $$;

create or replace function public.forecast_join_group(p_invite_code text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_group public.forecast_groups;
  v_count integer;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  select * into v_group from public.forecast_groups
  where lower(invite_code) = lower(trim(p_invite_code));
  if not found then raise exception 'Invite code not found'; end if;
  insert into public.forecast_group_members(group_id, user_id, role)
  values (v_group.id, v_user, 'member') on conflict do nothing;
  select count(*) into v_count from public.forecast_group_members where group_id = v_group.id;
  return jsonb_build_object(
    'id', v_group.id, 'name', v_group.name, 'description', v_group.description,
    'inviteCode', v_group.invite_code, 'memberCount', v_count,
    'marketCount', (select count(*) from public.forecast_markets where group_id = v_group.id),
    'role', case when v_group.owner_id = v_user then 'owner' else 'member' end
  );
end $$;

create or replace function public.forecast_place_position(p_market_id uuid, p_side text, p_amount integer)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_market public.forecast_markets;
  v_position public.forecast_positions;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_side not in ('yes', 'no') or p_amount <= 0 then raise exception 'Invalid position'; end if;
  select * into v_market from public.forecast_markets where id = p_market_id for update;
  if not found or not public.forecast_is_group_member(v_market.group_id, v_user) then
    raise exception 'Market not found';
  end if;
  if v_market.status <> 'open' or v_market.closes_at <= now() then raise exception 'Market is closed'; end if;
  update public.forecast_profiles
  set credits = credits - p_amount
  where id = v_user and credits >= p_amount;
  if not found then raise exception 'You do not have enough virtual credits'; end if;
  insert into public.forecast_positions(market_id, user_id, side, amount)
  values (p_market_id, v_user, p_side, p_amount) returning * into v_position;
  update public.forecast_markets set
    yes_credits = yes_credits + case when p_side = 'yes' then p_amount else 0 end,
    no_credits = no_credits + case when p_side = 'no' then p_amount else 0 end
  where id = p_market_id returning * into v_market;
  insert into public.forecast_activity(group_id, market_id, user_id, action, amount, side)
  values (v_market.group_id, p_market_id, v_user, 'allocated credits to', p_amount, p_side);
  return jsonb_build_object(
    'id', v_position.id, 'market_id', v_position.market_id, 'side', v_position.side,
    'amount', v_position.amount, 'created_at', v_position.created_at,
    'forecast_markets', jsonb_build_object(
      'question', v_market.question, 'yes_credits', v_market.yes_credits, 'no_credits', v_market.no_credits
    )
  );
end $$;

create or replace function public.forecast_leaderboard(p_group_id uuid default null)
returns table(user_id uuid, name text, avatar_url text, credits integer, invested bigint, markets_played bigint, score bigint)
language sql stable security definer set search_path = public
as $$
  select p.id, p.name, p.avatar_url, p.credits,
    coalesce(sum(pos.amount), 0)::bigint,
    count(distinct pos.market_id)::bigint,
    (10000 - p.credits + coalesce(sum(pos.amount), 0))::bigint
  from public.forecast_profiles p
  join public.forecast_group_members gm on gm.user_id = p.id
  left join public.forecast_markets m on m.group_id = gm.group_id
  left join public.forecast_positions pos on pos.market_id = m.id and pos.user_id = p.id
  where gm.group_id = coalesce(p_group_id, gm.group_id)
    and public.forecast_is_group_member(gm.group_id, auth.uid())
  group by p.id, p.name, p.avatar_url, p.credits
  order by (10000 - p.credits + coalesce(sum(pos.amount), 0)) desc, p.name asc
$$;

revoke all on function public.forecast_create_group(text, text) from public;
revoke all on function public.forecast_join_group(text) from public;
revoke all on function public.forecast_place_position(uuid, text, integer) from public;
revoke all on function public.forecast_leaderboard(uuid) from public;
grant execute on function public.forecast_create_group(text, text) to authenticated;
grant execute on function public.forecast_join_group(text) to authenticated;
grant execute on function public.forecast_place_position(uuid, text, integer) to authenticated;
grant execute on function public.forecast_leaderboard(uuid) to authenticated;