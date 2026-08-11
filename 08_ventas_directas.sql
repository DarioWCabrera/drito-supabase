-- =====================================================
-- DRITO - VENTAS DIRECTAS
-- =====================================================

create or replace function public.crear_venta_directa(
  p_comercio_id uuid,
  p_cliente_id uuid,
  p_fecha_venta date,
  p_moneda text,
  p_descuento_general_porcentaje numeric,
  p_observaciones text,
  p_items jsonb,

  p_pago_inicial numeric default 0,
  p_medio_pago text default 'efectivo',
  p_referencia_pago text default null,
  p_observaciones_pago text default null
)
returns table (
  venta_id uuid,
  numero_venta bigint,
  total_venta numeric,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text,
  pago_id uuid,
  numero_pago bigint,
  movimientos_generados integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
  v_producto public.productos%rowtype;
  v_requerimiento record;

  v_venta_id uuid;
  v_numero_venta bigint;

  v_producto_id uuid;
  v_cantidad numeric(14,3);

  v_precio_unitario numeric(14,2);
  v_descuento_porcentaje numeric(5,2);
  v_iva_porcentaje numeric(5,2);

  v_subtotal_linea numeric(14,2);
  v_descuento_linea numeric(14,2);
  v_neto_linea numeric(14,2);
  v_impuesto_linea numeric(14,2);
  v_total_linea numeric(14,2);

  v_subtotal numeric(14,2) := 0;
  v_descuento_items numeric(14,2) := 0;
  v_impuestos numeric(14,2) := 0;

  v_descuento_general_porcentaje numeric(5,2);
  v_descuento_general_importe numeric(14,2);
  v_total_antes_descuento numeric(14,2);
  v_total_venta numeric(14,2);

  v_stock_anterior numeric(14,3);
  v_stock_posterior numeric(14,3);

  v_movimientos_generados integer := 0;
  v_orden integer := 0;

  v_pago_inicial numeric(14,2);

  v_pago_id uuid := null;
  v_numero_pago bigint := null;

  v_total_pagado numeric(14,2) := 0;
  v_saldo_pendiente numeric(14,2) := 0;
  v_estado_pago text := 'pendiente';

  v_comercio_cliente uuid;
begin
  -- ===================================================
  -- AUTENTICACIÓN Y COMERCIO
  -- ===================================================

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
      'El usuario no pertenece al comercio indicado';
  end if;

  -- ===================================================
  -- CLIENTE
  -- ===================================================

  if p_cliente_id is null then
    raise exception
      'El cliente es obligatorio';
  end if;

  select c.comercio_id
  into v_comercio_cliente
  from public.clientes as c
  where c.id = p_cliente_id
    and c.activo = true;

  if not found then
    raise exception
      'El cliente no existe o se encuentra inactivo';
  end if;

  if v_comercio_cliente <> p_comercio_id then
    raise exception
      'El cliente no pertenece al comercio';
  end if;

  -- ===================================================
  -- FECHA
  -- ===================================================

  if p_fecha_venta is null then
    raise exception
      'La fecha de venta es obligatoria';
  end if;

  if p_fecha_venta > current_date then
    raise exception
      'La fecha de venta no puede ser futura';
  end if;

  -- ===================================================
  -- ARTÍCULOS
  -- ===================================================

  if (
    p_items is null
    or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) = 0
  ) then
    raise exception
      'La venta debe contener al menos un artículo';
  end if;

  -- ===================================================
  -- DESCUENTO GENERAL
  -- ===================================================

  v_descuento_general_porcentaje :=
    coalesce(
      p_descuento_general_porcentaje,
      0
    );

  if (
    v_descuento_general_porcentaje < 0
    or v_descuento_general_porcentaje > 100
  ) then
    raise exception
      'El descuento general debe estar entre 0 y 100';
  end if;

  -- ===================================================
  -- PAGO INICIAL
  -- ===================================================

  v_pago_inicial :=
    round(
      coalesce(
        p_pago_inicial,
        0
      ),
      2
    );

  if v_pago_inicial < 0 then
    raise exception
      'El pago inicial no puede ser negativo';
  end if;

  -- ===================================================
  -- PRIMERA VALIDACIÓN DE LOS ÍTEMS
  -- ===================================================

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
        'Todos los artículos deben tener un producto o servicio';
    end if;

    begin
      v_producto_id :=
        (v_item ->> 'producto_id')::uuid;
    exception
      when invalid_text_representation then
        raise exception
          'Uno de los artículos tiene un identificador inválido';
    end;

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
        'Todas las cantidades deben ser mayores que cero';
    end if;

    v_descuento_porcentaje :=
      coalesce(
        nullif(
          v_item ->> 'descuento_porcentaje',
          ''
        )::numeric,
        0
      );

    if (
      v_descuento_porcentaje < 0
      or v_descuento_porcentaje > 100
    ) then
      raise exception
        'El descuento de uno de los artículos es inválido';
    end if;

    if nullif(
      v_item ->> 'iva_porcentaje',
      ''
    ) is not null then
      v_iva_porcentaje :=
        (v_item ->> 'iva_porcentaje')::numeric;

      if (
        v_iva_porcentaje < 0
        or v_iva_porcentaje > 100
      ) then
        raise exception
          'El IVA de uno de los artículos es inválido';
      end if;
    end if;

    if nullif(
      v_item ->> 'precio_unitario',
      ''
    ) is not null then
      v_precio_unitario :=
        (v_item ->> 'precio_unitario')::numeric;

      if v_precio_unitario < 0 then
        raise exception
          'El precio de uno de los artículos es inválido';
      end if;
    end if;
  end loop;

  -- ===================================================
  -- BLOQUEO Y VALIDACIÓN DEL STOCK
  -- ===================================================

  /*
    Agrupamos las cantidades por producto.

    De esta manera, si el mismo producto apareciera
    dos veces, se valida la cantidad total y no cada
    línea de forma aislada.
  */

  for v_requerimiento in
    select
      (
        elemento.value
        ->> 'producto_id'
      )::uuid as producto_id,

      sum(
        (
          elemento.value
          ->> 'cantidad'
        )::numeric
      )::numeric(14,3) as cantidad_requerida

    from jsonb_array_elements(p_items)
      as elemento(value)

    group by (
      elemento.value
      ->> 'producto_id'
    )::uuid

    order by (
      elemento.value
      ->> 'producto_id'
    )::uuid
  loop
    select p.*
    into v_producto
    from public.productos as p
    where p.id = v_requerimiento.producto_id
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

    if (
      v_producto.tipo = 'producto'
      and v_producto.controla_stock = true
      and v_producto.stock_actual
        < v_requerimiento.cantidad_requerida
    ) then
      raise exception
        'Stock insuficiente para "%". Disponible: %, requerido: %',
        v_producto.nombre,
        v_producto.stock_actual,
        v_requerimiento.cantidad_requerida;
    end if;
  end loop;

  -- ===================================================
  -- GENERAR NÚMERO DE VENTA
  -- ===================================================

  insert into public.venta_contadores (
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
      public.venta_contadores.ultimo_numero + 1,

    updated_at = now()

  returning ultimo_numero
  into v_numero_venta;

  -- ===================================================
  -- CREAR CABECERA DE LA VENTA
  -- ===================================================

  insert into public.ventas (
    comercio_id,
    cotizacion_id,
    cliente_id,
    numero,
    estado,
    estado_pago,
    fecha_venta,
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
    null,
    p_cliente_id,
    v_numero_venta,
    'confirmada',
    'pendiente',
    p_fecha_venta,

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
  into v_venta_id;

  -- ===================================================
  -- CREAR ÍTEMS Y CALCULAR TOTALES
  -- ===================================================

  for v_item in
    select elemento.value
    from jsonb_array_elements(p_items)
      as elemento(value)
  loop
    v_orden := v_orden + 1;

    v_producto_id :=
      (v_item ->> 'producto_id')::uuid;

    select p.*
    into v_producto
    from public.productos as p
    where p.id = v_producto_id;

    if not found then
      raise exception
        'Uno de los artículos dejó de estar disponible';
    end if;

    v_cantidad :=
      (
        v_item
        ->> 'cantidad'
      )::numeric;

    v_precio_unitario :=
      coalesce(
        nullif(
          v_item
          ->> 'precio_unitario',
          ''
        )::numeric,
        v_producto.precio_venta,
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
        * v_precio_unitario,
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

    insert into public.items_venta (
      venta_id,
      comercio_id,
      producto_id,
      tipo,
      codigo,
      nombre,
      descripcion,
      unidad_medida,
      cantidad,
      costo_unitario,
      precio_unitario,
      descuento_porcentaje,
      iva_porcentaje,
      subtotal,
      descuento_importe,
      neto,
      impuesto_importe,
      total,
      afecta_stock,
      orden
    )
    values (
      v_venta_id,
      p_comercio_id,
      v_producto.id,
      v_producto.tipo,
      v_producto.codigo,
      v_producto.nombre,
      v_producto.descripcion,
      v_producto.unidad_medida,
      v_cantidad,

      coalesce(
        v_producto.costo,
        0
      ),

      v_precio_unitario,
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

      v_orden
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
  end loop;

  -- ===================================================
  -- CALCULAR TOTAL GENERAL
  -- ===================================================

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

  v_total_venta :=
    greatest(
      v_total_antes_descuento
      - v_descuento_general_importe,
      0
    );

  if v_pago_inicial > v_total_venta then
    raise exception
      'El pago inicial supera el total de la venta. Total disponible: %',
      v_total_venta;
  end if;

  update public.ventas as v
  set
    subtotal = v_subtotal,
    descuento_items = v_descuento_items,
    descuento_general_porcentaje =
      v_descuento_general_porcentaje,
    descuento_general_importe =
      v_descuento_general_importe,
    impuestos = v_impuestos,
    total = v_total_venta
  where v.id = v_venta_id;

  -- ===================================================
  -- DESCONTAR STOCK
  -- ===================================================

  for v_requerimiento in
    select
      (
        elemento.value
        ->> 'producto_id'
      )::uuid as producto_id,

      sum(
        (
          elemento.value
          ->> 'cantidad'
        )::numeric
      )::numeric(14,3) as cantidad_requerida

    from jsonb_array_elements(p_items)
      as elemento(value)

    group by (
      elemento.value
      ->> 'producto_id'
    )::uuid

    order by (
      elemento.value
      ->> 'producto_id'
    )::uuid
  loop
    select p.*
    into v_producto
    from public.productos as p
    where p.id = v_requerimiento.producto_id;

    if (
      v_producto.tipo = 'producto'
      and v_producto.controla_stock = true
    ) then
      v_stock_anterior :=
        v_producto.stock_actual;

      v_stock_posterior :=
        v_stock_anterior
        - v_requerimiento.cantidad_requerida;

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
        'venta',
        v_requerimiento.cantidad_requerida,
        v_stock_anterior,
        v_stock_posterior,

        format(
          'Venta directa VTA-%s',
          lpad(
            v_numero_venta::text,
            6,
            '0'
          )
        ),

        'venta',
        v_venta_id,
        auth.uid()
      );

      v_movimientos_generados :=
        v_movimientos_generados + 1;
    end if;
  end loop;

  -- ===================================================
  -- REGISTRAR PAGO INICIAL OPCIONAL
  -- ===================================================

  if v_pago_inicial > 0 then
    select
      rp.pago_id,
      rp.numero_pago,
      rp.total_pagado,
      rp.saldo_pendiente,
      rp.estado_pago
    into
      v_pago_id,
      v_numero_pago,
      v_total_pagado,
      v_saldo_pendiente,
      v_estado_pago
    from public.registrar_pago_venta(
      v_venta_id,
      v_pago_inicial,
      p_fecha_venta,
      p_medio_pago,
      p_referencia_pago,
      p_observaciones_pago
    ) as rp;
  else
    v_pago_id := null;
    v_numero_pago := null;

    v_total_pagado := 0;
    v_saldo_pendiente := v_total_venta;
    v_estado_pago := 'pendiente';
  end if;

  -- ===================================================
  -- DEVOLVER RESULTADO
  -- ===================================================

  return query
  select
    v_venta_id,
    v_numero_venta,
    v_total_venta,
    v_total_pagado,
    v_saldo_pendiente,
    v_estado_pago,
    v_pago_id,
    v_numero_pago,
    v_movimientos_generados;
end;
$$;

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on function public.crear_venta_directa(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  jsonb,
  numeric,
  text,
  text,
  text
)
from public;

grant execute
on function public.crear_venta_directa(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  jsonb,
  numeric,
  text,
  text,
  text
)
to authenticated;