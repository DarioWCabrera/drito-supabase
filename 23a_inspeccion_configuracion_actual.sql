-- =====================================================
-- DRITO - INSPECCIÓN PREVIA PARA CONFIGURACIÓN
-- Archivo: 23a_inspeccion_configuracion_actual.sql
--
-- SOLO LECTURA: no crea, altera ni elimina nada.
-- Devuelve una única fila JSON para que Supabase muestre
-- toda la inspección en un solo resultado.
-- =====================================================

select jsonb_pretty(
  jsonb_build_object(
    'columnas', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'tabla', c.table_name,
            'posicion', c.ordinal_position,
            'columna', c.column_name,
            'tipo', c.data_type,
            'udt', c.udt_name,
            'nullable', c.is_nullable,
            'default', c.column_default,
            'longitud', c.character_maximum_length,
            'precision', c.numeric_precision,
            'escala', c.numeric_scale
          )
          order by c.table_name, c.ordinal_position
        )
        from information_schema.columns as c
        where c.table_schema = 'public'
          and c.table_name in (
            'comercios',
            'configuraciones_comercio',
            'usuarios_comercios',
            'perfiles'
          )
      ),
      '[]'::jsonb
    ),

    'restricciones', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'tabla', cl.relname,
            'nombre', con.conname,
            'tipo', con.contype,
            'definicion', pg_get_constraintdef(con.oid, true)
          )
          order by cl.relname, con.conname
        )
        from pg_constraint as con
        inner join pg_class as cl
          on cl.oid = con.conrelid
        inner join pg_namespace as n
          on n.oid = cl.relnamespace
        where n.nspname = 'public'
          and cl.relname in (
            'comercios',
            'configuraciones_comercio',
            'usuarios_comercios',
            'perfiles'
          )
      ),
      '[]'::jsonb
    ),

    'indices', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'tabla', i.tablename,
            'nombre', i.indexname,
            'definicion', i.indexdef
          )
          order by i.tablename, i.indexname
        )
        from pg_indexes as i
        where i.schemaname = 'public'
          and i.tablename in (
            'comercios',
            'configuraciones_comercio',
            'usuarios_comercios',
            'perfiles'
          )
      ),
      '[]'::jsonb
    ),

    'rls', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'tabla', c.relname,
            'habilitado', c.relrowsecurity,
            'forzado', c.relforcerowsecurity
          )
          order by c.relname
        )
        from pg_class as c
        inner join pg_namespace as n
          on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname in (
            'comercios',
            'configuraciones_comercio',
            'usuarios_comercios',
            'perfiles'
          )
      ),
      '[]'::jsonb
    ),

    'politicas_public', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'tabla', p.tablename,
            'nombre', p.policyname,
            'permisiva', p.permissive,
            'roles', to_jsonb(p.roles),
            'operacion', p.cmd,
            'using', p.qual,
            'with_check', p.with_check
          )
          order by p.tablename, p.policyname
        )
        from pg_policies as p
        where p.schemaname = 'public'
          and p.tablename in (
            'comercios',
            'configuraciones_comercio',
            'usuarios_comercios',
            'perfiles'
          )
      ),
      '[]'::jsonb
    ),

    'triggers', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'tabla', t.event_object_table,
            'nombre', t.trigger_name,
            'momento', t.action_timing,
            'evento', t.event_manipulation,
            'accion', t.action_statement
          )
          order by
            t.event_object_table,
            t.trigger_name,
            t.event_manipulation
        )
        from information_schema.triggers as t
        where t.event_object_schema = 'public'
          and t.event_object_table in (
            'comercios',
            'configuraciones_comercio',
            'usuarios_comercios',
            'perfiles'
          )
      ),
      '[]'::jsonb
    ),

    'funciones_relacionadas', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'nombre', p.proname,
            'argumentos', pg_get_function_identity_arguments(p.oid),
            'retorno', pg_get_function_result(p.oid),
            'lenguaje', l.lanname,
            'security_definer', p.prosecdef
          )
          order by p.proname
        )
        from pg_proc as p
        inner join pg_namespace as n
          on n.oid = p.pronamespace
        inner join pg_language as l
          on l.oid = p.prolang
        where n.nspname = 'public'
          and (
            p.proname ilike '%comercio%'
            or p.proname ilike '%config%'
            or p.proname in (
              'pertenece_a_comercio',
              'actualizar_updated_at'
            )
          )
      ),
      '[]'::jsonb
    ),

    'funciones_clave', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'nombre', p.proname,
            'definicion', pg_get_functiondef(p.oid)
          )
          order by p.proname
        )
        from pg_proc as p
        inner join pg_namespace as n
          on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in (
            'pertenece_a_comercio',
            'actualizar_updated_at'
          )
      ),
      '[]'::jsonb
    ),

    'storage_buckets', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', b.id,
            'nombre', b.name,
            'publico', b.public,
            'limite_bytes', b.file_size_limit,
            'tipos_permitidos', to_jsonb(b.allowed_mime_types),
            'created_at', b.created_at,
            'updated_at', b.updated_at
          )
          order by b.name
        )
        from storage.buckets as b
      ),
      '[]'::jsonb
    ),

    'politicas_storage', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'nombre', p.policyname,
            'permisiva', p.permissive,
            'roles', to_jsonb(p.roles),
            'operacion', p.cmd,
            'using', p.qual,
            'with_check', p.with_check
          )
          order by p.policyname
        )
        from pg_policies as p
        where p.schemaname = 'storage'
          and p.tablename = 'objects'
      ),
      '[]'::jsonb
    ),

    'cantidades', jsonb_build_object(
      'comercios', (select count(*) from public.comercios),
      'configuraciones_comercio',
        (select count(*) from public.configuraciones_comercio),
      'usuarios_comercios',
        (select count(*) from public.usuarios_comercios),
      'perfiles', (select count(*) from public.perfiles)
    )
  )
) as inspeccion_configuracion;

-- =====================================================
-- FIN DE LA INSPECCIÓN
-- =====================================================