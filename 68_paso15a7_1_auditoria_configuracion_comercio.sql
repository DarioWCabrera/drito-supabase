-- ============================================================
-- DRITO
-- PASO 15A.7.1
-- AUDITORÍA OPERACIONAL - CONFIGURACIÓN DEL COMERCIO
--
-- Audita:
-- - actualización de datos generales del comercio;
-- - actualización de configuración fiscal del comercio.
--
-- No modifica los motores existentes.
-- No guarda credenciales ni secretos de ARCA.
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
    'public.__drito_original_guardar_datos_comercio_feb57ac078(uuid,jsonb)'
  ) is null then
    raise exception
      'Falta el motor original de guardar_datos_comercio';
  end if;


  if to_regprocedure(
    'public.__drito_original_guardar_configuracion_fiscal_comerc_feb57ac078(uuid,jsonb)'
  ) is null then
    raise exception
      'Falta el motor original de guardar_configuracion_fiscal_comercio';
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
-- 1. DATOS GENERALES DEL COMERCIO + AUDITORÍA
-- ============================================================

create or replace function
public.guardar_datos_comercio(
  p_comercio_id uuid,
  p_datos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_anterior public.comercios%rowtype;

  v_nuevo public.comercios%rowtype;

  v_resultado jsonb;

  v_campos jsonb;

begin

  -- ==========================================================
  -- PERMISO
  -- ==========================================================

  if p_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'configuracion.editar_general'
  );


  -- ==========================================================
  -- SNAPSHOT ANTERIOR
  -- ==========================================================

  select c.*
  into v_anterior
  from public.comercios c
  where c.id = p_comercio_id;


  if not found then
    raise exception
      'Comercio no encontrado';
  end if;


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  v_resultado :=
    public.__drito_original_guardar_datos_comercio_feb57ac078(
      p_comercio_id,
      p_datos
    );


  -- ==========================================================
  -- SNAPSHOT NUEVO
  -- ==========================================================

  select c.*
  into v_nuevo
  from public.comercios c
  where c.id = p_comercio_id;


  select coalesce(
    jsonb_agg(k order by k),
    '[]'::jsonb
  )
  into v_campos
  from jsonb_object_keys(
    coalesce(
      p_datos,
      '{}'::jsonb
    )
  ) as claves(k);


  -- ==========================================================
  -- AUDITORÍA
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      p_comercio_id,

    p_modulo =>
      'configuracion',

    p_accion =>
      'datos_comercio_actualizados',

    p_entidad_tipo =>
      'comercio',

    p_entidad_id =>
      p_comercio_id::text,

    p_referencia =>
      v_nuevo.nombre_comercial,

    p_detalle =>
      jsonb_build_object(

        'campos_solicitados',
          v_campos,

        'nombre_comercial_anterior',
          v_anterior.nombre_comercial,

        'nombre_comercial_nuevo',
          v_nuevo.nombre_comercial,

        'razon_social_anterior',
          v_anterior.razon_social,

        'razon_social_nueva',
          v_nuevo.razon_social,

        'cuit_anterior',
          v_anterior.cuit,

        'cuit_nuevo',
          v_nuevo.cuit,

        'email_anterior',
          v_anterior.email,

        'email_nuevo',
          v_nuevo.email,

        'telefono_anterior',
          v_anterior.telefono,

        'telefono_nuevo',
          v_nuevo.telefono,

        'direccion_anterior',
          v_anterior.direccion,

        'direccion_nueva',
          v_nuevo.direccion,

        'localidad_anterior',
          v_anterior.localidad,

        'localidad_nueva',
          v_nuevo.localidad,

        'provincia_anterior',
          v_anterior.provincia,

        'provincia_nueva',
          v_nuevo.provincia,

        'codigo_postal_anterior',
          v_anterior.codigo_postal,

        'codigo_postal_nuevo',
          v_nuevo.codigo_postal,

        'pais_anterior',
          v_anterior.pais,

        'pais_nuevo',
          v_nuevo.pais,

        'sitio_web_anterior',
          v_anterior.sitio_web,

        'sitio_web_nuevo',
          v_nuevo.sitio_web

      )

  );


  return v_resultado;

end;
$function$;


-- ============================================================
-- 2. CONFIGURACIÓN FISCAL DEL COMERCIO + AUDITORÍA
-- ============================================================

