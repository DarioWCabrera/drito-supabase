-- ============================================================
-- DRITO 12B.4.1
-- MODELO BASE DE PERCEPCIONES PRACTICADAS EN VENTAS
-- Archivo: 43_paso12b4_1_modelo_percepciones_practicadas.sql
--
-- Objetivo:
--   - Registrar percepciones practicadas al cliente en una venta.
--   - Mantener trazabilidad fiscal independiente del IVA.
--   - Conservar snapshot de configuración fiscal y del cliente.
--   - Preparar el futuro motor:
--
--       total comercial
--       + percepciones practicadas vigentes
--       = total final a cobrar
--
-- IMPORTANTE:
--   Esta migración NO modifica todavía el total de ventas,
--   NO genera percepciones automáticamente,
--   NO toca Caja,
--   NO modifica cobranzas
--   y NO configura ningún comercio como agente.
-- ============================================================

begin;


-- ============================================================
-- 0. DEPENDENCIAS
-- ============================================================

do $$
begin

  if to_regclass(
    'public.comercios'
  ) is null then
    raise exception
      'Falta public.comercios';
  end if;


  if to_regclass(
    'public.clientes'
  ) is null then
    raise exception
      'Falta public.clientes';
  end if;


  if to_regclass(
    'public.ventas'
  ) is null then
    raise exception
      'Falta public.ventas';
  end if;


  if to_regclass(
    'public.configuraciones_agentes_fiscales'
  ) is null then
    raise exception
      'Falta public.configuraciones_agentes_fiscales';
  end if;


  if to_regclass(
    'public.permisos_sistema'
  ) is null then
    raise exception
      'Falta public.permisos_sistema';
  end if;


  if to_regprocedure(
    'public.tiene_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.tiene_permiso_comercio(uuid,text)';
  end if;


  if to_regprocedure(
    'public.actualizar_updated_at()'
  ) is null then
    raise exception
      'Falta public.actualizar_updated_at()';
  end if;

end;
$$;


-- ============================================================
-- 1. TABLA PRINCIPAL
-- ============================================================

create table if not exists
public.percepciones_practicadas (

  id uuid primary key
    default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  configuracion_agente_id uuid not null
    references public.configuraciones_agentes_fiscales(id)
    on delete restrict,

  venta_id uuid not null
    references public.ventas(id)
    on delete restrict,

  cliente_id uuid not null
    references public.clientes(id)
    on delete restrict,

  -- Se vinculará cuando exista un comprobante fiscal
  -- asociado a la operación.
  comprobante_fiscal_id uuid null,

  fecha_percepcion date not null,

  periodo_desde date null,
  periodo_hasta date null,

  -- Snapshot de la configuración fiscal.
  organismo text not null,
  impuesto text not null,
  jurisdiccion text not null,

  regimen_codigo text null,
  regimen_descripcion text null,

  numero_inscripcion_agente text null,
  sistema_presentacion text null,

  -- Snapshot del cliente percibido.
  sujeto_percibido_tipo_documento text null,
  sujeto_percibido_documento text null,
  sujeto_percibido_razon_social text not null,

  -- Datos económicos de la percepción.
  base_calculo numeric(14,2) not null,
  alicuota numeric(9,4) not null,
  importe numeric(14,2) not null,

  moneda text not null
    default 'ARS',

  -- Evidencia/documentación.
  numero_certificado text null,
  certificado_storage_path text null,

  -- Estado del registro.
  estado text not null
    default 'registrada',

  -- Obligación del agente frente al organismo.
  estado_obligacion text not null
    default 'pendiente',

  observaciones text null,

  creado_por uuid null
    references auth.users(id)
    on delete set null,

  anulado_por uuid null
    references auth.users(id)
    on delete set null,

  anulado_at timestamptz null,
  motivo_anulacion text null,

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),


  constraint
    percepciones_practicadas_periodo_check
  check (
    periodo_hasta is null
    or periodo_desde is null
    or periodo_hasta >= periodo_desde
  ),


  constraint
    percepciones_practicadas_base_calculo_check
  check (
    base_calculo >= 0
  ),


  constraint
    percepciones_practicadas_alicuota_check
  check (
    alicuota >= 0
    and alicuota <= 100
  ),


  constraint
    percepciones_practicadas_importe_check
  check (
    importe > 0
  ),


  constraint
    percepciones_practicadas_moneda_check
  check (
    char_length(
      trim(moneda)
    ) >= 3
  ),


  constraint
    percepciones_practicadas_numero_certificado_check
  check (
    numero_certificado is null
    or nullif(
      trim(numero_certificado),
      ''
    ) is not null
  ),


  constraint
    percepciones_practicadas_estado_check
  check (
    estado in (
      'registrada',
      'anulada'
    )
  ),


  constraint
    percepciones_practicadas_estado_obligacion_check
  check (
    estado_obligacion in (
      'pendiente',
      'presentada',
      'ingresada',
      'anulada'
    )
  ),


  constraint
    percepciones_practicadas_anulacion_check
  check (
    estado <> 'anulada'
    or (
      anulado_at is not null
      and nullif(
        trim(
          coalesce(
            motivo_anulacion,
            ''
          )
        ),
        ''
      ) is not null
    )
  ),


  constraint
    percepciones_practicadas_estado_fiscal_check
  check (
    (
      estado = 'anulada'
      and estado_obligacion = 'anulada'
    )
    or
    (
      estado = 'registrada'
      and estado_obligacion in (
        'pendiente',
        'presentada',
        'ingresada'
      )
    )
  )

);


