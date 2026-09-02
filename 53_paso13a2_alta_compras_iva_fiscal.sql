-- ============================================================
-- DRITO
-- PASO 13A.2 - ALTA DE COMPRAS CON TRATAMIENTO FISCAL DE IVA
-- Archivo: 53_paso13a2_alta_compras_iva_fiscal.sql
--
-- Objetivo:
--   Extender el motor real de crear_compra(...) sin cambiar su
--   firma pública ni romper crear_compra_con_percepciones(...).
--
-- Compatibilidad:
--   - Si p_items NO envía iva_tratamiento, se conserva exactamente
--     el cálculo histórico de compras.
--   - Si se informa tratamiento fiscal, TODOS los ítems de la compra
--     deben estar clasificados.
--   - El código ARCA se valida contra arca_alicuotas_iva.
--   - iva_base_fiscal se calcula en backend; no se confía en un valor
--     recibido desde frontend.
--
-- Regla para compras fiscalmente clasificadas:
--   neto línea
--   - descuento general proporcional
--   = base fiscal IVA
--
--   base fiscal IVA
--   + IVA de la línea
--   = total fiscal de la línea
--
--   subtotal
--   - descuento_items
--   - descuento_general_importe
--   + impuestos
--   = total comercial
--
-- Caja:
--   No se modifica. Crear una compra no registra un pago.
--
-- Percepciones:
--   crear_compra_con_percepciones(...) continúa reutilizando
--   crear_compra(...), por lo que hereda este soporte fiscal.
-- ============================================================

begin;

-- ============================================================
-- 1. PRECONDICIONES
-- ============================================================

do $$
begin
  if to_regprocedure(
    'public.__drito_original_crear_compra_f52f1a839b(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb)'
  ) is null then
    raise exception
      'No existe el motor interno esperado de crear_compra';
  end if;

  if to_regprocedure(
    'public.crear_compra(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb)'
  ) is null then
    raise exception
      'No existe public.crear_compra con la firma esperada';
  end if;

  if to_regprocedure(
    'public.crear_compra_con_percepciones(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb,jsonb)'
  ) is null then
    raise exception
      'No existe public.crear_compra_con_percepciones con la firma esperada';
  end if;

  if to_regclass('public.arca_alicuotas_iva') is null then
    raise exception
      'No existe public.arca_alicuotas_iva';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'items_compra'
      and column_name = 'iva_tratamiento'
  ) then
    raise exception
      'Primero debe ejecutarse la migración 52';
  end if;
end;
$$;

-- ============================================================
-- 2. MOTOR INTERNO DE CREACIÓN DE COMPRA
-- ============================================================

