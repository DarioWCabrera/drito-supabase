-- ============================================================
-- DRITO - MODULO 27
-- BACKEND SEGURO PARA CREDENCIALES ARCA
-- Archivo: 27_backend_seguro_arca.sql
--
-- Este módulo:
--   - crea un bucket PRIVADO para credenciales cifradas;
--   - guarda solamente METADATOS no secretos en PostgreSQL;
--   - no concede acceso directo a React;
--   - deja las escrituras reservadas al backend/service_role.
--
-- NO IMPLEMENTA WSAA ni WSFEv1 todavía.
-- ============================================================

begin;

-- ============================================================
-- 0. DEPENDENCIAS
-- ============================================================

do $$
begin
  if to_regclass('public.comercios') is null then
    raise exception 'Falta public.comercios';
  end if;

  if to_regclass(
    'public.configuraciones_fiscales_comercio'
  ) is null then
    raise exception
      'Falta configuraciones_fiscales_comercio';
  end if;

  if to_regclass('public.puntos_venta_fiscales') is null then
    raise exception
      'Ejecutá primero el Módulo 26';
  end if;
end;
$$;

-- ============================================================
-- 1. METADATOS DE CREDENCIALES
-- ============================================================

create table if not exists
public.arca_credenciales_metadata (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  ambiente_arca text not null
    check (
      ambiente_arca in ('homologacion', 'produccion')
    ),

  alias text,

  -- Ruta del BLOB CIFRADO. Nunca contiene la credencial.
  storage_path text not null,

  bundle_version smallint not null default 1
    check (bundle_version > 0),

  cifrado_algoritmo text not null default 'AES-256-GCM'
    check (
      cifrado_algoritmo = 'AES-256-GCM'
    ),

  certificado_subject text,
  certificado_issuer text,
  certificado_serial text,

  certificado_fingerprint_sha256 text not null,

  certificado_valido_desde timestamptz,
  certificado_valido_hasta timestamptz,

  clave_algoritmo text,

  cuit_certificado text,

  estado text not null default 'almacenadas'
    check (
      estado in (
        'almacenadas',
        'validas_localmente',
        'vencidas',
        'error'
      )
    ),

  ultimo_control_local_at timestamptz,
  ultimo_error text,

  creado_por uuid
    references auth.users(id) on delete set null,

  actualizado_por uuid
    references auth.users(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (
    comercio_id,
    ambiente_arca
  )
);

comment on table public.arca_credenciales_metadata is
  'Metadatos no secretos de credenciales ARCA. La clave privada y el certificado se almacenan cifrados en Storage privado.';

comment on column
public.arca_credenciales_metadata.storage_path is
  'Ruta del bundle cifrado AES-256-GCM. Nunca es una URL pública.';

comment on column
public.arca_credenciales_metadata.certificado_fingerprint_sha256 is
  'Huella SHA-256 del certificado; no es una clave privada.';

drop trigger if exists
arca_credenciales_metadata_updated_at
on public.arca_credenciales_metadata;

create trigger arca_credenciales_metadata_updated_at
before update
on public.arca_credenciales_metadata
for each row
execute function public.actualizar_updated_at();

create index if not exists
arca_credenciales_metadata_comercio_idx
on public.arca_credenciales_metadata (
  comercio_id,
  ambiente_arca
);

create index if not exists
arca_credenciales_metadata_vencimiento_idx
on public.arca_credenciales_metadata (
  certificado_valido_hasta
);

-- ============================================================
-- 2. RLS: NINGÚN ACCESO DIRECTO DESDE EL FRONTEND
-- ============================================================

alter table public.arca_credenciales_metadata
  enable row level security;

-- Intencionalmente NO se crean policies para authenticated/anon.
-- El service_role del backend accede con bypass RLS.

revoke all on table
public.arca_credenciales_metadata
from public, anon, authenticated;

-- En Supabase el backend utiliza service_role.
grant select, insert, update, delete
on table public.arca_credenciales_metadata
to service_role;

-- ============================================================
-- 3. BUCKET PRIVADO
-- ============================================================

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'arca-credenciales',
  'arca-credenciales',
  false,
  2097152,
  array['application/octet-stream']
)
on conflict (id) do update
set
  public = false,
  file_size_limit = 2097152,
  allowed_mime_types =
    array['application/octet-stream'];

-- Refuerzo: aunque en el proyecto exista alguna policy amplia
-- de Storage, este bucket queda bloqueado para navegador.
-- Las políticas son RESTRICTIVE y sólo bloquean este bucket.

drop policy if exists
arca_credenciales_deny_select
on storage.objects;

create policy arca_credenciales_deny_select
on storage.objects
as restrictive
for select
to anon, authenticated
using (
  bucket_id <> 'arca-credenciales'
);

drop policy if exists
arca_credenciales_deny_insert
on storage.objects;

create policy arca_credenciales_deny_insert
on storage.objects
as restrictive
for insert
to anon, authenticated
with check (
  bucket_id <> 'arca-credenciales'
);

drop policy if exists
arca_credenciales_deny_update
on storage.objects;

create policy arca_credenciales_deny_update
on storage.objects
as restrictive
for update
to anon, authenticated
using (
  bucket_id <> 'arca-credenciales'
)
with check (
  bucket_id <> 'arca-credenciales'
);

drop policy if exists
arca_credenciales_deny_delete
on storage.objects;

create policy arca_credenciales_deny_delete
on storage.objects
as restrictive
for delete
to anon, authenticated
using (
  bucket_id <> 'arca-credenciales'
);

-- El service_role del backend opera Storage con bypass RLS.

-- ============================================================
-- 4. REFUERZO DE CAMPOS DEL MÓDULO 23
-- ============================================================

comment on column
public.configuraciones_fiscales_comercio.certificado_alias is
  'Alias informativo. Nunca contiene certificado, clave privada ni passphrase.';

comment on column
public.configuraciones_fiscales_comercio.certificado_identificador is
  'Huella/identificador informativo del certificado. Nunca contiene la clave privada.';

-- ============================================================
-- 5. VERIFICACIÓN
-- ============================================================

notify pgrst, 'reload schema';

commit;

select jsonb_build_object(
  'modulo', 27,
  'nombre', 'Backend seguro ARCA',
  'tabla_metadata',
    to_regclass(
      'public.arca_credenciales_metadata'
    ) is not null,
  'bucket_privado',
    exists (
      select 1
      from storage.buckets
      where id = 'arca-credenciales'
        and public = false
    ),
  'policies_frontend_metadata',
    (
      select count(*)
      from pg_policies
      where schemaname = 'public'
        and tablename =
          'arca_credenciales_metadata'
    ),
  'objetos_credenciales',
    (
      select count(*)
      from storage.objects
      where bucket_id = 'arca-credenciales'
    )
) as modulo_27_instalado;

-- ============================================================
-- FIN MÓDULO 27 - SQL
-- ============================================================