create or replace function
public.guardar_configuracion_fiscal_comercio(
  p_comercio_id uuid,
  p_datos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_anterior jsonb;

  v_nuevo jsonb;

  v_resultado jsonb;

  v_campos jsonb;

  v_referencia text;

begin

  -- ==========================================================
  -- PERMISO
  -- ==========================================================

  if p_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;


  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'configuracion.editar_fiscal'
  );


  -- ==========================================================
  -- SNAPSHOT ANTERIOR
  -- ==========================================================

  select to_jsonb(fis)
  into v_anterior
  from public.configuraciones_fiscales_comercio fis
  where fis.comercio_id = p_comercio_id;


  v_anterior :=
    coalesce(
      v_anterior,
      '{}'::jsonb
    );


  -- ==========================================================
  -- MOTOR ORIGINAL
  -- ==========================================================

  v_resultado :=
    public.__drito_original_guardar_configuracion_fiscal_comerc_feb57ac078(
      p_comercio_id,
      p_datos
    );


  -- ==========================================================
  -- SNAPSHOT NUEVO
  -- ==========================================================

  select to_jsonb(fis)
  into v_nuevo
  from public.configuraciones_fiscales_comercio fis
  where fis.comercio_id = p_comercio_id;


  v_nuevo :=
    coalesce(
      v_nuevo,
      '{}'::jsonb
    );


  select coalesce(
    jsonb_agg(k order by k),
    '[]'::jsonb
  )
  into v_campos
  from jsonb_object_keys(
    coalesce(
      p_datos,
      '{}'::jsonb
    )
  ) as claves(k);


  v_referencia :=
    case
      when nullif(
        trim(
          coalesce(
            v_nuevo ->> 'punto_venta',
            ''
          )
        ),
        ''
      ) is not null
      then
        'PV-' ||
        lpad(
          v_nuevo ->> 'punto_venta',
          5,
          '0'
        )
      else
        'Configuración fiscal'
    end;


  -- ==========================================================
  -- AUDITORÍA
  -- ==========================================================

  perform public.__drito_registrar_auditoria_operacion(

    p_comercio_id =>
      p_comercio_id,

    p_modulo =>
      'configuracion',

    p_accion =>
      'configuracion_fiscal_actualizada',

    p_entidad_tipo =>
      'configuracion_fiscal_comercio',

    p_entidad_id =>
      p_comercio_id::text,

    p_referencia =>
      v_referencia,

    p_detalle =>
      jsonb_build_object(

        'campos_solicitados',
          v_campos,

        'condicion_iva_anterior',
          v_anterior -> 'condicion_iva',

        'condicion_iva_nueva',
          v_nuevo -> 'condicion_iva',

        'ingresos_brutos_anterior',
          v_anterior -> 'ingresos_brutos',

        'ingresos_brutos_nuevo',
          v_nuevo -> 'ingresos_brutos',

        'inicio_actividades_anterior',
          v_anterior -> 'inicio_actividades',

        'inicio_actividades_nuevo',
          v_nuevo -> 'inicio_actividades',

        'domicilio_fiscal_anterior',
          v_anterior -> 'domicilio_fiscal',

        'domicilio_fiscal_nuevo',
          v_nuevo -> 'domicilio_fiscal',

        'localidad_fiscal_anterior',
          v_anterior -> 'localidad_fiscal',

        'localidad_fiscal_nueva',
          v_nuevo -> 'localidad_fiscal',

        'provincia_fiscal_anterior',
          v_anterior -> 'provincia_fiscal',

        'provincia_fiscal_nueva',
          v_nuevo -> 'provincia_fiscal',

        'codigo_postal_fiscal_anterior',
          v_anterior -> 'codigo_postal_fiscal',

        'codigo_postal_fiscal_nuevo',
          v_nuevo -> 'codigo_postal_fiscal',

        'concepto_facturacion_anterior',
          v_anterior -> 'concepto_facturacion',

        'concepto_facturacion_nuevo',
          v_nuevo -> 'concepto_facturacion',

        'punto_venta_anterior',
          v_anterior -> 'punto_venta',

        'punto_venta_nuevo',
          v_nuevo -> 'punto_venta',

        'ambiente_arca_anterior',
          v_anterior -> 'ambiente_arca',

        'ambiente_arca_nuevo',
          v_nuevo -> 'ambiente_arca',

        'tipos_comprobante_anterior',
          v_anterior -> 'tipos_comprobante_habilitados',

        'tipos_comprobante_nuevo',
          v_nuevo -> 'tipos_comprobante_habilitados',

        'leyenda_factura_anterior',
          v_anterior -> 'leyenda_factura',

        'leyenda_factura_nueva',
          v_nuevo -> 'leyenda_factura',

        'estado_arca_anterior',
          v_anterior -> 'estado_arca',

        'estado_arca_nuevo',
          v_nuevo -> 'estado_arca'

      )

  );


  return v_resultado;

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all on function
public.guardar_datos_comercio(
  uuid,
  jsonb
)
from public, anon;


grant execute on function
public.guardar_datos_comercio(
  uuid,
  jsonb
)
to authenticated;


revoke all on function
public.guardar_configuracion_fiscal_comercio(
  uuid,
  jsonb
)
from public, anon;


grant execute on function
public.guardar_configuracion_fiscal_comercio(
  uuid,
  jsonb
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

  'guardar_datos_comercio_existe',
    to_regprocedure(
      'public.guardar_datos_comercio(uuid,jsonb)'
    ) is not null,

  'guardar_configuracion_fiscal_existe',
    to_regprocedure(
      'public.guardar_configuracion_fiscal_comercio(uuid,jsonb)'
    ) is not null,

  'motor_datos_comercio_existe',
    to_regprocedure(
      'public.__drito_original_guardar_datos_comercio_feb57ac078(uuid,jsonb)'
    ) is not null,

  'motor_configuracion_fiscal_existe',
    to_regprocedure(
      'public.__drito_original_guardar_configuracion_fiscal_comerc_feb57ac078(uuid,jsonb)'
    ) is not null,

  'helper_auditoria_existe',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'authenticated_datos_comercio',
    has_function_privilege(
      'authenticated',
      'public.guardar_datos_comercio(uuid,jsonb)',
      'EXECUTE'
    ),

  'authenticated_configuracion_fiscal',
    has_function_privilege(
      'authenticated',
      'public.guardar_configuracion_fiscal_comercio(uuid,jsonb)',
      'EXECUTE'
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a7_1;