create or replace function public.__drito_original_crear_compra_f52f1a839b(
  p_comercio_id uuid,
  p_proveedor_id uuid,
  p_fecha_compra date,
  p_fecha_vencimiento date,
  p_tipo_comprobante text,
  p_numero_comprobante text,
  p_moneda text,
  p_descuento_general_porcentaje numeric,
  p_observaciones text,
  p_actualizar_costos boolean,
  p_items jsonb
)
returns table(
  compra_id uuid,
  numero_compra bigint,
  total_compra numeric,
  movimientos_generados integer,
  cantidad_total_ingresada numeric
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_item jsonb;
  v_producto public.productos%rowtype;

  v_proveedor_comercio_id uuid;
  v_proveedor_activo boolean;

  v_compra_id uuid;
  v_numero_compra bigint;

  v_producto_id uuid;

  v_cantidad numeric(14,3);
  v_costo_unitario numeric(14,2);

  v_descuento_porcentaje numeric(5,2);
  v_iva_porcentaje numeric(7,4);

  v_iva_tratamiento text;
  v_iva_alicuota_codigo smallint;
  v_iva_catalogo_porcentaje numeric;
  v_iva_catalogo_activo boolean;

  v_subtotal_linea numeric(14,2);
  v_descuento_linea numeric(14,2);
  v_neto_linea numeric(14,2);

  v_iva_base_fiscal numeric(14,2);
  v_descuento_general_linea numeric(14,2);

  v_impuesto_linea numeric(14,2);
  v_total_linea numeric(14,2);

  v_subtotal numeric(14,2) := 0;
  v_descuento_items numeric(14,2) := 0;
  v_impuestos numeric(14,2) := 0;

  v_total_antes_descuento numeric(14,2);

  v_descuento_general_porcentaje numeric(5,2);
  v_descuento_general_importe numeric(14,2) := 0;

  v_total_compra numeric(14,2);

  v_stock_anterior numeric(14,3);
  v_stock_posterior numeric(14,3);

  v_movimientos_generados integer := 0;
  v_cantidad_total_ingresada numeric(14,3) := 0;

  v_orden integer := 0;
  v_tipo_comprobante text;

  v_items_total integer;
  v_items_clasificados integer;
  v_modo_fiscal boolean := false;
begin

  -- ==========================================================
  -- AUTENTICACIÓN / COMERCIO
  -- ==========================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;

  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;

  if not public.pertenece_a_comercio(
    p_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  -- ==========================================================
  -- PROVEEDOR
  -- ==========================================================

  if p_proveedor_id is null then
    raise exception
      'El proveedor es obligatorio';
  end if;

  select
    pr.comercio_id,
    pr.activo
  into
    v_proveedor_comercio_id,
    v_proveedor_activo
  from public.proveedores as pr
  where pr.id = p_proveedor_id;

  if not found then
    raise exception
      'Proveedor no encontrado';
  end if;

  if v_proveedor_comercio_id <> p_comercio_id then
    raise exception
      'El proveedor no pertenece al comercio';
  end if;

  if v_proveedor_activo = false then
    raise exception
      'El proveedor se encuentra inactivo';
  end if;

  -- ==========================================================
  -- FECHAS
  -- ==========================================================

  if p_fecha_compra is null then
    raise exception
      'La fecha de compra es obligatoria';
  end if;

  if p_fecha_compra > current_date then
    raise exception
      'La fecha de compra no puede ser futura';
  end if;

  if (
    p_fecha_vencimiento is not null
    and p_fecha_vencimiento < p_fecha_compra
  ) then
    raise exception
      'La fecha de vencimiento no puede ser anterior a la compra';
  end if;

  -- ==========================================================
  -- COMPROBANTE
  -- ==========================================================

  v_tipo_comprobante :=
    lower(
      trim(
        coalesce(
          p_tipo_comprobante,
          'factura'
        )
      )
    );

  if v_tipo_comprobante not in (
    'factura',
    'remito',
    'ticket',
    'recibo',
    'otro'
  ) then
    raise exception
      'El tipo de comprobante es inválido';
  end if;

  -- ==========================================================
  -- DESCUENTO GENERAL
  -- ==========================================================

  v_descuento_general_porcentaje :=
    round(
      coalesce(
        p_descuento_general_porcentaje,
        0
      ),
      2
    );

  if (
    v_descuento_general_porcentaje < 0
    or v_descuento_general_porcentaje > 100
  ) then
    raise exception
      'El descuento general debe estar entre 0 y 100';
  end if;

  -- ==========================================================
  -- ÍTEMS
  -- ==========================================================

  if (
    p_items is null
    or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) = 0
  ) then
    raise exception
      'La compra debe contener al menos un artículo';
  end if;

  v_items_total :=
    jsonb_array_length(p_items);

  select count(*)
  into v_items_clasificados
  from jsonb_array_elements(p_items)
    as elemento(value)
  where nullif(
    trim(
      coalesce(
        elemento.value ->> 'iva_tratamiento',
        ''
      )
    ),
    ''
  ) is not null;

  if (
    v_items_clasificados > 0
    and v_items_clasificados <> v_items_total
  ) then
    raise exception
      'Si se informa tratamiento fiscal de IVA, todos los artículos de la compra deben estar clasificados';
  end if;

  v_modo_fiscal :=
    v_items_clasificados = v_items_total;

  -- No permitimos repetir un artículo en varias líneas.

  if exists (
    select 1
    from jsonb_array_elements(p_items)
      as elemento(value)
    group by (
      elemento.value
      ->> 'producto_id'
    )
    having count(*) > 1
  ) then
    raise exception
      'Un mismo artículo no puede aparecer más de una vez';
  end if;

  -- ==========================================================
  -- VALIDAR Y BLOQUEAR PRODUCTOS + IVA
  -- ==========================================================

  for v_item in
    select elemento.value
    from jsonb_array_elements(p_items)
      as elemento(value)
  loop

    if nullif(
      trim(
        coalesce(
          v_item ->> 'producto_id',
          ''
        )
      ),
      ''
    ) is null then
      raise exception
        'Todos los artículos deben estar vinculados a un producto o servicio';
    end if;

    begin
      v_producto_id :=
        (
          v_item
          ->> 'producto_id'
        )::uuid;
    exception
      when invalid_text_representation then
        raise exception
          'Uno de los artículos tiene un identificador inválido';
    end;

    select p.*
    into v_producto
    from public.productos as p
    where p.id = v_producto_id
    for update;

    if not found then
      raise exception
        'Uno de los artículos no existe';
    end if;

    if v_producto.comercio_id <> p_comercio_id then
      raise exception
        'Uno de los artículos pertenece a otro comercio';
    end if;

    if v_producto.activo = false then
      raise exception
        'El artículo "%" se encuentra inactivo',
        v_producto.nombre;
    end if;

    v_cantidad :=
      coalesce(
        nullif(
          v_item ->> 'cantidad',
          ''
        )::numeric,
        0
      );

    if v_cantidad <= 0 then
      raise exception
        'La cantidad de "%" debe ser mayor que cero',
        v_producto.nombre;
    end if;

    v_costo_unitario :=
      coalesce(
        nullif(
          v_item ->> 'costo_unitario',
          ''
        )::numeric,
        v_producto.costo,
        0
      );

    if v_costo_unitario < 0 then
      raise exception
        'El costo de "%" no puede ser negativo',
        v_producto.nombre;
    end if;

    v_descuento_porcentaje :=
      coalesce(
        nullif(
          v_item
          ->> 'descuento_porcentaje',
          ''
        )::numeric,
        0
      );

    if (
      v_descuento_porcentaje < 0
      or v_descuento_porcentaje > 100
    ) then
      raise exception
        'El descuento de "%" es inválido',
        v_producto.nombre;
    end if;

    v_iva_porcentaje :=
      coalesce(
        nullif(
          v_item
          ->> 'iva_porcentaje',
          ''
        )::numeric,
        v_producto.iva_porcentaje,
        0
      );

    if (
      v_iva_porcentaje < 0
      or v_iva_porcentaje > 100
    ) then
      raise exception
        'El IVA de "%" es inválido',
        v_producto.nombre;
    end if;

    if v_modo_fiscal then

      v_iva_tratamiento :=
        lower(
          trim(
            v_item ->> 'iva_tratamiento'
          )
        );

      if v_iva_tratamiento not in (
        'computable',
        'no_computable',
        'exento',
        'no_gravado'
      ) then
        raise exception
          'Tratamiento de IVA inválido para "%"',
          v_producto.nombre;
      end if;

      if v_iva_tratamiento in (
        'exento',
        'no_gravado'
      ) then

        if v_iva_porcentaje <> 0 then
          raise exception
            'El artículo "%" con tratamiento % debe tener IVA 0%%',
            v_producto.nombre,
            v_iva_tratamiento;
        end if;

        if nullif(
          trim(
            coalesce(
              v_item ->> 'iva_alicuota_codigo',
              ''
            )
          ),
          ''
        ) is not null then
          raise exception
            'El artículo "%" con tratamiento % no debe indicar código de alícuota IVA',
            v_producto.nombre,
            v_iva_tratamiento;
        end if;

      else

        if nullif(
          trim(
            coalesce(
              v_item ->> 'iva_alicuota_codigo',
              ''
            )
          ),
          ''
        ) is null then
          raise exception
            'El artículo "%" debe indicar código de alícuota IVA',
            v_producto.nombre;
        end if;

        begin
          v_iva_alicuota_codigo :=
            (
              v_item
              ->> 'iva_alicuota_codigo'
            )::smallint;
        exception
          when invalid_text_representation
            or numeric_value_out_of_range then
            raise exception
              'Código de alícuota IVA inválido para "%"',
              v_producto.nombre;
        end;

        select
          a.porcentaje,
          a.activo
        into
          v_iva_catalogo_porcentaje,
          v_iva_catalogo_activo
        from public.arca_alicuotas_iva as a
        where a.codigo = v_iva_alicuota_codigo;

        if not found then
          raise exception
            'Código de alícuota IVA inexistente para "%"',
            v_producto.nombre;
        end if;

        if v_iva_catalogo_activo is not true then
          raise exception
            'La alícuota IVA de "%" se encuentra inactiva',
            v_producto.nombre;
        end if;

        if v_iva_catalogo_porcentaje is null then
          raise exception
            'La alícuota IVA de "%" no posee porcentaje',
            v_producto.nombre;
        end if;

        if round(v_iva_catalogo_porcentaje, 4)
           <> round(v_iva_porcentaje, 4) then
          raise exception
            'La alícuota IVA de "%" no coincide con el código ARCA seleccionado',
            v_producto.nombre;
        end if;

      end if;

    end if;

  end loop;

  -- ==========================================================
  -- GENERAR NÚMERO DE COMPRA
  -- ==========================================================

  insert into public.compra_contadores (
    comercio_id,
    ultimo_numero,
    updated_at
  )
  values (
    p_comercio_id,
    1,
    now()
  )
  on conflict (comercio_id)
  do update set
    ultimo_numero =
      public.compra_contadores.ultimo_numero + 1,
    updated_at = now()
  returning ultimo_numero
  into v_numero_compra;

  -- ==========================================================
  -- CREAR CABECERA
  -- ==========================================================

  insert into public.compras (
    comercio_id,
    proveedor_id,
    numero,
    estado,
    estado_pago,
    fecha_compra,
    fecha_vencimiento,
    tipo_comprobante,
    numero_comprobante,
    moneda,
    subtotal,
    descuento_items,
    descuento_general_porcentaje,
    descuento_general_importe,
    impuestos,
    total,
    total_pagado,
    observaciones,
    creado_por
  )
  values (
    p_comercio_id,
    p_proveedor_id,
    v_numero_compra,
    'confirmada',
    'pendiente',
    p_fecha_compra,
    p_fecha_vencimiento,
    v_tipo_comprobante,

    nullif(
      trim(
        coalesce(
          p_numero_comprobante,
          ''
        )
      ),
      ''
    ),

    coalesce(
      nullif(
        trim(
          coalesce(
            p_moneda,
            ''
          )
        ),
        ''
      ),
      'ARS'
    ),

    0,
    0,
    v_descuento_general_porcentaje,
    0,
    0,
    0,
    0,

    nullif(
      trim(
        coalesce(
          p_observaciones,
          ''
        )
      ),
      ''
    ),

    auth.uid()
  )
  returning id
  into v_compra_id;

  -- ==========================================================
  -- CREAR ÍTEMS, COSTOS Y STOCK
  -- ==========================================================

  for v_item in
    select elemento.value
    from jsonb_array_elements(p_items)
      as elemento(value)
  loop

    v_orden := v_orden + 1;

    v_producto_id :=
      (
        v_item
        ->> 'producto_id'
      )::uuid;

    select p.*
    into v_producto
    from public.productos as p
    where p.id = v_producto_id;

    v_cantidad :=
      (
        v_item
        ->> 'cantidad'
      )::numeric;

    v_costo_unitario :=
      coalesce(
        nullif(
          v_item
          ->> 'costo_unitario',
          ''
        )::numeric,
        v_producto.costo,
        0
      );

    v_descuento_porcentaje :=
      coalesce(
        nullif(
          v_item
          ->> 'descuento_porcentaje',
          ''
        )::numeric,
        0
      );

    v_iva_porcentaje :=
      coalesce(
        nullif(
          v_item
          ->> 'iva_porcentaje',
          ''
        )::numeric,
        v_producto.iva_porcentaje,
        0
      );

    v_subtotal_linea :=
      round(
        v_cantidad
        * v_costo_unitario,
        2
      );

    v_descuento_linea :=
      round(
        v_subtotal_linea
        * v_descuento_porcentaje
        / 100,
        2
      );

    v_neto_linea :=
      v_subtotal_linea
      - v_descuento_linea;

    -- ========================================================
    -- CÁLCULO FISCAL / LEGACY
    -- ========================================================

    if v_modo_fiscal then

      v_iva_tratamiento :=
        lower(
          trim(
            v_item ->> 'iva_tratamiento'
          )
        );

      if v_iva_tratamiento in (
        'computable',
        'no_computable'
      ) then
        v_iva_alicuota_codigo :=
          (
            v_item
            ->> 'iva_alicuota_codigo'
          )::smallint;
      else
        v_iva_alicuota_codigo := null;
      end if;

      v_iva_base_fiscal :=
        round(
          v_neto_linea
          * (
            100
            - v_descuento_general_porcentaje
          )
          / 100,
          2
        );

      v_descuento_general_linea :=
        v_neto_linea
        - v_iva_base_fiscal;

      if v_iva_tratamiento in (
        'exento',
        'no_gravado'
      ) then
        v_impuesto_linea := 0;
      else
        v_impuesto_linea :=
          round(
            v_iva_base_fiscal
            * v_iva_porcentaje
            / 100,
            2
          );
      end if;

      v_total_linea :=
        v_iva_base_fiscal
        + v_impuesto_linea;

      v_descuento_general_importe :=
        v_descuento_general_importe
        + v_descuento_general_linea;

    else

      -- Compatibilidad histórica exacta.
      v_iva_tratamiento := null;
      v_iva_alicuota_codigo := null;
      v_iva_base_fiscal := v_neto_linea;

      v_impuesto_linea :=
        round(
          v_neto_linea
          * v_iva_porcentaje
          / 100,
          2
        );

      v_total_linea :=
        v_neto_linea
        + v_impuesto_linea;

    end if;

    insert into public.items_compra (
      compra_id,
      comercio_id,
      producto_id,
      tipo,
      codigo,
      nombre,
      descripcion,
      unidad_medida,
      cantidad,
      costo_unitario,
      descuento_porcentaje,
      iva_porcentaje,
      subtotal,
      descuento_importe,
      neto,
      impuesto_importe,
      total,
      afecta_stock,
      orden,
      iva_tratamiento,
      iva_alicuota_codigo,
      iva_base_fiscal
    )
    values (
      v_compra_id,
      p_comercio_id,
      v_producto.id,
      v_producto.tipo,
      v_producto.codigo,
      v_producto.nombre,
      v_producto.descripcion,
      v_producto.unidad_medida,
      v_cantidad,
      v_costo_unitario,
      v_descuento_porcentaje,
      v_iva_porcentaje,
      v_subtotal_linea,
      v_descuento_linea,
      v_neto_linea,
      v_impuesto_linea,
      v_total_linea,

      (
        v_producto.tipo = 'producto'
        and v_producto.controla_stock = true
      ),

      v_orden,
      v_iva_tratamiento,
      v_iva_alicuota_codigo,
      v_iva_base_fiscal
    );

    v_subtotal :=
      v_subtotal
      + v_subtotal_linea;

    v_descuento_items :=
      v_descuento_items
      + v_descuento_linea;

    v_impuestos :=
      v_impuestos
      + v_impuesto_linea;

    -- Actualizar costo actual del artículo.

    if coalesce(
      p_actualizar_costos,
      true
    ) then
      update public.productos as p
      set
        costo = v_costo_unitario
      where p.id = v_producto.id;
    end if;

    -- Ingreso automático de stock.

    if (
      v_producto.tipo = 'producto'
      and v_producto.controla_stock = true
    ) then

      v_stock_anterior :=
        v_producto.stock_actual;

      v_stock_posterior :=
        v_stock_anterior
        + v_cantidad;

      update public.productos as p
      set
        stock_actual = v_stock_posterior
      where p.id = v_producto.id;

      insert into public.movimientos_stock (
        comercio_id,
        producto_id,
        tipo,
        cantidad,
        stock_anterior,
        stock_posterior,
        motivo,
        referencia_tipo,
        referencia_id,
        creado_por
      )
      values (
        p_comercio_id,
        v_producto.id,
        'entrada',
        v_cantidad,
        v_stock_anterior,
        v_stock_posterior,

        format(
          'Ingreso por compra COM-%s',
          lpad(
            v_numero_compra::text,
            6,
            '0'
          )
        ),

        'compra',
        v_compra_id,
        auth.uid()
      );

      v_movimientos_generados :=
        v_movimientos_generados + 1;

      v_cantidad_total_ingresada :=
        v_cantidad_total_ingresada
        + v_cantidad;
    end if;

  end loop;

  -- ==========================================================
  -- CALCULAR TOTALES
  -- ==========================================================

  if v_modo_fiscal then

    -- En modo fiscal el descuento general ya fue distribuido
    -- proporcionalmente sobre la base de cada ítem.
    v_descuento_general_importe :=
      round(
        v_descuento_general_importe,
        2
      );

    v_total_compra :=
      greatest(
        round(
          v_subtotal
          - v_descuento_items
          - v_descuento_general_importe
          + v_impuestos,
          2
        ),
        0
      );

  else

    -- Compatibilidad histórica exacta.
    v_total_antes_descuento :=
      v_subtotal
      - v_descuento_items
      + v_impuestos;

    v_descuento_general_importe :=
      round(
        v_total_antes_descuento
        * v_descuento_general_porcentaje
        / 100,
        2
      );

    v_total_compra :=
      greatest(
        v_total_antes_descuento
        - v_descuento_general_importe,
        0
      );

  end if;

  update public.compras as c
  set
    subtotal = v_subtotal,
    descuento_items = v_descuento_items,

    descuento_general_porcentaje =
      v_descuento_general_porcentaje,

    descuento_general_importe =
      v_descuento_general_importe,

    impuestos = v_impuestos,
    total = v_total_compra,
    total_pagado = 0,
    estado_pago = 'pendiente'
  where c.id = v_compra_id;

  -- ==========================================================
  -- RESULTADO
  -- ==========================================================

  return query
  select
    v_compra_id,
    v_numero_compra,
    v_total_compra,
    v_movimientos_generados,
    v_cantidad_total_ingresada;

end;
$function$;

comment on function public.__drito_original_crear_compra_f52f1a839b(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb
) is
  'Motor interno de crear_compra. Desde paso 13A.2 admite tratamiento fiscal IVA por item dentro de p_items, preservando modo legacy cuando no se informa clasificación.';

-- ============================================================
-- 3. SEGURIDAD DEL MOTOR INTERNO
-- ============================================================

revoke all
on function public.__drito_original_crear_compra_f52f1a839b(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb
)
from public;

revoke all
on function public.__drito_original_crear_compra_f52f1a839b(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb
)
from anon;

revoke all
on function public.__drito_original_crear_compra_f52f1a839b(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb
)
from authenticated;

-- ============================================================
-- 4. ASSERTIONS DE COMPATIBILIDAD
-- ============================================================

do $$
begin

  if to_regprocedure(
    'public.crear_compra(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb)'
  ) is null then
    raise exception
      'Se perdió la firma pública de crear_compra';
  end if;

  if to_regprocedure(
    'public.crear_compra_con_percepciones(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb,jsonb)'
  ) is null then
    raise exception
      'Se perdió la firma pública de crear_compra_con_percepciones';
  end if;

  if not exists (
    select 1
    from public.rpc_permisos_drito
    where funcion_nombre = 'crear_compra'
      and permiso_codigo = 'compras.crear'
      and resolver_tipo = 'argumento_comercio'
      and activo = true
  ) then
    raise exception
      'La guardia de crear_compra dejó de estar activa';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.__drito_original_crear_compra_f52f1a839b(uuid,uuid,date,date,text,text,text,numeric,text,boolean,jsonb)',
    'EXECUTE'
  ) then
    raise exception
      'El motor interno de crear_compra no debe ser ejecutable directamente por authenticated';
  end if;

end;
$$;

commit;
s