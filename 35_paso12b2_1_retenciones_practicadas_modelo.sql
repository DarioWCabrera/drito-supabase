-- =============================================================
-- DRITO - PASO 12B.2.1
-- MODELO BASE DE RETENCIONES PRACTICADAS A PROVEEDORES
-- =============================================================
--
-- Objetivos:
--
-- 1. Registrar retenciones practicadas por el comercio al pagar
--    a un proveedor.
--
-- 2. Admitir los dos circuitos existentes:
--
--      a) pago individual de compra
--         pagos_compras
--
--      b) pago agrupado de cuenta corriente
--         pagos_proveedores
--
-- 3. Toda retención debe depender de una configuración fiscal
--    explícita creada en 12B.1.
--
-- 4. La retención NO representa dinero salido de Caja.
--
-- Regla económica futura:
--
--   deuda cancelada =
--     dinero efectivamente pagado
--     + retenciones practicadas
--
--   Caja =
--     solamente dinero efectivamente pagado
--
-- Ejemplo:
--
--   Deuda proveedor       1.000.000
--   Retención practicada     30.000
--   Transferencia            970.000
--
--   Deuda cancelada       1.000.000
--   Caja                   -970.000
--   Obligación fiscal        30.000
--
-- IMPORTANTE:
-- Este paso solamente crea el MODELO.
-- NO modifica todavía registrar_pago_compra.
-- NO modifica registrar_pago_cuenta_proveedor.
-- NO genera movimientos de Caja.
-- =============================================================


begin;


-- =============================================================
-- 0. PRECONDICIONES
-- =============================================================

