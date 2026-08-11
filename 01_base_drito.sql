-- =====================================================
-- DRITO - ESTRUCTURA BASE MULTIEMPRESA
-- =====================================================

create extension if not exists pgcrypto;

-- =====================================================
-- TABLAS
-- =====================================================

create table if not exists public.comercios (
  id uuid primary key default gen_random_uuid(),

  nombre_comercial text not null,
  razon_social text,
  cuit text,
  email text,
  telefono text,
  direccion text,

  slug text not null unique,

  activo boolean not null default true,

  modo_facturacion text not null default 'manual'
    check (modo_facturacion in ('manual', 'arca')),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.perfiles (
  id uuid primary key references auth.users(id) on delete cascade,

  nombre_completo text,
  email text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.usuarios_comercios (
  id uuid primary key default gen_random_uuid(),

  usuario_id uuid not null
    references public.perfiles(id) on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  rol text not null default 'empleado'
    check (rol in ('admin', 'empleado', 'vendedor')),

  activo boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (usuario_id, comercio_id)
);

create table if not exists public.configuraciones_comercio (
  comercio_id uuid primary key
    references public.comercios(id) on delete cascade,

  logo_url text,

  color_primario text not null default '#4f46e5',
  color_secundario text not null default '#111827',

  moneda text not null default 'ARS',

  texto_cotizacion text,
  texto_comprobante text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =====================================================
-- UPDATED_AT AUTOMÁTICO
-- =====================================================

create or replace function public.actualizar_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists comercios_updated_at
on public.comercios;

create trigger comercios_updated_at
before update on public.comercios
for each row
execute function public.actualizar_updated_at();

drop trigger if exists perfiles_updated_at
on public.perfiles;

create trigger perfiles_updated_at
before update on public.perfiles
for each row
execute function public.actualizar_updated_at();

drop trigger if exists usuarios_comercios_updated_at
on public.usuarios_comercios;

create trigger usuarios_comercios_updated_at
before update on public.usuarios_comercios
for each row
execute function public.actualizar_updated_at();

drop trigger if exists configuraciones_comercio_updated_at
on public.configuraciones_comercio;

create trigger configuraciones_comercio_updated_at
before update on public.configuraciones_comercio
for each row
execute function public.actualizar_updated_at();

-- =====================================================
-- CREACIÓN AUTOMÁTICA DEL PERFIL
-- =====================================================

create or replace function public.crear_perfil_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.perfiles (
    id,
    nombre_completo,
    email
  )
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'nombre_completo',
      split_part(coalesce(new.email, ''), '@', 1)
    ),
    new.email
  )
  on conflict (id) do update
  set
    email = excluded.email,
    updated_at = now();

  return new;
end;
$$;

drop trigger if exists on_auth_user_created
on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.crear_perfil_nuevo_usuario();

-- Crear perfiles para usuarios que ya existían
insert into public.perfiles (
  id,
  nombre_completo,
  email
)
select
  id,
  coalesce(
    raw_user_meta_data ->> 'nombre_completo',
    split_part(coalesce(email, ''), '@', 1)
  ),
  email
from auth.users
on conflict (id) do update
set
  email = excluded.email,
  updated_at = now();

-- =====================================================
-- FUNCIONES DE SEGURIDAD MULTIEMPRESA
-- =====================================================

create or replace function public.pertenece_a_comercio(
  p_comercio_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.usuarios_comercios uc
    where uc.comercio_id = p_comercio_id
      and uc.usuario_id = (select auth.uid())
      and uc.activo = true
  );
$$;

create or replace function public.es_admin_comercio(
  p_comercio_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.usuarios_comercios uc
    where uc.comercio_id = p_comercio_id
      and uc.usuario_id = (select auth.uid())
      and uc.rol = 'admin'
      and uc.activo = true
  );
$$;

revoke all
on function public.pertenece_a_comercio(uuid)
from public;

revoke all
on function public.es_admin_comercio(uuid)
from public;

grant execute
on function public.pertenece_a_comercio(uuid)
to authenticated;

grant execute
on function public.es_admin_comercio(uuid)
to authenticated;

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.comercios
enable row level security;

alter table public.perfiles
enable row level security;

alter table public.usuarios_comercios
enable row level security;

alter table public.configuraciones_comercio
enable row level security;

-- PERFILES

drop policy if exists perfiles_select_propio
on public.perfiles;

create policy perfiles_select_propio
on public.perfiles
for select
to authenticated
using (
  id = (select auth.uid())
);

drop policy if exists perfiles_update_propio
on public.perfiles;

create policy perfiles_update_propio
on public.perfiles
for update
to authenticated
using (
  id = (select auth.uid())
)
with check (
  id = (select auth.uid())
);

-- COMERCIOS

drop policy if exists comercios_select_miembro
on public.comercios;

create policy comercios_select_miembro
on public.comercios
for select
to authenticated
using (
  public.pertenece_a_comercio(id)
);

drop policy if exists comercios_update_admin
on public.comercios;

create policy comercios_update_admin
on public.comercios
for update
to authenticated
using (
  public.es_admin_comercio(id)
)
with check (
  public.es_admin_comercio(id)
);

-- USUARIOS DEL COMERCIO

drop policy if exists usuarios_comercios_select
on public.usuarios_comercios;

create policy usuarios_comercios_select
on public.usuarios_comercios
for select
to authenticated
using (
  usuario_id = (select auth.uid())
  or public.es_admin_comercio(comercio_id)
);

drop policy if exists usuarios_comercios_insert_admin
on public.usuarios_comercios;

create policy usuarios_comercios_insert_admin
on public.usuarios_comercios
for insert
to authenticated
with check (
  public.es_admin_comercio(comercio_id)
);

drop policy if exists usuarios_comercios_update_admin
on public.usuarios_comercios;

create policy usuarios_comercios_update_admin
on public.usuarios_comercios
for update
to authenticated
using (
  public.es_admin_comercio(comercio_id)
)
with check (
  public.es_admin_comercio(comercio_id)
);

drop policy if exists usuarios_comercios_delete_admin
on public.usuarios_comercios;

create policy usuarios_comercios_delete_admin
on public.usuarios_comercios
for delete
to authenticated
using (
  public.es_admin_comercio(comercio_id)
);

-- CONFIGURACIÓN DEL COMERCIO

drop policy if exists configuracion_select_miembro
on public.configuraciones_comercio;

create policy configuracion_select_miembro
on public.configuraciones_comercio
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

drop policy if exists configuracion_insert_admin
on public.configuraciones_comercio;

create policy configuracion_insert_admin
on public.configuraciones_comercio
for insert
to authenticated
with check (
  public.es_admin_comercio(comercio_id)
);

drop policy if exists configuracion_update_admin
on public.configuraciones_comercio;

create policy configuracion_update_admin
on public.configuraciones_comercio
for update
to authenticated
using (
  public.es_admin_comercio(comercio_id)
)
with check (
  public.es_admin_comercio(comercio_id)
);

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all on public.comercios from anon;
revoke all on public.perfiles from anon;
revoke all on public.usuarios_comercios from anon;
revoke all on public.configuraciones_comercio from anon;

grant select, insert, update, delete
on public.comercios
to authenticated;

grant select, insert, update, delete
on public.perfiles
to authenticated;

grant select, insert, update, delete
on public.usuarios_comercios
to authenticated;

grant select, insert, update, delete
on public.configuraciones_comercio
to authenticated;