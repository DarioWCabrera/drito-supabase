-- ============================================================
-- DRITO
-- PASO 16A.6
-- CONSULTA SEGURA DE CONFIGURACIÓN DE SOLICITUDES WEB
--
-- Objetivo:
-- - exponer a usuarios autorizados el estado del canal;
-- - mostrar canal_publico dentro de Configuración;
-- - no conceder lectura pública;
-- - no habilitar ningún comercio;
-- - mantener la integración externa totalmente apagada.
-- ============================================================


-- ============================================================
-- 1. RPC DE CONSULTA
-- ============================================================

create or replace function
public.obtener_configuracion_solicitudes_web(
  p_comercio_id uuid
)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_config
    public.configuraciones_solicitudes_web%rowtype;

begin

  if auth.uid() is null then

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

  where csw.comercio_id =
    p_comercio_id;


  if not found then

    raise exception
      'No existe configuración de solicitudes web para el comercio';

  end if;


  return jsonb_build_object(

    'comercio_id',
      v_config.comercio_id,

    'canal_publico',
      v_config.canal_publico,

    'habilitado',
      v_config.habilitado,

    'habilitado_at',
      v_config.habilitado_at,

    'habilitado_por',
      v_config.habilitado_por,

    'created_at',
      v_config.created_at,

    'updated_at',
      v_config.updated_at,

    'estado',
      case

        when v_config.habilitado
          then 'habilitado'

        else 'deshabilitado'

      end

  );

end;

$$;



-- ============================================================
-- 2. SEGURIDAD
-- ============================================================

revoke all on function
public.obtener_configuracion_solicitudes_web(uuid)
from public, anon;


grant execute on function
public.obtener_configuracion_solicitudes_web(uuid)
to authenticated;



-- ============================================================
-- 3. ASEGURAR QUE EL CANAL SIGUE APAGADO
-- ============================================================

update public.configuraciones_solicitudes_web

set
  habilitado = false,
  habilitado_at = null,
  habilitado_por = null

where habilitado = true;



-- ============================================================
-- 4. POSTGREST
-- ============================================================

notify pgrst, 'reload schema';



-- ============================================================
-- 5. VERIFICACIÓN
-- ============================================================

select jsonb_build_object(

  'rpc_consulta_existe',
    to_regprocedure(
      'public.obtener_configuracion_solicitudes_web(uuid)'
    ) is not null,

  'anon_rpc_consulta',
    has_function_privilege(
      'anon',
      'public.obtener_configuracion_solicitudes_web(uuid)',
      'EXECUTE'
    ),

  'authenticated_rpc_consulta',
    has_function_privilege(
      'authenticated',
      'public.obtener_configuracion_solicitudes_web(uuid)',
      'EXECUTE'
    ),

  'anon_rpc_publica',
    has_function_privilege(
      'anon',
      'public.crear_solicitud_web_publica(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),

  'motor_interno_anon_cerrado',
    not has_function_privilege(
      'anon',
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
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

) as verificacion_16a6_consulta;