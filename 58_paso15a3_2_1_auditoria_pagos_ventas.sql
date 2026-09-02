-- ============================================================
-- DRITO
-- PASO 15A.3.2.1
-- AUDITORÍA OPERACIONAL - PAGOS DE VENTAS
--
-- Integra auditoría en:
-- - registrar_pago_venta(...)
-- - anular_pago_venta(...)
--
-- No modifica los motores económicos originales.
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
    'public.__drito_original_registrar_pago_venta_e00709f6b3(uuid,numeric,date,text,text,text)'
  ) is null then
    raise exception
      'Falta el motor original de registrar_pago_venta';
  end if;


  if to_regprocedure(
    'public.__drito_original_anular_pago_venta_b0df0ab45e(uuid,text)'
  ) is null then
    raise exception
      'Falta el motor original de anular_pago_venta';
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
-- 1. REGISTRAR PAGO DE VENTA + AUDITORÍA
-- ============================================================

create or replace function
public.registrar_pago_venta(
  p_venta_id uuid,
  p_importe numeric,
  p_fecha_pago date default current_date,
  p_medio_pago text default 'efectivo',
  p_referencia text default null,
  p_observaciones text default null
)
returns table (
  pago_id uuid,
  numero_pago bigint,
  venta_id uuid,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $function$
declare

  v_comercio_id uuid;

  v_resultado record;

  v_referencia_pago text;

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
    'ventas.registrar_cobros'
  );


  select *
  into v_resultado
  from public.__drito_original_registrar_pago_venta_e00709f6b3(
    p_venta_id,
    p_importe,
    p_fecha_pago,
    p_medio_pago,
    p_referencia,
    p_observaciones
  );


  if v_resultado.pago_id is null then
    raise exception
      'El pago fue procesado pero no devolvió identificación';
  end if;


  v_referencia_pago :=
    'PAG-' ||
    lpad(
      v_resultado.numero_pago::text,
      6,
      '0'
    );


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id  => v_comercio_id,
    p_modulo       => 'ventas',
    p_accion       => 'pago_venta_registrado',
    p_entidad_tipo => 'pago_venta',
    p_entidad_id   => v_resultado.pago_id::text,
    p_referencia   => v_referencia_pago,
    p_detalle      => jsonb_build_object(

      'venta_id',
        p_venta_id,

      'importe',
        p_importe,

      'fecha_pago',
        p_fecha_pago,

      'medio_pago',
        p_medio_pago,

      'referencia_externa',
        nullif(
          trim(coalesce(p_referencia, '')),
          ''
        ),

      'total_pagado',
        v_resultado.total_pagado,

      'saldo_pendiente',
        v_resultado.saldo_pendiente,

      'estado_pago',
        v_resultado.estado_pago

    )
  );


  return query
  select
    v_resultado.pago_id::uuid,
    v_resultado.numero_pago::bigint,
    v_resultado.venta_id::uuid,
    v_resultado.total_pagado::numeric,
    v_resultado.saldo_pendiente::numeric,
    v_resultado.estado_pago::text;

end;
$function$;


-- ============================================================
-- 2. ANULAR PAGO DE VENTA + AUDITORÍA
-- ============================================================

create or replace function
public.anular_pago_venta(
  p_pago_id uuid,
  p_motivo text
)
returns table (
  pago_id uuid,
  venta_id uuid,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $function$
declare

  v_comercio_id uuid;

  v_pago public.pagos_ventas%rowtype;

  v_resultado record;

  v_referencia_pago text;

begin

  select pv.*
  into v_pago
  from public.pagos_ventas pv
  where pv.id = p_pago_id;


  if not found then
    raise exception
      'No se pudo determinar el pago de la operación';
  end if;


  v_comercio_id :=
    v_pago.comercio_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'ventas.anular_pagos'
  );


  select *
  into v_resultado
  from public.__drito_original_anular_pago_venta_b0df0ab45e(
    p_pago_id,
    p_motivo
  );


  if v_resultado.pago_id is null then
    raise exception
      'La anulación fue procesada pero no devolvió identificación';
  end if;


  v_referencia_pago :=
    'PAG-' ||
    lpad(
      v_pago.numero::text,
      6,
      '0'
    );


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id  => v_comercio_id,
    p_modulo       => 'ventas',
    p_accion       => 'pago_venta_anulado',
    p_entidad_tipo => 'pago_venta',
    p_entidad_id   => p_pago_id::text,
    p_referencia   => v_referencia_pago,
    p_detalle      => jsonb_build_object(

      'venta_id',
        v_resultado.venta_id,

      'motivo',
        nullif(
          trim(coalesce(p_motivo, '')),
          ''
        ),

      'importe_original',
        v_pago.importe,

      'fecha_pago',
        v_pago.fecha_pago,

      'medio_pago',
        v_pago.medio_pago,

      'referencia_externa',
        v_pago.referencia,

      'total_pagado',
        v_resultado.total_pagado,

      'saldo_pendiente',
        v_resultado.saldo_pendiente,

      'estado_pago',
        v_resultado.estado_pago

    )
  );


  return query
  select
    v_resultado.pago_id::uuid,
    v_resultado.venta_id::uuid,
    v_resultado.total_pagado::numeric,
    v_resultado.saldo_pendiente::numeric,
    v_resultado.estado_pago::text;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.registrar_pago_venta(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
from public, anon;


grant execute on function
public.registrar_pago_venta(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
to authenticated;


revoke all on function
public.anular_pago_venta(
  uuid,
  text
)
from public, anon;


grant execute on function
public.anular_pago_venta(
  uuid,
  text
)
to authenticated;


-- ============================================================
-- 4. RECARGA POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 5. VERIFICACIÓN
-- ============================================================

select jsonb_build_object(

  'registrar_pago_venta_existe',
    to_regprocedure(
      'public.registrar_pago_venta(uuid,numeric,date,text,text,text)'
    ) is not null,

  'anular_pago_venta_existe',
    to_regprocedure(
      'public.anular_pago_venta(uuid,text)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_registrar_pago',
    has_function_privilege(
      'authenticated',
      'public.registrar_pago_venta(uuid,numeric,date,text,text,text)',
      'EXECUTE'
    ),

  'authenticated_anular_pago',
    has_function_privilege(
      'authenticated',
      'public.anular_pago_venta(uuid,text)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a3_2_1;