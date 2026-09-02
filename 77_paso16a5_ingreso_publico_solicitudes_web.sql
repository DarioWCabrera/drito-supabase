-- ============================================================
-- DRITO
-- PASO 16A.5
-- PUERTA DE ENTRADA PÚBLICA PARA SOLICITUDES WEB
--
-- OBJETIVOS:
-- - preparar RPC pública SOL;
-- - resolver comercio mediante canal_publico;
-- - mantener el motor interno cerrado;
-- - permitir activación explícita solo a usuarios autorizados;
-- - permitir regenerar el identificador del canal;
-- - mantener TODOS los comercios apagados por defecto;
-- - no modificar ninguna web externa.
--
-- IMPORTANTE:
-- Esta migración NO habilita ningún canal.
-- ============================================================


-- ============================================================
-- 1. RPC INTERNA AUTENTICADA PARA HABILITAR EL CANAL
-- ============================================================

create or replace function
public.habilitar_solicitudes_web(
  p_comercio_id uuid
)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_usuario uuid;

  v_config
    public.configuraciones_solicitudes_web%rowtype;

begin

  v_usuario := auth.uid();


  if v_usuario is null then

    raise exception
      'Usuario no autenticado';

  end if;


  perform public.exigir_permiso_comercio(

    p_comercio_id,

    'solicitudes_web.configurar'

  );


  select csw.*
  into v_config

  from public.configuraciones_solicitudes_web csw

  where csw.comercio_id = p_comercio_id

  for update;


  if not found then

    raise exception
      'No existe configuración de solicitudes web para el comercio';

  end if;


  if v_config.habilitado = true then

    return jsonb_build_object(

      'comercio_id',
        p_comercio_id,

      'habilitado',
        true,

      'canal_publico',
        v_config.canal_publico,

      'sin_cambios',
        true

    );

  end if;


  update public.configuraciones_solicitudes_web

  set
    habilitado = true,

    habilitado_at = now(),

    habilitado_por = v_usuario

  where comercio_id = p_comercio_id;


  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id,

    'solicitudes_web',

    'solicitudes_web_habilitadas',

    'configuracion_solicitudes_web',

    p_comercio_id::text,

    null,

    jsonb_build_object(
      'habilitado',
      true
    ),

    v_usuario

  );


  return jsonb_build_object(

    'comercio_id',
      p_comercio_id,

    'habilitado',
      true,

    'canal_publico',
      v_config.canal_publico,

    'sin_cambios',
      false

  );

end;

$$;


revoke all on function
public.habilitar_solicitudes_web(uuid)
from public, anon;


grant execute on function
public.habilitar_solicitudes_web(uuid)
to authenticated;



-- ============================================================
-- 2. REGENERAR IDENTIFICADOR DEL CANAL
--
-- Solo se permite con el canal APAGADO.
--
-- canal_publico NO es una contraseña.
-- Es un identificador público de integración.
--
-- Regenerarlo sirve para retirar una integración anterior
-- antes de publicar otra.
-- ============================================================

create or replace function
public.regenerar_canal_solicitudes_web(
  p_comercio_id uuid
)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_usuario uuid;

  v_config
    public.configuraciones_solicitudes_web%rowtype;

  v_nuevo_canal uuid;

begin

  v_usuario := auth.uid();


  if v_usuario is null then

    raise exception
      'Usuario no autenticado';

  end if;


  perform public.exigir_permiso_comercio(

    p_comercio_id,

    'solicitudes_web.configurar'

  );


  select csw.*
  into v_config

  from public.configuraciones_solicitudes_web csw

  where csw.comercio_id = p_comercio_id

  for update;


  if not found then

    raise exception
      'No existe configuración de solicitudes web para el comercio';

  end if;


  if v_config.habilitado = true then

    raise exception
      'Deshabilitá el canal antes de regenerarlo';

  end if;


  v_nuevo_canal :=
    gen_random_uuid();


  update public.configuraciones_solicitudes_web

  set
    canal_publico = v_nuevo_canal

  where comercio_id = p_comercio_id;


  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id,

    'solicitudes_web',

    'canal_solicitudes_web_regenerado',

    'configuracion_solicitudes_web',

    p_comercio_id::text,

    null,

    jsonb_build_object(
      'canal_regenerado',
      true
    ),

    v_usuario

  );


  return jsonb_build_object(

    'comercio_id',
      p_comercio_id,

    'habilitado',
      false,

    'canal_publico',
      v_nuevo_canal

  );

