-- ============================================================
-- DRITO
-- PASO 15A.5
-- AUDITORÍA OPERACIONAL - CAJA MANUAL
--
-- Audita:
-- - registro manual de ingreso/egreso;
-- - anulación manual de movimiento.
--
-- NO audita nuevamente movimientos automáticos provenientes de:
-- - pagos de ventas;
-- - pagos de compras;
-- - cobros agrupados;
-- - pagos agrupados a proveedores;
-- - otras operaciones que ya poseen auditoría en su origen.
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
    'public.__drito_original_registrar_movimiento_caja_60bccf0453(uuid,uuid,text,date,numeric,text,text,text,text)'
  ) is null then
    raise exception
      'Falta el motor original de registrar_movimiento_caja';
  end if;


  if to_regprocedure(
    'public.__drito_original_anular_movimiento_caja_754cb5d23c(uuid,text)'
  ) is null then
    raise exception
      'Falta el motor original de anular_movimiento_caja';
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
-- 1. REGISTRAR MOVIMIENTO MANUAL + AUDITORÍA
-- ============================================================

create or replace function
public.registrar_movimiento_caja(
  p_comercio_id uuid,
  p_categoria_id uuid,
  p_tipo text,
  p_fecha date,
  p_importe numeric,
  p_medio_pago text,
  p_concepto text,
  p_referencia text,
  p_observaciones text
)
returns table (
  movimiento_id uuid,
  tipo_movimiento text,
  importe_movimiento numeric,
  fecha_movimiento date
)
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_resultado record;

  v_movimiento public.movimientos_caja%rowtype;

  v_referencia text;

begin

  -- ==========================================================
  -- PERMISO
  -- ==========================================================

  if p_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'caja.registrar_manual'
  );


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  select *
  into v_resultado
  from public.__drito_original_registrar_movimiento_caja_60bccf0453(
    p_comercio_id,
    p_categoria_id,
    p_tipo,
    p_fecha,
    p_importe,
    p_medio_pago,
    p_concepto,
    p_referencia,
    p_observaciones
  );


  if v_resultado.movimiento_id is null then
    raise exception
      'El movimiento fue procesado pero no devolvió identificación';
  end if;


  -- ==========================================================
  -- SNAPSHOT REAL DE LA FILA CREADA
  -- ==========================================================

  select mc.*
  into v_movimiento
  from public.movimientos_caja mc
  where mc.id = v_resultado.movimiento_id;


  if not found then
    raise exception
      'No se encontró el movimiento recién registrado';
  end if;


  v_referencia :=
    nullif(
      trim(
        coalesce(
          v_movimiento.referencia,
          ''
        )
      ),
      ''
    );


  -- ==========================================================
  -- AUDITORÍA
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      p_comercio_id,

    p_modulo =>
      'caja',

    p_accion =>
      'movimiento_caja_manual_registrado',

    p_entidad_tipo =>
      'movimiento_caja',

    p_entidad_id =>
      v_movimiento.id::text,

    p_referencia =>
      v_referencia,

    p_detalle =>
      jsonb_build_object(

        'categoria_id',
          v_movimiento.categoria_id,

        'tipo',
          v_movimiento.tipo,

        'origen',
          v_movimiento.origen,

        'fecha',
          v_movimiento.fecha,

        'importe',
          v_movimiento.importe,

        'medio_pago',
          v_movimiento.medio_pago,

        'concepto',
          v_movimiento.concepto,

        'referencia',
          v_movimiento.referencia,

        'observaciones',
          v_movimiento.observaciones,

        'estado',
          v_movimiento.estado

      )

  );


  -- ==========================================================
  -- RESPUESTA ORIGINAL
  -- ==========================================================

  return query
  select

    v_resultado.movimiento_id::uuid,

    v_resultado.tipo_movimiento::text,

    v_resultado.importe_movimiento::numeric,

    v_resultado.fecha_movimiento::date;

end;
$function$;


-- ============================================================
-- 2. ANULAR MOVIMIENTO MANUAL + AUDITORÍA
-- ============================================================

