-- =====================================================================
-- City of Arab — Zoning Map (arabcityzoning.jadecruz.dev): shared storage
-- v3 (2026-10-18): only Building Department logins (and Administrators)
-- get the staff dashboard. City Clerk logins can browse the public map only.
-- v2 (2026-10-17): sign-in uses the Arab City Staff Portal logins
-- (bf_accounts / bf_sessions, the same logins as
-- arabcityapplications.jadecruz.dev), including its lockout, 2-step
-- verification and "choose your own password" rules.
-- Run in the Supabase SQL Editor (project yighcuismepfmappcfui) after the
-- Staff Portal's bf_*.sql files. Safe to re-run. Nothing is deleted:
-- the zm_properties / zm_layers / zm_log tables are kept as they are.
--
-- Who can do what on the map (Staff Portal roles):
--   public (not signed in)      zoning map only; annexations are hidden
--   City Clerk login            same as the public: browse only, sign-in is refused
--   Building Department + admin see, add, edit and delete annexations
--     (Building Department = role 'staff', or any login with the 'building' add-on)
--   Administrator               also replace / remove / restore map layers
-- Logins, passwords and 2-step are managed in the Staff Portal.
-- =====================================================================
set search_path = public, extensions;

create table if not exists zm_properties (
  id         text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by text
);
create table if not exists zm_layers (
  kind       text primary key check (kind in ('parcels','limits','gas')),
  geojson    jsonb,              -- null = removed from the map
  updated_at timestamptz not null default now(),
  updated_by text
);
create table if not exists zm_log (
  id      bigserial primary key,
  at      timestamptz not null default now(),
  actor   text,
  action  text,
  detail  jsonb
);
alter table zm_properties enable row level security;
alter table zm_layers     enable row level security;
alter table zm_log        enable row level security;
revoke all on zm_properties, zm_layers, zm_log from anon, authenticated;

-- ---------- helpers (not callable from the website) ----------
-- staff dashboard access: Building Department or Administrator only
-- (City Clerk logins without the 'building' add-on are refused)
create or replace function zm_is_staff(a bf_accounts) returns boolean
language sql immutable as $$
  select bf_is_staff(a);
$$;
-- 1 = view, 2 = edit (both Building Department), 3 = Administrator; returns the email
create or replace function zm_actor(p_token uuid, p_min int) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare a bf_accounts := bf_session_account(p_token);
begin
  if a.id is null then raise exception 'unauthorized'; end if;
  if (p_min >= 3 and not bf_is_admin(a)) or (p_min = 2 and not bf_is_staff(a)) or (p_min = 1 and not zm_is_staff(a)) then
    raise exception 'forbidden';
  end if;
  return a.email;
end $$;
revoke all on function zm_is_staff(bf_accounts), zm_actor(uuid,int) from public, anon, authenticated;

-- ---------- who am I (restores a session on page load) ----------
drop function if exists zm_me(uuid);
create or replace function zm_me(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a bf_accounts := bf_session_account(p_token);
begin
  if a.id is null or not zm_is_staff(a) then return null; end if;
  return bf_account_json(a) || jsonb_build_object('map', jsonb_build_object(
    'view', true, 'edit', bf_is_staff(a), 'admin', bf_is_admin(a)));
end $$;

-- ---------- properties / annexations: staff only ----------
create or replace function zm_list_properties(p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare a bf_accounts := bf_session_account(p_token);
begin
  if a.id is null or not zm_is_staff(a) then return '[]'::jsonb; end if;   -- the public sees no annexations
  return coalesce((select jsonb_agg(p.data || jsonb_build_object('id',p.id,'updated_at',p.updated_at,'updated_by',p.updated_by)
                                    order by p.updated_at desc) from zm_properties p), '[]'::jsonb);
end $$;

create or replace function zm_upsert_property(p_token uuid, p_row jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare who text := zm_actor(p_token, 2); pid text := coalesce(nullif(p_row->>'id',''), 'p'||replace(gen_random_uuid()::text,'-',''));
begin
  insert into zm_properties(id,data,updated_at,updated_by)
  values (pid, p_row - 'id' - 'updated_at' - 'updated_by', now(), who)
  on conflict (id) do update set data = zm_properties.data || excluded.data, updated_at = now(), updated_by = who;
  insert into zm_log(actor,action,detail) values (who,'upsert_property',jsonb_build_object('id',pid,'status',p_row->>'status'));
  return jsonb_build_object('id',pid);
end $$;

create or replace function zm_delete_property(p_token uuid, p_id text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare who text := zm_actor(p_token, 2);
begin
  delete from zm_properties where id = p_id;
  insert into zm_log(actor,action,detail) values (who,'delete_property',jsonb_build_object('id',p_id));
end $$;

-- ---------- map layers (shared overrides of the files in /data) ----------
create or replace function zm_get_layers() returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(kind, jsonb_build_object('geojson',geojson,'updated_at',updated_at)),'{}'::jsonb) from zm_layers $$;

create or replace function zm_set_layer(p_token uuid, p_kind text, p_mode text, p_geojson jsonb default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare who text := zm_actor(p_token, 3);
begin
  if p_kind not in ('parcels','limits','gas') then raise exception 'Unknown layer.'; end if;
  if p_mode = 'restore' then delete from zm_layers where kind = p_kind;
  elsif p_mode = 'remove' then insert into zm_layers(kind,geojson,updated_by) values (p_kind,null,who)
       on conflict (kind) do update set geojson = null, updated_at = now(), updated_by = who;
  elsif p_mode = 'set' then insert into zm_layers(kind,geojson,updated_by) values (p_kind,p_geojson,who)
       on conflict (kind) do update set geojson = excluded.geojson, updated_at = now(), updated_by = who;
  else raise exception 'Unknown mode.'; end if;
  insert into zm_log(actor,action,detail) values (who,'layer_'||p_mode,jsonb_build_object('kind',p_kind));
end $$;

-- ---------- what the website may call ----------
-- (Sign-in uses the Staff Portal's bf_sign_in / bf_sign_in_code / bf_me / bf_sign_out.)
revoke all on function zm_me(uuid), zm_list_properties(uuid), zm_upsert_property(uuid,jsonb), zm_delete_property(uuid,text),
  zm_get_layers(), zm_set_layer(uuid,text,text,jsonb) from public;
grant execute on function zm_me(uuid), zm_list_properties(uuid), zm_upsert_property(uuid,jsonb), zm_delete_property(uuid,text),
  zm_get_layers(), zm_set_layer(uuid,text,text,jsonb)
to anon, authenticated;
