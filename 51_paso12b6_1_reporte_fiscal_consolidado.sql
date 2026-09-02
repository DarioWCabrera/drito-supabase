-- ============================================================
-- DRITO 12B.6.1
-- REPORTE FISCAL CONSOLIDADO DE RETENCIONES Y PERCEPCIONES
--
-- Archivo:
--   51_paso12b6_1_reporte_fiscal_consolidado.sql
--
-- Objetivo:
--   Consolidar, sin modificar la operatoria existente:
--   - retenciones sufridas;
--   - retenciones practicadas;
--   - percepciones practicadas;
--   - percepciones sufridas.
--
-- Principios:
--   - multiempresa por comercio_id;
--   - permiso reportes.ver;
--   - solo lectura;
--   - no modifica Caja;
--   - no modifica ventas/compras;
--   - no modifica estados fiscales;
--   - no mezcla importes de monedas diferentes;
--   - conserva registros anulados para trazabilidad.
--
-- El reporte devuelve:
--   - filtros aplicados;
--   - conteos por tipo;
--   - montos por tipo + moneda;
--   - totales por impuesto + moneda + tipo;
--   - totales por jurisdicción + moneda + tipo;
--   - estados de obligación de operaciones practicadas;
--   - detalle normalizado y paginado.
-- ============================================================

begin;


-- ============================================================
-- 0. DEPENDENCIAS
-- ============================================================

do $$
begin

  if to_regclass(
    'public.retenciones_sufridas'
  ) is null then
    raise exception
      'Falta public.retenciones_sufridas';
  end if;


  if to_regclass(
    'public.retenciones_practicadas'
  ) is null then
    raise exception
      'Falta public.retenciones_practicadas';
  end if;


  if to_regclass(
    'public.percepciones_practicadas'
  ) is null then
    raise exception
      'Falta public.percepciones_practicadas';
  end if;


  if to_regclass(
    'public.percepciones_sufridas'
  ) is null then
    raise exception
      'Falta public.percepciones_sufridas';
  end if;


  if to_regclass(
    'public.rpc_permisos_drito'
  ) is null then
    raise exception
      'Falta public.rpc_permisos_drito';
  end if;


  if to_regprocedure(
    'public.instalar_guardia_rpc_drito(text)'
  ) is null then
    raise exception
      'Falta public.instalar_guardia_rpc_drito(text)';
  end if;


  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.exigir_permiso_comercio(uuid,text)';
  end if;


  if not exists (
    select 1
    from public.permisos_sistema as p
    where p.codigo = 'reportes.ver'
      and p.activo = true
  ) then
    raise exception
      'Falta el permiso activo reportes.ver';
  end if;

end;
$$;


-- ============================================================
-- 1. RPC BASE DEL REPORTE
--
-- La guardia genérica de Drito se instala más abajo.
-- ============================================================

