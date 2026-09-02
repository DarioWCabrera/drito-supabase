-- ============================================================
-- DRITO 12B.5.1
-- MODELO BASE DE PERCEPCIONES SUFRIDAS EN COMPRAS
--
-- Archivo:
--   47_paso12b5_1_modelo_percepciones_sufridas.sql
--
-- Objetivo:
--   - Registrar percepciones cobradas por proveedores dentro
--     de una compra.
--   - Conservar trazabilidad fiscal independiente del IVA.
--   - Preparar el futuro motor:
--
--       total comercial de la compra
--       + percepciones sufridas vigentes
--       = total final adeudado al proveedor
--
-- IMPORTANTE:
--   Esta migración:
--   - NO modifica todavía compras.total.
--   - NO modifica pagos ni Caja.
--   - NO modifica el motor de cancelación de compras.
--   - NO calcula percepciones automáticamente.
--   - NO requiere que nuestro comercio sea agente fiscal:
--     en una percepción sufrida el agente es el proveedor.
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

  if to_regclass('public.compras') is null then
    raise exception 'Falta public.compras';
  end if;

  if to_regclass('public.proveedores') is null then
    raise exception 'Falta public.proveedores';
  end if;

  if to_regprocedure('public.tiene_permiso_comercio(uuid,text)') is null then
    raise exception 'Falta public.tiene_permiso_comercio(uuid,text)';
  end if;

  if to_regprocedure('public.actualizar_updated_at()') is null then
    raise exception 'Falta public.actualizar_updated_at()';
  end if;
end;
$$;

-- ============================================================
-- 1. TABLA PRINCIPAL
-- ============================================================

create table if not exists public.percepciones_sufridas (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  compra_id uuid not null
    references public.compras(id) on delete restrict,

  proveedor_id uuid not null
    references public.proveedores(id) on delete restrict,

  fecha_percepcion date not null,
  periodo_desde date null,
  periodo_hasta date null,

  organismo text not null,
  impuesto text not null,
  jurisdiccion text null,
  regimen_codigo text null,
  regimen_descripcion text null,

  agente_percepcion_tipo_documento text null,
  agente_percepcion_documento text null,
  agente_percepcion_razon_social text not null,
  numero_inscripcion_agente text null,

  tipo_comprobante_snapshot text null,
  numero_comprobante_snapshot text null,

  base_calculo numeric(14,2) not null,
  alicuota numeric(9,4) not null,
  importe numeric(14,2) not null,

  moneda text not null default 'ARS',

  numero_certificado text null,
  certificado_storage_path text null,

  estado text not null default 'registrada',
  observaciones text null,

  creado_por uuid null
    references auth.users(id) on delete set null,

  anulado_por uuid null
    references auth.users(id) on delete set null,

  anulado_at timestamptz null,
  motivo_anulacion text null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint percepciones_sufridas_periodo_check
    check (
      periodo_hasta is null
      or periodo_desde is null
      or periodo_hasta >= periodo_desde
    ),

  constraint percepciones_sufridas_base_calculo_check
    check (base_calculo >= 0),

  constraint percepciones_sufridas_alicuota_check
    check (alicuota >= 0 and alicuota <= 100),

  constraint percepciones_sufridas_importe_check
    check (importe > 0),

  constraint percepciones_sufridas_moneda_check
    check (char_length(trim(moneda)) >= 3),

  constraint percepciones_sufridas_estado_check
    check (estado in ('registrada', 'anulada')),

  constraint percepciones_sufridas_anulacion_check
    check (
      estado <> 'anulada'
      or (
        anulado_at is not null
        and nullif(trim(coalesce(motivo_anulacion, '')), '') is not null
      )
    )
);

-- ============================================================
-- 2. ÍNDICES
-- ============================================================

create index if not exists percepciones_sufridas_comercio_fecha_idx
on public.percepciones_sufridas (comercio_id, fecha_percepcion desc);

create index if not exists percepciones_sufridas_compra_idx
on public.percepciones_sufridas (compra_id, fecha_percepcion desc);

create index if not exists percepciones_sufridas_proveedor_idx
on public.percepciones_sufridas (proveedor_id, fecha_percepcion desc);

create index if not exists percepciones_sufridas_impuesto_idx
on public.percepciones_sufridas (
  comercio_id,
  impuesto,
  jurisdiccion,
  fecha_percepcion desc
);

