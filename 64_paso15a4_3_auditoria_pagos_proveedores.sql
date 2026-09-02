-- ============================================================
-- DRITO
-- PASO 15A.4.3
-- AUDITORÍA OPERACIONAL - PAGOS AGRUPADOS A PROVEEDORES
--
-- Integra auditoría en:
-- - registrar_pago_cuenta_proveedor(...)
-- - anular_pago_cuenta_proveedor(...)
--
-- registrar_pago_cuenta_proveedor_con_retenciones(...)
-- reutiliza registrar_pago_cuenta_proveedor(...) para el dinero,
-- por lo que genera exactamente una auditoría padre PPR.
--
-- Las retenciones practicadas agrupadas ya son auditadas
-- independientemente por el PASO 15A.4.2.2.
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
    'public.__drito_original_registrar_pago_cuenta_proveedor_08bf6aac1e(uuid,date,numeric,text,text,text)'
  ) is null then
    raise exception
      'Falta el motor original de registrar_pago_cuenta_proveedor';
  end if;


  if to_regprocedure(
    'public.__drito_original_anular_pago_cuenta_proveedor_15db9aba1a(uuid,text)'
  ) is null then
    raise exception
      'Falta el motor original de anular_pago_cuenta_proveedor';
  end if;


  if to_regprocedure(
    'public.registrar_pago_cuenta_proveedor_con_retenciones(uuid,numeric,date,text,text,text,jsonb)'
  ) is null then
    raise exception
      'Falta registrar_pago_cuenta_proveedor_con_retenciones';
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
-- 1. REGISTRAR PAGO AGRUPADO A PROVEEDOR + AUDITORÍA
-- ============================================================

create or replace function
public.registrar_pago_cuenta_proveedor(
  p_proveedor_id uuid,
  p_fecha_pago date,
  p_importe numeric,
  p_medio_pago text,
  p_referencia text default null,
  p_observaciones text default null
)
returns table (
  pago_proveedor_id uuid,
  numero_pago_proveedor bigint,
  comprobante text,
  nombre_proveedor text,
  importe_pagado numeric,
  compras_afectadas integer,
  pagos_generados integer,
  saldo_anterior numeric,
  saldo_final numeric,
  movimiento_caja_id uuid
)
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_comercio_id uuid;

  v_resultado record;

begin

  -- ==========================================================
  -- COMERCIO
  -- ==========================================================

  select pr.comercio_id
  into v_comercio_id
  from public.proveedores pr
  where pr.id = p_proveedor_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  -- ==========================================================
  -- PERMISO
  -- ==========================================================

  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'cuentas_proveedores.registrar_pagos'
  );


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  select *
  into v_resultado
  from public.__drito_original_registrar_pago_cuenta_proveedor_08bf6aac1e(
    p_proveedor_id,
    p_fecha_pago,
    p_importe,
    p_medio_pago,
    p_referencia,
    p_observaciones
  );


  if v_resultado.pago_proveedor_id is null then
    raise exception
      'El pago agrupado fue procesado pero no devolvió identificación';
  end if;


  -- ==========================================================
  -- AUDITORÍA PADRE PPR
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      v_comercio_id,

    p_modulo =>
      'cuentas_proveedores',

    p_accion =>
      'pago_proveedor_registrado',

    p_entidad_tipo =>
      'pago_proveedor',

    p_entidad_id =>
      v_resultado.pago_proveedor_id::text,

    p_referencia =>
      v_resultado.comprobante::text,

    p_detalle =>
      jsonb_build_object(

        'proveedor_id',
          p_proveedor_id,

        'nombre_proveedor',
          v_resultado.nombre_proveedor,

        'fecha_pago',
          p_fecha_pago,

        'importe_pagado',
          v_resultado.importe_pagado,

        'medio_pago',
          p_medio_pago,

        'referencia_externa',
          nullif(
            trim(
              coalesce(
                p_referencia,
                ''
              )
            ),
            ''
          ),

        'compras_afectadas',
          v_resultado.compras_afectadas,

        'pagos_generados',
          v_resultado.pagos_generados,

        'saldo_anterior',
          v_resultado.saldo_anterior,

        'saldo_final',
          v_resultado.saldo_final,

        'movimiento_caja_id',
          v_resultado.movimiento_caja_id

      )

  );


  -- ==========================================================
  -- RESPUESTA ORIGINAL
  -- ==========================================================

  return query
  select

    v_resultado.pago_proveedor_id::uuid,

    v_resultado.numero_pago_proveedor::bigint,

    v_resultado.comprobante::text,

    v_resultado.nombre_proveedor::text,

    v_resultado.importe_pagado::numeric,

    v_resultado.compras_afectadas::integer,

    v_resultado.pagos_generados::integer,

    v_resultado.saldo_anterior::numeric,

    v_resultado.saldo_final::numeric,

    v_resultado.movimiento_caja_id::uuid;