end;

$$;


revoke all on function
public.regenerar_canal_solicitudes_web(uuid)
from public, anon;


grant execute on function
public.regenerar_canal_solicitudes_web(uuid)
to authenticated;



-- ============================================================
-- 3. PUERTA PÚBLICA DE INGRESO
--
-- IMPORTANTE:
-- - esta RPC SÍ puede ser ejecutada por anon;
-- - NO recibe comercio_id;
-- - resuelve el comercio mediante canal_publico;
-- - el canal debe estar habilitado;
-- - delega toda creación al motor interno ya probado;
-- - no concede acceso directo a tablas;
-- - no concede acceso al motor interno.
-- ============================================================

create or replace function
public.crear_solicitud_web_publica(

  p_canal_publico uuid,

  p_clave_idempotencia uuid,

  p_origen text,

  p_nombre_contacto text,

  p_empresa text default null,

  p_telefono text default null,

  p_email text default null,

  p_cuit_cuil text default null,

  p_mensaje text default null,

  p_origen_url text default null,

  p_items jsonb default '[]'::jsonb

)
returns table (

  solicitud_id uuid,

  numero bigint,

  referencia text,

  reutilizada boolean

)

language plpgsql
security definer
set search_path = public

as $$

declare

  v_comercio_id uuid;

  v_origen text;

  v_items_cantidad integer;

begin

  -- ----------------------------------------------------------
  -- Canal
  -- ----------------------------------------------------------

  if p_canal_publico is null then

    raise exception
      'Canal de solicitudes inválido';

  end if;


  select csw.comercio_id
  into v_comercio_id

  from public.configuraciones_solicitudes_web csw

  where csw.canal_publico = p_canal_publico
    and csw.habilitado = true;


  if not found then

    raise exception
      'Canal de solicitudes no disponible';

  end if;


  -- ----------------------------------------------------------
  -- Origen público permitido
  --
  -- Desde Internet no permitimos identificarse como
  -- api ni manual.
  -- ----------------------------------------------------------

  v_origen :=
    lower(
      trim(
        coalesce(
          p_origen,
          'web'
        )
      )
    );


  if v_origen not in (
    'web',
    'catalogo'
  ) then

    raise exception
      'Origen público inválido';

  end if;


  -- ----------------------------------------------------------
  -- Límites básicos de payload
  -- ----------------------------------------------------------

  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
  then

    raise exception
      'Los ítems deben enviarse como un arreglo';

  end if;


  v_items_cantidad :=
    jsonb_array_length(p_items);


  if v_items_cantidad < 1 then

    raise exception
      'La solicitud debe contener al menos un ítem';

  end if;


  if v_items_cantidad > 50 then

    raise exception
      'La solicitud supera el máximo de 50 ítems';

  end if;


  if length(
    coalesce(
      p_nombre_contacto,
      ''
    )
  ) > 200 then

    raise exception
      'El nombre de contacto es demasiado largo';

  end if;


  if length(
    coalesce(
      p_empresa,
      ''
    )
  ) > 200 then

    raise exception
      'El nombre de empresa es demasiado largo';

  end if;


  if length(
    coalesce(
      p_telefono,
      ''
    )
  ) > 80 then

    raise exception
      'El teléfono es demasiado largo';

  end if;


  if length(
    coalesce(
      p_email,
      ''
    )
  ) > 254 then

    raise exception
      'El email es demasiado largo';

  end if;


  if length(
    coalesce(
      p_cuit_cuil,
      ''
    )
  ) > 30 then

    raise exception
      'El CUIT/CUIL es demasiado largo';

  end if;


  if length(
    coalesce(
      p_mensaje,
      ''
    )
  ) > 4000 then

    raise exception
      'El mensaje es demasiado largo';

  end if;


  if length(
    coalesce(
      p_origen_url,
      ''
    )
  ) > 2000 then

    raise exception
      'La URL de origen es demasiado larga';

  end if;


  -- ----------------------------------------------------------
  -- Motor interno
  -- ----------------------------------------------------------

  return query

  select
    r.solicitud_id,
    r.numero,
    r.referencia,
    r.reutilizada

  from public.__drito_crear_solicitud_web(

    v_comercio_id,

    p_clave_idempotencia,

    v_origen,

    p_nombre_contacto,

    p_empresa,

    p_telefono,

    p_email,

    p_cuit_cuil,

    p_mensaje,

    p_origen_url,

    p_items

  ) r;

