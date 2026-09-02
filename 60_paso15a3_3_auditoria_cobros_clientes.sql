-- ============================================================
-- DRITO
-- PASO 15A.3.3
-- AUDITORÍA OPERACIONAL - COBROS AGRUPADOS DE CLIENTES
--
-- Integra auditoría en:
-- - registrar_cobro_cuenta_cliente(...)
-- - anular_cobro_cuenta_cliente(...)
--
-- Los PAG internos conservan su propia auditoría.
-- Este bloque registra el evento padre COB-xxxxxx.
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
    'public.__drito_original_registrar_cobro_cuenta_cliente_60401c70d0(uuid,numeric,date,text,text,text)'
  ) is null then
    raise exception
      'Falta el motor original de registrar_cobro_cuenta_cliente';
  end if;


  if to_regprocedure(
    'public.__drito_original_anular_cobro_cuenta_cliente_7e1db32b2a(uuid,text)'
  ) is null then
    raise exception
      'Falta el motor original de anular_cobro_cuenta_cliente';
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
-- 1. REGISTRAR COBRO AGRUPADO + AUDITORÍA
-- ============================================================

create or replace function
public.registrar_cobro_cuenta_cliente(
  p_cliente_id uuid,
  p_importe numeric,
  p_fecha_pago date,
  p_medio_pago text,
  p_referencia text default null,
  p_observaciones text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare

  v_comercio_id uuid;

  v_resultado jsonb;

  v_cobro_id uuid;

  v_comprobante text;

begin

  select c.comercio_id
  into v_comercio_id
  from public.clientes c
  where c.id = p_cliente_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'cuentas_clientes.registrar_cobros'
  );


  v_resultado :=
    public.__drito_original_registrar_cobro_cuenta_cliente_60401c70d0(
      p_cliente_id,
      p_importe,
      p_fecha_pago,
      p_medio_pago,
      p_referencia,
      p_observaciones
    );


  v_cobro_id :=
    nullif(
      v_resultado->>'cobro_id',
      ''
    )::uuid;


  v_comprobante :=
    nullif(
      trim(
        coalesce(
          v_resultado->>'comprobante',
          ''
        )
      ),
      ''
    );


  if v_cobro_id is null then
    raise exception
      'El cobro fue procesado pero no devolvió identificación';
  end if;


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id  => v_comercio_id,
    p_modulo       => 'cuentas_clientes',
    p_accion       => 'cobro_cliente_registrado',
    p_entidad_tipo => 'cobro_cliente',
    p_entidad_id   => v_cobro_id::text,
    p_referencia   => v_comprobante,
    p_detalle      => jsonb_build_object(

      'cliente_id',
        p_cliente_id,

      'nombre_cliente',
        v_resultado->>'nombre_cliente',

      'fecha_cobro',
        p_fecha_pago,

      'medio_pago',
        p_medio_pago,

      'referencia_externa',
        nullif(
          trim(coalesce(p_referencia, '')),
          ''
        ),

      'importe_recibido',
        v_resultado->'importe_recibido',

      'saldo_anterior',
        v_resultado->'saldo_anterior',

      'saldo_final',
        v_resultado->'saldo_final',

      'ventas_afectadas',
        v_resultado->'ventas_afectadas',

      'asignaciones',
        coalesce(
          v_resultado->'asignaciones',
          '[]'::jsonb
        )

    )
  );


  return v_resultado;

end;
$function$;


-- ============================================================
-- 2. ANULAR COBRO AGRUPADO + AUDITORÍA
-- ============================================================

create or replace function
public.anular_cobro_cuenta_cliente(
  p_cobro_id uuid,
  p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare

  v_cobro public.cobros_clientes%rowtype;

  v_comercio_id uuid;

  v_resultado jsonb;

  v_comprobante text;

begin

  select cc.*
  into v_cobro
  from public.cobros_clientes cc
  where cc.id = p_cobro_id;


  if not found then
    raise exception
      'No se pudo determinar el cobro de la operación';
  end if;


  v_comercio_id :=
    v_cobro.comercio_id;


  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'cuentas_clientes.anular_cobros'
  );


  v_resultado :=
    public.__drito_original_anular_cobro_cuenta_cliente_7e1db32b2a(
      p_cobro_id,
      p_motivo
    );


  v_comprobante :=
    coalesce(
      nullif(
        trim(
          coalesce(
            v_resultado->>'comprobante',
            ''
          )
        ),
        ''
      ),

      'COB-' ||
      lpad(
        v_cobro.numero::text,
        6,
        '0'
      )
    );


  perform public.__drito_registrar_auditoria_operacion(
    p_comercio_id  => v_comercio_id,
    p_modulo       => 'cuentas_clientes',
    p_accion       => 'cobro_cliente_anulado',
    p_entidad_tipo => 'cobro_cliente',
    p_entidad_id   => p_cobro_id::text,
    p_referencia   => v_comprobante,
    p_detalle      => jsonb_build_object(

      'cliente_id',
        v_resultado->'cliente_id',

      'motivo',
        nullif(
          trim(coalesce(p_motivo, '')),
          ''
        ),

      'importe_anulado',
        v_resultado->'importe_anulado',

      'pagos_anulados',
        v_resultado->'pagos_anulados',

      'fecha_cobro',
        v_cobro.fecha_cobro,

      'medio_pago',
        v_cobro.medio_pago,

      'referencia_externa',
        v_cobro.referencia,

      'estado',
        v_resultado->>'estado'

    )
  );


  return v_resultado;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.registrar_cobro_cuenta_cliente(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
from public, anon;


grant execute on function
public.registrar_cobro_cuenta_cliente(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
to authenticated;


revoke all on function
public.anular_cobro_cuenta_cliente(
  uuid,
  text
)
from public, anon;


grant execute on function
public.anular_cobro_cuenta_cliente(
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

  'registrar_cobro_existe',
    to_regprocedure(
      'public.registrar_cobro_cuenta_cliente(uuid,numeric,date,text,text,text)'
    ) is not null,

  'anular_cobro_existe',
    to_regprocedure(
      'public.anular_cobro_cuenta_cliente(uuid,text)'
    ) is not null,

  'motor_registro_existe',
    to_regprocedure(
      'public.__drito_original_registrar_cobro_cuenta_cliente_60401c70d0(uuid,numeric,date,text,text,text)'
    ) is not null,

  'motor_anulacion_existe',
    to_regprocedure(
      'public.__drito_original_anular_cobro_cuenta_cliente_7e1db32b2a(uuid,text)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_registrar_cobro',
    has_function_privilege(
      'authenticated',
      'public.registrar_cobro_cuenta_cliente(uuid,numeric,date,text,text,text)',
      'EXECUTE'
    ),

  'authenticated_anular_cobro',
    has_function_privilege(
      'authenticated',
      'public.anular_cobro_cuenta_cliente(uuid,text)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a3_3;