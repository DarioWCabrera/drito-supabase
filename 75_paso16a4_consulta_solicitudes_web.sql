-- ============================================================
-- DRITO
-- PASO 16A.4.1
-- CAPA DE CONSULTA DE SOLICITUDES WEB
--
-- Incluye:
-- - listado paginado;
-- - filtros por estado;
-- - búsqueda;
-- - detalle completo con ítems;
-- - referencias SOL / COT formateadas;
-- - control de permisos por comercio.
--
-- NO modifica:
-- - recepción pública;
-- - configuración del canal;
-- - web externa;
-- - WhatsApp.
-- ============================================================


-- ============================================================
-- 1. LISTADO DE SOLICITUDES WEB
-- ============================================================

create or replace function
public.obtener_solicitudes_web(

  p_comercio_id uuid,

  p_estado text default null,

  p_busqueda text default null,

  p_limite integer default 50,

  p_offset integer default 0

)
returns table (

  solicitud_id uuid,

  numero bigint,

  referencia text,

  estado text,

  origen text,

  nombre_contacto text,

  empresa text,

  telefono text,

  email text,

  cuit_cuil text,

  mensaje text,

  cliente_id uuid,

  cliente_nombre text,

  cotizacion_id uuid,

  cotizacion_numero bigint,

  cotizacion_referencia text,

  cantidad_items bigint,

  moneda_referencia text,

  importe_referencia numeric,

  revisado_at timestamptz,

  convertido_at timestamptz,

  descartado_at timestamptz,

  motivo_descarte text,

  created_at timestamptz,

  updated_at timestamptz,

  total_registros bigint

)

language plpgsql
security definer
set search_path = public

as $$

declare

  v_estado text;

  v_busqueda text;

  v_limite integer;

  v_offset integer;

begin

  -- ----------------------------------------------------------
  -- Permiso
  -- ----------------------------------------------------------

  perform public.exigir_permiso_comercio(

    p_comercio_id,

    'solicitudes_web.ver'

  );


  -- ----------------------------------------------------------
  -- Filtros
  -- ----------------------------------------------------------

  v_estado :=
    nullif(
      trim(
        coalesce(
          p_estado,
          ''
        )
      ),
      ''
    );


  if v_estado is not null
     and v_estado not in (
       'recibida',
       'en_revision',
       'convertida',
       'descartada'
     )
  then

    raise exception
      'Estado de solicitud inválido';

  end if;


  v_busqueda :=
    nullif(
      trim(
        coalesce(
          p_busqueda,
          ''
        )
      ),
      ''
    );


  v_limite :=
    greatest(
      1,
      least(
        coalesce(
          p_limite,
          50
        ),
        200
      )
    );


  v_offset :=
    greatest(
      coalesce(
        p_offset,
        0
      ),
      0
    );


  -- ----------------------------------------------------------
  -- Listado
  -- ----------------------------------------------------------

  return query

  select

    sw.id
      as solicitud_id,

    sw.numero,

    'SOL-' ||
    lpad(
      sw.numero::text,
      6,
      '0'
    )
      as referencia,

    sw.estado,

    sw.origen,

    sw.nombre_contacto,

    sw.empresa,

    sw.telefono,

    sw.email,

    sw.cuit_cuil,

    sw.mensaje,

    sw.cliente_id,

    case
      when cl.id is null then null
      else coalesce(
        nullif(
          trim(
            coalesce(
              cl.razon_social,
              ''
            )
          ),
          ''
        ),
        cl.nombre
      )
    end
      as cliente_nombre,

    sw.cotizacion_id,

    cot.numero
      as cotizacion_numero,

    case
      when cot.numero is null then null
      else
        'COT-' ||
        lpad(
          cot.numero::text,
          6,
          '0'
        )
    end
      as cotizacion_referencia,

    coalesce(
      items.cantidad_items,
      0
    )
      as cantidad_items,

    items.moneda_referencia,

    items.importe_referencia,

    sw.revisado_at,

    sw.convertido_at,

    sw.descartado_at,

    sw.motivo_descarte,

    sw.created_at,

    sw.updated_at,

    count(*) over()
      as total_registros

  from public.solicitudes_web sw

  left join public.clientes cl
    on cl.id = sw.cliente_id
   and cl.comercio_id = sw.comercio_id

  left join public.cotizaciones cot
    on cot.id = sw.cotizacion_id
   and cot.comercio_id = sw.comercio_id

  left join lateral (

    select

      count(*)::bigint
        as cantidad_items,

      case
        when count(
          distinct i.moneda_snapshot
        ) = 1
        then min(
          i.moneda_snapshot
        )
        else null
      end
        as moneda_referencia,

      case
        when count(*) = 0 then 0::numeric

        when count(
          i.precio_referencia
        ) = count(*)
        then
          round(
            sum(
              i.cantidad
              *
              i.precio_referencia
              *
              (
                1
                +
                coalesce(
                  i.iva_porcentaje_snapshot,
                  0
                )
                / 100
              )
            ),
            2
          )

        else null
      end
        as importe_referencia

    from public.items_solicitud_web i

    where i.solicitud_id = sw.id
      and i.comercio_id = sw.comercio_id

  ) items
    on true

  where sw.comercio_id = p_comercio_id

    and (
      v_estado is null
      or sw.estado = v_estado
    )

    and (

      v_busqueda is null

      or sw.nombre_contacto
        ilike '%' || v_busqueda || '%'

      or coalesce(
        sw.empresa,
        ''
      )
        ilike '%' || v_busqueda || '%'

      or coalesce(
        sw.telefono,
        ''
      )
        ilike '%' || v_busqueda || '%'

      or coalesce(
        sw.email,
        ''
      )
        ilike '%' || v_busqueda || '%'

      or coalesce(
        sw.cuit_cuil,
        ''
      )
        ilike '%' || v_busqueda || '%'

      or (
        'SOL-' ||
        lpad(
          sw.numero::text,
          6,
          '0'
        )
      )
        ilike '%' || v_busqueda || '%'

    )

  order by

    case sw.estado

      when 'recibida'
        then 1

      when 'en_revision'
        then 2

      when 'convertida'
        then 3

      when 'descartada'
        then 4

      else 5

    end,

    sw.created_at desc,

    sw.numero desc

  limit v_limite
  offset v_offset;

