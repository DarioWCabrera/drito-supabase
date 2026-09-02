-- ============================================================
-- DRITO
-- PASO 15A.6
-- AUDITORÍA OPERACIONAL - GASTOS GENERALES
--
-- Audita:
-- - registro de gasto general (GTO);
-- - anulación de gasto general.
--
-- El movimiento de Caja asociado NO se audita nuevamente como
-- movimiento manual independiente:
-- la operación económica padre es el GTO.
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
    'public.__drito_original_registrar_gasto_general_f36eb3aa88(uuid,uuid,date,text,numeric,text,text,text,text)'
  ) is null then
    raise exception
      'Falta el motor original de registrar_gasto_general';
  end if;


  if to_regprocedure(
    'public.__drito_original_anular_gasto_general_1c1a40f76d(uuid,text)'
  ) is null then
    raise exception
      'Falta el motor original de anular_gasto_general';
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
-- 1. REGISTRAR GASTO GENERAL + AUDITORÍA
-- ============================================================

create or replace function
public.registrar_gasto_general(
  p_comercio_id uuid,
  p_categoria_id uuid,
  p_fecha_gasto date,
  p_concepto text,
  p_importe numeric,
  p_medio_pago text,
  p_beneficiario text default null,
  p_referencia text default null,
  p_observaciones text default null
)
returns table (
  gasto_id uuid,
  numero bigint,
  comprobante text,
  fecha_gasto date,
  categoria_id uuid,
  categoria_nombre text,
  concepto text,
  beneficiario text,
  importe numeric,
  medio_pago text,
  referencia text,
  observaciones text,
  estado text,
  movimiento_caja_id uuid
)
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_resultado record;

begin

  -- ==========================================================
  -- COMERCIO / PERMISO
  -- ==========================================================

  if p_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'gastos.registrar'
  );


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  select *
  into v_resultado
  from public.__drito_original_registrar_gasto_general_f36eb3aa88(
    p_comercio_id,
    p_categoria_id,
    p_fecha_gasto,
    p_concepto,
    p_importe,
    p_medio_pago,
    p_beneficiario,
    p_referencia,
    p_observaciones
  );


  if v_resultado.gasto_id is null then
    raise exception
      'El gasto fue procesado pero no devolvió identificación';
  end if;


  -- ==========================================================
  -- AUDITORÍA PADRE GTO
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      p_comercio_id,

    p_modulo =>
      'gastos',

    p_accion =>
      'gasto_general_registrado',

    p_entidad_tipo =>
      'gasto_general',

    p_entidad_id =>
      v_resultado.gasto_id::text,

    p_referencia =>
      v_resultado.comprobante::text,

    p_detalle =>
      jsonb_build_object(

        'categoria_id',
          v_resultado.categoria_id,

        'categoria_nombre',
          v_resultado.categoria_nombre,

        'fecha_gasto',
          v_resultado.fecha_gasto,

        'concepto',
          v_resultado.concepto,

        'beneficiario',
          v_resultado.beneficiario,

        'importe',
          v_resultado.importe,

        'medio_pago',
          v_resultado.medio_pago,

        'referencia_externa',
          v_resultado.referencia,

        'observaciones',
          v_resultado.observaciones,

        'estado',
          v_resultado.estado,

        'movimiento_caja_id',
          v_resultado.movimiento_caja_id

      )

  );


  -- ==========================================================
  -- RESPUESTA ORIGINAL
  -- ==========================================================

  return query
  select

    v_resultado.gasto_id::uuid,

    v_resultado.numero::bigint,

    v_resultado.comprobante::text,

    v_resultado.fecha_gasto::date,

    v_resultado.categoria_id::uuid,

    v_resultado.categoria_nombre::text,

    v_resultado.concepto::text,

    v_resultado.beneficiario::text,

    v_resultado.importe::numeric,

    v_resultado.medio_pago::text,

    v_resultado.referencia::text,

    v_resultado.observaciones::text,

    v_resultado.estado::text,

    v_resultado.movimiento_caja_id::uuid;

end;
$function$;


-- ============================================================
-- 2. ANULAR GASTO GENERAL + AUDITORÍA
-- ============================================================

