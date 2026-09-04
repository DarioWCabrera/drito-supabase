begin;

-- =====================================================
-- 1. DEVOLVER COLOR DE TEXTO DEL SIDEBAR
-- =====================================================

create or replace function
public.obtener_configuracion_comercio(
  p_comercio_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_resultado jsonb;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_comercio_id is null then
    raise exception 'El comercio es obligatorio';
  end if;

  if not public.pertenece_a_comercio(
    p_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio indicado';
  end if;

  select jsonb_build_object(
    'comercio',
      jsonb_build_object(
        'id', c.id,
        'nombre_comercial', c.nombre_comercial,
        'razon_social', c.razon_social,
        'cuit', c.cuit,
        'email', c.email,
        'telefono', c.telefono,
        'direccion', c.direccion,
        'localidad', c.localidad,
        'provincia', c.provincia,
        'codigo_postal', c.codigo_postal,
        'pais', c.pais,
        'sitio_web', c.sitio_web,
        'slug', c.slug,
        'activo', c.activo,
        'modo_facturacion', c.modo_facturacion
      ),

    'apariencia',
      jsonb_build_object(
        'logo_url', cfg.logo_url,
        'color_primario', cfg.color_primario,
        'color_secundario', cfg.color_secundario,
        'color_acento', cfg.color_acento,
        'color_texto_sidebar', cfg.color_texto_sidebar
      ),

    'preferencias',
      jsonb_build_object(
        'moneda', cfg.moneda,
        'zona_horaria', cfg.zona_horaria,
        'idioma', cfg.idioma,
        'cotizacion_validez_dias',
          cfg.cotizacion_validez_dias,
        'decimales_cantidad',
          cfg.decimales_cantidad,
        'alerta_stock_bajo',
          cfg.alerta_stock_bajo,
        'permitir_stock_negativo',
          cfg.permitir_stock_negativo,
        'controla_stock_por_defecto',
          cfg.controla_stock_por_defecto,
        'formato_fecha',
          cfg.formato_fecha,
        'mostrar_logo_comprobantes',
          cfg.mostrar_logo_comprobantes,
        'mostrar_datos_comercio_comprobantes',
          cfg.mostrar_datos_comercio_comprobantes,
        'texto_cotizacion',
          cfg.texto_cotizacion,
        'texto_comprobante',
          cfg.texto_comprobante
      ),

    'modulos',
      cfg.modulos_habilitados,

    'fiscal',
      jsonb_build_object(
        'condicion_iva', fis.condicion_iva,
        'ingresos_brutos', fis.ingresos_brutos,
        'inicio_actividades', fis.inicio_actividades,
        'domicilio_fiscal', fis.domicilio_fiscal,
        'localidad_fiscal', fis.localidad_fiscal,
        'provincia_fiscal', fis.provincia_fiscal,
        'codigo_postal_fiscal',
          fis.codigo_postal_fiscal,
        'concepto_facturacion',
          fis.concepto_facturacion,
        'punto_venta', fis.punto_venta,
        'ambiente_arca', fis.ambiente_arca,
        'tipos_comprobante_habilitados',
          fis.tipos_comprobante_habilitados,
        'leyenda_factura', fis.leyenda_factura,
        'facturacion_electronica_activa',
          fis.facturacion_electronica_activa,
        'estado_arca', fis.estado_arca,
        'certificado_alias',
          fis.certificado_alias,
        'certificado_vencimiento',
          fis.certificado_vencimiento,
        'ultimo_control_arca_at',
          fis.ultimo_control_arca_at,
        'ultimo_error_arca',
          fis.ultimo_error_arca
      ),

    'permisos',
      jsonb_build_object(
        'puede_editar',
          public.es_admin_comercio(p_comercio_id)
      ),

    'estado_configuracion',
      jsonb_build_object(
        'datos_comerciales_completos',
          (
            nullif(trim(c.nombre_comercial), '') is not null
            and nullif(trim(coalesce(c.email, '')), '')
              is not null
            and nullif(trim(coalesce(c.telefono, '')), '')
              is not null
          ),

        'datos_fiscales_completos',
          (
            c.cuit ~ '^[0-9]{11}$'
            and fis.condicion_iva <> 'no_configurada'
            and fis.punto_venta is not null
            and nullif(
              trim(coalesce(fis.domicilio_fiscal, '')),
              ''
            ) is not null
          ),

        'logo_configurado',
          nullif(trim(coalesce(cfg.logo_url, '')), '')
            is not null,

        'arca_lista_para_credenciales',
          (
            c.cuit ~ '^[0-9]{11}$'
            and fis.condicion_iva <> 'no_configurada'
            and fis.punto_venta is not null
          )
      )
  )
  into v_resultado
  from public.comercios as c
  inner join public.configuraciones_comercio as cfg
    on cfg.comercio_id = c.id
  inner join public.configuraciones_fiscales_comercio as fis
    on fis.comercio_id = c.id
  where c.id = p_comercio_id;

  if v_resultado is null then
    raise exception
      'No se encontró la configuración del comercio';
  end if;

  return v_resultado;
end;
$$;


-- =====================================================
-- 2. GUARDAR COLOR DE TEXTO DEL SIDEBAR
-- =====================================================

create or replace function
public.guardar_preferencias_comercio(
  p_comercio_id uuid,
  p_datos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actual public.configuraciones_comercio;
  v_logo_url text;
  v_color_primario text;
  v_color_secundario text;
  v_color_acento text;
  v_color_texto_sidebar text;
  v_moneda text;
  v_zona_horaria text;
  v_idioma text;
  v_validez integer;
  v_decimales smallint;
  v_formato_fecha text;
  v_modulos jsonb;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if not public.es_admin_comercio(
    p_comercio_id
  ) then
    raise exception
      'Solo un administrador puede modificar la configuración';
  end if;

  if p_datos is null
    or jsonb_typeof(p_datos) <> 'object' then
    raise exception
      'Las preferencias deben enviarse como un objeto';
  end if;

  insert into public.configuraciones_comercio (
    comercio_id
  )
  values (
    p_comercio_id
  )
  on conflict (comercio_id) do nothing;

  select cfg.*
  into v_actual
  from public.configuraciones_comercio as cfg
  where cfg.comercio_id = p_comercio_id
  for update;

  v_logo_url :=
    case
      when p_datos ? 'logo_url' then
        nullif(trim(coalesce(
          p_datos->>'logo_url',
          ''
        )), '')
      else v_actual.logo_url
    end;

  v_color_primario :=
    case
      when p_datos ? 'color_primario' then
        lower(trim(coalesce(
          p_datos->>'color_primario',
          ''
        )))
      else v_actual.color_primario
    end;

  v_color_secundario :=
    case
      when p_datos ? 'color_secundario' then
        lower(trim(coalesce(
          p_datos->>'color_secundario',
          ''
        )))
      else v_actual.color_secundario
    end;

  v_color_acento :=
    case
      when p_datos ? 'color_acento' then
        lower(trim(coalesce(
          p_datos->>'color_acento',
          ''
        )))
      else v_actual.color_acento
    end;

  v_color_texto_sidebar :=
    case
      when p_datos ? 'color_texto_sidebar' then
        lower(trim(coalesce(
          p_datos->>'color_texto_sidebar',
          ''
        )))
      else v_actual.color_texto_sidebar
    end;

  if v_color_primario !~ '^#[0-9a-f]{6}$'
    or v_color_secundario !~ '^#[0-9a-f]{6}$'
    or v_color_acento !~ '^#[0-9a-f]{6}$' then
    raise exception
      'Los colores deben tener formato hexadecimal, por ejemplo #4f46e5';
  end if;

  if v_color_texto_sidebar not in (
    '#ffffff',
    '#111827'
  ) then
    raise exception
      'El color del texto lateral debe ser blanco o negro';
  end if;

  v_moneda :=
    case
      when p_datos ? 'moneda' then
        upper(trim(coalesce(
          p_datos->>'moneda',
          ''
        )))
      else v_actual.moneda
    end;

  if v_moneda !~ '^[A-Z]{3}$' then
    raise exception
      'La moneda debe tener un código de 3 letras';
  end if;

  v_zona_horaria :=
    case
      when p_datos ? 'zona_horaria' then
        coalesce(
          nullif(trim(coalesce(
            p_datos->>'zona_horaria',
            ''
          )), ''),
          v_actual.zona_horaria
        )
      else v_actual.zona_horaria
    end;

  if not exists (
    select 1
    from pg_timezone_names
    where name = v_zona_horaria
  ) then
    raise exception
      'La zona horaria indicada no es válida';
  end if;

  v_idioma :=
    case
      when p_datos ? 'idioma' then
        coalesce(
          nullif(trim(coalesce(
            p_datos->>'idioma',
            ''
          )), ''),
          v_actual.idioma
        )
      else v_actual.idioma
    end;

  v_validez :=
    case
      when p_datos ? 'cotizacion_validez_dias' then
        (p_datos->>'cotizacion_validez_dias')::integer
      else v_actual.cotizacion_validez_dias
    end;

  if v_validez not between 1 and 365 then
    raise exception
      'La validez de cotización debe estar entre 1 y 365 días';
  end if;

  v_decimales :=
    case
      when p_datos ? 'decimales_cantidad' then
        (p_datos->>'decimales_cantidad')::smallint
      else v_actual.decimales_cantidad
    end;

  if v_decimales not between 0 and 3 then
    raise exception
      'Los decimales de cantidad deben estar entre 0 y 3';
  end if;

  v_formato_fecha :=
    case
      when p_datos ? 'formato_fecha' then
        trim(coalesce(
          p_datos->>'formato_fecha',
          ''
        ))
      else v_actual.formato_fecha
    end;

  if v_formato_fecha not in (
    'DD/MM/YYYY',
    'YYYY-MM-DD'
  ) then
    raise exception
      'El formato de fecha seleccionado no está permitido';
  end if;

  v_modulos := v_actual.modulos_habilitados;

  if p_datos ? 'modulos_habilitados' then
    if jsonb_typeof(
      p_datos->'modulos_habilitados'
    ) <> 'object' then
      raise exception
        'La configuración de módulos debe ser un objeto';
    end if;

    v_modulos :=
      coalesce(v_modulos, '{}'::jsonb)
      || p_datos->'modulos_habilitados';
  end if;

  update public.configuraciones_comercio as cfg
  set
    logo_url = v_logo_url,
    color_primario = v_color_primario,
    color_secundario = v_color_secundario,
    color_acento = v_color_acento,
    color_texto_sidebar = v_color_texto_sidebar,
    moneda = v_moneda,
    zona_horaria = v_zona_horaria,
    idioma = v_idioma,
    cotizacion_validez_dias = v_validez,
    decimales_cantidad = v_decimales,

    alerta_stock_bajo =
      case
        when p_datos ? 'alerta_stock_bajo' then
          coalesce(
            (p_datos->>'alerta_stock_bajo')::boolean,
            cfg.alerta_stock_bajo
          )
        else cfg.alerta_stock_bajo
      end,

    permitir_stock_negativo =
      case
        when p_datos ? 'permitir_stock_negativo' then
          coalesce(
            (p_datos->>'permitir_stock_negativo')::boolean,
            cfg.permitir_stock_negativo
          )
        else cfg.permitir_stock_negativo
      end,

    controla_stock_por_defecto =
      case
        when p_datos ? 'controla_stock_por_defecto' then
          coalesce(
            (p_datos->>'controla_stock_por_defecto')::boolean,
            cfg.controla_stock_por_defecto
          )
        else cfg.controla_stock_por_defecto
      end,

    formato_fecha = v_formato_fecha,

    mostrar_logo_comprobantes =
      case
        when p_datos ? 'mostrar_logo_comprobantes' then
          coalesce(
            (p_datos->>'mostrar_logo_comprobantes')::boolean,
            cfg.mostrar_logo_comprobantes
          )
        else cfg.mostrar_logo_comprobantes
      end,

    mostrar_datos_comercio_comprobantes =
      case
        when p_datos ?
          'mostrar_datos_comercio_comprobantes' then
          coalesce(
            (
              p_datos
              ->>'mostrar_datos_comercio_comprobantes'
            )::boolean,
            cfg.mostrar_datos_comercio_comprobantes
          )
        else
          cfg.mostrar_datos_comercio_comprobantes
      end,

    texto_cotizacion =
      case
        when p_datos ? 'texto_cotizacion' then
          nullif(trim(coalesce(
            p_datos->>'texto_cotizacion',
            ''
          )), '')
        else cfg.texto_cotizacion
      end,

    texto_comprobante =
      case
        when p_datos ? 'texto_comprobante' then
          nullif(trim(coalesce(
            p_datos->>'texto_comprobante',
            ''
          )), '')
        else cfg.texto_comprobante
      end,

    modulos_habilitados = v_modulos
  where cfg.comercio_id = p_comercio_id;

  return public.obtener_configuracion_comercio(
    p_comercio_id
  );

exception
  when invalid_text_representation then
    raise exception
      'Una preferencia numérica o booleana tiene un formato inválido';
end;
$$;

commit;
