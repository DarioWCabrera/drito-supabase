begin;

-- =====================================================
-- 18A.1 - CUENTA DRITO / BASE MULTIEMPRESA
-- =====================================================

create table if not exists public.cuentas_drito (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  multiempresa_habilitada boolean not null default false,
  activo boolean not null default true,
  creado_por uuid null
    references public.perfiles(id)
    on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Cada comercio pertenece a una Cuenta Drito.
alter table public.comercios
  add column if not exists cuenta_drito_id uuid null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'comercios_cuenta_drito_id_fkey'
  ) then
    alter table public.comercios
      add constraint comercios_cuenta_drito_id_fkey
      foreign key (cuenta_drito_id)
      references public.cuentas_drito(id)
      on delete restrict;
  end if;
end
$$;

create index if not exists idx_comercios_cuenta_drito_id
  on public.comercios(cuenta_drito_id);

-- =====================================================
-- BACKFILL SEGURO
-- Cada comercio existente recibe inicialmente
-- su propia Cuenta Drito.
--
-- NO agrupamos automáticamente empresas por usuario:
-- un mismo administrador podría gestionar clientes
-- completamente independientes.
-- =====================================================

do $$
declare
  v_comercio record;
  v_cuenta_id uuid;
begin
  for v_comercio in
    select
      id,
      nombre_comercial
    from public.comercios
    where cuenta_drito_id is null
    order by created_at
  loop
    insert into public.cuentas_drito (
      nombre,
      multiempresa_habilitada,
      activo
    )
    values (
      v_comercio.nombre_comercial,
      false,
      true
    )
    returning id into v_cuenta_id;

    update public.comercios
    set cuenta_drito_id = v_cuenta_id
    where id = v_comercio.id;
  end loop;
end
$$;

alter table public.comercios
  alter column cuenta_drito_id set not null;

-- =====================================================
-- HELPERS DE SEGURIDAD
-- =====================================================

create or replace function public.pertenece_a_cuenta_drito(
  p_cuenta_drito_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.comercios c
    join public.usuarios_comercios uc
      on uc.comercio_id = c.id
    where c.cuenta_drito_id = p_cuenta_drito_id
      and uc.usuario_id = (select auth.uid())
      and uc.activo = true
      and c.activo = true
  );
$$;

create or replace function public.es_admin_cuenta_drito(
  p_cuenta_drito_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.comercios c
    join public.usuarios_comercios uc
      on uc.comercio_id = c.id
    where c.cuenta_drito_id = p_cuenta_drito_id
      and uc.usuario_id = (select auth.uid())
      and uc.activo = true
      and uc.rol = 'admin'
      and c.activo = true
  );
$$;

revoke all
on function public.pertenece_a_cuenta_drito(uuid)
from public;

revoke all
on function public.es_admin_cuenta_drito(uuid)
from public;

grant execute
on function public.pertenece_a_cuenta_drito(uuid)
to authenticated;

grant execute
on function public.es_admin_cuenta_drito(uuid)
to authenticated;

-- =====================================================
-- RLS CUENTAS DRITO
-- Por ahora sólo lectura.
-- Los cambios y altas multiempresa se harán después
-- mediante RPCs controladas.
-- =====================================================

alter table public.cuentas_drito
  enable row level security;

drop policy if exists
cuentas_drito_select_miembro
on public.cuentas_drito;

create policy
cuentas_drito_select_miembro
on public.cuentas_drito
for select
to authenticated
using (
  public.pertenece_a_cuenta_drito(id)
);

-- =====================================================
-- UPDATED_AT
-- =====================================================

do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgname = 'cuentas_drito_actualizar_updated_at'
  ) then
    create trigger cuentas_drito_actualizar_updated_at
    before update on public.cuentas_drito
    for each row
    execute function public.actualizar_updated_at();
  end if;
end
$$;

commit;