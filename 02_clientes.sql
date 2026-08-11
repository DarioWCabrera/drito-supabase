-- =====================================================
-- DRITO - MÓDULO DE CLIENTES
-- =====================================================

create table if not exists public.clientes (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  tipo_cliente text not null default 'persona'
    check (tipo_cliente in ('persona', 'empresa')),

  nombre text not null
    check (char_length(trim(nombre)) >= 2),

  razon_social text,

  tipo_documento text not null default 'DNI'
    check (
      tipo_documento in (
        'DNI',
        'CUIT',
        'CUIL',
        'OTRO'
      )
    ),

  documento text,

  condicion_iva text not null default 'consumidor_final'
    check (
      condicion_iva in (
        'consumidor_final',
        'responsable_inscripto',
        'monotributista',
        'exento',
        'no_responsable',
        'otro'
      )
    ),

  email text,
  telefono text,

  direccion text,
  localidad text,
  provincia text,
  codigo_postal text,

  observaciones text,

  activo boolean not null default true,

  creado_por uuid
    references auth.users(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =====================================================
-- ÍNDICES
-- =====================================================

create index if not exists clientes_comercio_activo_idx
on public.clientes (
  comercio_id,
  activo
);

create index if not exists clientes_comercio_nombre_idx
on public.clientes (
  comercio_id,
  lower(nombre)
);

create index if not exists clientes_comercio_documento_idx
on public.clientes (
  comercio_id,
  documento
);

-- Evita repetir el mismo documento dentro de un comercio.
-- El mismo cliente sí puede existir en comercios diferentes.

create unique index if not exists clientes_documento_unique_idx
on public.clientes (
  comercio_id,
  tipo_documento,
  (
    regexp_replace(
      coalesce(documento, ''),
      '[^0-9A-Za-z]',
      '',
      'g'
    )
  )
)
where documento is not null
  and trim(documento) <> '';

-- =====================================================
-- UPDATED_AT AUTOMÁTICO
-- =====================================================

drop trigger if exists clientes_updated_at
on public.clientes;

create trigger clientes_updated_at
before update on public.clientes
for each row
execute function public.actualizar_updated_at();

-- =====================================================
-- PROTEGER CAMPOS INTERNOS
-- =====================================================

create or replace function public.proteger_campos_cliente()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.comercio_id <> old.comercio_id then
    raise exception
      'No se puede cambiar un cliente de comercio';
  end if;

  new.creado_por = old.creado_por;

  return new;
end;
$$;

drop trigger if exists clientes_proteger_campos
on public.clientes;

create trigger clientes_proteger_campos
before update on public.clientes
for each row
execute function public.proteger_campos_cliente();

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.clientes
enable row level security;

-- Los miembros pueden ver clientes de su comercio.

drop policy if exists clientes_select_miembro
on public.clientes;

create policy clientes_select_miembro
on public.clientes
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

-- Los miembros pueden crear clientes dentro de su comercio.

drop policy if exists clientes_insert_miembro
on public.clientes;

create policy clientes_insert_miembro
on public.clientes
for insert
to authenticated
with check (
  public.pertenece_a_comercio(comercio_id)
  and creado_por = (select auth.uid())
);

-- Los miembros pueden modificar clientes de su comercio.

drop policy if exists clientes_update_miembro
on public.clientes;

create policy clientes_update_miembro
on public.clientes
for update
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
)
with check (
  public.pertenece_a_comercio(comercio_id)
);

-- Solo un administrador puede borrar físicamente un cliente.

drop policy if exists clientes_delete_admin
on public.clientes;

create policy clientes_delete_admin
on public.clientes
for delete
to authenticated
using (
  public.es_admin_comercio(comercio_id)
);

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on public.clientes
from anon;

grant select, insert, update, delete
on public.clientes
to authenticated;