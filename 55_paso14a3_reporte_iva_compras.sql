-- ============================================================
-- DRITO
-- PASO 14A.3 - REPORTE DE IVA EN COMPRAS
-- Archivo: 55_paso14a3_reporte_iva_compras.sql
--
-- Objetivo:
--   Exponer un reporte de IVA Compras de solo lectura, multiempresa
--   y apto para exportaciones/paquete contador.
--
-- Principios:
--   - permiso reportes.ver;
--   - aislamiento por comercio_id;
--   - NO modifica Caja;
--   - NO modifica compras, items, pagos, stock ni fiscalidad;
--   - NO mezcla monedas distintas;
--   - conserva compras anuladas para trazabilidad;
--   - NO inventa tratamiento fiscal histórico;
--   - NULL en iva_tratamiento se informa como histórico sin clasificar;
--   - solo "computable" confirmado integra crédito fiscal computable.
-- ============================================================

begin;

-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

do $$
begin
  if to_regclass('public.compras') is null then
    raise exception 'Falta public.compras';
  end if;

  if to_regclass('public.items_compra') is null then
    raise exception 'Falta public.items_compra';
  end if;

  if to_regclass('public.proveedores') is null then
    raise exception 'Falta public.proveedores';
  end if;

  if to_regclass('public.arca_alicuotas_iva') is null then
    raise exception 'Falta public.arca_alicuotas_iva';
  end if;

  if to_regclass('public.permisos_sistema') is null then
    raise exception 'Falta public.permisos_sistema';
  end if;

  if to_regclass('public.rpc_permisos_drito') is null then
    raise exception 'Falta public.rpc_permisos_drito';
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
    from public.permisos_sistema
    where codigo = 'reportes.ver'
      and activo = true
  ) then
    raise exception
      'Falta el permiso activo reportes.ver';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'items_compra'
      and column_name = 'iva_tratamiento'
  ) then
    raise exception
      'Falta items_compra.iva_tratamiento. Ejecutar antes PASO 13A.';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'items_compra'
      and column_name = 'iva_alicuota_codigo'
  ) then
    raise exception
      'Falta items_compra.iva_alicuota_codigo. Ejecutar antes PASO 13A.';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'items_compra'
      and column_name = 'iva_base_fiscal'
  ) then
    raise exception
      'Falta items_compra.iva_base_fiscal. Ejecutar antes PASO 13A.';
  end if;
end;
$$;

-- ============================================================
-- 1. RPC BASE
-- ============================================================

