-- =====================================================
-- DRITO - CIERRE DE FUNCIONES TRIGGER INTERNAS
-- Archivo: 24d_cerrar_funciones_trigger_internas.sql
--
-- Requisitos:
--   24_usuarios_roles_permisos.sql
--   24b_aplicar_permisos_operaciones.sql
--   24c_cerrar_rpc_sin_guardia.sql
--
-- Las funciones de este archivo son utilizadas exclusivamente
-- por triggers internos de PostgreSQL. No son operaciones RPC
-- destinadas al frontend y no requieren una guardia por módulo.
-- =====================================================

begin;

-- =====================================================
-- 1. VERIFICAR QUE SEAN FUNCIONES TRIGGER
-- =====================================================

do $$
declare
  v_nombre text;
  v_retorno text;
begin
  foreach v_nombre in array array[
    'crear_perfil_nuevo_usuario',
    'proteger_usuario_comercio',
    'sincronizar_pago_con_caja_trigger'
  ]
  loop
    select pg_get_function_result(p.oid)
    into v_retorno
    from pg_proc as p
    inner join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = v_nombre
      and p.prokind = 'f'
    limit 1;

    if v_retorno is null then
      raise exception
        'No existe la función public.%()',
        v_nombre;
    end if;

    if lower(v_retorno) <> 'trigger' then
      raise exception
        'La función public.%() devuelve %, no trigger',
        v_nombre,
        v_retorno;
    end if;
  end loop;
end;
$$;

-- =====================================================
-- 2. REVOCAR EJECUCIÓN RPC DIRECTA
-- =====================================================

do $$
declare
  v_funcion record;
begin
  for v_funcion in
    select
      p.proname,
      pg_get_function_identity_arguments(p.oid) as argumentos
    from pg_proc as p
    inner join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (
        array[
          'crear_perfil_nuevo_usuario',
          'proteger_usuario_comercio',
          'sincronizar_pago_con_caja_trigger'
        ]::text[]
      )
      and pg_get_function_result(p.oid) = 'trigger'
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
      'DRITO_FUNCION_TRIGGER_INTERNA_NO_RPC'
    );
  end loop;
end;
$$;

notify pgrst, 'reload schema';

commit;

-- =====================================================
-- 3. VERIFICACIÓN FINAL
-- =====================================================

with triggers_objetivo as (
  select unnest(
    array[
      'crear_perfil_nuevo_usuario',
      'proteger_usuario_comercio',
      'sincronizar_pago_con_caja_trigger'
    ]::text[]
  ) as funcion
),
triggers_expuestos as (
  select
    p.proname,
    pg_get_function_identity_arguments(p.oid) as argumentos
  from pg_proc as p
  inner join pg_namespace as n
    on n.oid = p.pronamespace
  inner join triggers_objetivo as o
    on o.funcion = p.proname
  where n.nspname = 'public'
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    )
),
rpc_expuestas_sin_guardia as (
  select
    p.proname,
    pg_get_function_identity_arguments(p.oid) as argumentos
  from pg_proc as p
  inner join pg_namespace as n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and p.prosecdef = true
    and pg_get_function_result(p.oid) <> 'trigger'
    and p.proname not like '__drito_original_%'
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    )
    and not exists (
      select 1
      from public.rpc_guardias_instaladas as gi
      where gi.funcion_nombre = p.proname
        and gi.argumentos_identidad =
          pg_get_function_identity_arguments(p.oid)
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
  'triggers_internos_expuestos',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'funcion', proname,
            'argumentos', argumentos
          )
          order by proname
        )
        from triggers_expuestos
      ),
      '[]'::jsonb
    ),
  'rpc_operativas_expuestas_sin_guardia',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'funcion', proname,
            'argumentos', argumentos
          )
          order by proname, argumentos
        )
        from rpc_expuestas_sin_guardia
      ),
      '[]'::jsonb
    ),
  'estado',
    case
      when not exists (
        select 1 from triggers_expuestos
      )
      and not exists (
        select 1 from rpc_expuestas_sin_guardia
      )
      then 'permisos_backend_completos'
      else 'requiere_revision'
    end
) as cierre_final_permisos_backend;