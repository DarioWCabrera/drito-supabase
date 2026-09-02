-- ============================================================
-- DRITO
-- PASO 15A.4.1
-- AUDITORÍA OPERACIONAL - COMPRAS
--
-- Integra auditoría en:
-- - crear_compra(...)
-- - anular_compra(...)
--
-- crear_compra_con_percepciones(...) reutiliza crear_compra(...),
-- por lo que queda cubierta sin generar un segundo evento padre.
--
-- Las percepciones sufridas tendrán su propia auditoría.
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
    'public.__drito_original_crear_compra_f52f1a839b(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb)'
  ) is null then
    raise exception
      'Falta el motor original de crear_compra';
  end if;


  if to_regprocedure(
    'public.__drito_original_anular_compra_c40d574d1b(uuid,text)'
  ) is null then
    raise exception
      'Falta el motor original de anular_compra';
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
-- 1. CREAR COMPRA + AUDITORÍA
-- ============================================================

create or replace function
public.crear_compra(
  p_comercio_id uuid,
  p_proveedor_id uuid,
  p_fecha_compra date,
  p_fecha_vencimiento date,
  p_tipo_comprobante text,
  p_numero_comprobante text,
  p_moneda text,
  p_descuento_general_porcentaje numeric,
  p_observaciones text,
  p_actualizar_costos boolean,
  p_items jsonb
)
returns table (
  compra_id uuid,
  numero_compra bigint,
  total_compra numeric,
  movimientos_generados integer,
  cantidad_total_ingresada numeric
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

  v_comercio_id :=
    p_comercio_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'compras.crear'
  );


  select *
  into v_resultado
  from public.__drito_original_crear_compra_f52f1a839b(
    p_comercio_id,
    p_proveedor_id,
    p_fecha_compra,
    p_fecha_vencimiento,
    p_tipo_comprobante,
    p_numero_comprobante,
    p_moneda,
    p_descuento_general_porcentaje,
    p_observaciones,
    p_actualizar_costos,
    p_items
  );


  if v_resultado.compra_id is null then
    raise exception
      'La compra fue procesada pero no devolvió identificación';
  end if;


  v_referencia :=
    'COM-' ||
    lpad(
      v_resultado.numero_compra::text,
      6,
      '0'
    );


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id  => v_comercio_id,
    p_modulo       => 'compras',
    p_accion       => 'compra_creada',
    p_entidad_tipo => 'compra',
    p_entidad_id   => v_resultado.compra_id::text,
    p_referencia   => v_referencia,
    p_detalle      => jsonb_build_object(

      'proveedor_id',
        p_proveedor_id,

      'fecha_compra',
        p_fecha_compra,

      'fecha_vencimiento',
        p_fecha_vencimiento,

      'tipo_comprobante',
        p_tipo_comprobante,

      'numero_comprobante_proveedor',
        nullif(
          trim(coalesce(p_numero_comprobante, '')),
          ''
        ),

      'moneda',
        p_moneda,

      'descuento_general_porcentaje',
        coalesce(
          p_descuento_general_porcentaje,
          0
        ),

      -- Este total corresponde al motor comercial base.
      -- Si la operación superior agrega percepciones sufridas,
      -- estas se auditan de forma independiente.

      'total_comercial_inicial',
        v_resultado.total_compra,

      'actualizar_costos',
        coalesce(
          p_actualizar_costos,
          false
        ),

      'movimientos_stock_generados',
        v_resultado.movimientos_generados,

      'cantidad_total_ingresada',
        v_resultado.cantidad_total_ingresada

    )
  );


  return query
  select
    v_resultado.compra_id::uuid,
    v_resultado.numero_compra::bigint,
    v_resultado.total_compra::numeric,
    v_resultado.movimientos_generados::integer,
    v_resultado.cantidad_total_ingresada::numeric;

end;
$function$;


-- ============================================================
-- 2. ANULAR COMPRA + AUDITORÍA
-- ============================================================

create or replace function
public.anular_compra(
  p_compra_id uuid,
  p_motivo text
)
returns table (
  compra_id uuid,
  numero_compra bigint,
  movimientos_generados integer,
  cantidad_total_revertida numeric,
  estado_compra text
)
language plpgsql
security definer
set search_path = public
as $function$
declare

  v_compra public.compras%rowtype;

  v_comercio_id uuid;

  v_resultado record;

  v_referencia text;

begin

  select c.*
  into v_compra
  from public.compras c
  where c.id = p_compra_id;


  if not found then
    raise exception
      'No se pudo determinar la compra de la operación';
  end if;


  v_comercio_id :=
    v_compra.comercio_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'compras.anular_compras'
  );


  select *
  into v_resultado
  from public.__drito_original_anular_compra_c40d574d1b(
    p_compra_id,
    p_motivo
  );


  if v_resultado.compra_id is null then
    raise exception
      'La anulación fue procesada pero no devolvió identificación';
  end if;


  v_referencia :=
    'COM-' ||
    lpad(
      v_resultado.numero_compra::text,
      6,
      '0'
    );


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id  => v_comercio_id,
    p_modulo       => 'compras',
    p_accion       => 'compra_anulada',
    p_entidad_tipo => 'compra',
    p_entidad_id   => p_compra_id::text,
    p_referencia   => v_referencia,
    p_detalle      => jsonb_build_object(

      'proveedor_id',
        v_compra.proveedor_id,

      'motivo',
        nullif(
          trim(coalesce(p_motivo, '')),
          ''
        ),

      'tipo_comprobante',
        v_compra.tipo_comprobante,

      'numero_comprobante_proveedor',
        v_compra.numero_comprobante,

      'total_compra',
        v_compra.total,

      'estado_anterior',
        v_compra.estado,

      'estado_nuevo',
        v_resultado.estado_compra,

      'movimientos_stock_generados',
        v_resultado.movimientos_generados,

      'cantidad_total_revertida',
        v_resultado.cantidad_total_revertida

    )
  );


  return query
  select
    v_resultado.compra_id::uuid,
    v_resultado.numero_compra::bigint,
    v_resultado.movimientos_generados::integer,
    v_resultado.cantidad_total_revertida::numeric,
    v_resultado.estado_compra::text;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.crear_compra(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb
)
from public, anon;


grant execute on function
public.crear_compra(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb
)
to authenticated;


revoke all on function
public.anular_compra(
  uuid,
  text
)
from public, anon;


grant execute on function
public.anular_compra(
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

  'crear_compra_existe',
    to_regprocedure(
      'public.crear_compra(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb)'
    ) is not null,

  'crear_compra_con_percepciones_existe',
    to_regprocedure(
      'public.crear_compra_con_percepciones(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb,jsonb)'
    ) is not null,

  'anular_compra_existe',
    to_regprocedure(
      'public.anular_compra(uuid,text)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_crear_compra',
    has_function_privilege(
      'authenticated',
      'public.crear_compra(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb)',
      'EXECUTE'
    ),

  'authenticated_anular_compra',
    has_function_privilege(
      'authenticated',
      'public.anular_compra(uuid,text)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a4_1;