-- ============================================================
-- 2. FK OPCIONAL A COMPROBANTE FISCAL
-- ============================================================

do $$
begin

  if to_regclass(
    'public.comprobantes_fiscales'
  ) is not null
  and not exists (
    select 1
    from pg_constraint
    where conname =
      'percepciones_practicadas_comprobante_fiscal_id_fkey'
      and conrelid =
        'public.percepciones_practicadas'::regclass
  ) then

    alter table
      public.percepciones_practicadas

    add constraint
      percepciones_practicadas_comprobante_fiscal_id_fkey

    foreign key (
      comprobante_fiscal_id
    )

    references
      public.comprobantes_fiscales(id)

    on delete set null;

  end if;

end;
$$;


-- ============================================================
-- 3. ÍNDICES
-- ============================================================

create index if not exists
percepciones_practicadas_comercio_fecha_idx

on public.percepciones_practicadas (
  comercio_id,
  fecha_percepcion desc
);


create index if not exists
percepciones_practicadas_venta_idx

on public.percepciones_practicadas (
  venta_id
);


create index if not exists
percepciones_practicadas_cliente_idx

on public.percepciones_practicadas (
  cliente_id,
  fecha_percepcion desc
);


create index if not exists
percepciones_practicadas_obligacion_idx

on public.percepciones_practicadas (
  comercio_id,
  estado_obligacion,
  fecha_percepcion
);


-- Una misma configuración de percepción no debe cargarse
-- dos veces como vigente dentro de la misma venta.
create unique index if not exists
percepciones_practicadas_venta_config_activa_uidx

on public.percepciones_practicadas (
  venta_id,
  configuracion_agente_id
)

where estado = 'registrada';


-- El certificado puede no existir.
-- Si existe, evitamos duplicarlo dentro del mismo ámbito fiscal.
create unique index if not exists
percepciones_practicadas_certificado_uidx

on public.percepciones_practicadas (
  comercio_id,
  impuesto,
  jurisdiccion,
  numero_certificado
)

where
  numero_certificado is not null
  and estado = 'registrada';


-- ============================================================
-- 4. VALIDACIÓN + SNAPSHOT FISCAL
-- ============================================================

create or replace function
public.validar_percepcion_practicada_integridad()

returns trigger

language plpgsql
security definer
set search_path = public

as $$

declare

  v_config
    public.configuraciones_agentes_fiscales%rowtype;

  v_venta
    public.ventas%rowtype;

  v_cliente
    public.clientes%rowtype;

  v_validar_vigencia boolean := false;
  v_validar_venta boolean := false;