create or replace function public.obtener_reporte_iva_compras(
  p_comercio_id uuid,
  p_fecha_desde date default null,
  p_fecha_hasta date default null,
  p_estado_compra text default null,
  p_iva_tratamiento text default null,
  p_iva_alicuota_codigo smallint default null,
  p_proveedor_id uuid default null,
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
  v_estado text;
  v_tratamiento text;
  v_busqueda text;
  v_limite integer;
  v_offset integer;
  v_resultado jsonb;
begin
  if p_comercio_id is null then
    raise exception 'p_comercio_id es obligatorio';
  end if;

  if p_fecha_desde is not null
     and p_fecha_hasta is not null
     and p_fecha_hasta < p_fecha_desde then
    raise exception
      'La fecha hasta no puede ser anterior a la fecha desde';
  end if;

  v_estado :=
    nullif(
      lower(trim(coalesce(p_estado_compra, ''))),
      ''
    );

  if v_estado is not null
     and v_estado not in (
       'confirmada',
       'anulada'
     ) then
    raise exception
      'Estado de compra inválido: %',
      p_estado_compra;
  end if;

  v_tratamiento :=
    nullif(
      lower(trim(coalesce(p_iva_tratamiento, ''))),
      ''
    );

  if v_tratamiento is not null
     and v_tratamiento not in (
       'computable',
       'no_computable',
       'exento',
       'no_gravado',
       'historico'
     ) then
    raise exception
      'Tratamiento IVA inválido: %',
      p_iva_tratamiento;
  end if;

  if p_iva_alicuota_codigo is not null
     and not exists (
       select 1
       from public.arca_alicuotas_iva a
       where a.codigo = p_iva_alicuota_codigo
     ) then
    raise exception
      'Código de alícuota IVA inexistente: %',
      p_iva_alicuota_codigo;
  end if;

  if p_proveedor_id is not null
     and not exists (
       select 1
       from public.proveedores p
       where p.id = p_proveedor_id
         and p.comercio_id = p_comercio_id
     ) then
    raise exception
      'El proveedor indicado no pertenece al comercio';
  end if;

  v_busqueda :=
    nullif(
      trim(coalesce(p_busqueda, '')),
      ''
    );

  v_limite :=
    least(
      greatest(
        coalesce(p_limite, 500),
        1
      ),
      2000
    );

  v_offset :=
    greatest(
      coalesce(p_offset, 0),
      0
    );

  with base as (
    select
      i.id as item_id,
      i.compra_id,
      i.comercio_id,

      c.numero as numero_compra,
      c.fecha_compra,
      c.fecha_vencimiento,
      c.estado as estado_compra,
      c.estado_pago,
      c.tipo_comprobante,
      c.numero_comprobante,
      c.moneda,
      c.descuento_general_porcentaje,
      c.descuento_general_importe,
      c.observaciones as compra_observaciones,
      c.created_at as compra_created_at,
      c.updated_at as compra_updated_at,

      p.id as proveedor_id,
      p.nombre as proveedor_nombre,
      p.razon_social as proveedor_razon_social,
      p.tipo_documento as proveedor_tipo_documento,
      p.documento as proveedor_documento,
      p.condicion_iva as proveedor_condicion_iva,

      i.producto_id,
      i.tipo as item_tipo,
      i.codigo as item_codigo,
      i.nombre as item_nombre,
      i.descripcion as item_descripcion,
      i.unidad_medida,
      i.cantidad,
      i.costo_unitario,
      i.descuento_porcentaje,
      i.subtotal,
      i.descuento_importe,
      i.neto,

      i.iva_tratamiento,
      case
        when i.iva_tratamiento is null
          then 'historico_sin_clasificar'
        else i.iva_tratamiento
      end as iva_clasificacion,

      i.iva_alicuota_codigo,
      i.iva_porcentaje,
      i.iva_base_fiscal,
      i.impuesto_importe,
      i.total as total_item,
      i.afecta_stock,
      i.orden,
      i.created_at as item_created_at

    from public.items_compra i

    join public.compras c
      on c.id = i.compra_id
     and c.comercio_id = i.comercio_id

    join public.proveedores p
      on p.id = c.proveedor_id
     and p.comercio_id = c.comercio_id

    where i.comercio_id = p_comercio_id

      and (
        p_fecha_desde is null
        or c.fecha_compra >= p_fecha_desde
      )

      and (
        p_fecha_hasta is null
        or c.fecha_compra <= p_fecha_hasta
      )

      and (
        v_estado is null
        or c.estado = v_estado
      )

      and (
        v_tratamiento is null

        or (
          v_tratamiento = 'historico'
          and i.iva_tratamiento is null
        )

        or i.iva_tratamiento = v_tratamiento
      )

      and (
        p_iva_alicuota_codigo is null
        or i.iva_alicuota_codigo =
          p_iva_alicuota_codigo
      )

      and (
        p_proveedor_id is null
        or c.proveedor_id = p_proveedor_id
      )

      and (
        v_busqueda is null

        or coalesce(
          p.nombre,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          p.razon_social,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          p.documento,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          c.numero_comprobante,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or c.numero::text ilike
          '%' || v_busqueda || '%'

        or (
          'COM-' ||
          lpad(
            c.numero::text,
            6,
            '0'
          )
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          i.codigo,
          ''
        ) ilike
          '%' || v_busqueda || '%'

        or coalesce(
          i.nombre,
          ''
        ) ilike
          '%' || v_busqueda || '%'
      )
  ),

  resumen_moneda as (
    select
      b.moneda,

      count(distinct b.compra_id)
        as cantidad_compras,

      count(*)
        as cantidad_items,

      count(*) filter (
        where b.estado_compra = 'confirmada'
      )
        as items_confirmados,

      count(*) filter (
        where b.estado_compra = 'anulada'
      )
        as items_anulados,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'confirmada'
        ),
        0
      )::numeric(18,2)
        as base_fiscal_confirmada,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'confirmada'
        ),
        0
      )::numeric(18,2)
        as iva_confirmado,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'confirmada'
            and b.iva_tratamiento = 'computable'
        ),
        0
      )::numeric(18,2)
        as credito_fiscal_computable,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'confirmada'
            and b.iva_tratamiento = 'no_computable'
        ),
        0
      )::numeric(18,2)
        as iva_no_computable,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'confirmada'
            and b.iva_tratamiento = 'exento'
        ),
        0
      )::numeric(18,2)
        as base_exenta,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'confirmada'
            and b.iva_tratamiento = 'no_gravado'
        ),
        0
      )::numeric(18,2)
        as base_no_gravada,

      count(*) filter (
        where b.estado_compra = 'confirmada'
          and b.iva_tratamiento is null
      )
        as items_historicos_sin_clasificar,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'confirmada'
            and b.iva_tratamiento is null
        ),
        0
      )::numeric(18,2)
        as base_historica_sin_clasificar,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'confirmada'
            and b.iva_tratamiento is null
        ),
        0
      )::numeric(18,2)
        as iva_historico_sin_clasificar,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'anulada'
        ),
        0
      )::numeric(18,2)
        as base_fiscal_anulada,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'anulada'
        ),
        0
      )::numeric(18,2)
        as iva_anulado

    from base b
    group by b.moneda
  ),

  por_tratamiento as (
    select
      b.moneda,
      b.iva_clasificacion,

      count(*)
        as cantidad_items,

      count(distinct b.compra_id)
        as cantidad_compras,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'confirmada'
        ),
        0
      )::numeric(18,2)
        as base_confirmada,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'confirmada'
        ),
        0
      )::numeric(18,2)
        as iva_confirmado,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'anulada'
        ),
        0
      )::numeric(18,2)
        as base_anulada,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'anulada'
        ),
        0
      )::numeric(18,2)
        as iva_anulado

    from base b
    group by
      b.moneda,
      b.iva_clasificacion
  ),

  por_alicuota as (
    select
      b.moneda,
      b.iva_clasificacion,
      b.iva_alicuota_codigo,
      b.iva_porcentaje,

      count(*)
        as cantidad_items,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'confirmada'
        ),
        0
      )::numeric(18,2)
        as base_confirmada,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'confirmada'
        ),
        0
      )::numeric(18,2)
        as iva_confirmado,

      coalesce(
        sum(b.iva_base_fiscal) filter (
          where b.estado_compra = 'anulada'
        ),
        0
      )::numeric(18,2)
        as base_anulada,

      coalesce(
        sum(b.impuesto_importe) filter (
          where b.estado_compra = 'anulada'
        ),
        0
      )::numeric(18,2)
        as iva_anulado

    from base b
    group by
      b.moneda,
      b.iva_clasificacion,
      b.iva_alicuota_codigo,
      b.iva_porcentaje
  ),

  pagina as (
    select b.*
    from base b
    order by
      b.fecha_compra desc,
      b.numero_compra desc,
      b.orden asc,
      b.item_id
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
      'estado_compra',
        v_estado,
      'iva_tratamiento',
        v_tratamiento,
      'iva_alicuota_codigo',
        p_iva_alicuota_codigo,
      'proveedor_id',
        p_proveedor_id,
      'busqueda',
        v_busqueda,
      'limite',
        v_limite,
      'offset',
        v_offset
    ),

    'cantidad_compras',
    (
      select count(distinct compra_id)
      from base
    ),

    'cantidad_items',
    (
      select count(*)
      from base
    ),

    'cantidad_items_clasificados',
    (
      select count(*)
      from base
      where iva_tratamiento is not null
    ),

    'cantidad_items_historicos_sin_clasificar',
    (
      select count(*)
      from base
      where iva_tratamiento is null
    ),

    'advertencias',
    jsonb_build_object(
      'historicos_sin_clasificar',
        (
          select count(*)
          from base
          where iva_tratamiento is null
        ),
      'mensaje_historicos',
        case
          when exists (
            select 1
            from base
            where iva_tratamiento is null
          ) then
            'Existen ítems históricos sin clasificación fiscal. Su IVA se informa por separado y NO se considera crédito fiscal computable automáticamente.'
          else
            null
        end
    ),

    'resumen_por_moneda',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'moneda',
              r.moneda,
            'cantidad_compras',
              r.cantidad_compras,
            'cantidad_items',
              r.cantidad_items,
            'items_confirmados',
              r.items_confirmados,
            'items_anulados',
              r.items_anulados,
            'base_fiscal_confirmada',
              r.base_fiscal_confirmada,
            'iva_confirmado',
              r.iva_confirmado,
            'credito_fiscal_computable',
              r.credito_fiscal_computable,
            'iva_no_computable',
              r.iva_no_computable,
            'base_exenta',
              r.base_exenta,
            'base_no_gravada',
              r.base_no_gravada,
            'items_historicos_sin_clasificar',
              r.items_historicos_sin_clasificar,
            'base_historica_sin_clasificar',
              r.base_historica_sin_clasificar,
            'iva_historico_sin_clasificar',
              r.iva_historico_sin_clasificar,
            'base_fiscal_anulada',
              r.base_fiscal_anulada,
            'iva_anulado',
              r.iva_anulado
          )
          order by r.moneda
        ),
        '[]'::jsonb
      )
      from resumen_moneda r
    ),

    'por_tratamiento',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'moneda',
              t.moneda,
            'clasificacion',
              t.iva_clasificacion,
            'cantidad_items',
              t.cantidad_items,
            'cantidad_compras',
              t.cantidad_compras,
            'base_confirmada',
              t.base_confirmada,
            'iva_confirmado',
              t.iva_confirmado,
            'base_anulada',
              t.base_anulada,
            'iva_anulado',
              t.iva_anulado
          )
          order by
            t.moneda,
            t.iva_clasificacion
        ),
        '[]'::jsonb
      )
      from por_tratamiento t
    ),

    'por_alicuota',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'moneda',
              a.moneda,
            'clasificacion',
              a.iva_clasificacion,
            'codigo_arca',
              a.iva_alicuota_codigo,
            'alicuota',
              a.iva_porcentaje,
            'cantidad_items',
              a.cantidad_items,
            'base_confirmada',
              a.base_confirmada,
            'iva_confirmado',
              a.iva_confirmado,
            'base_anulada',
              a.base_anulada,
            'iva_anulado',
              a.iva_anulado
          )
          order by
            a.moneda,
            a.iva_porcentaje,
            a.iva_clasificacion
        ),
        '[]'::jsonb
      )
      from por_alicuota a
    ),

    'registros',
    (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'item_id',
              p.item_id,
            'compra_id',
              p.compra_id,
            'comercio_id',
              p.comercio_id,

            'numero_compra',
              p.numero_compra,
            'fecha_compra',
              p.fecha_compra,
            'fecha_vencimiento',
              p.fecha_vencimiento,
            'estado_compra',
              p.estado_compra,
            'estado_pago',
              p.estado_pago,
            'tipo_comprobante',
              p.tipo_comprobante,
            'numero_comprobante',
              p.numero_comprobante,
            'moneda',
              p.moneda,
            'descuento_general_porcentaje',
              p.descuento_general_porcentaje,
            'descuento_general_importe',
              p.descuento_general_importe,
            'compra_observaciones',
              p.compra_observaciones,

            'proveedor_id',
              p.proveedor_id,
            'proveedor_nombre',
              p.proveedor_nombre,
            'proveedor_razon_social',
              p.proveedor_razon_social,
            'proveedor_tipo_documento',
              p.proveedor_tipo_documento,
            'proveedor_documento',
              p.proveedor_documento,
            'proveedor_condicion_iva',
              p.proveedor_condicion_iva,

            'producto_id',
              p.producto_id,
            'item_tipo',
              p.item_tipo,
            'item_codigo',
              p.item_codigo,
            'item_nombre',
              p.item_nombre,
            'item_descripcion',
              p.item_descripcion,
            'unidad_medida',
              p.unidad_medida,
            'cantidad',
              p.cantidad,
            'costo_unitario',
              p.costo_unitario,
            'descuento_porcentaje',
              p.descuento_porcentaje,
            'subtotal',
              p.subtotal,
            'descuento_importe',
              p.descuento_importe,
            'neto',
              p.neto,

            'iva_tratamiento',
              p.iva_tratamiento,
            'iva_clasificacion',
              p.iva_clasificacion,
            'iva_alicuota_codigo',
              p.iva_alicuota_codigo,
            'iva_porcentaje',
              p.iva_porcentaje,
            'iva_base_fiscal',
              p.iva_base_fiscal,
            'impuesto_importe',
              p.impuesto_importe,
            'total_item',
              p.total_item,

            'afecta_stock',
              p.afecta_stock,
            'orden',
              p.orden,
            'item_created_at',
              p.item_created_at,
            'compra_created_at',
              p.compra_created_at,
            'compra_updated_at',
              p.compra_updated_at
          )
          order by
            p.fecha_compra desc,
            p.numero_compra desc,
            p.orden asc,
            p.item_id
        ),
        '[]'::jsonb
      )
      from pagina p
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
  'obtener_reporte_iva_compras',
  'reportes.ver',
  'argumento_comercio',
  array[
    'p_comercio_id'
  ],
  null,
  'id',
  'comercio_id',
  true,
  'Reporte de IVA en compras para exportaciones y paquete contador',
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

-- ============================================================
-- 3. INSTALAR GUARDIA GENÉRICA
-- ============================================================

do $$
declare
  v_resultado jsonb;
begin
  v_resultado :=
    public.instalar_guardia_rpc_drito(
      'obtener_reporte_iva_compras'
    );

  if coalesce(
    (
      v_resultado ->
        'instaladas'
    )::text::integer,
    0
  ) < 1 then
    raise exception
      'No se pudo instalar la guardia del reporte IVA Compras: %',
      v_resultado;
  end if;
end;
$$;

-- ============================================================
-- 4. COMENTARIO FUNCIONAL
-- ============================================================

comment on function
public.obtener_reporte_iva_compras(
  uuid,
  date,
  date,
  text,
  text,
  smallint,
  uuid,
  text,
  integer,
  integer
)
is
'DRITO_GUARDIA_PERMISO:reportes.ver | Reporte IVA Compras de solo lectura. Mantiene monedas separadas, conserva anuladas y no clasifica automáticamente históricos.';

notify pgrst, 'reload schema';

commit;

-- ============================================================
-- FIN PASO 14A.3
-- Archivo obligatorio en repo:
--   supabase/55_paso14a3_reporte_iva_compras.sql
-- ============================================================