end;

$$;



-- ============================================================
-- 4. SEGURIDAD PUERTA PÚBLICA
-- ============================================================

revoke all on function
public.crear_solicitud_web_publica(
  uuid,
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  jsonb
)
from public;


grant execute on function
public.crear_solicitud_web_publica(
  uuid,
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  jsonb
)
to anon, authenticated;



-- ============================================================
-- 5. ASEGURAR QUE EL MOTOR INTERNO SIGUE CERRADO
-- ============================================================

revoke all on function
public.__drito_crear_solicitud_web(
  uuid,
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  jsonb
)
from public, anon, authenticated;



-- ============================================================
-- 6. ASEGURAR ESTADO ACTUAL APAGADO
--
-- No se habilita ningún comercio durante la migración.
-- ============================================================

update public.configuraciones_solicitudes_web

set
  habilitado = false,
  habilitado_at = null,
  habilitado_por = null

where habilitado = true;



-- ============================================================
-- 7. POSTGREST
-- ============================================================

notify pgrst, 'reload schema';



-- ============================================================
-- 8. VERIFICACIÓN
-- ============================================================

select jsonb_build_object(

  'rpc_publica_existe',
    to_regprocedure(
      'public.crear_solicitud_web_publica(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)'
    ) is not null,

  'anon_rpc_publica',
    has_function_privilege(
      'anon',
      'public.crear_solicitud_web_publica(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),

  'authenticated_rpc_publica',
    has_function_privilege(
      'authenticated',
      'public.crear_solicitud_web_publica(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),

  'motor_interno_anon_cerrado',
    not has_function_privilege(
      'anon',
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),

  'motor_interno_authenticated_cerrado',
    not has_function_privilege(
      'authenticated',
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),

  'rpc_habilitar_existe',
    to_regprocedure(
      'public.habilitar_solicitudes_web(uuid)'
    ) is not null,

  'anon_rpc_habilitar',
    has_function_privilege(
      'anon',
      'public.habilitar_solicitudes_web(uuid)',
      'EXECUTE'
    ),

  'authenticated_rpc_habilitar',
    has_function_privilege(
      'authenticated',
      'public.habilitar_solicitudes_web(uuid)',
      'EXECUTE'
    ),

  'rpc_regenerar_canal_existe',
    to_regprocedure(
      'public.regenerar_canal_solicitudes_web(uuid)'
    ) is not null,

  'anon_rpc_regenerar_canal',
    has_function_privilege(
      'anon',
      'public.regenerar_canal_solicitudes_web(uuid)',
      'EXECUTE'
    ),

  'authenticated_rpc_regenerar_canal',
    has_function_privilege(
      'authenticated',
      'public.regenerar_canal_solicitudes_web(uuid)',
      'EXECUTE'
    ),

  'canales_habilitados',
    (
      select count(*)
      from public.configuraciones_solicitudes_web
      where habilitado = true
    ),

  'solicitudes_actuales',
    (
      select count(*)
      from public.solicitudes_web
    )

) as verificacion_16a5;