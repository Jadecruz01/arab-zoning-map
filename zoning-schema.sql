-- =====================================================================
-- City of Arab — Zoning & Property Map: staff logins + shared storage
-- Supabase project: yighcuismepfmappcfui (shared with the permit checker
-- and ticket portal). Every object here is prefixed zm_ so nothing
-- collides with the pm_ / ticket tables. Safe to re-run.
--
-- Roles:  super_admin > admin > editor > viewer
--   super_admin  everything, including creating/removing admins
--   admin        manage editor/viewer logins, reset their passwords,
--                change map layers, add/edit/delete properties
--   editor       add/edit/delete properties
--   viewer       sign in and see staff-only fields
-- =====================================================================

create extension if not exists pgcrypto;

create table if not exists zm_users (
  id          uuid primary key default gen_random_uuid(),
  email       text not null unique,
  name        text not null default '',
  role        text not null default 'editor' check (role in ('super_admin','admin','editor','viewer')),
  pw_hash     text not null,
  active      boolean not null default true,
  must_change boolean not null default false,
  created_at  timestamptz not null default now(),
  last_login  timestamptz
);

create table if not exists zm_sessions (
  token      uuid primary key default gen_random_uuid(),
  user_id    uuid not null references zm_users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '12 hours'
);

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

alter table zm_users      enable row level security;
alter table zm_sessions   enable row level security;
alter table zm_properties enable row level security;
alter table zm_layers     enable row level security;
alter table zm_log        enable row level security;
revoke all on zm_users, zm_sessions, zm_properties, zm_layers, zm_log from anon, authenticated;

-- ---------- helpers (not callable from the website) ----------
create or replace function zm_rank(r text) returns int language sql immutable as $$
  select case r when 'super_admin' then 4 when 'admin' then 3 when 'editor' then 2 when 'viewer' then 1 else 0 end $$;

create or replace function zm_auth(p_token uuid, p_min text default 'viewer')
returns zm_users language plpgsql security definer set search_path = public as $$
declare u zm_users;
begin
  select users.* into u from zm_sessions s join zm_users users on users.id = s.user_id
   where s.token = p_token and s.expires_at > now() and users.active;
  if u.id is null then raise exception 'Your session has expired. Sign in again.' using errcode = '28000'; end if;
  if zm_rank(u.role) < zm_rank(p_min) then raise exception 'You don''t have permission to do that.' using errcode = '42501'; end if;
  return u;
end $$;

create or replace function zm_user_json(u zm_users) returns jsonb language sql stable as $$
  select jsonb_build_object('id',u.id,'email',u.email,'name',u.name,'role',u.role,'active',u.active,
    'must_change',u.must_change,'created_at',u.created_at,'last_login',u.last_login) $$;

