-- =====================================================================
-- City of Arab — Zoning & Property Map: shared storage
-- Sign-in uses the PERMIT CHECKER's staff logins (pm_staff_users /
-- pm_staff_sessions) in the same Supabase project, so one username and
-- password works on both sites. Run the permit checker's schema.sql
-- first (it already is, on the live project). Safe to re-run.
--
-- Access on the map follows the permit checker's access level:
--   admin   → everything: properties, map layers, staff logins
--   staff   → add / edit / delete properties
--   viewer  → sign in and see staff-only details
-- =====================================================================

create extension if not exists pgcrypto;

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

-- Remove the separate map logins from the first draft of this file, if they were ever created.
drop function if exists zm_bootstrap(text,text);
drop function if exists zm_login(text,text);
drop function if exists zm_logout(uuid);
drop function if exists zm_change_password(uuid,text,text);
drop function if exists zm_list_users(uuid);
drop function if exists zm_save_user(uuid,text,text,text,boolean,text);
drop function if exists zm_reset_password(uuid,uuid,text);
drop function if exists zm_delete_user(uuid,uuid);
drop function if exists zm_me(uuid);
drop table if exists zm_sessions, zm_users cascade;   -- cascade also removes zm_auth / zm_user_json
drop function if exists zm_rank(text);

-- ---------- helpers (not callable from the website) ----------
-- Checks a permit-checker session and access level (1 viewer, 2 staff, 3 admin); returns the username.
create or replace function zm_actor(p_token uuid, p_min int) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := pm_require(p_token, p_min); n text;
begin
  select username into n from pm_staff_users where id = uid;
  return n;
end $$;
revoke all on function zm_actor(uuid,int) from public, anon, authenticated;

-- ---------- who am I (restores a session on page load) ----------
create or replace function zm_me(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := pm_auth(p_token); u pm_staff_users%rowtype;
begin
  select * into u from pm_staff_users where id = uid;
  return jsonb_build_object('id',u.id,'username',u.username,'full_name',u.full_name,'role',u.role);
end $$;

-- ---------- properties / annexations ----------
create or replace function zm_list_properties(p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare staff boolean := false;
begin
  if p_token is not null then
    begin perform pm_auth(p_token); staff := true; exception when others then staff := false; end;
  end if;
  return coalesce((select jsonb_agg(
            case when staff then p.data || jsonb_build_object('id',p.id,'updated_at',p.updated_at,'updated_by',p.updated_by)
                 else (p.data - 'owner' - 'updated_by') || jsonb_build_object('id',p.id,'updated_at',p.updated_at) end
            order by p.updated_at desc)
          from zm_properties p
          where staff or upper(coalesce(p.data->>'public','Y')) <> 'N'), '[]'::jsonb);
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
  select coalesce(jsonb_object_agg(kind, jsonb_build_object('geojson',geojson,'updated_at',updated_at,'updated_by',updated_by)),'{}'::jsonb) from zm_layers $$;

-- p_mode: 'set' (use p_geojson), 'remove' (hide the layer), 'restore' (go back to the file in /data)
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
-- (Sign-in, password changes and staff logins use the permit checker's existing pm_staff_* functions.)
grant execute on function zm_me(uuid), zm_list_properties(uuid), zm_upsert_property(uuid,jsonb), zm_delete_property(uuid,text),
  zm_get_layers(), zm_set_layer(uuid,text,text,jsonb)
to anon, authenticated;

-- =====================================================================
-- OPTIONAL: give yourself an email login (the permit checker's 'admin'
-- login also works). Replace the placeholder, run it once, then clear it.
--
--   select pm_create_staff('jade.cruz@collinsalexander.com', 'PASTE-YOUR-PASSWORD-HERE', 'admin');
--
-- Or sign in with your existing admin login and add it from Staff logins.
-- =====================================================================