end;

$$;


-- ============================================================
-- 2. SEGURIDAD DEL LISTADO
-- ============================================================

revoke all on function
public.obtener_solicitudes_web(
  uuid,
  text,
  text,
  integer,
  integer
)
from public, anon;


grant execute on function
public.obtener_solicitudes_web(
  uuid,
  text,
  text,
  integer,
  integer
)
to authenticated;


-- ============================================================
-- 3. DETALLE DE UNA SOLICITUD
-- ============================================================

create or replace function
public.obtener_solicitud_web_detalle(
  p_solicitud_id uuid
)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_solicitud public.solicitudes_web%rowtype;

  v_resultado jsonb;

begin

  -- ----------------------------------------------------------
  -- Solicitud
  -- ----------------------------------------------------------

  select sw.*
  into v_solicitud

  from public.solicitudes_web sw

  where sw.id = p_solicitud_id;


  if not found then

    raise exception
      'Solicitud web no encontrada';

  end if;


  -- ----------------------------------------------------------
  -- Permiso
  -- ----------------------------------------------------------

  perform public.exigir_permiso_comercio(

    v_solicitud.comercio_id,

    'solicitudes_web.ver'

  );


  -- ----------------------------------------------------------
  -- Resultado
  -- ----------------------------------------------------------

  select jsonb_build_object(

    'id',
      sw.id,

    'comercio_id',
      sw.comercio_id,

    'numero',
      sw.numero,

    'referencia',
      'SOL-' ||
      lpad(
        sw.numero::text,
        6,
        '0'
      ),

    'estado',
      sw.estado,

    'origen',
      sw.origen,

    'contacto',
      jsonb_build_object(

        'nombre',
          sw.nombre_contacto,

        'empresa',
          sw.empresa,

        'telefono',
          sw.telefono,

        'email',
          sw.email,

        'cuit_cuil',
          sw.cuit_cuil

      ),

    'mensaje',
      sw.mensaje,

    'origen_url',
      sw.origen_url,

    'cliente',
      case

        when cl.id is null
          then null

        else jsonb_build_object(

          'id',
            cl.id,

          'nombre',
            cl.nombre,

          'razon_social',
            cl.razon_social,

          'documento',
            cl.documento,

          'telefono',
            cl.telefono,

          'email',
            cl.email

        )

      end,

    'cotizacion',
      case

        when cot.id is null
          then null

        else jsonb_build_object(

          'id',
            cot.id,

          'numero',
            cot.numero,

          'referencia',
            'COT-' ||
            lpad(
              cot.numero::text,
              6,
              '0'
            ),

          'estado',
            cot.estado,

          'total',
            cot.total,

          'moneda',
            cot.moneda

        )

      end,

    'items',
      coalesce(

        (

          select jsonb_agg(

            jsonb_build_object(

              'id',
                i.id,

              'producto_id',
                i.producto_id,

              'tipo',
                i.tipo_snapshot,

              'codigo',
                i.codigo_snapshot,

              'nombre',
                i.nombre_snapshot,

              'descripcion',
                i.descripcion_snapshot,

              'unidad_medida',
                i.unidad_medida_snapshot,

              'cantidad',
                i.cantidad,

              'precio_referencia',
                i.precio_referencia,

              'iva_porcentaje',
                i.iva_porcentaje_snapshot,

              'moneda',
                i.moneda_snapshot,

              'observaciones',
                i.observaciones,

              'importe_neto_referencia',

                case

                  when i.precio_referencia
                    is null
                    then null

                  else round(
                    i.cantidad
                    *
                    i.precio_referencia,
                    2
                  )

                end,

              'importe_total_referencia',

                case

                  when i.precio_referencia
                    is null
                    then null

                  else round(

                    i.cantidad
                    *
                    i.precio_referencia
                    *
                    (
                      1
                      +
                      coalesce(
                        i.iva_porcentaje_snapshot,
                        0
                      )
                      / 100
                    ),

                    2

                  )

                end

            )

            order by
              i.created_at,
              i.id

          )

          from public.items_solicitud_web i

          where i.solicitud_id = sw.id
            and i.comercio_id = sw.comercio_id

        ),

        '[]'::jsonb

      ),

    'gestion',
      jsonb_build_object(

        'revisado_por',
          sw.revisado_por,

        'revisado_at',
          sw.revisado_at,

        'convertido_por',
          sw.convertido_por,

        'convertido_at',
          sw.convertido_at,

        'descartado_por',
          sw.descartado_por,

        'descartado_at',
          sw.descartado_at,

        'motivo_descarte',
          sw.motivo_descarte

      ),

    'created_at',
      sw.created_at,

    'updated_at',
      sw.updated_at

  )

  into v_resultado

  from public.solicitudes_web sw

  left join public.clientes cl
    on cl.id = sw.cliente_id
   and cl.comercio_id = sw.comercio_id

  left join public.cotizaciones cot
    on cot.id = sw.cotizacion_id
   and cot.comercio_id = sw.comercio_id

  where sw.id = p_solicitud_id;


  return v_resultado;