-- First super admin. Run once from the SQL Editor (not exposed to the website).
create or replace function zm_bootstrap(p_email text, p_password text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if length(p_password) < 10 then raise exception 'Use at least 10 characters'; end if;
  insert into zm_users(email,name,role,pw_hash) values (lower(trim(p_email)),'', 'super_admin', crypt(p_password, gen_salt('bf',10)))
  on conflict (email) do update set role='super_admin', pw_hash=excluded.pw_hash, active=true, must_change=false;
  return 'Super admin ready: '||lower(trim(p_email));
end $$;
revoke all on function zm_bootstrap(text,text) from public, anon, authenticated;

-- ---------- sign in / out ----------
create or replace function zm_login(p_email text, p_password text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u zm_users; t uuid;
begin
  select * into u from zm_users where email = lower(trim(p_email));
  if u.id is null or not u.active or u.pw_hash <> crypt(p_password, u.pw_hash) then
    perform pg_sleep(0.6);
    raise exception 'That email and password don''t match.' using errcode = '28P01';
  end if;
  delete from zm_sessions where expires_at < now();
  insert into zm_sessions(user_id) values (u.id) returning token into t;
  update zm_users set last_login = now() where id = u.id;
  insert into zm_log(actor,action) values (u.email,'login');
  return jsonb_build_object('token',t,'user',zm_user_json(u));
end $$;

create or replace function zm_logout(p_token uuid) returns void language sql security definer set search_path = public as $$
  delete from zm_sessions where token = p_token $$;

create or replace function zm_me(p_token uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u zm_users; begin u := zm_auth(p_token); return zm_user_json(u); end $$;

create or replace function zm_change_password(p_token uuid, p_old text, p_new text)
returns void language plpgsql security definer set search_path = public as $$
declare u zm_users;
begin
  u := zm_auth(p_token);
  if u.pw_hash <> crypt(p_old, u.pw_hash) then raise exception 'Your current password is wrong.'; end if;
  if length(p_new) < 10 then raise exception 'Use at least 10 characters.'; end if;
  update zm_users set pw_hash = crypt(p_new, gen_salt('bf',10)), must_change = false where id = u.id;
  delete from zm_sessions where user_id = u.id and token <> p_token;
  insert into zm_log(actor,action) values (u.email,'change_password');
end $$;

-- ---------- staff logins (admin+) ----------
create or replace function zm_list_users(p_token uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare u zm_users;
begin
  u := zm_auth(p_token,'admin');
  return coalesce((select jsonb_agg(zm_user_json(x) order by zm_rank(x.role) desc, x.email) from zm_users x),'[]'::jsonb);
end $$;

-- Create a login, or update name/role/active. p_password only used when creating.
create or replace function zm_save_user(p_token uuid, p_email text, p_name text, p_role text, p_active boolean, p_password text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me zm_users; x zm_users; e text := lower(trim(p_email));
begin
  me := zm_auth(p_token,'admin');
  if p_role not in ('super_admin','admin','editor','viewer') then raise exception 'Unknown role.'; end if;
  if zm_rank(p_role) >= zm_rank('admin') and me.role <> 'super_admin' then raise exception 'Only a super admin can create or change admins.'; end if;
  select * into x from zm_users where email = e;
  if x.id is not null then
    if zm_rank(x.role) >= zm_rank('admin') and me.role <> 'super_admin' then raise exception 'Only a super admin can change an admin.'; end if;
    if x.id = me.id and (p_role <> me.role or not p_active) then raise exception 'You can''t change your own role or deactivate yourself.'; end if;
    update zm_users set name = coalesce(p_name,''), role = p_role, active = p_active where id = x.id returning * into x;
    if not p_active then delete from zm_sessions where user_id = x.id; end if;
  else
    if p_password is null or length(p_password) < 10 then raise exception 'Give the new login a temporary password of at least 10 characters.'; end if;
    insert into zm_users(email,name,role,active,pw_hash,must_change)
    values (e, coalesce(p_name,''), p_role, p_active, crypt(p_password, gen_salt('bf',10)), true) returning * into x;
  end if;
  insert into zm_log(actor,action,detail) values (me.email,'save_user',jsonb_build_object('email',e,'role',p_role,'active',p_active));
  return zm_user_json(x);
end $$;

create or replace function zm_reset_password(p_token uuid, p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public as $$
declare me zm_users; x zm_users;
begin
  me := zm_auth(p_token,'admin');
  select * into x from zm_users where id = p_user;
  if x.id is null then raise exception 'That login no longer exists.'; end if;
  if zm_rank(x.role) >= zm_rank('admin') and me.role <> 'super_admin' and x.id <> me.id then raise exception 'Only a super admin can reset an admin''s password.'; end if;
  if length(p_password) < 10 then raise exception 'Use at least 10 characters.'; end if;
  update zm_users set pw_hash = crypt(p_password, gen_salt('bf',10)), must_change = (x.id <> me.id) where id = x.id;
  delete from zm_sessions where user_id = x.id and token <> p_token;
  insert into zm_log(actor,action,detail) values (me.email,'reset_password',jsonb_build_object('email',x.email));
end $$;

create or replace function zm_delete_user(p_token uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me zm_users; x zm_users;
begin
  me := zm_auth(p_token,'admin');
  select * into x from zm_users where id = p_user;
  if x.id is null then return; end if;
  if x.id = me.id then raise exception 'You can''t delete your own login.'; end if;
  if zm_rank(x.role) >= zm_rank('admin') and me.role <> 'super_admin' then raise exception 'Only a super admin can delete an admin.'; end if;
  if x.role = 'super_admin' and (select count(*) from zm_users where role='super_admin' and active) <= 1 then raise exception 'Keep at least one super admin.'; end if;
  delete from zm_users where id = x.id;
  insert into zm_log(actor,action,detail) values (me.email,'delete_user',jsonb_build_object('email',x.email));
end $$;

-- ---------- properties / annexations ----------
create or replace function zm_list_properties(p_token uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare staff boolean := false;
begin
  if p_token is not null then
    begin perform zm_auth(p_token); staff := true; exception when others then staff := false; end;
  end if;
  return coalesce((select jsonb_agg(
            case when staff then p.data || jsonb_build_object('id',p.id,'updated_at',p.updated_at,'updated_by',p.updated_by)
                 else (p.data - 'owner' - 'updated_by') || jsonb_build_object('id',p.id,'updated_at',p.updated_at) end
            order by p.updated_at desc)
          from zm_properties p
          where staff or upper(coalesce(p.data->>'public','Y')) <> 'N'), '[]'::jsonb);
end $$;

create or replace function zm_upsert_property(p_token uuid, p_row jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me zm_users; pid text := coalesce(nullif(p_row->>'id',''), 'p'||replace(gen_random_uuid()::text,'-',''));
begin
  me := zm_auth(p_token,'editor');
  insert into zm_properties(id,data,updated_at,updated_by)
  values (pid, p_row - 'id' - 'updated_at' - 'updated_by', now(), me.email)
  on conflict (id) do update set data = zm_properties.data || excluded.data, updated_at = now(), updated_by = me.email;
  insert into zm_log(actor,action,detail) values (me.email,'upsert_property',jsonb_build_object('id',pid,'status',p_row->>'status'));
  return jsonb_build_object('id',pid);
end $$;

create or replace function zm_delete_property(p_token uuid, p_id text)
returns void language plpgsql security definer set search_path = public as $$
declare me zm_users;
begin
  me := zm_auth(p_token,'editor');
  delete from zm_properties where id = p_id;
  insert into zm_log(actor,action,detail) values (me.email,'delete_property',jsonb_build_object('id',p_id));
end $$;

-- ---------- map layers (shared overrides of the files in /data) ----------
create or replace function zm_get_layers() returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(kind, jsonb_build_object('geojson',geojson,'updated_at',updated_at,'updated_by',updated_by)),'{}'::jsonb) from zm_layers $$;

-- p_mode: 'set' (use p_geojson), 'remove' (hide the layer), 'restore' (go back to the file in /data)
create or replace function zm_set_layer(p_token uuid, p_kind text, p_mode text, p_geojson jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare me zm_users;
begin
  me := zm_auth(p_token,'admin');
  if p_kind not in ('parcels','limits','gas') then raise exception 'Unknown layer.'; end if;
  if p_mode = 'restore' then delete from zm_layers where kind = p_kind;
  elsif p_mode = 'remove' then insert into zm_layers(kind,geojson,updated_by) values (p_kind,null,me.email)
       on conflict (kind) do update set geojson = null, updated_at = now(), updated_by = me.email;
  elsif p_mode = 'set' then insert into zm_layers(kind,geojson,updated_by) values (p_kind,p_geojson,me.email)
       on conflict (kind) do update set geojson = excluded.geojson, updated_at = now(), updated_by = me.email;
  else raise exception 'Unknown mode.'; end if;
  insert into zm_log(actor,action,detail) values (me.email,'layer_'||p_mode,jsonb_build_object('kind',p_kind));
end $$;

-- ---------- what the website may call ----------
grant execute on function zm_login(text,text), zm_logout(uuid), zm_me(uuid), zm_change_password(uuid,text,text),
  zm_list_users(uuid), zm_save_user(uuid,text,text,text,boolean,text), zm_reset_password(uuid,uuid,text), zm_delete_user(uuid,uuid),
  zm_list_properties(uuid), zm_upsert_property(uuid,jsonb), zm_delete_property(uuid,text),
  zm_get_layers(), zm_set_layer(uuid,text,text,jsonb)
to anon, authenticated;
revoke all on function zm_auth(uuid,text), zm_user_json(zm_users) from public, anon, authenticated;

-- =====================================================================
-- LAST STEP (run once, by you, in the SQL Editor): create your login.
-- Replace the placeholder with your password, run it, then clear it.
--
--   select zm_bootstrap('jade.cruz@collinsalexander.com', 'PASTE-YOUR-PASSWORD-HERE');
-- =====================================================================