begin

  -- ==========================================================
  -- CONFIGURACIÓN FISCAL
  -- ==========================================================

  select *
  into v_config

  from public.configuraciones_agentes_fiscales

  where id =
    new.configuracion_agente_id;


  if not found then
    raise exception
      'Configuración de agente fiscal inexistente';
  end if;


  if
    v_config.comercio_id
      <> new.comercio_id
  then
    raise exception
      'La configuración fiscal pertenece a otro comercio';
  end if;


  if
    v_config.tipo_agente
      <> 'percepcion'
  then
    raise exception
      'La configuración fiscal seleccionada no corresponde a un agente de percepción';
  end if;


  if tg_op = 'INSERT' then

    v_validar_vigencia := true;

  elsif
    new.configuracion_agente_id
      is distinct from
    old.configuracion_agente_id

    or new.fecha_percepcion
      is distinct from
    old.fecha_percepcion
  then

    v_validar_vigencia := true;

  end if;


  if v_validar_vigencia then

    if v_config.activo is not true then
      raise exception
        'La configuración del agente de percepción no está activa';
    end if;


    if
      new.fecha_percepcion
        < v_config.vigencia_desde
    then
      raise exception
        'La configuración fiscal todavía no estaba vigente en la fecha de percepción';
    end if;


    if
      v_config.vigencia_hasta is not null
      and new.fecha_percepcion
        > v_config.vigencia_hasta
    then
      raise exception
        'La configuración fiscal ya no estaba vigente en la fecha de percepción';
    end if;


    -- Snapshot de la configuración.
    new.organismo :=
      v_config.organismo;

    new.impuesto :=
      v_config.impuesto;

    new.jurisdiccion :=
      v_config.jurisdiccion;

    new.regimen_codigo :=
      v_config.regimen_codigo;

    new.regimen_descripcion :=
      v_config.regimen_descripcion;

    new.numero_inscripcion_agente :=
      v_config.numero_inscripcion_agente;

    new.sistema_presentacion :=
      v_config.sistema_presentacion;

  end if;


  -- ==========================================================
  -- VENTA
  -- ==========================================================

  select *
  into v_venta

  from public.ventas

  where id =
    new.venta_id;


  if not found then
    raise exception
      'Venta inexistente';
  end if;


  if
    v_venta.comercio_id
      <> new.comercio_id
  then
    raise exception
      'La percepción y la venta pertenecen a comercios diferentes';
  end if;


  if
    v_venta.cliente_id
      <> new.cliente_id
  then
    raise exception
      'La venta pertenece a otro cliente';
  end if;


  if tg_op = 'INSERT' then

    v_validar_venta := true;

  elsif
    new.venta_id
      is distinct from
    old.venta_id

    or new.cliente_id
      is distinct from
    old.cliente_id
  then

    v_validar_venta := true;

  end if;


  if v_validar_venta then

    if
      v_venta.estado
        <> 'confirmada'
    then
      raise exception
        'Solo se pueden registrar percepciones sobre ventas confirmadas';
    end if;

  end if;


  -- ==========================================================
  -- CLIENTE
  -- ==========================================================

  select *
  into v_cliente

  from public.clientes

  where id =
    new.cliente_id;


  if not found then
    raise exception
      'Cliente inexistente';
  end if;


  if
    v_cliente.comercio_id
      <> new.comercio_id
  then
    raise exception
      'La percepción y el cliente pertenecen a comercios diferentes';
  end if;


  if
    tg_op = 'INSERT'
    and v_cliente.activo is not true
  then
    raise exception
      'El cliente se encuentra inactivo';
  end if;


  -- Snapshot del sujeto percibido.
  if
    new.sujeto_percibido_tipo_documento
      is null
  then

    new.sujeto_percibido_tipo_documento :=
      v_cliente.tipo_documento;

  end if;


  if
    new.sujeto_percibido_documento
      is null
  then

    new.sujeto_percibido_documento :=
      v_cliente.documento;

  end if;


  if
    nullif(
      trim(
        coalesce(
          new.sujeto_percibido_razon_social,
          ''
        )
      ),
      ''
    ) is null
  then

    new.sujeto_percibido_razon_social :=
      coalesce(
        nullif(
          trim(
            coalesce(
              v_cliente.razon_social,
              ''
            )
          ),
          ''
        ),
        v_cliente.nombre
      );

  end if;


  -- Auditoría de alta.
  if
    tg_op = 'INSERT'
    and new.creado_por is null
  then

    new.creado_por :=
      auth.uid();

  end if;


  return new;

end;
$$;


drop trigger if exists
percepciones_practicadas_validar_integridad

on public.percepciones_practicadas;


create trigger
percepciones_practicadas_validar_integridad

before insert or update

on public.percepciones_practicadas

for each row

execute function
public.validar_percepcion_practicada_integridad();


-- ============================================================
-- 5. UPDATED_AT
-- ============================================================

drop trigger if exists
percepciones_practicadas_updated_at

on public.percepciones_practicadas;


create trigger
percepciones_practicadas_updated_at

before update

on public.percepciones_practicadas

for each row

execute function
public.actualizar_updated_at();


-- ============================================================
-- 6. RLS
-- ============================================================

alter table
public.percepciones_practicadas

enable row level security;


drop policy if exists
percepciones_practicadas_select

on public.percepciones_practicadas;


create policy
percepciones_practicadas_select

on public.percepciones_practicadas

for select

to authenticated

using (

  public.tiene_permiso_comercio(
    comercio_id,
    'ventas.ver'
  )

  or

  public.tiene_permiso_comercio(
    comercio_id,
    'facturacion.ver'
  )

);


-- ============================================================
-- 7. PERMISOS DIRECTOS
-- ============================================================

revoke all

on public.percepciones_practicadas

from public, anon, authenticated;


grant select

on public.percepciones_practicadas

to authenticated;


-- Las escrituras se harán por RPC controlada
-- en los próximos pasos.
revoke all

on function
public.validar_percepcion_practicada_integridad()

from public, anon, authenticated;


-- ============================================================
-- 8. COMENTARIOS
-- ============================================================

comment on table
public.percepciones_practicadas

is
'Percepciones fiscales practicadas a clientes en ventas. La percepción incrementa la deuda del cliente pero no representa ingreso de Caja hasta que sea efectivamente cobrada.';


comment on column
public.percepciones_practicadas.estado_obligacion

is
'Estado de la obligación fiscal del agente: pendiente, presentada, ingresada o anulada.';


comment on column
public.percepciones_practicadas.base_calculo

is
'Base fiscal utilizada para determinar la percepción. La migración no impone una fórmula única porque depende del régimen configurado.';


comment on column
public.percepciones_practicadas.importe

is
'Importe de percepción practicada que deberá sumarse al total comercial de la venta mediante el motor de totalización del paso siguiente.';


commit;
