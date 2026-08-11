-- =====================================================
-- DRITO - VENTAS Y CONVERSIÓN DE COTIZACIONES
-- =====================================================

-- =====================================================
-- CONTADOR DE VENTAS POR COMERCIO
-- =====================================================

create table if not exists public.venta_contadores (
  comercio_id uuid primary key
    references public.comercios(id) on delete cascade,

  ultimo_numero bigint not null default 0
    check (ultimo_numero >= 0),

  updated_at timestamptz not null default now()
);

-- =====================================================
-- VENTAS
-- =====================================================

create table if not exists public.ventas (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  cotizacion_id uuid
    references public.cotizaciones(id) on delete restrict,

  cliente_id uuid not null
    references public.clientes(id) on delete restrict,

  numero bigint not null
    check (numero > 0),

  estado text not null default 'confirmada'
    check (
      estado in (
        'confirmada',
        'anulada'
      )
    ),

  estado_pago text not null default 'pendiente'
    check (
      estado_pago in (
        'pendiente',
        'parcial',
        'pagada'
      )
    ),

  fecha_venta date not null default current_date,

  moneda text not null default 'ARS',

  subtotal numeric(14,2) not null default 0
    check (subtotal >= 0),

  descuento_items numeric(14,2) not null default 0
    check (descuento_items >= 0),

  descuento_general_porcentaje numeric(5,2)
    not null default 0
    check (
      descuento_general_porcentaje >= 0
      and descuento_general_porcentaje <= 100
    ),

  descuento_general_importe numeric(14,2)
    not null default 0
    check (descuento_general_importe >= 0),

  impuestos numeric(14,2) not null default 0
    check (impuestos >= 0),

  total numeric(14,2) not null default 0
    check (total >= 0),

  total_pagado numeric(14,2) not null default 0
    check (total_pagado >= 0),

  observaciones text,

  creado_por uuid
    references auth.users(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (comercio_id, numero),
  unique (cotizacion_id),

  check (total_pagado <= total)
);

create index if not exists ventas_comercio_fecha_idx
on public.ventas (
  comercio_id,
  created_at desc
);

create index if not exists ventas_cliente_fecha_idx
on public.ventas (
  cliente_id,
  created_at desc
);

create index if not exists ventas_estado_idx
on public.ventas (
  comercio_id,
  estado
);

create index if not exists ventas_estado_pago_idx
on public.ventas (
  comercio_id,
  estado_pago
);

-- =====================================================
-- ÍTEMS DE VENTA
-- =====================================================

create table if not exists public.items_venta (
  id uuid primary key default gen_random_uuid(),

  venta_id uuid not null
    references public.ventas(id) on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  producto_id uuid
    references public.productos(id) on delete set null,

  tipo text not null default 'producto'
    check (
      tipo in (
        'producto',
        'servicio'
      )
    ),

  codigo text,

  nombre text not null
    check (char_length(trim(nombre)) >= 2),

  descripcion text,

  unidad_medida text not null default 'unidad',

  cantidad numeric(14,3) not null
    check (cantidad > 0),

  costo_unitario numeric(14,2) not null default 0
    check (costo_unitario >= 0),

  precio_unitario numeric(14,2) not null
    check (precio_unitario >= 0),

  descuento_porcentaje numeric(5,2)
    not null default 0
    check (
      descuento_porcentaje >= 0
      and descuento_porcentaje <= 100
    ),

  iva_porcentaje numeric(5,2)
    not null default 0
    check (
      iva_porcentaje >= 0
      and iva_porcentaje <= 100
    ),

  subtotal numeric(14,2) not null
    check (subtotal >= 0),

  descuento_importe numeric(14,2)
    not null default 0
    check (descuento_importe >= 0),

  neto numeric(14,2) not null
    check (neto >= 0),

  impuesto_importe numeric(14,2)
    not null default 0
    check (impuesto_importe >= 0),

  total numeric(14,2) not null
    check (total >= 0),

  afecta_stock boolean not null default false,

  orden integer not null default 0,

  created_at timestamptz not null default now()
);

create index if not exists items_venta_venta_idx
on public.items_venta (
  venta_id,
  orden
);

create index if not exists items_venta_producto_idx
on public.items_venta (
  producto_id
);

-- =====================================================
-- UPDATED_AT
-- =====================================================

drop trigger if exists ventas_updated_at
on public.ventas;

create trigger ventas_updated_at
before update on public.ventas
for each row
execute function public.actualizar_updated_at();

-- =====================================================
-- CONVERTIR COTIZACIÓN EN VENTA
-- =====================================================

create or replace function public.convertir_cotizacion_en_venta(
  p_cotizacion_id uuid,
  p_fecha_venta date default current_date,
  p_observaciones text default null
)
returns table (
  venta_id uuid,
  numero bigint,
  total numeric,
  movimientos_generados integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cotizacion public.cotizaciones%rowtype;
  v_producto public.productos%rowtype;

  v_requerimiento record;

  v_venta_id uuid;
  v_numero bigint;

  v_stock_anterior numeric(14,3);
  v_stock_posterior numeric(14,3);

  v_movimientos_generados integer := 0;
  v_cantidad_items integer := 0;
begin
  -- ===================================================
  -- VALIDACIONES GENERALES
  -- ===================================================

  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_cotizacion_id is null then
    raise exception
      'La cotización es obligatoria';
  end if;

  if p_fecha_venta is null then
    raise exception
      'La fecha de venta es obligatoria';
  end if;

  -- Bloquear la cotización para evitar que dos usuarios
  -- la conviertan al mismo tiempo.

  select *
  into v_cotizacion
  from public.cotizaciones
  where id = p_cotizacion_id
  for update;

  if not found then
    raise exception
      'Cotización no encontrada';
  end if;

  if not public.pertenece_a_comercio(
    v_cotizacion.comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  if v_cotizacion.estado = 'convertida' then
    raise exception
      'La cotización ya fue convertida en venta';
  end if;

  if v_cotizacion.estado <> 'aceptada' then
    raise exception
      'Solo se puede convertir una cotización aceptada';
  end if;

  if p_fecha_venta < v_cotizacion.fecha_emision then
    raise exception
      'La fecha de venta no puede ser anterior a la cotización';
  end if;

  -- Verificar que el cliente siga perteneciendo
  -- al comercio.

  if not exists (
    select 1
    from public.clientes c
    where c.id = v_cotizacion.cliente_id
      and c.comercio_id = v_cotizacion.comercio_id
  ) then
    raise exception
      'El cliente no pertenece al comercio';
  end if;

  select count(*)
  into v_cantidad_items
  from public.items_cotizacion
  where cotizacion_id = p_cotizacion_id;

  if v_cantidad_items = 0 then
    raise exception
      'La cotización no contiene artículos';
  end if;

  -- ===================================================
  -- VALIDACIÓN Y BLOQUEO DEL STOCK
  -- ===================================================

  /*
    Se agrupan las cantidades por producto.

    Esto evita que dos líneas del mismo producto puedan
    superar el stock disponible al evaluarse por separado.

    El ORDER BY mantiene siempre el mismo orden de bloqueo
    y reduce el riesgo de bloqueos cruzados.
  */

  for v_requerimiento in
    select
      ic.producto_id,
      sum(ic.cantidad)::numeric(14,3)
        as cantidad_requerida
    from public.items_cotizacion ic
    where ic.cotizacion_id = p_cotizacion_id
      and ic.producto_id is not null
    group by ic.producto_id
    order by ic.producto_id
  loop
    select *
    into v_producto
    from public.productos
    where id = v_requerimiento.producto_id
    for update;

    if not found then
      raise exception
        'Uno de los productos ya no existe';
    end if;

    if (
      v_producto.comercio_id
      <> v_cotizacion.comercio_id
    ) then
      raise exception
        'Uno de los productos pertenece a otro comercio';
    end if;

    if v_producto.activo = false then
      raise exception
        'El producto "%" se encuentra inactivo',
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
    v_cotizacion.comercio_id,
    1,
    now()
  )
  on conflict (comercio_id)
  do update set
    ultimo_numero =
      public.venta_contadores.ultimo_numero + 1,

    updated_at = now()

  returning ultimo_numero
  into v_numero;

  -- ===================================================
  -- CREAR VENTA
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
    v_cotizacion.comercio_id,
    v_cotizacion.id,
    v_cotizacion.cliente_id,
    v_numero,
    'confirmada',
    'pendiente',
    p_fecha_venta,
    v_cotizacion.moneda,
    v_cotizacion.subtotal,
    v_cotizacion.descuento_items,
    v_cotizacion.descuento_general_porcentaje,
    v_cotizacion.descuento_general_importe,
    v_cotizacion.impuestos,
    v_cotizacion.total,
    0,
    coalesce(
      nullif(trim(p_observaciones), ''),
      v_cotizacion.observaciones
    ),
    auth.uid()
  )
  returning id
  into v_venta_id;

  -- ===================================================
  -- COPIAR ÍTEMS DE COTIZACIÓN
  -- ===================================================

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
  select
    v_venta_id,
    ic.comercio_id,
    ic.producto_id,
    ic.tipo,
    ic.codigo,
    ic.nombre,
    ic.descripcion,
    ic.unidad_medida,
    ic.cantidad,

    coalesce(
      p.costo,
      0
    ) as costo_unitario,

    ic.precio_unitario,
    ic.descuento_porcentaje,
    ic.iva_porcentaje,
    ic.subtotal,
    ic.descuento_importe,
    ic.neto,
    ic.impuesto_importe,
    ic.total,

    (
      p.id is not null
      and p.tipo = 'producto'
      and p.controla_stock = true
    ) as afecta_stock,

    ic.orden

  from public.items_cotizacion ic

  left join public.productos p
    on p.id = ic.producto_id

  where ic.cotizacion_id = p_cotizacion_id

  order by ic.orden;

  -- ===================================================
  -- DESCONTAR STOCK
  -- ===================================================

  for v_requerimiento in
    select
      ic.producto_id,
      sum(ic.cantidad)::numeric(14,3)
        as cantidad_requerida
    from public.items_cotizacion ic
    where ic.cotizacion_id = p_cotizacion_id
      and ic.producto_id is not null
    group by ic.producto_id
    order by ic.producto_id
  loop
    /*
      El producto ya quedó bloqueado durante la
      validación anterior y continuará bloqueado hasta
      finalizar toda la transacción.
    */

    select *
    into v_producto
    from public.productos
    where id = v_requerimiento.producto_id;

    if (
      v_producto.tipo = 'producto'
      and v_producto.controla_stock = true
    ) then
      v_stock_anterior :=
        v_producto.stock_actual;

      v_stock_posterior :=
        v_stock_anterior
        - v_requerimiento.cantidad_requerida;

      update public.productos
      set stock_actual = v_stock_posterior
      where id = v_producto.id;

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
        v_cotizacion.comercio_id,
        v_producto.id,
        'venta',
        v_requerimiento.cantidad_requerida,
        v_stock_anterior,
        v_stock_posterior,

        format(
          'Venta VTA-%s desde cotización COT-%s',
          lpad(v_numero::text, 6, '0'),
          lpad(v_cotizacion.numero::text, 6, '0')
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
  -- MARCAR COTIZACIÓN COMO CONVERTIDA
  -- ===================================================

  update public.cotizaciones
  set estado = 'convertida'
  where id = p_cotizacion_id;

  -- ===================================================
  -- DEVOLVER RESULTADO
  -- ===================================================

  return query
  select
    v_venta_id,
    v_numero,
    v_cotizacion.total,
    v_movimientos_generados;
end;
$$;

-- =====================================================
-- SEGURIDAD RLS
-- =====================================================

alter table public.ventas
enable row level security;

alter table public.items_venta
enable row level security;

alter table public.venta_contadores
enable row level security;

-- VENTAS

drop policy if exists ventas_select_miembro
on public.ventas;

create policy ventas_select_miembro
on public.ventas
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

-- ÍTEMS DE VENTA

drop policy if exists items_venta_select_miembro
on public.items_venta;

create policy items_venta_select_miembro
on public.items_venta
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on public.ventas
from anon, authenticated;

revoke all
on public.items_venta
from anon, authenticated;

revoke all
on public.venta_contadores
from anon, authenticated;

grant select
on public.ventas
to authenticated;

grant select
on public.items_venta
to authenticated;

revoke all
on function public.convertir_cotizacion_en_venta(
  uuid,
  date,
  text
)
from public;

grant execute
on function public.convertir_cotizacion_en_venta(
  uuid,
  date,
  text
)
to authenticated;