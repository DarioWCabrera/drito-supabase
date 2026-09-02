-- ============================================================
-- DRITO
-- PASO 15A.8
-- AUDITORÍA OPERACIONAL + ACCESO SEGURO
-- MOVIMIENTOS MANUALES DE STOCK
--
-- Expone una RPC pública controlada:
--   registrar_movimiento_stock(...)
--
-- Tipos manuales permitidos:
-- - entrada
-- - salida
-- - ajuste_positivo
-- - ajuste_negativo
--
-- Los movimientos automáticos:
-- - venta
-- - devolucion_cliente
-- - devolucion_proveedor
--
-- NO pueden ejecutarse mediante esta RPC.
--
-- Ventas y Compras conservan sus motores propios y
-- su auditoría operacional padre.
-- ============================================================


-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

do $$
begin

  if to_regclass(
    'public.productos'
  ) is null then
    raise exception
      'Falta public.productos';
  end if;


  if to_regclass(
    'public.movimientos_stock'
  ) is null then
    raise exception
      'Falta public.movimientos_stock';
  end if;


  if to_regprocedure(
    'public.__drito_original_registrar_movimiento_stock_7954a1c030(uuid,text,numeric,text,text,uuid)'
  ) is null then
    raise exception
      'Falta el motor original de movimientos de stock';
  end if;


  if to_regprocedure(
    'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
  ) is null then
    raise exception
      'Falta el helper de auditoría operacional';
  end if;


  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta exigir_permiso_comercio(uuid,text)';
  end if;


  if not exists (
    select 1
    from public.permisos_sistema
    where codigo = 'stock.registrar_ingreso'
      and activo = true
  ) then
    raise exception
      'Falta el permiso stock.registrar_ingreso';
  end if;


  if not exists (
    select 1
    from public.permisos_sistema
    where codigo = 'stock.registrar_egreso'
      and activo = true
  ) then
    raise exception
      'Falta el permiso stock.registrar_egreso';
  end if;


  if not exists (
    select 1
    from public.permisos_sistema
    where codigo = 'stock.ajustar'
      and activo = true
  ) then
    raise exception
      'Falta el permiso stock.ajustar';
  end if;

end;
$$;


-- ============================================================
-- 1. RPC PÚBLICA CONTROLADA
-- ============================================================

create or replace function
public.registrar_movimiento_stock(
  p_producto_id uuid,
  p_tipo text,
  p_cantidad numeric,
  p_motivo text default null,
  p_referencia_tipo text default null,
  p_referencia_id uuid default null
)
returns table (
  movimiento_id uuid,
  stock_anterior numeric,
  stock_posterior numeric
)
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_comercio_id uuid;

  v_tipo_normalizado text;

  v_permiso text;

  v_accion_auditoria text;

  v_resultado record;