end;

$$;


-- ============================================================
-- 4. SEGURIDAD DEL DETALLE
-- ============================================================

revoke all on function
public.obtener_solicitud_web_detalle(uuid)
from public, anon;


grant execute on function
public.obtener_solicitud_web_detalle(uuid)
to authenticated;


-- ============================================================
-- 5. POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 6. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

select jsonb_build_object(

  'rpc_listado_existe',
    to_regprocedure(
      'public.obtener_solicitudes_web(uuid,text,text,integer,integer)'
    ) is not null,

  'rpc_detalle_existe',
    to_regprocedure(
      'public.obtener_solicitud_web_detalle(uuid)'
    ) is not null,

  'anon_rpc_listado',
    has_function_privilege(
      'anon',
      'public.obtener_solicitudes_web(uuid,text,text,integer,integer)',
      'EXECUTE'
    ),

  'authenticated_rpc_listado',
    has_function_privilege(
      'authenticated',
      'public.obtener_solicitudes_web(uuid,text,text,integer,integer)',
      'EXECUTE'
    ),

  'anon_rpc_detalle',
    has_function_privilege(
      'anon',
      'public.obtener_solicitud_web_detalle(uuid)',
      'EXECUTE'
    ),

  'authenticated_rpc_detalle',
    has_function_privilege(
      'authenticated',
      'public.obtener_solicitud_web_detalle(uuid)',
      'EXECUTE'
    ),

  'motor_publico_anon_sigue_cerrado',
    not has_function_privilege(
      'anon',
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),

  'canal_habilitado',
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

) as verificacion_16a4_1;