do $$
begin

  if to_regclass(
    'public.comercios'
  ) is null then
    raise exception
      'Falta public.comercios';
  end if;


  if to_regclass(
    'public.proveedores'
  ) is null then
    raise exception
      'Falta public.proveedores';
  end if;


  if to_regclass(
    'public.compras'
  ) is null then
    raise exception
      'Falta public.compras';
  end if;


  if to_regclass(
    'public.pagos_compras'
  ) is null then
    raise exception
      'Falta public.pagos_compras';
  end if;


  if to_regclass(
    'public.pagos_proveedores'
  ) is null then
    raise exception
      'Falta public.pagos_proveedores';
  end if;


  if to_regclass(
    'public.configuraciones_agentes_fiscales'
  ) is null then
    raise exception
      'Primero debe ejecutarse el PASO 12B.1';
  end if;


  if to_regprocedure(
    'public.tiene_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.tiene_permiso_comercio(uuid,text)';
  end if;

end;
$$;


-- =============================================================
-- 1. RETENCIONES PRACTICADAS
-- =============================================================

create table if not exists
public.retenciones_practicadas (

  id uuid primary key
    default gen_random_uuid(),


  -- ===========================================================
  -- MULTIEMPRESA
  -- ===========================================================

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,


  -- Configuración fiscal que habilitó al comercio
  -- para actuar como agente.
  configuracion_agente_id uuid not null
    references public.configuraciones_agentes_fiscales(id)
    on delete restrict,


  -- Proveedor al que se le practicó la retención.
  proveedor_id uuid not null
    references public.proveedores(id)
    on delete restrict,


  -- ===========================================================
  -- OPERACIÓN COMERCIAL
  -- ===========================================================

  -- Compra individual cuando corresponda.
  compra_id uuid
    references public.compras(id)
    on delete set null,


  -- Pago individual de compra.
  pago_compra_id uuid
    references public.pagos_compras(id)
    on delete set null,


  -- Pago agrupado de cuenta corriente.
  pago_proveedor_id uuid
    references public.pagos_proveedores(id)
    on delete set null,


  -- ===========================================================
  -- FECHA / PERÍODO
  -- ===========================================================

  fecha_retencion date not null
    default current_date,

  periodo_desde date,

  periodo_hasta date,


  -- ===========================================================
  -- SNAPSHOT DEL RÉGIMEN
  --
  -- Estos valores se copian desde la configuración fiscal
  -- vigente al momento de generar la retención.
  --
  -- Si posteriormente cambia la configuración, la retención
  -- histórica conserva los datos originales.
  -- ===========================================================

  organismo text not null,

  impuesto text not null,

  jurisdiccion text not null,

  regimen_codigo text,

  regimen_descripcion text not null,

  numero_inscripcion_agente text,

  sistema_presentacion text,


  -- ===========================================================
  -- SNAPSHOT DE LAS PARTES
  -- ===========================================================

  -- Comercio que practica la retención.
  agente_retencion_cuit text,

  agente_retencion_razon_social text,


  -- Proveedor sujeto a la retención.
  sujeto_retenido_cuit text,

  sujeto_retenido_razon_social text,


  -- ===========================================================
  -- CERTIFICADO
  -- ===========================================================

  -- Puede quedar temporalmente NULL porque el circuito de
  -- generación/gestión de certificados se completa en 12B.3.
  numero_certificado text,

  certificado_storage_path text,


  -- ===========================================================
  -- CÁLCULO
  -- ===========================================================

  base_calculo numeric(18,2)
    check (
      base_calculo is null
      or base_calculo >= 0
    ),

  alicuota numeric(9,6)
    check (
      alicuota is null
      or (
        alicuota >= 0
        and alicuota <= 100
      )
    ),

  importe numeric(18,2) not null
    check (
      importe > 0
    ),

  moneda text not null
    default 'ARS'
    check (
      char_length(trim(moneda)) >= 3
    ),


  observaciones text,


  -- ===========================================================
  -- ESTADO DE LA RETENCIÓN
  -- ===========================================================

  estado text not null
    default 'registrada'
    check (
      estado in (
        'registrada',
        'anulada'
      )
    ),


  -- ===========================================================
  -- OBLIGACIÓN FISCAL
  --
  -- Una retención practicada genera un importe que el comercio
  -- deberá posteriormente informar/ingresar según el régimen.
  --
  -- Este paso solo conserva el estado.
  -- NO implementa todavía presentación ni pago al organismo.
  -- ===========================================================

  estado_obligacion text not null
    default 'pendiente'
    check (
      estado_obligacion in (
        'pendiente',
        'presentada',
        'ingresada',
        'anulada'
      )
    ),


  -- ===========================================================
  -- AUDITORÍA
  -- ===========================================================

  creado_por uuid
    references auth.users(id)
    on delete set null,

  anulado_por uuid
    references auth.users(id)
    on delete set null,

  anulado_at timestamptz,

  motivo_anulacion text,

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),


  -- ===========================================================
  -- VALIDACIONES
  -- ===========================================================

  check (
    periodo_hasta is null
    or periodo_desde is null
    or periodo_hasta >= periodo_desde
  ),


  -- Una retención practicada pertenece exactamente a uno
  -- de los dos circuitos:
  --
  -- 1. Pago individual:
  --      compra_id + pago_compra_id
  --
  -- 2. Pago agrupado:
  --      pago_proveedor_id
  --
  check (
    (
      compra_id is not null
      and pago_compra_id is not null
      and pago_proveedor_id is null
    )
    or
    (
      compra_id is null
      and pago_compra_id is null
      and pago_proveedor_id is not null
    )
  ),


  -- Certificado vacío no permitido.
  check (
    numero_certificado is null
    or nullif(
      trim(numero_certificado),
      ''
    ) is not null
  ),


  -- La anulación debe conservar trazabilidad.
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


  -- Si se anula la retención también se anula
  -- su obligación fiscal.
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


comment on table
public.retenciones_practicadas is
  'Retenciones practicadas por el comercio a proveedores. Cancelan deuda comercial pero NO representan dinero egresado de Caja.';


comment on column
public.retenciones_practicadas.importe is
  'Importe retenido al proveedor. Reduce deuda comercial pero no debe registrarse como egreso de Caja.';


comment on column
public.retenciones_practicadas.configuracion_agente_id is
  'Configuración fiscal explícita que habilita al comercio para actuar como agente de retención.';


comment on column
public.retenciones_practicadas.estado_obligacion is
  'Seguimiento de la obligación fiscal originada por la retención practicada.';


-- =============================================================
-- 2. ÍNDICES
-- =============================================================

create index if not exists
retenciones_practicadas_comercio_fecha_idx
on public.retenciones_practicadas (
  comercio_id,
  fecha_retencion desc,
  created_at desc
);


create index if not exists
retenciones_practicadas_proveedor_fecha_idx
on public.retenciones_practicadas (
  proveedor_id,
  fecha_retencion desc
);


create index if not exists
retenciones_practicadas_compra_idx
on public.retenciones_practicadas (
  compra_id
)
where compra_id is not null;


create index if not exists
retenciones_practicadas_pago_compra_idx
on public.retenciones_practicadas (
  pago_compra_id
)
where pago_compra_id is not null;


create index if not exists
retenciones_practicadas_pago_proveedor_idx
on public.retenciones_practicadas (
  pago_proveedor_id
)
where pago_proveedor_id is not null;


create index if not exists
retenciones_practicadas_configuracion_idx
on public.retenciones_practicadas (
  configuracion_agente_id
);


create index if not exists
retenciones_practicadas_obligacion_idx
on public.retenciones_practicadas (
  comercio_id,
  estado_obligacion,
  fecha_retencion
);


-- Evita duplicar certificados ya emitidos.
-- Los registros sin certificado todavía no participan
-- del índice único.

create unique index if not exists
retenciones_practicadas_certificado_uq
on public.retenciones_practicadas (
  comercio_id,
  lower(trim(impuesto)),
  lower(trim(jurisdiccion)),
  lower(trim(numero_certificado))
)
where numero_certificado is not null;


-- =============================================================
-- 3. INTEGRIDAD MULTIEMPRESA Y CONFIGURACIÓN DE AGENTE
-- =============================================================

create or replace function
public.validar_retencion_practicada_integridad()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare

  v_config
    public.configuraciones_agentes_fiscales%rowtype;

  v_proveedor public.proveedores%rowtype;

  v_compra public.compras%rowtype;

  v_pago_compra public.pagos_compras%rowtype;

  v_pago_proveedor public.pagos_proveedores%rowtype;

  v_validar_vigencia boolean := false;

begin

  -- ===========================================================
  -- CONFIGURACIÓN FISCAL
  -- ===========================================================

  select *
  into v_config
  from public.configuraciones_agentes_fiscales
  where id = new.configuracion_agente_id;


  if not found then
    raise exception
      'Configuración de agente fiscal inexistente';
  end if;


  if v_config.comercio_id <> new.comercio_id then
    raise exception
      'La configuración fiscal pertenece a otro comercio';
  end if;


  if v_config.tipo_agente <> 'retencion' then
    raise exception
      'La configuración fiscal seleccionada no corresponde a un agente de retención';
  end if;


  if tg_op = 'INSERT' then

    v_validar_vigencia := true;

  elsif
    new.configuracion_agente_id
      is distinct from
    old.configuracion_agente_id

    or new.fecha_retencion
      is distinct from
    old.fecha_retencion
  then

    v_validar_vigencia := true;

  end if;


  if v_validar_vigencia then

    if v_config.activo is not true then
      raise exception
        'La configuración del agente fiscal no está activa';
    end if;


    if new.fecha_retencion < v_config.vigencia_desde then
      raise exception
        'La configuración fiscal todavía no estaba vigente en la fecha de retención';
    end if;


    if
      v_config.vigencia_hasta is not null
      and new.fecha_retencion > v_config.vigencia_hasta
    then
      raise exception
        'La configuración fiscal ya no estaba vigente en la fecha de retención';
    end if;


    -- Snapshot fiscal.
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


  -- ===========================================================
  -- PROVEEDOR
  -- ===========================================================

  select *
  into v_proveedor
  from public.proveedores
  where id = new.proveedor_id;


  if not found then
    raise exception
      'Proveedor inexistente';
  end if;


  if v_proveedor.comercio_id <> new.comercio_id then
    raise exception
      'La retención y el proveedor pertenecen a comercios diferentes';
  end if;


  -- Guardamos snapshot del proveedor cuando no fue informado.
  if new.sujeto_retenido_cuit is null then
    new.sujeto_retenido_cuit :=
      v_proveedor.documento;
  end if;


  if new.sujeto_retenido_razon_social is null then
    new.sujeto_retenido_razon_social :=
      coalesce(
        nullif(
          trim(
            coalesce(
              v_proveedor.razon_social,
              ''
            )
          ),
          ''
        ),
        v_proveedor.nombre
      );
  end if;


  -- ===========================================================
  -- PAGO INDIVIDUAL DE COMPRA
  -- ===========================================================

  if new.pago_compra_id is not null then

    select *
    into v_compra
    from public.compras
    where id = new.compra_id;


    if not found then
      raise exception
        'Compra inexistente';
    end if;


    if v_compra.comercio_id <> new.comercio_id then
      raise exception
        'La retención y la compra pertenecen a comercios diferentes';
    end if;


    if v_compra.proveedor_id <> new.proveedor_id then
      raise exception
        'La compra pertenece a otro proveedor';
    end if;


    select *
    into v_pago_compra
    from public.pagos_compras
    where id = new.pago_compra_id;


    if not found then
      raise exception
        'Pago de compra inexistente';
    end if;


    if v_pago_compra.comercio_id <> new.comercio_id then
      raise exception
        'La retención y el pago pertenecen a comercios diferentes';
    end if;


    if v_pago_compra.proveedor_id <> new.proveedor_id then
      raise exception
        'El pago de compra pertenece a otro proveedor';
    end if;


    if v_pago_compra.compra_id <> new.compra_id then
      raise exception
        'El pago indicado no corresponde a la compra seleccionada';
    end if;

  end if;


  -- ===========================================================
  -- PAGO AGRUPADO DE PROVEEDOR
  -- ===========================================================

  if new.pago_proveedor_id is not null then

    select *
    into v_pago_proveedor
    from public.pagos_proveedores
    where id = new.pago_proveedor_id;


    if not found then
      raise exception
        'Pago agrupado de proveedor inexistente';
    end if;


    if v_pago_proveedor.comercio_id <> new.comercio_id then
      raise exception
        'La retención y el pago agrupado pertenecen a comercios diferentes';
    end if;


    if v_pago_proveedor.proveedor_id <> new.proveedor_id then
      raise exception
        'El pago agrupado pertenece a otro proveedor';
    end if;

  end if;


  return new;

end;
$$;


revoke all
on function
public.validar_retencion_practicada_integridad()
from public, anon, authenticated;


drop trigger if exists
retenciones_practicadas_validar_integridad
on public.retenciones_practicadas;


create trigger
retenciones_practicadas_validar_integridad
before insert or update
on public.retenciones_practicadas
for each row
execute function
public.validar_retencion_practicada_integridad();


-- =============================================================
-- 4. UPDATED_AT
-- =============================================================

create or replace function
public.actualizar_retencion_practicada_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin

  new.updated_at := now();

  return new;

end;
$$;


revoke all
on function
public.actualizar_retencion_practicada_updated_at()
from public, anon, authenticated;


drop trigger if exists
retenciones_practicadas_updated_at
on public.retenciones_practicadas;


create trigger
retenciones_practicadas_updated_at
before update
on public.retenciones_practicadas
for each row
execute function
public.actualizar_retencion_practicada_updated_at();


-- =============================================================
-- 5. SEGURIDAD / RLS
-- =============================================================

alter table
public.retenciones_practicadas
enable row level security;


drop policy if exists
retenciones_practicadas_select
on public.retenciones_practicadas;


create policy
retenciones_practicadas_select
on public.retenciones_practicadas
for select
to authenticated
using (

  public.tiene_permiso_comercio(
    comercio_id,
    'cuentas_proveedores.ver'
  )

  or

  public.tiene_permiso_comercio(
    comercio_id,
    'compras.ver'
  )

);


-- Las altas, modificaciones y anulaciones
-- serán exclusivamente mediante RPC.

revoke insert, update, delete
on table public.retenciones_practicadas
from authenticated;


revoke all
on table public.retenciones_practicadas
from anon;


grant select
on table public.retenciones_practicadas
to authenticated;


commit;


-- =============================================================
-- FIN PASO 12B.2.1
-- =============================================================