begin

  -- ==========================================================
  -- PRODUCTO
  -- ==========================================================

  if p_producto_id is null then
    raise exception
      'El producto es obligatorio';
  end if;


  select p.comercio_id
  into v_comercio_id
  from public.productos p
  where p.id = p_producto_id;


  if v_comercio_id is null then
    raise exception
      'Producto no encontrado';
  end if;


  -- ==========================================================
  -- TIPO MANUAL
  -- ==========================================================

  v_tipo_normalizado :=
    lower(
      trim(
        coalesce(
          p_tipo,
          ''
        )
      )
    );


  case v_tipo_normalizado

    when 'entrada' then

      v_permiso :=
        'stock.registrar_ingreso';

      v_accion_auditoria :=
        'stock_ingreso_manual_registrado';


    when 'salida' then

      v_permiso :=
        'stock.registrar_egreso';

      v_accion_auditoria :=
        'stock_egreso_manual_registrado';


    when 'ajuste_positivo' then

      v_permiso :=
        'stock.ajustar';

      v_accion_auditoria :=
        'stock_ajuste_positivo_registrado';


    when 'ajuste_negativo' then

      v_permiso :=
        'stock.ajustar';

      v_accion_auditoria :=
        'stock_ajuste_negativo_registrado';


    else

      raise exception
        'Esta RPC solo admite entradas, salidas y ajustes manuales de stock';

  end case;


  -- ==========================================================
  -- PERMISO
  -- ==========================================================

  perform public.exigir_permiso_comercio(
    v_comercio_id,
    v_permiso
  );


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  select *
  into v_resultado
  from public.__drito_original_registrar_movimiento_stock_7954a1c030(
    p_producto_id,
    v_tipo_normalizado,
    p_cantidad,
    p_motivo,
    p_referencia_tipo,
    p_referencia_id
  );


  if v_resultado.movimiento_id is null then
    raise exception
      'El movimiento de stock fue procesado pero no devolvió identificación';
  end if;


  -- ==========================================================
  -- AUDITORÍA OPERACIONAL
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      v_comercio_id,

    p_modulo =>
      'stock',

    p_accion =>
      v_accion_auditoria,

    p_entidad_tipo =>
      'movimiento_stock',

    p_entidad_id =>
      v_resultado.movimiento_id::text,

    p_referencia =>
      nullif(
        trim(
          coalesce(
            p_referencia_tipo,
            ''
          )
        ),
        ''
      ),

    p_detalle =>
      jsonb_build_object(

        'producto_id',
          p_producto_id,

        'tipo',
          v_tipo_normalizado,

        'cantidad',
          p_cantidad,

        'stock_anterior',
          v_resultado.stock_anterior,

        'stock_posterior',
          v_resultado.stock_posterior,

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

        'referencia_tipo',
          nullif(
            trim(
              coalesce(
                p_referencia_tipo,
                ''
              )
            ),
            ''
          ),

        'referencia_id',
          p_referencia_id

      )

  );


  -- ==========================================================
  -- RESPUESTA ORIGINAL
  -- ==========================================================

  return query
  select

    v_resultado.movimiento_id::uuid,

    v_resultado.stock_anterior::numeric,

    v_resultado.stock_posterior::numeric;

end;
$function$;


-- ============================================================
-- 2. CERRAR ACCESO DIRECTO AL MOTOR INTERNO
-- ============================================================

revoke all on function
public.__drito_original_registrar_movimiento_stock_7954a1c030(
  uuid,
  text,
  numeric,
  text,
  text,
  uuid
)
from public, anon, authenticated;


-- ============================================================
-- 3. SEGURIDAD RPC PÚBLICA
-- ============================================================

revoke all on function
public.registrar_movimiento_stock(
  uuid,
  text,
  numeric,
  text,
  text,
  uuid
)
from public, anon;


grant execute on function
public.registrar_movimiento_stock(
  uuid,
  text,
  numeric,
  text,
  text,
  uuid
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

  'rpc_publica_existe',
    to_regprocedure(
      'public.registrar_movimiento_stock(uuid,text,numeric,text,text,uuid)'
    ) is not null,

  'motor_original_existe',
    to_regprocedure(
      'public.__drito_original_registrar_movimiento_stock_7954a1c030(uuid,text,numeric,text,text,uuid)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'permiso_ingreso_existe',
    exists (
      select 1
      from public.permisos_sistema
      where codigo = 'stock.registrar_ingreso'
        and activo = true
    ),

  'permiso_egreso_existe',
    exists (
      select 1
      from public.permisos_sistema
      where codigo = 'stock.registrar_egreso'
        and activo = true
    ),

  'permiso_ajuste_existe',
    exists (
      select 1
      from public.permisos_sistema
      where codigo = 'stock.ajustar'
        and activo = true
    ),

  'authenticated_rpc_publica',
    has_function_privilege(
      'authenticated',
      'public.registrar_movimiento_stock(uuid,text,numeric,text,text,uuid)',
      'EXECUTE'
    ),

  'anon_rpc_publica',
    has_function_privilege(
      'anon',
      'public.registrar_movimiento_stock(uuid,text,numeric,text,text,uuid)',
      'EXECUTE'
    ),

  'authenticated_motor_interno',
    has_function_privilege(
      'authenticated',
      'public.__drito_original_registrar_movimiento_stock_7954a1c030(uuid,text,numeric,text,text,uuid)',
      'EXECUTE'
    ),

  'anon_motor_interno',
    has_function_privilege(
      'anon',
      'public.__drito_original_registrar_movimiento_stock_7954a1c030(uuid,text,numeric,text,text,uuid)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a8;