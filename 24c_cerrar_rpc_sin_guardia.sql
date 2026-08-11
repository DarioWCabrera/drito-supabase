-- =====================================================
-- DRITO - CIERRE DE RPC SIN GUARDIA
-- Archivo: 24c_cerrar_rpc_sin_guardia.sql
--
-- Requisitos previos:
--   24_usuarios_roles_permisos.sql
--   24b_aplicar_permisos_operaciones.sql
--
-- Corrige las seis funciones detectadas por la verificación:
--
-- FUNCIONES OPERATIVAS:
--   - anular_cobro_cuenta_cliente
--   - crear_compra
--   - crear_venta_directa
--
-- FUNCIONES INTERNAS:
--   - crear_categorias_caja_predeterminadas
--   - obtener_o_crear_categoria_caja_sistema
--   - sincronizar_pago_caja_desde_json
-- =====================================================

begin;

-- =====================================================
-- 1. VALIDACIONES
-- =====================================================

do $$
begin
  if to_regprocedure(
    'public.instalar_guardia_rpc_drito(text)'
  ) is null then
    raise exception
      'Primero debés ejecutar 24b_aplicar_permisos_operaciones.sql';
  end if;

  if to_regclass(
    'public.rpc_permisos_drito'
  ) is null then
    raise exception
      'No existe la tabla rpc_permisos_drito';
  end if;
end;
$$;

-- =====================================================
-- 2. AGREGAR LAS OPERACIONES FALTANTES
-- =====================================================

insert into public.rpc_permisos_drito (
  funcion_nombre,
  permiso_codigo,
  resolver_tipo,
  argumentos_referencia,
  tablas_referencia,
  columna_id,
  columna_comercio,
  obligatorio,
  descripcion,
  activo
)
values
  (
    'anular_cobro_cuenta_cliente',
    'cuentas_clientes.anular_cobros',
    'entidad',
    array[
      'p_cobro_id',
      'p_pago_id'
    ],
    array[
      'cobros_clientes',
      'cobros_cuenta_cliente',
      'cobros_cuenta_corriente_clientes',
      'pagos_clientes'
    ],
    'id',
    'comercio_id',
    true,
    'Anulación de cobro agrupado de cliente',
    true
  ),
  (
    'crear_compra',
    'compras.crear',
    'argumento_comercio',
    array[
      'p_comercio_id'
    ],
    null,
    'id',
    'comercio_id',
    true,
    'Creación transaccional de compra',
    true
  ),
  (
    'crear_venta_directa',
    'ventas.crear',
    'argumento_comercio',
    array[
      'p_comercio_id'
    ],
    null,
    'id',
    'comercio_id',
    true,
    'Creación transaccional de venta directa',
    true
  )
on conflict (funcion_nombre) do update
set
  permiso_codigo =
    excluded.permiso_codigo,
  resolver_tipo =
    excluded.resolver_tipo,
  argumentos_referencia =
    excluded.argumentos_referencia,
  tablas_referencia =
    excluded.tablas_referencia,
  columna_id =
    excluded.columna_id,
  columna_comercio =
    excluded.columna_comercio,
  obligatorio =
    excluded.obligatorio,
  descripcion =
    excluded.descripcion,
  activo = true,
  updated_at = now();

-- =====================================================
-- 3. INSTALAR LAS TRES GUARDIAS
-- =====================================================

do $$
declare
  v_funcion text;
  v_resultado jsonb;
begin
  foreach v_funcion in array array[
    'anular_cobro_cuenta_cliente',
    'crear_compra',
    'crear_venta_directa'
  ]
  loop
    if not exists (
      select 1
      from pg_proc as p
      inner join pg_namespace as n
        on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_funcion
        and p.prokind = 'f'
    ) then
      raise exception
        'No existe la función operativa public.%',
        v_funcion;
    end if;

    v_resultado :=
      public.instalar_guardia_rpc_drito(
        v_funcion
      );

    if coalesce(
      (v_resultado->>'instaladas')::integer,
      0
    ) = 0
    and not exists (
      select 1
      from public.rpc_guardias_instaladas as gi
      where gi.funcion_nombre =
        v_funcion
    ) then
      raise exception
        'No se pudo instalar la guardia para %. Resultado: %',
        v_funcion,
        v_resultado;
    end if;
  end loop;
end;
$$;

-- =====================================================
-- 4. OCULTAR FUNCIONES AUXILIARES
-- =====================================================

do $$
declare
  v_funcion record;
