-- =============================================================
-- DRITO - PASO 12A.1
-- MODELO BASE DE RETENCIONES SUFRIDAS EN COBRANZAS
-- =============================================================
-- Objetivo de este paso:
--   1) Crear una estructura multiempresa para guardar certificados
--      de retenciones sufridas por el comercio.
--   2) NO modificar todavía registrar_pago_venta, cobros agrupados
--      ni movimientos_caja.
--   3) NO generar ingresos de Caja por una retención.
--   4) NO hardcodear alícuotas, regímenes ni jurisdicciones.
--
-- Regla económica que implementaremos en el paso siguiente:
--   deuda cancelada = dinero recibido + retenciones sufridas
--   Caja             = solo dinero efectivamente recibido
-- =============================================================

begin;

-- -------------------------------------------------------------
-- 0. PRECONDICIONES
-- -------------------------------------------------------------
do $$
begin
  if to_regclass('public.comercios') is null then
    raise exception 'Falta public.comercios';
  end if;

  if to_regclass('public.clientes') is null then
    raise exception 'Falta public.clientes';
  end if;

  if to_regclass('public.ventas') is null then
    raise exception 'Falta public.ventas';
  end if;

  if to_regclass('public.pagos_ventas') is null then
    raise exception 'Falta public.pagos_ventas';
  end if;

  if to_regprocedure(
    'public.tiene_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.tiene_permiso_comercio(uuid,text)';
  end if;
end;
$$;

-- -------------------------------------------------------------
-- 1. RETENCIONES SUFRIDAS
-- -------------------------------------------------------------
create table if not exists public.retenciones_sufridas (
  id uuid primary key default gen_random_uuid(),

  -- Aislamiento multiempresa obligatorio.
  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  -- El cliente/agente que practicó la retención.
  cliente_id uuid not null
    references public.clientes(id) on delete restrict,

  -- Relación comercial opcional.
  -- Una retención puede corresponder a una venta puntual o a un
  -- cobro agrupado que cancela varias ventas.
  venta_id uuid
    references public.ventas(id) on delete set null,

  -- Cobro individual de una venta.
  pago_venta_id uuid
    references public.pagos_ventas(id) on delete set null,

  -- Cobro agrupado de cuenta corriente.
  -- La FK se agrega dinámicamente más abajo si la tabla actual
  -- public.cobros_clientes existe en esta instalación.
  cobro_cliente_id uuid,

  -- Fecha del certificado / retención.
  fecha_retencion date not null default current_date,

  -- Período informado en el certificado, cuando exista.
  periodo_desde date,
  periodo_hasta date,

  -- Datos fiscales del certificado como SNAPSHOT.
  -- Son texto deliberadamente: Drito no debe asumir que los
  -- regímenes o jurisdicciones son universales o permanentes.
  impuesto text not null
    check (char_length(trim(impuesto)) >= 2),

  jurisdiccion text,
  regimen_codigo text,
  regimen_descripcion text,

  -- CUIT/razón social del agente retenedor al momento del cobro.
  -- Se guardan como snapshot para conservar trazabilidad aunque
  -- luego cambie la ficha del cliente.
  agente_retencion_cuit text,
  agente_retencion_razon_social text,

  numero_certificado text not null
    check (char_length(trim(numero_certificado)) >= 1),

  -- Datos de cálculo informativos. No se calculan ni se fuerzan.
  base_calculo numeric(18,2)
    check (base_calculo is null or base_calculo >= 0),

  alicuota numeric(9,6)
    check (
      alicuota is null
      or (alicuota >= 0 and alicuota <= 100)
    ),

  importe numeric(18,2) not null
    check (importe > 0),

  moneda text not null default 'ARS'
    check (char_length(trim(moneda)) >= 3),

  observaciones text,

  -- Preparado para adjuntar el certificado en Storage más adelante.
  certificado_storage_path text,

  estado text not null default 'registrada'
    check (estado in ('registrada', 'anulada')),

  creado_por uuid
    references auth.users(id) on delete set null,

  anulado_por uuid
    references auth.users(id) on delete set null,

  anulado_at timestamptz,
  motivo_anulacion text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (
    periodo_hasta is null
    or periodo_desde is null
    or periodo_hasta >= periodo_desde
  ),

  -- Una retención se asocia al cobro individual O al agrupado,
  -- nunca a ambos simultáneamente.
  check (
    num_nonnulls(pago_venta_id, cobro_cliente_id) <= 1
  ),

  -- Si está anulada debe quedar trazabilidad mínima.
  check (
    estado <> 'anulada'
    or (
      anulado_at is not null
      and nullif(trim(coalesce(motivo_anulacion, '')), '')
        is not null
    )
  )
);

comment on table public.retenciones_sufridas is
  'Certificados de retenciones sufridas en cobranzas. Cancelan deuda comercial pero NO representan dinero ingresado a Caja.';

comment on column public.retenciones_sufridas.importe is
  'Importe que reduce la deuda del cliente como retención sufrida. No debe sumarse como ingreso de Caja.';

comment on column public.retenciones_sufridas.alicuota is
  'Snapshot informativo de la alícuota del certificado. No se hardcodea ni se usa como regla global.';

comment on column public.retenciones_sufridas.certificado_storage_path is
  'Ruta opcional del certificado adjunto. El bucket se definirá en un paso posterior.';

-- -------------------------------------------------------------
-- 2. ÍNDICES
-- -------------------------------------------------------------
create index if not exists
retenciones_sufridas_comercio_fecha_idx
on public.retenciones_sufridas (
  comercio_id,
  fecha_retencion desc,
  created_at desc
);

create index if not exists
retenciones_sufridas_cliente_fecha_idx
on public.retenciones_sufridas (
  cliente_id,
  fecha_retencion desc
);

create index if not exists
retenciones_sufridas_venta_idx
on public.retenciones_sufridas (venta_id)
where venta_id is not null;

create index if not exists
retenciones_sufridas_pago_venta_idx
on public.retenciones_sufridas (pago_venta_id)
where pago_venta_id is not null;

create index if not exists
retenciones_sufridas_cobro_cliente_idx
on public.retenciones_sufridas (cobro_cliente_id)
where cobro_cliente_id is not null;

-- Evita duplicar el mismo certificado dentro de un comercio.
-- Incluimos impuesto y jurisdicción porque un mismo número externo
-- podría existir en circuitos fiscales diferentes.
create unique index if not exists
retenciones_sufridas_certificado_uq
on public.retenciones_sufridas (
  comercio_id,
  lower(trim(impuesto)),
  lower(trim(coalesce(jurisdiccion, ''))),
  lower(trim(numero_certificado))
);

-- -------------------------------------------------------------
-- 3. FK OPCIONAL A COBRO AGRUPADO
-- -------------------------------------------------------------
-- La instalación actual de Drito usa cobro_cliente_id en
-- pagos_ventas. Agregamos integridad referencial únicamente si
-- existe public.cobros_clientes. Si una instalación histórica usa
-- otro nombre, este paso no falla ni inventa una relación.
do $$
begin
  if to_regclass('public.cobros_clientes') is not null
     and not exists (
       select 1
       from pg_constraint
       where conname =
         'retenciones_sufridas_cobro_cliente_id_fkey'
     ) then
    alter table public.retenciones_sufridas
      add constraint
      retenciones_sufridas_cobro_cliente_id_fkey
      foreign key (cobro_cliente_id)
      references public.cobros_clientes(id)
      on delete set null;
  end if;
end;
$$;

-- -------------------------------------------------------------
-- 4. CONSISTENCIA MULTIEMPRESA
-- -------------------------------------------------------------
create or replace function
public.validar_retencion_sufrida_comercio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
begin
  -- Cliente.
  select c.comercio_id
  into v_comercio_id
  from public.clientes as c
  where c.id = new.cliente_id;

  if not found then
    raise exception 'Cliente inexistente';
  end if;

  if v_comercio_id <> new.comercio_id then
    raise exception
      'La retención y el cliente pertenecen a comercios diferentes';
  end if;

  -- Venta opcional.
  if new.venta_id is not null then
    select v.comercio_id
    into v_comercio_id
    from public.ventas as v
    where v.id = new.venta_id;

    if not found then
      raise exception 'Venta inexistente';
    end if;

    if v_comercio_id <> new.comercio_id then
      raise exception
        'La retención y la venta pertenecen a comercios diferentes';
    end if;
  end if;

  -- Pago individual opcional.
  if new.pago_venta_id is not null then
    select pv.comercio_id
    into v_comercio_id
    from public.pagos_ventas as pv
    where pv.id = new.pago_venta_id;

    if not found then
      raise exception 'Pago de venta inexistente';
    end if;

    if v_comercio_id <> new.comercio_id then
      raise exception
        'La retención y el pago pertenecen a comercios diferentes';
    end if;
  end if;

  -- Cobro agrupado opcional. Se consulta dinámicamente para que
  -- el script siga siendo compatible si la tabla histórica no existe.
  if new.cobro_cliente_id is not null then
    if to_regclass('public.cobros_clientes') is null then
      raise exception
        'No existe la tabla de cobros agrupados para asociar esta retención';
    end if;

    execute
      'select comercio_id from public.cobros_clientes where id = $1'
      into v_comercio_id
      using new.cobro_cliente_id;

    if v_comercio_id is null then
      raise exception 'Cobro agrupado inexistente';
    end if;

    if v_comercio_id <> new.comercio_id then
      raise exception
        'La retención y el cobro agrupado pertenecen a comercios diferentes';
    end if;
  end if;

  return new;
end;
$$;

revoke all on function
public.validar_retencion_sufrida_comercio()
from public, anon, authenticated;

drop trigger if exists
retenciones_sufridas_validar_comercio
on public.retenciones_sufridas;

create trigger
retenciones_sufridas_validar_comercio
before insert or update
on public.retenciones_sufridas
for each row
execute function
public.validar_retencion_sufrida_comercio();

-- -------------------------------------------------------------
-- 5. UPDATED_AT
-- -------------------------------------------------------------
create or replace function
public.actualizar_retencion_sufrida_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function
public.actualizar_retencion_sufrida_updated_at()
from public, anon, authenticated;

drop trigger if exists
retenciones_sufridas_updated_at
on public.retenciones_sufridas;

create trigger
retenciones_sufridas_updated_at
before update
on public.retenciones_sufridas
for each row
execute function
public.actualizar_retencion_sufrida_updated_at();

-- -------------------------------------------------------------
-- 6. SEGURIDAD / RLS
-- -------------------------------------------------------------
alter table public.retenciones_sufridas
  enable row level security;

-- Por ahora el frontend puede LEER las retenciones con permiso de
-- cuenta corriente. Las altas/anulaciones serán exclusivamente por
-- RPC transaccional en 12A.2.
drop policy if exists
retenciones_sufridas_select
on public.retenciones_sufridas;

create policy
retenciones_sufridas_select
on public.retenciones_sufridas
for select
to authenticated
using (
  public.tiene_permiso_comercio(
    comercio_id,
    'cuentas_clientes.ver'
  )
  or public.tiene_permiso_comercio(
    comercio_id,
    'ventas.ver'
  )
);

revoke insert, update, delete
on table public.retenciones_sufridas
from authenticated;

grant select
on table public.retenciones_sufridas
to authenticated;

commit;

-- =============================================================
-- 7. VERIFICACIÓN DEL PASO 12A.1
-- =============================================================
select
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'retenciones_sufridas'
order by ordinal_position;