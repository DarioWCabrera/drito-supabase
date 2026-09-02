-- ============================================================
-- DRITO
-- PASO 15A.3.1
-- AUDITORÍA OPERACIONAL - VENTAS
--
-- Integra auditoría en:
-- - crear_venta_directa(...)
-- - anular_venta(...)
--
-- Mantiene intactos los motores internos ya existentes.
-- ============================================================


-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

do $$
begin

  if to_regprocedure(
    'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
  ) is null then
    raise exception
      'Falta el helper de auditoría operacional';
  end if;


  if to_regprocedure(
    'public.__drito_original_crear_venta_directa_f4f43d8f40(uuid,uuid,date,text,numeric,text,jsonb,numeric,text,text,text)'
  ) is null then
    raise exception
      'Falta el motor original de crear_venta_directa';
  end if;


  if to_regprocedure(
    'public.__drito_original_anular_venta_c76661b0be(uuid,text)'
  ) is null then
    raise exception
      'Falta el motor original de anular_venta';
  end if;


  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta exigir_permiso_comercio(uuid,text)';
  end if;

end;
$$;


-- ============================================================
-- 1. CREAR VENTA DIRECTA + AUDITORÍA
-- ============================================================

create or replace function
public.crear_venta_directa(
  p_comercio_id uuid,
  p_cliente_id uuid,
  p_fecha_venta date,
  p_moneda text,
  p_descuento_general_porcentaje numeric,
  p_observaciones text,
  p_items jsonb,
  p_pago_inicial numeric default 0,
  p_medio_pago text default 'efectivo',
  p_referencia_pago text default null,
  p_observaciones_pago text default null
)
returns table (
  venta_id uuid,
  numero_venta bigint,
  total_venta numeric,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text,
  pago_id uuid,
  numero_pago bigint,
  movimientos_generados integer
)
language plpgsql
security definer
set search_path = public
as $function$
declare

  v_comercio_id uuid;

  v_resultado record;

  v_referencia text;

begin

  v_comercio_id := p_comercio_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'ventas.crear'
  );


  select *
  into v_resultado
  from public.__drito_original_crear_venta_directa_f4f43d8f40(
    p_comercio_id,
    p_cliente_id,
    p_fecha_venta,
    p_moneda,
    p_descuento_general_porcentaje,
    p_observaciones,
    p_items,
    p_pago_inicial,
    p_medio_pago,
    p_referencia_pago,
    p_observaciones_pago
  );


  if v_resultado.venta_id is null then
    raise exception
      'La venta fue procesada pero no devolvió identificación';
  end if;


  v_referencia :=
    'VTA-' ||
    lpad(
      v_resultado.numero_venta::text,
      6,
      '0'
    );


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id      => v_comercio_id,
    p_modulo           => 'ventas',
    p_accion           => 'venta_creada',
    p_entidad_tipo     => 'venta',
    p_entidad_id       => v_resultado.venta_id::text,
    p_referencia       => v_referencia,
    p_detalle          => jsonb_build_object(
      'cliente_id',
        p_cliente_id,

      'fecha_venta',
        p_fecha_venta,

      'moneda',
        p_moneda,

      'total_venta',
        v_resultado.total_venta,

      'total_pagado',
        v_resultado.total_pagado,

      'saldo_pendiente',
        v_resultado.saldo_pendiente,

      'estado_pago',
        v_resultado.estado_pago,

      'pago_inicial',
        coalesce(p_pago_inicial, 0),

      'medio_pago_inicial',
        case
          when coalesce(p_pago_inicial, 0) > 0
            then p_medio_pago
          else null
        end,

      'pago_id',
        v_resultado.pago_id,

      'numero_pago',
        v_resultado.numero_pago,

      'movimientos_stock_generados',
        v_resultado.movimientos_generados
    )
  );


  return query
  select
    v_resultado.venta_id::uuid,
    v_resultado.numero_venta::bigint,
    v_resultado.total_venta::numeric,
    v_resultado.total_pagado::numeric,
    v_resultado.saldo_pendiente::numeric,
    v_resultado.estado_pago::text,
    v_resultado.pago_id::uuid,
    v_resultado.numero_pago::bigint,
    v_resultado.movimientos_generados::integer;

end;
$function$;


-- ============================================================
-- 2. ANULAR VENTA + AUDITORÍA
-- ============================================================

create or replace function
public.anular_venta(
  p_venta_id uuid,
  p_motivo text
)
returns table (
  venta_id uuid,
  numero_venta bigint,
  total_venta numeric,
  movimientos_generados integer,
  cantidad_total_repuesta numeric
)
language plpgsql
security definer
set search_path = public
as $function$
declare

  v_comercio_id uuid;

  v_resultado record;

  v_referencia text;

begin

  select v.comercio_id
  into v_comercio_id
  from public.ventas v
  where v.id = p_venta_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'ventas.anular_ventas'
  );


  select *
  into v_resultado
  from public.__drito_original_anular_venta_c76661b0be(
    p_venta_id,
    p_motivo
  );


  if v_resultado.venta_id is null then
    raise exception
      'La anulación fue procesada pero no devolvió identificación';
  end if;


  v_referencia :=
    'VTA-' ||
    lpad(
      v_resultado.numero_venta::text,
      6,
      '0'
    );


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id      => v_comercio_id,
    p_modulo           => 'ventas',
    p_accion           => 'venta_anulada',
    p_entidad_tipo     => 'venta',
    p_entidad_id       => v_resultado.venta_id::text,
    p_referencia       => v_referencia,
    p_detalle          => jsonb_build_object(
      'motivo',
        nullif(
          trim(coalesce(p_motivo, '')),
          ''
        ),

      'total_venta',
        v_resultado.total_venta,

      'movimientos_stock_generados',
        v_resultado.movimientos_generados,

      'cantidad_total_repuesta',
        v_resultado.cantidad_total_repuesta
    )
  );


  return query
  select
    v_resultado.venta_id::uuid,
    v_resultado.numero_venta::bigint,
    v_resultado.total_venta::numeric,
    v_resultado.movimientos_generados::integer,
    v_resultado.cantidad_total_repuesta::numeric;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.crear_venta_directa(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  jsonb,
  numeric,
  text,
  text,
  text
)
from public, anon;


grant execute on function
public.crear_venta_directa(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  jsonb,
  numeric,
  text,
  text,
  text
)
to authenticated;


revoke all on function
public.anular_venta(
  uuid,
  text
)
from public, anon;


grant execute on function
public.anular_venta(
  uuid,
  text
)
to authenticated;


-- ============================================================
-- 4. RECARGA POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 5. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

select jsonb_build_object(

  'crear_venta_directa_existe',
    to_regprocedure(
      'public.crear_venta_directa(uuid,uuid,date,text,numeric,text,jsonb,numeric,text,text,text)'
    ) is not null,

  'anular_venta_existe',
    to_regprocedure(
      'public.anular_venta(uuid,text)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_crear_venta',
    has_function_privilege(
      'authenticated',
      'public.crear_venta_directa(uuid,uuid,date,text,numeric,text,jsonb,numeric,text,text,text)',
      'EXECUTE'
    ),

  'authenticated_anular_venta',
    has_function_privilege(
      'authenticated',
      'public.anular_venta(uuid,text)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a3_1;