create or replace function
public.anular_gasto_general(
  p_gasto_id uuid,
  p_motivo text
)
returns table (
  gasto_id uuid,
  numero bigint,
  comprobante text,
  importe_anulado numeric,
  estado text,
  movimiento_caja_id uuid
)
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_gasto public.gastos_generales%rowtype;

  v_comercio_id uuid;

  v_resultado record;

  v_estado_caja text;

begin

  -- ==========================================================
  -- SNAPSHOT DEL GASTO
  -- ==========================================================

  select gg.*
  into v_gasto
  from public.gastos_generales gg
  where gg.id = p_gasto_id;


  if not found then
    raise exception
      'No se pudo determinar el gasto';
  end if;


  v_comercio_id :=
    v_gasto.comercio_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  -- ==========================================================
  -- PERMISO
  -- ==========================================================

  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'gastos.anular'
  );


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  select *
  into v_resultado
  from public.__drito_original_anular_gasto_general_1c1a40f76d(
    p_gasto_id,
    p_motivo
  );


  if v_resultado.gasto_id is null then
    raise exception
      'La anulación fue procesada pero no devolvió identificación';
  end if;


  -- ==========================================================
  -- ESTADO FINAL DE CAJA
  -- ==========================================================

  select mc.estado
  into v_estado_caja
  from public.movimientos_caja mc
  where mc.id = v_resultado.movimiento_caja_id;


  -- ==========================================================
  -- AUDITORÍA PADRE GTO
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      v_comercio_id,

    p_modulo =>
      'gastos',

    p_accion =>
      'gasto_general_anulado',

    p_entidad_tipo =>
      'gasto_general',

    p_entidad_id =>
      p_gasto_id::text,

    p_referencia =>
      v_resultado.comprobante::text,

    p_detalle =>
      jsonb_build_object(

        'categoria_id',
          v_gasto.categoria_id,

        'fecha_gasto',
          v_gasto.fecha_gasto,

        'concepto',
          v_gasto.concepto,

        'beneficiario',
          v_gasto.beneficiario,

        'importe_anulado',
          v_resultado.importe_anulado,

        'medio_pago',
          v_gasto.medio_pago,

        'referencia_externa',
          v_gasto.referencia,

        'estado_anterior',
          v_gasto.estado,

        'estado_nuevo',
          v_resultado.estado,

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

        'movimiento_caja_id',
          v_resultado.movimiento_caja_id,

        'estado_movimiento_caja',
          v_estado_caja

      )

  );


  -- ==========================================================
  -- RESPUESTA ORIGINAL
  -- ==========================================================

  return query
  select

    v_resultado.gasto_id::uuid,

    v_resultado.numero::bigint,

    v_resultado.comprobante::text,

    v_resultado.importe_anulado::numeric,

    v_resultado.estado::text,

    v_resultado.movimiento_caja_id::uuid;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.registrar_gasto_general(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  text,
  text,
  text
)
from public, anon;


grant execute on function
public.registrar_gasto_general(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  text,
  text,
  text
)
to authenticated;


revoke all on function
public.anular_gasto_general(
  uuid,
  text
)
from public, anon;


grant execute on function
public.anular_gasto_general(
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

  'registrar_gasto_existe',
    to_regprocedure(
      'public.registrar_gasto_general(uuid,uuid,date,text,numeric,text,text,text,text)'
    ) is not null,

  'anular_gasto_existe',
    to_regprocedure(
      'public.anular_gasto_general(uuid,text)'
    ) is not null,

  'motor_registro_existe',
    to_regprocedure(
      'public.__drito_original_registrar_gasto_general_f36eb3aa88(uuid,uuid,date,text,numeric,text,text,text,text)'
    ) is not null,

  'motor_anulacion_existe',
    to_regprocedure(
      'public.__drito_original_anular_gasto_general_1c1a40f76d(uuid,text)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_registrar_gasto',
    has_function_privilege(
      'authenticated',
      'public.registrar_gasto_general(uuid,uuid,date,text,numeric,text,text,text,text)',
      'EXECUTE'
    ),

  'authenticated_anular_gasto',
    has_function_privilege(
      'authenticated',
      'public.anular_gasto_general(uuid,text)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a6;