create or replace function
public.obtener_reporte_fiscal_retenciones_percepciones(
  p_comercio_id uuid,
  p_fecha_desde date default null,
  p_fecha_hasta date default null,
  p_tipo text default null,
  p_estado text default null,
  p_estado_obligacion text default null,
  p_impuesto text default null,
  p_jurisdiccion text default null,
  p_busqueda text default null,
  p_limite integer default 500,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tipo text;
  v_estado text;
  v_estado_obligacion text;
  v_impuesto text;
  v_jurisdiccion text;
  v_busqueda text;

  v_limite integer;
  v_offset integer;

  v_resultado jsonb;
begin

  -- ==========================================================
  -- VALIDACIONES GENERALES
  -- ==========================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;


  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;


  if
    p_fecha_desde is not null
    and p_fecha_hasta is not null
    and p_fecha_hasta < p_fecha_desde
  then
    raise exception
      'La fecha hasta no puede ser anterior a la fecha desde';
  end if;


  v_tipo :=
    nullif(
      lower(
        trim(
          coalesce(
            p_tipo,
            ''
          )
        )
      ),
      ''
    );


  if
    v_tipo is not null
    and v_tipo not in (
      'retencion_sufrida',
      'retencion_practicada',
      'percepcion_practicada',
      'percepcion_sufrida'
    )
  then
    raise exception
      'Tipo fiscal inválido';
  end if;


  v_estado :=
    nullif(
      lower(
        trim(
          coalesce(
            p_estado,
            ''
          )
        )
      ),
      ''
    );


  if
    v_estado is not null
    and v_estado not in (
      'registrada',
      'anulada'
    )
  then
    raise exception
      'Estado inválido';
  end if;


  v_estado_obligacion :=
    nullif(
      lower(
        trim(
          coalesce(
            p_estado_obligacion,
            ''
          )
        )
      ),
      ''
    );


  if
    v_estado_obligacion is not null
    and v_estado_obligacion not in (
      'pendiente',
      'presentada',
      'ingresada',
      'anulada'
    )
  then
    raise exception
      'Estado de obligación inválido';
  end if;


  v_impuesto :=
    nullif(
      trim(
        coalesce(
          p_impuesto,
          ''
        )
      ),
      ''
    );


  v_jurisdiccion :=
    nullif(
      trim(
        coalesce(
          p_jurisdiccion,
          ''
        )
      ),
      ''
    );


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
    least(
      greatest(
        coalesce(
          p_limite,
          500
        ),
        1
      ),
      2000
    );


  v_offset :=
    greatest(
      coalesce(
        p_offset,
        0
      ),
      0
    );


  -- ==========================================================
  -- NORMALIZACIÓN + FILTROS + RESULTADO
  -- ==========================================================

  with

  catalogo_tipos as (
    select *
    from (
      values
        (
          'retencion_sufrida'::text,
          'Retención sufrida'::text
        ),
        (
          'retencion_practicada'::text,
          'Retención practicada'::text
        ),
        (
          'percepcion_practicada'::text,
          'Percepción practicada'::text
        ),
        (
          'percepcion_sufrida'::text,
          'Percepción sufrida'::text
        )
    ) as x(
      tipo,
      etiqueta
    )
  ),

  movimientos as (

    -- ========================================================
    -- RETENCIONES SUFRIDAS
    -- ========================================================

    select
      r.id,

      r.comercio_id,

      'retencion_sufrida'::text
        as tipo,

      'retencion'::text
        as clase,

      'sufrida'::text
        as naturaleza,

      r.fecha_retencion
        as fecha_fiscal,

      null::text
        as organismo,

      r.impuesto,

      r.jurisdiccion,

      r.regimen_codigo,

      r.regimen_descripcion,

      r.base_calculo,

      r.alicuota,

      r.importe,

      r.moneda,

      r.estado,

      null::text
        as estado_obligacion,

      r.numero_certificado,

      r.certificado_storage_path,

      'cliente'::text
        as contraparte_tipo,

      r.cliente_id
        as contraparte_id,

      r.agente_retencion_razon_social
        as contraparte_nombre,

      case
        when r.venta_id is not null
          then 'venta'
        when r.cobro_cliente_id is not null
          then 'cobro_cliente'
        when r.pago_venta_id is not null
          then 'pago_venta'
        else null
      end::text
        as operacion_tipo,

      coalesce(
        r.venta_id,
        r.cobro_cliente_id,
        r.pago_venta_id
      )
        as operacion_id,

      r.observaciones,

      r.creado_por,

      r.anulado_por,

      r.anulado_at,

      r.motivo_anulacion,

      r.created_at,

      r.updated_at

    from public.retenciones_sufridas as r

    where r.comercio_id =
      p_comercio_id


    union all


    -- ========================================================
    -- RETENCIONES PRACTICADAS
    -- ========================================================

    select
      r.id,

      r.comercio_id,

      'retencion_practicada'::text
        as tipo,

      'retencion'::text
        as clase,

      'practicada'::text
        as naturaleza,

      r.fecha_retencion
        as fecha_fiscal,

      r.organismo,

      r.impuesto,

      r.jurisdiccion,

      r.regimen_codigo,

      r.regimen_descripcion,

      r.base_calculo,

      r.alicuota,

      r.importe,

      r.moneda,

      r.estado,

      r.estado_obligacion,

      r.numero_certificado,

      r.certificado_storage_path,

      'proveedor'::text
        as contraparte_tipo,

      r.proveedor_id
        as contraparte_id,

      r.sujeto_retenido_razon_social
        as contraparte_nombre,

      case
        when r.compra_id is not null
          then 'compra'
        when r.pago_proveedor_id is not null
          then 'pago_proveedor'
        when r.pago_compra_id is not null
          then 'pago_compra'
        else null
      end::text
        as operacion_tipo,

      coalesce(
        r.compra_id,
        r.pago_proveedor_id,
        r.pago_compra_id
      )
        as operacion_id,

      r.observaciones,

      r.creado_por,

      r.anulado_por,

      r.anulado_at,

      r.motivo_anulacion,

      r.created_at,

      r.updated_at

    from public.retenciones_practicadas as r

    where r.comercio_id =
      p_comercio_id


    union all


    -- ========================================================
    -- PERCEPCIONES PRACTICADAS
    -- ========================================================

    select
      p.id,

      p.comercio_id,

      'percepcion_practicada'::text
        as tipo,

      'percepcion'::text
        as clase,

      'practicada'::text
        as naturaleza,

      p.fecha_percepcion
        as fecha_fiscal,

      p.organismo,

      p.impuesto,

      p.jurisdiccion,

      p.regimen_codigo,

      p.regimen_descripcion,

      p.base_calculo,

      p.alicuota,

      p.importe,

      p.moneda,

      p.estado,

      p.estado_obligacion,

      p.numero_certificado,

      p.certificado_storage_path,

      'cliente'::text
        as contraparte_tipo,

      p.cliente_id
        as contraparte_id,

      p.sujeto_percibido_razon_social
        as contraparte_nombre,

      'venta'::text
        as operacion_tipo,

      p.venta_id
        as operacion_id,

      p.observaciones,

      p.creado_por,

      p.anulado_por,

      p.anulado_at,

      p.motivo_anulacion,

      p.created_at,

      p.updated_at

    from public.percepciones_practicadas as p

    where p.comercio_id =
      p_comercio_id


    union all


    -- ========================================================
    -- PERCEPCIONES SUFRIDAS
    -- ========================================================

    select
      p.id,

      p.comercio_id,

      'percepcion_sufrida'::text
        as tipo,

      'percepcion'::text
        as clase,

      'sufrida'::text
        as naturaleza,

      p.fecha_percepcion
        as fecha_fiscal,

      p.organismo,

      p.impuesto,

      p.jurisdiccion,

      p.regimen_codigo,

      p.regimen_descripcion,

      p.base_calculo,

      p.alicuota,

      p.importe,

      p.moneda,

      p.estado,

      null::text
        as estado_obligacion,

      p.numero_certificado,

      p.certificado_storage_path,

      'proveedor'::text
        as contraparte_tipo,

      p.proveedor_id
        as contraparte_id,

      p.agente_percepcion_razon_social
        as contraparte_nombre,

      'compra'::text
        as operacion_tipo,

      p.compra_id
        as operacion_id,

      p.observaciones,

      p.creado_por,

      p.anulado_por,

      p.anulado_at,

      p.motivo_anulacion,

      p.created_at,

      p.updated_at

    from public.percepciones_sufridas as p

    where p.comercio_id =
      p_comercio_id
  ),

  filtrados as (
    select m.*
    from movimientos as m
    where
      (
        p_fecha_desde is null
        or m.fecha_fiscal >=
          p_fecha_desde
      )
      and (
        p_fecha_hasta is null
        or m.fecha_fiscal <=
          p_fecha_hasta
      )
      and (
        v_tipo is null
        or m.tipo =
          v_tipo
      )
      and (
        v_estado is null
        or m.estado =
          v_estado
      )
      and (
        v_estado_obligacion is null
        or m.estado_obligacion =
          v_estado_obligacion
      )
      and (
        v_impuesto is null
        or m.impuesto ilike
          v_impuesto
      )
      and (
        v_jurisdiccion is null
        or coalesce(
          m.jurisdiccion,
          ''
        ) ilike
          v_jurisdiccion
      )
      and (
        v_busqueda is null

        or coalesce(
          m.contraparte_nombre,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.numero_certificado,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.organismo,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.impuesto,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.jurisdiccion,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.regimen_codigo,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.regimen_descripcion,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.observaciones,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.motivo_anulacion,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          m.operacion_id::text,
          ''
        ) ilike
          '%' || v_busqueda || '%'
      )
  ),

  resumen_conteos as (
    select
      ct.tipo,

      ct.etiqueta,

      count(f.id)
        as cantidad_total,

      count(f.id)
        filter (
          where f.estado =
            'registrada'
        )
        as cantidad_registrada,

      count(f.id)
        filter (
          where f.estado =
            'anulada'
        )
        as cantidad_anulada

    from catalogo_tipos as ct

    left join filtrados as f
      on f.tipo =
        ct.tipo

    group by
      ct.tipo,
      ct.etiqueta
  ),

  montos_tipo_moneda as (
    select
      f.tipo,
      f.moneda,

      count(*)
        as cantidad,

      coalesce(
        sum(f.importe)
          filter (
            where f.estado =
              'registrada'
          ),
        0
      )::numeric(18,2)
        as importe_registrado,

      coalesce(
        sum(f.importe)
          filter (
            where f.estado =
              'anulada'
          ),
        0
      )::numeric(18,2)
        as importe_anulado

    from filtrados as f

    group by
      f.tipo,
      f.moneda
  ),

  por_impuesto as (
    select
      f.tipo,
      f.impuesto,
      f.moneda,

      count(*)
        as cantidad,

      coalesce(
        sum(f.importe)
          filter (
            where f.estado =
              'registrada'
          ),
        0
      )::numeric(18,2)
        as importe_registrado,

      coalesce(
        sum(f.importe)
          filter (
            where f.estado =
              'anulada'
          ),
        0
      )::numeric(18,2)
        as importe_anulado

    from filtrados as f

    group by
      f.tipo,
      f.impuesto,
      f.moneda
  ),

  por_jurisdiccion as (
    select
      f.tipo,

      nullif(
        trim(
          coalesce(
            f.jurisdiccion,
            ''
          )
        ),
        ''
      )
        as jurisdiccion,

      f.moneda,

      count(*)
        as cantidad,

      coalesce(
        sum(f.importe)
          filter (
            where f.estado =
              'registrada'
          ),
        0
      )::numeric(18,2)
        as importe_registrado,

      coalesce(
        sum(f.importe)
          filter (
            where f.estado =
              'anulada'
          ),
        0
      )::numeric(18,2)
        as importe_anulado

    from filtrados as f

    group by
      f.tipo,
      nullif(
        trim(
          coalesce(
            f.jurisdiccion,
            ''
          )
        ),
        ''
      ),
      f.moneda
  ),

  obligaciones_practicadas as (
    select
      f.tipo,
      f.estado_obligacion,
      f.moneda,

      count(*)
        as cantidad,

      coalesce(
        sum(f.importe),
        0
      )::numeric(18,2)
        as importe

    from filtrados as f

    where f.naturaleza =
      'practicada'

    group by
      f.tipo,
      f.estado_obligacion,
      f.moneda
  ),

  pagina as (
    select f.*
    from filtrados as f
    order by
      f.fecha_fiscal desc,
      f.created_at desc,
      f.id desc
    limit v_limite
    offset v_offset
  )

  select jsonb_build_object(

    'filtros',
    jsonb_build_object(
      'comercio_id',
        p_comercio_id,
      'fecha_desde',
        p_fecha_desde,
      'fecha_hasta',
        p_fecha_hasta,
      'tipo',
        v_tipo,
      'estado',
        v_estado,
      'estado_obligacion',
        v_estado_obligacion,
      'impuesto',
        v_impuesto,
      'jurisdiccion',
        v_jurisdiccion,
      'busqueda',
        v_busqueda,
      'limite',
        v_limite,
      'offset',
        v_offset
    ),

    'cantidad_total',
    (
      select count(*)
      from filtrados
    ),

    'cantidad_registrada',
    (
      select count(*)
      from filtrados
      where estado =
        'registrada'
    ),

    'cantidad_anulada',
    (
      select count(*)
      from filtrados
      where estado =
        'anulada'
    ),

    'resumen_por_tipo',
    (
      select coalesce(
        jsonb_object_agg(
          r.tipo,
          jsonb_build_object(
            'etiqueta',
              r.etiqueta,
            'cantidad_total',
              r.cantidad_total,
            'cantidad_registrada',
              r.cantidad_registrada,
            'cantidad_anulada',
              r.cantidad_anulada
          )
          order by r.tipo
        ),
        '{}'::jsonb
      )
      from resumen_conteos as r
    ),

    'montos_por_tipo_moneda',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'tipo',
              m.tipo,
            'moneda',
              m.moneda,
            'cantidad',
              m.cantidad,
            'importe_registrado',
              m.importe_registrado,
            'importe_anulado',
              m.importe_anulado
          )
          order by
            m.tipo,
            m.moneda
        ),
        '[]'::jsonb
      )
      from montos_tipo_moneda as m
    ),

    'por_impuesto',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'tipo',
              i.tipo,
            'impuesto',
              i.impuesto,
            'moneda',
              i.moneda,
            'cantidad',
              i.cantidad,
            'importe_registrado',
              i.importe_registrado,
            'importe_anulado',
              i.importe_anulado
          )
          order by
            i.tipo,
            i.impuesto,
            i.moneda
        ),
        '[]'::jsonb
      )
      from por_impuesto as i
    ),

    'por_jurisdiccion',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'tipo',
              j.tipo,
            'jurisdiccion',
              j.jurisdiccion,
            'moneda',
              j.moneda,
            'cantidad',
              j.cantidad,
            'importe_registrado',
              j.importe_registrado,
            'importe_anulado',
              j.importe_anulado
          )
          order by
            j.tipo,
            j.jurisdiccion nulls last,
            j.moneda
        ),
        '[]'::jsonb
      )
      from por_jurisdiccion as j
    ),

    'obligaciones_practicadas',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'tipo',
              o.tipo,
            'estado_obligacion',
              o.estado_obligacion,
            'moneda',
              o.moneda,
            'cantidad',
              o.cantidad,
            'importe',
              o.importe
          )
          order by
            o.tipo,
            o.estado_obligacion,
            o.moneda
        ),
        '[]'::jsonb
      )
      from obligaciones_practicadas as o
    ),

    'registros',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',
              p.id,
            'comercio_id',
              p.comercio_id,
            'tipo',
              p.tipo,
            'clase',
              p.clase,
            'naturaleza',
              p.naturaleza,
            'fecha_fiscal',
              p.fecha_fiscal,
            'organismo',
              p.organismo,
            'impuesto',
              p.impuesto,
            'jurisdiccion',
              p.jurisdiccion,
            'regimen_codigo',
              p.regimen_codigo,
            'regimen_descripcion',
              p.regimen_descripcion,
            'base_calculo',
              p.base_calculo,
            'alicuota',
              p.alicuota,
            'importe',
              p.importe,
            'moneda',
              p.moneda,
            'estado',
              p.estado,
            'estado_obligacion',
              p.estado_obligacion,
            'numero_certificado',
              p.numero_certificado,
            'certificado_storage_path',
              p.certificado_storage_path,
            'contraparte_tipo',
              p.contraparte_tipo,
            'contraparte_id',
              p.contraparte_id,
            'contraparte_nombre',
              p.contraparte_nombre,
            'operacion_tipo',
              p.operacion_tipo,
            'operacion_id',
              p.operacion_id,
            'observaciones',
              p.observaciones,
            'creado_por',
              p.creado_por,
            'anulado_por',
              p.anulado_por,
            'anulado_at',
              p.anulado_at,
            'motivo_anulacion',
              p.motivo_anulacion,
            'created_at',
              p.created_at,
            'updated_at',
              p.updated_at
          )
          order by
            p.fecha_fiscal desc,
            p.created_at desc,
            p.id desc
        ),
        '[]'::jsonb
      )
      from pagina as p
    )

  )
  into v_resultado;


  return v_resultado;