create or replace function
public.anular_movimiento_caja(
  p_movimiento_id uuid,
  p_motivo text
)
returns table (
  movimiento_id uuid,
  tipo_movimiento text,
  importe_movimiento numeric,
  estado_movimiento text
)
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_movimiento public.movimientos_caja%rowtype;

  v_comercio_id uuid;

  v_resultado record;

  v_referencia text;

begin

  -- ==========================================================
  -- SNAPSHOT ANTES DE ANULAR
  -- ==========================================================

  select mc.*
  into v_movimiento
  from public.movimientos_caja mc
  where mc.id = p_movimiento_id;


  if not found then
    raise exception
      'No se pudo determinar el movimiento de Caja';
  end if;


  v_comercio_id :=
    v_movimiento.comercio_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  -- ==========================================================
  -- PERMISO
  -- ==========================================================

  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'caja.anular_manual'
  );


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  select *
  into v_resultado
  from public.__drito_original_anular_movimiento_caja_754cb5d23c(
    p_movimiento_id,
    p_motivo
  );


  if v_resultado.movimiento_id is null then
    raise exception
      'La anulación fue procesada pero no devolvió identificación';
  end if;


  v_referencia :=
    nullif(
      trim(
        coalesce(
          v_movimiento.referencia,
          ''
        )
      ),
      ''
    );


  -- ==========================================================
  -- AUDITORÍA
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      v_comercio_id,

    p_modulo =>
      'caja',

    p_accion =>
      'movimiento_caja_manual_anulado',

    p_entidad_tipo =>
      'movimiento_caja',

    p_entidad_id =>
      p_movimiento_id::text,

    p_referencia =>
      v_referencia,

    p_detalle =>
      jsonb_build_object(

        'categoria_id',
          v_movimiento.categoria_id,

        'tipo',
          v_movimiento.tipo,

        'origen',
          v_movimiento.origen,

        'fecha',
          v_movimiento.fecha,

        'importe',
          v_movimiento.importe,

        'medio_pago',
          v_movimiento.medio_pago,

        'concepto',
          v_movimiento.concepto,

        'referencia',
          v_movimiento.referencia,

        'estado_anterior',
          v_movimiento.estado,

        'estado_nuevo',
          v_resultado.estado_movimiento,

        'motivo',
          nullif(
            trim(
              coalesce(
                p_motivo,
                ''
              )
            ),
            ''
          )

      )

  );


  -- ==========================================================
  -- RESPUESTA ORIGINAL
  -- ==========================================================

  return query
  select

    v_resultado.movimiento_id::uuid,

    v_resultado.tipo_movimiento::text,

    v_resultado.importe_movimiento::numeric,

    v_resultado.estado_movimiento::text;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.registrar_movimiento_caja(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  text
)
from public, anon;


grant execute on function
public.registrar_movimiento_caja(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  text
)
to authenticated;


revoke all on function
public.anular_movimiento_caja(
  uuid,
  text
)
from public, anon;


grant execute on function
public.anular_movimiento_caja(
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

  'registrar_movimiento_existe',
    to_regprocedure(
      'public.registrar_movimiento_caja(uuid,uuid,text,date,numeric,text,text,text,text)'
    ) is not null,

  'anular_movimiento_existe',
    to_regprocedure(
      'public.anular_movimiento_caja(uuid,text)'
    ) is not null,

  'motor_registro_existe',
    to_regprocedure(
      'public.__drito_original_registrar_movimiento_caja_60bccf0453(uuid,uuid,text,date,numeric,text,text,text,text)'
    ) is not null,

  'motor_anulacion_existe',
    to_regprocedure(
      'public.__drito_original_anular_movimiento_caja_754cb5d23c(uuid,text)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_registrar_manual',
    has_function_privilege(
      'authenticated',
      'public.registrar_movimiento_caja(uuid,uuid,text,date,numeric,text,text,text,text)',
      'EXECUTE'
    ),

  'authenticated_anular_manual',
    has_function_privilege(
      'authenticated',
      'public.anular_movimiento_caja(uuid,text)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a5;