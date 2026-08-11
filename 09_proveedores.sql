-- =====================================================
-- DRITO - PROVEEDORES
-- =====================================================

create table if not exists public.proveedores (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  nombre text not null
    check (
      char_length(trim(nombre)) >= 2
    ),

  razon_social text,

  tipo_documento text not null default 'CUIT'
    check (
      tipo_documento in (
        'CUIT',
        'CUIL',
        'DNI',
        'Otro'
      )
    ),

  documento text,

  condicion_iva text not null default 'otro'
    check (
      condicion_iva in (
        'responsable_inscripto',
        'monotributista',
        'exento',
        'consumidor_final',
        'no_responsable',
        'otro'
      )
    ),

  nombre_contacto text,

  telefono text,
  email text,

  direccion text,
  ciudad text,
  provincia text,
  codigo_postal text,

  plazo_pago_dias integer not null default 0
    check (
      plazo_pago_dias >= 0
    ),

  observaciones text,

  activo boolean not null default true,

  creado_por uuid
    references auth.users(id)
    on delete set null
    default auth.uid(),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =====================================================
-- ÍNDICES
-- =====================================================

create index if not exists proveedores_comercio_idx
on public.proveedores (
  comercio_id,
  created_at desc
);

create index if not exists proveedores_nombre_idx
on public.proveedores (
  comercio_id,
  nombre
);

create index if not exists proveedores_activo_idx
on public.proveedores (
  comercio_id,
  activo
);

create unique index if not exists proveedores_documento_unique_idx
on public.proveedores (
  comercio_id,
  documento
)
where documento is not null
  and trim(documento) <> '';

-- =====================================================
-- UPDATED_AT
-- =====================================================

create or replace function
public.actualizar_proveedores_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();

  return new;
end;
$$;

drop trigger if exists proveedores_updated_at
on public.proveedores;

create trigger proveedores_updated_at
before update
on public.proveedores
for each row
execute function
public.actualizar_proveedores_updated_at();

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.proveedores
enable row level security;

drop policy if exists
"Miembros pueden ver proveedores"
on public.proveedores;

create policy
"Miembros pueden ver proveedores"
on public.proveedores
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

drop policy if exists
"Miembros pueden crear proveedores"
on public.proveedores;

create policy
"Miembros pueden crear proveedores"
on public.proveedores
for insert
to authenticated
with check (
  public.pertenece_a_comercio(
    comercio_id
  )
);

drop policy if exists
"Miembros pueden actualizar proveedores"
on public.proveedores;

create policy
"Miembros pueden actualizar proveedores"
on public.proveedores
for update
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
)
with check (
  public.pertenece_a_comercio(
    comercio_id
  )
);

-- No creamos DELETE.
-- Los proveedores se desactivarán para conservar
-- el historial futuro de compras y pagos.

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on public.proveedores
from anon;

grant select, insert, update
on public.proveedores
to authenticated;