create unique index if not exists percepciones_sufridas_certificado_uidx
on public.percepciones_sufridas (
  comercio_id,
  impuesto,
  coalesce(jurisdiccion, ''),
  numero_certificado
)
where numero_certificado is not null
  and estado = 'registrada';

-- ============================================================
-- 3. VALIDACIÓN + SNAPSHOT
-- ============================================================

create or replace function public.validar_percepcion_sufrida_integridad()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_compra public.compras%rowtype;
  v_proveedor public.proveedores%rowtype;
begin
  select *
  into v_compra
  from public.compras
  where id = new.compra_id;

  if not found then
    raise exception 'Compra inexistente';
  end if;

  if v_compra.comercio_id <> new.comercio_id then
    raise exception 'La percepción y la compra pertenecen a comercios diferentes';
  end if;

  if v_compra.proveedor_id <> new.proveedor_id then
    raise exception 'La percepción y la compra pertenecen a proveedores diferentes';
  end if;

  if tg_op = 'INSERT' and v_compra.estado <> 'confirmada' then
    raise exception 'Solo se pueden registrar percepciones sobre compras confirmadas';
  end if;

  select *
  into v_proveedor
  from public.proveedores
  where id = new.proveedor_id;

  if not found then
    raise exception 'Proveedor inexistente';
  end if;

  if v_proveedor.comercio_id <> new.comercio_id then
    raise exception 'La percepción y el proveedor pertenecen a comercios diferentes';
  end if;

  if new.agente_percepcion_tipo_documento is null then
    new.agente_percepcion_tipo_documento := v_proveedor.tipo_documento;
  end if;

  if new.agente_percepcion_documento is null then
    new.agente_percepcion_documento := v_proveedor.documento;
  end if;

  if nullif(trim(coalesce(new.agente_percepcion_razon_social, '')), '') is null then
    new.agente_percepcion_razon_social := coalesce(
      nullif(trim(coalesce(v_proveedor.razon_social, '')), ''),
      v_proveedor.nombre
    );
  end if;

  if new.tipo_comprobante_snapshot is null then
    new.tipo_comprobante_snapshot := v_compra.tipo_comprobante;
  end if;

  if new.numero_comprobante_snapshot is null then
    new.numero_comprobante_snapshot := v_compra.numero_comprobante;
  end if;

  if new.moneda is null then
    new.moneda := v_compra.moneda;
  end if;

  if tg_op = 'INSERT' and new.creado_por is null then
    new.creado_por := auth.uid();
  end if;

  return new;
end;
$$;

drop trigger if exists percepciones_sufridas_validar_integridad
on public.percepciones_sufridas;

create trigger percepciones_sufridas_validar_integridad
before insert or update
on public.percepciones_sufridas
for each row
execute function public.validar_percepcion_sufrida_integridad();

-- ============================================================
-- 4. UPDATED_AT
-- ============================================================

drop trigger if exists percepciones_sufridas_updated_at
on public.percepciones_sufridas;

create trigger percepciones_sufridas_updated_at
before update
on public.percepciones_sufridas
for each row
execute function public.actualizar_updated_at();

-- ============================================================
-- 5. RLS
-- ============================================================

alter table public.percepciones_sufridas enable row level security;

drop policy if exists percepciones_sufridas_select
on public.percepciones_sufridas;

create policy percepciones_sufridas_select
on public.percepciones_sufridas
for select
to authenticated
using (
  public.tiene_permiso_comercio(comercio_id, 'compras.ver')
  or public.tiene_permiso_comercio(comercio_id, 'cuentas_proveedores.ver')
);

-- ============================================================
-- 6. SEGURIDAD
-- ============================================================

revoke insert, update, delete
on public.percepciones_sufridas
from public, anon, authenticated;

revoke all
on function public.validar_percepcion_sufrida_integridad()
from public, anon, authenticated;

-- ============================================================
-- 7. COMENTARIOS
-- ============================================================

comment on table public.percepciones_sufridas is
'Percepciones fiscales cobradas por proveedores dentro de compras. No representan Caja por sí mismas y se mantienen separadas del IVA de ítems.';

comment on function public.validar_percepcion_sufrida_integridad() is
'Valida coherencia comercio/compra/proveedor y conserva snapshots del proveedor agente y comprobante de compra.';

commit;