end;
$function$;


-- ============================================================
-- 2. MAPEO DE PERMISO
-- ============================================================

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
values (
  'obtener_reporte_fiscal_retenciones_percepciones',
  'reportes.ver',
  'argumento_comercio',
  array[
    'p_comercio_id'
  ],
  null,
  'id',
  'comercio_id',
  true,
  'Reporte fiscal consolidado de retenciones y percepciones',
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
  activo =
    true,
  updated_at =
    now();


-- ============================================================
-- 3. INSTALAR GUARDIA GENÉRICA DE DRITO
--
-- El instalador:
--   - renombra internamente la función original;
--   - crea el wrapper público con la misma firma;
--   - exige reportes.ver para p_comercio_id;
--   - concede EXECUTE solo a authenticated;
--   - revoca acceso directo al helper interno.
-- ============================================================

do $$
declare
  v_resultado jsonb;
begin

  v_resultado :=
    public.instalar_guardia_rpc_drito(
      'obtener_reporte_fiscal_retenciones_percepciones'
    );


  if coalesce(
    (
      v_resultado ->
        'instaladas'
    )::text::integer,
    0
  ) < 1 then
    raise exception
      'No se pudo instalar la guardia del reporte fiscal: %',
      v_resultado;
  end if;

end;
$$;


-- ============================================================
-- 4. COMENTARIO FUNCIONAL
-- ============================================================

comment on function
public.obtener_reporte_fiscal_retenciones_percepciones(
  uuid,
  date,
  date,
  text,
  text,
  text,
  text,
  text,
  text,
  integer,
  integer
)
is
'DRITO_GUARDIA_PERMISO:reportes.ver | Reporte fiscal consolidado de retenciones y percepciones. Solo lectura; no modifica Caja ni operaciones.';


-- Refresca el esquema de PostgREST.
notify pgrst, 'reload schema';


commit;


-- ============================================================
-- FIN DRITO 12B.6.1
--
-- Siguiente paso:
--   verificación estructural y prueba funcional de lectura.
-- ============================================================