begin
  for v_funcion in
    select
      p.proname,
      pg_get_function_identity_arguments(
        p.oid
      ) as argumentos
    from pg_proc as p
    inner join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (
        array[
          'crear_categorias_caja_predeterminadas',
          'obtener_o_crear_categoria_caja_sistema',
          'sincronizar_pago_caja_desde_json'
        ]::text[]
      )
  loop
    execute format(
      'revoke all on function public.%I(%s)
       from public, anon, authenticated',
      v_funcion.proname,
      v_funcion.argumentos
    );

    execute format(
      'comment on function public.%I(%s)
       is %L',
      v_funcion.proname,
      v_funcion.argumentos,
      'DRITO_FUNCION_INTERNA_NO_RPC'
    );
  end loop;
end;
$$;

-- Actualiza la caché de funciones de PostgREST.
notify pgrst, 'reload schema';

commit;

-- =====================================================
-- 5. VERIFICACIÓN
-- =====================================================

with objetivo as (
  select unnest(
    array[
      'anular_cobro_cuenta_cliente',
      'crear_compra',
      'crear_venta_directa'
    ]::text[]
  ) as funcion
),
internas as (
  select unnest(
    array[
      'crear_categorias_caja_predeterminadas',
      'obtener_o_crear_categoria_caja_sistema',
      'sincronizar_pago_caja_desde_json'
    ]::text[]
  ) as funcion
),
operativas_sin_guardia as (
  select o.funcion
  from objetivo as o
  where not exists (
    select 1
    from public.rpc_guardias_instaladas as gi
    where gi.funcion_nombre =
      o.funcion
  )
),
internas_expuestas as (
  select
    p.proname as funcion,
    pg_get_function_identity_arguments(
      p.oid
    ) as argumentos
  from pg_proc as p
  inner join pg_namespace as n
    on n.oid = p.pronamespace
  inner join internas as i
    on i.funcion = p.proname
  where n.nspname = 'public'
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    )
),
todas_expuestas_sin_guardia as (
  select
    p.proname,
    pg_get_function_identity_arguments(
      p.oid
    ) as argumentos
  from pg_proc as p
  inner join pg_namespace as n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and p.prosecdef = true
    and p.proname not like
      '__drito_original_%'
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    )
    and not exists (
      select 1
      from public.rpc_guardias_instaladas as gi
      where gi.funcion_nombre =
        p.proname
        and gi.argumentos_identidad =
          pg_get_function_identity_arguments(
            p.oid
          )
    )
    and p.proname <> all (
      array[
        'aceptar_invitacion_comercio',
        'cambiar_estado_usuario_comercio',
        'cambiar_rol_usuario_comercio',
        'crear_invitacion_comercio',
        'es_admin_comercio',
        'exigir_permiso_comercio',
        'guardar_permisos_usuario',
        'obtener_mis_permisos',
        'obtener_usuarios_comercio',
        'pertenece_a_comercio',
        'registrar_acceso_comercio',
        'restablecer_permisos_usuario',
        'revocar_invitacion_comercio',
        'tiene_permiso_comercio',
        'usuario_tiene_permiso_comercio'
      ]::text[]
    )
)
select jsonb_build_object(
  'guardias_totales',
    (
      select count(*)
      from public.rpc_guardias_instaladas
    ),

  'nuevas_guardias',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'funcion',
              gi.funcion_nombre,
            'permiso',
              gi.permiso_codigo,
            'argumentos',
              gi.argumentos_identidad
          )
          order by gi.funcion_nombre
        )
        from public.rpc_guardias_instaladas as gi
        where gi.funcion_nombre = any (
          array[
            'anular_cobro_cuenta_cliente',
            'crear_compra',
            'crear_venta_directa'
          ]::text[]
        )
      ),
      '[]'::jsonb
    ),

  'operativas_sin_guardia',
    coalesce(
      (
        select jsonb_agg(
          funcion
          order by funcion
        )
        from operativas_sin_guardia
      ),
      '[]'::jsonb
    ),

  'internas_expuestas',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'funcion', funcion,
            'argumentos', argumentos
          )
          order by funcion, argumentos
        )
        from internas_expuestas
      ),
      '[]'::jsonb
    ),

  'rpc_expuestas_sin_guardia',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'funcion', proname,
            'argumentos', argumentos
          )
          order by proname, argumentos
        )
        from todas_expuestas_sin_guardia
      ),
      '[]'::jsonb
    )
) as cierre_rpc_permisos;