end;
$function$;


-- ============================================================
-- 2. ANULAR PAGO AGRUPADO A PROVEEDOR + AUDITORÍA
-- ============================================================

create or replace function
public.anular_pago_cuenta_proveedor(
  p_pago_proveedor_id uuid,
  p_motivo text
)
returns table (
  pago_proveedor_id uuid,
  numero_pago_proveedor bigint,
  comprobante text,
  importe_anulado numeric,
  pagos_anulados integer,
  compras_actualizadas integer,
  saldo_actual numeric
)
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_pago public.pagos_proveedores%rowtype;

  v_comercio_id uuid;

  v_resultado record;

begin

  -- ==========================================================
  -- SNAPSHOT DEL PPR
  -- ==========================================================

  select pp.*
  into v_pago
  from public.pagos_proveedores pp
  where pp.id = p_pago_proveedor_id;


  if not found then
    raise exception
      'No se pudo determinar el pago agrupado';
  end if;


  v_comercio_id :=
    v_pago.comercio_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  -- ==========================================================
  -- PERMISO
  -- ==========================================================

  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'cuentas_proveedores.anular_pagos'
  );


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  select *
  into v_resultado
  from public.__drito_original_anular_pago_cuenta_proveedor_15db9aba1a(
    p_pago_proveedor_id,
    p_motivo
  );


  if v_resultado.pago_proveedor_id is null then
    raise exception
      'La anulación fue procesada pero no devolvió identificación';
  end if;


  -- ==========================================================
  -- AUDITORÍA PADRE PPR
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      v_comercio_id,

    p_modulo =>
      'cuentas_proveedores',

    p_accion =>
      'pago_proveedor_anulado',

    p_entidad_tipo =>
      'pago_proveedor',

    p_entidad_id =>
      p_pago_proveedor_id::text,

    p_referencia =>
      v_resultado.comprobante::text,

    p_detalle =>
      jsonb_build_object(

        'proveedor_id',
          v_pago.proveedor_id,

        'motivo',
          nullif(
            trim(
              coalesce(
                p_motivo,
                ''
              )
            ),
            ''
          ),

        'fecha_pago',
          v_pago.fecha_pago,

        'importe_anulado',
          v_resultado.importe_anulado,

        'medio_pago',
          v_pago.medio_pago,

        'referencia_externa',
          v_pago.referencia,

        'estado_anterior',
          v_pago.estado,

        'estado_nuevo',
          'anulado',

        'pagos_anulados',
          v_resultado.pagos_anulados,

        'compras_actualizadas',
          v_resultado.compras_actualizadas,

        'saldo_actual',
          v_resultado.saldo_actual

      )

  );


  -- ==========================================================
  -- RESPUESTA ORIGINAL
  -- ==========================================================

  return query
  select

    v_resultado.pago_proveedor_id::uuid,

    v_resultado.numero_pago_proveedor::bigint,

    v_resultado.comprobante::text,

    v_resultado.importe_anulado::numeric,

    v_resultado.pagos_anulados::integer,

    v_resultado.compras_actualizadas::integer,

    v_resultado.saldo_actual::numeric;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.registrar_pago_cuenta_proveedor(
  uuid,
  date,
  numeric,
  text,
  text,
  text
)
from public, anon;


grant execute on function
public.registrar_pago_cuenta_proveedor(
  uuid,
  date,
  numeric,
  text,
  text,
  text
)
to authenticated;


revoke all on function
public.anular_pago_cuenta_proveedor(
  uuid,
  text
)
from public, anon;


grant execute on function
public.anular_pago_cuenta_proveedor(
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

  'registrar_pago_proveedor_existe',
    to_regprocedure(
      'public.registrar_pago_cuenta_proveedor(uuid,date,numeric,text,text,text)'
    ) is not null,

  'anular_pago_proveedor_existe',
    to_regprocedure(
      'public.anular_pago_cuenta_proveedor(uuid,text)'
    ) is not null,

  'pago_proveedor_con_retenciones_existe',
    to_regprocedure(
      'public.registrar_pago_cuenta_proveedor_con_retenciones(uuid,numeric,date,text,text,text,jsonb)'
    ) is not null,

  'motor_registro_existe',
    to_regprocedure(
      'public.__drito_original_registrar_pago_cuenta_proveedor_08bf6aac1e(uuid,date,numeric,text,text,text)'
    ) is not null,

  'motor_anulacion_existe',
    to_regprocedure(
      'public.__drito_original_anular_pago_cuenta_proveedor_15db9aba1a(uuid,text)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_registrar_pago',
    has_function_privilege(
      'authenticated',
      'public.registrar_pago_cuenta_proveedor(uuid,date,numeric,text,text,text)',
      'EXECUTE'
    ),

  'authenticated_anular_pago',
    has_function_privilege(
      'authenticated',
      'public.anular_pago_cuenta_proveedor(uuid,text)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a4_3;