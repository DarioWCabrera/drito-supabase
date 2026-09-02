-- ============================================================
-- DRITO
-- PASO 15A.9
-- HARDENING FINAL DE FUNCIONES
--
-- Objetivos:
--
-- 1. Cerrar acceso anónimo a:
--    guardar_certificado_retencion_practicada(...)
--
-- 2. Mantener acceso authenticated a dicha RPC.
--
-- 3. Revocar ejecución directa de todas las funciones
--    RETURNS trigger del schema public.
--
-- 4. Mantener deliberadamente EXECUTE para anon sobre:
--    - pertenece_a_comercio(uuid)
--    - es_admin_comercio(uuid)
--
--    porque son helpers utilizados por políticas RLS.
--    Con auth.uid() NULL simplemente devuelven false.
-- ============================================================


-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

do $$
begin

  if to_regprocedure(
    'public.guardar_certificado_retencion_practicada(uuid,text,text)'
  ) is null then
    raise exception
      'Falta guardar_certificado_retencion_practicada(uuid,text,text)';
  end if;


  if to_regprocedure(
    'public.pertenece_a_comercio(uuid)'
  ) is null then
    raise exception
      'Falta pertenece_a_comercio(uuid)';
  end if;


  if to_regprocedure(
    'public.es_admin_comercio(uuid)'
  ) is null then
    raise exception
      'Falta es_admin_comercio(uuid)';
  end if;

end;
$$;


-- ============================================================
-- 1. CERRAR ACCESO ANÓNIMO A CERTIFICADOS
-- ============================================================

revoke all on function
public.guardar_certificado_retencion_practicada(
  uuid,
  text,
  text
)
from public, anon;


grant execute on function
public.guardar_certificado_retencion_practicada(
  uuid,
  text,
  text
)
to authenticated;


-- ============================================================
-- 2. HARDENING DE FUNCIONES TRIGGER
--
-- Las funciones RETURNS trigger no necesitan EXECUTE directo
-- por parte de anon/authenticated para funcionar mediante
-- triggers ya instalados.
-- ============================================================

do $$
declare

  v_funcion record;

  v_firma text;

begin

  for v_funcion in

    select
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid)
        as argumentos

    from pg_proc p

    join pg_namespace n
      on n.oid = p.pronamespace

    where n.nspname = 'public'
      and p.prokind = 'f'
      and pg_get_function_result(p.oid) = 'trigger'

  loop

    v_firma :=
      format(
        '%I.%I(%s)',
        v_funcion.nspname,
        v_funcion.proname,
        v_funcion.argumentos
      );


    execute format(
      'revoke all on function %s from public, anon, authenticated',
      v_firma
    );

  end loop;

end;
$$;


-- ============================================================
-- 3. LOS HELPERS DE RLS SE MANTIENEN
--
-- Se otorga explícitamente EXECUTE a anon/authenticated
-- para que el comportamiento no dependa de grants históricos.
-- ============================================================

grant execute on function
public.pertenece_a_comercio(uuid)
to anon, authenticated;


grant execute on function
public.es_admin_comercio(uuid)
to anon, authenticated;


-- ============================================================
-- 4. RECARGA POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 5. VERIFICACIÓN FINAL
-- ============================================================

select jsonb_build_object(

  -- ----------------------------------------------------------
  -- CERTIFICADO
  -- ----------------------------------------------------------

  'anon_guardar_certificado',
    has_function_privilege(
      'anon',
      'public.guardar_certificado_retencion_practicada(uuid,text,text)',
      'EXECUTE'
    ),

  'authenticated_guardar_certificado',
    has_function_privilege(
      'authenticated',
      'public.guardar_certificado_retencion_practicada(uuid,text,text)',
      'EXECUTE'
    ),


  -- ----------------------------------------------------------
  -- HELPERS RLS
  -- ----------------------------------------------------------

  'anon_pertenece_a_comercio',
    has_function_privilege(
      'anon',
      'public.pertenece_a_comercio(uuid)',
      'EXECUTE'
    ),

  'authenticated_pertenece_a_comercio',
    has_function_privilege(
      'authenticated',
      'public.pertenece_a_comercio(uuid)',
      'EXECUTE'
    ),

  'anon_es_admin_comercio',
    has_function_privilege(
      'anon',
      'public.es_admin_comercio(uuid)',
      'EXECUTE'
    ),

  'authenticated_es_admin_comercio',
    has_function_privilege(
      'authenticated',
      'public.es_admin_comercio(uuid)',
      'EXECUTE'
    ),


  -- ----------------------------------------------------------
  -- TRIGGERS CON EXECUTE DIRECTO
  -- ----------------------------------------------------------

  'triggers_ejecutables_anon',
    (
      select count(*)

      from pg_proc p

      join pg_namespace n
        on n.oid = p.pronamespace

      where n.nspname = 'public'
        and p.prokind = 'f'
        and pg_get_function_result(p.oid) = 'trigger'

        and has_function_privilege(
          'anon',
          p.oid,
          'EXECUTE'
        )
    ),

  'triggers_ejecutables_authenticated',
    (
      select count(*)

      from pg_proc p

      join pg_namespace n
        on n.oid = p.pronamespace

      where n.nspname = 'public'
        and p.prokind = 'f'
        and pg_get_function_result(p.oid) = 'trigger'

        and has_function_privilege(
          'authenticated',
          p.oid,
          'EXECUTE'
        )
    ),


  -- ----------------------------------------------------------
  -- FUNCIONES NO-TRIGGER ABIERTAS A ANON
  --
  -- Resultado esperado: 2
  -- pertenece_a_comercio + es_admin_comercio.
  -- ----------------------------------------------------------

  'funciones_no_trigger_anon',
    (
      select count(*)

      from pg_proc p

      join pg_namespace n
        on n.oid = p.pronamespace

      where n.nspname = 'public'
        and p.prokind = 'f'
        and pg_get_function_result(p.oid) <> 'trigger'

        and has_function_privilege(
          'anon',
          p.oid,
          'EXECUTE'
        )
    )

) as verificacion_15a9;