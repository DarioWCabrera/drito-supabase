-- ============================================================
-- DRITO
-- PASO 15A.4.2.1
-- AUDITORÍA OPERACIONAL - PAGOS DE COMPRAS
--
-- Integra auditoría en:
-- - registrar_pago_compra(...)
-- - anular_pago_compra(...)
--
-- registrar_pago_compra_con_retenciones(...)
-- reutiliza registrar_pago_compra(...) cuando existe dinero,
-- por lo que no se genera una auditoría duplicada del pago.
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
    'public.__drito_original_registrar_pago_compra_8ebed35a41(uuid,numeric,date,text,text,text)'
  ) is null then
    raise exception
      'Falta el motor original de registrar_pago_compra';
  end if;


  if to_regprocedure(
    'public.__drito_original_anular_pago_compra_b0df0ab45e(uuid,text)'
  ) is null then
    raise exception
      'Falta el motor original de anular_pago_compra';
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
-- 1. REGISTRAR PAGO DE COMPRA + AUDITORÍA
-- ============================================================

create or replace function
public.registrar_pago_compra(
  p_compra_id uuid,
  p_importe numeric,
  p_fecha_pago date,
  p_medio_pago text,
  p_referencia text,
  p_observaciones text
)
returns table (
  pago_id uuid,
  numero_pago bigint,
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

  select c.comercio_id
  into v_comercio_id
  from public.compras c
  where c.id = p_compra_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'compras.registrar_pagos'
  );


  select *
  into v_resultado
  from public.__drito_original_registrar_pago_compra_8ebed35a41(
    p_compra_id,
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
    p_modulo       => 'compras',
    p_accion       => 'pago_compra_registrado',
    p_entidad_tipo => 'pago_compra',
    p_entidad_id   => v_resultado.pago_id::text,
    p_referencia   => v_referencia_pago,
    p_detalle      => jsonb_build_object(

      'compra_id',
        p_compra_id,

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
    v_resultado.total_pagado::numeric,
    v_resultado.saldo_pendiente::numeric,
    v_resultado.estado_pago::text;

end;
$function$;


-- ============================================================
-- 2. ANULAR PAGO DE COMPRA + AUDITORÍA
-- ============================================================

create or replace function
public.anular_pago_compra(
  p_pago_id uuid,
  p_motivo text
)
returns table (
  pago_id uuid,
  compra_id uuid,
  numero_pago bigint,
  importe_anulado numeric,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $function$
declare

  v_pago public.pagos_compras%rowtype;

  v_comercio_id uuid;

  v_resultado record;

  v_referencia_pago text;

begin

  select pc.*
  into v_pago
  from public.pagos_compras pc
  where pc.id = p_pago_id;


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
    'compras.anular_pagos'
  );


  select *
  into v_resultado
  from public.__drito_original_anular_pago_compra_b0df0ab45e(
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
      v_resultado.numero_pago::text,
      6,
      '0'
    );


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id  => v_comercio_id,
    p_modulo       => 'compras',
    p_accion       => 'pago_compra_anulado',
    p_entidad_tipo => 'pago_compra',
    p_entidad_id   => p_pago_id::text,
    p_referencia   => v_referencia_pago,
    p_detalle      => jsonb_build_object(

      'compra_id',
        v_resultado.compra_id,

      'motivo',
        nullif(
          trim(coalesce(p_motivo, '')),
          ''
        ),

      'importe_anulado',
        v_resultado.importe_anulado,

      'fecha_pago',
        to_jsonb(v_pago)->>'fecha_pago',

      'medio_pago',
        to_jsonb(v_pago)->>'medio_pago',

      'referencia_externa',
        to_jsonb(v_pago)->>'referencia',

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
    v_resultado.compra_id::uuid,
    v_resultado.numero_pago::bigint,
    v_resultado.importe_anulado::numeric,
    v_resultado.total_pagado::numeric,
    v_resultado.saldo_pendiente::numeric,
    v_resultado.estado_pago::text;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.registrar_pago_compra(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
from public, anon;


grant execute on function
public.registrar_pago_compra(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
to authenticated;


revoke all on function
public.anular_pago_compra(
  uuid,
  text
)
from public, anon;


grant execute on function
public.anular_pago_compra(
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

  'registrar_pago_compra_existe',
    to_regprocedure(
      'public.registrar_pago_compra(uuid,numeric,date,text,text,text)'
    ) is not null,

  'anular_pago_compra_existe',
    to_regprocedure(
      'public.anular_pago_compra(uuid,text)'
    ) is not null,

  'pago_con_retenciones_existe',
    to_regprocedure(
      'public.registrar_pago_compra_con_retenciones(uuid,numeric,date,text,text,text,jsonb)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_registrar_pago',
    has_function_privilege(
      'authenticated',
      'public.registrar_pago_compra(uuid,numeric,date,text,text,text)',
      'EXECUTE'
    ),

  'authenticated_anular_pago',
    has_function_privilege(
      'authenticated',
      'public.anular_pago_compra(uuid,text)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a4_2_1;