-- =====================================================
-- DRITO - COMPRAS
-- INGRESO AUTOMÁTICO DE STOCK
-- =====================================================

-- =====================================================
-- CONTADOR DE COMPRAS
-- =====================================================

create table if not exists public.compra_contadores (
  comercio_id uuid primary key
    references public.comercios(id)
    on delete cascade,

  ultimo_numero bigint not null default 0
    check (ultimo_numero >= 0),

  updated_at timestamptz not null default now()
);

-- =====================================================
-- COMPRAS
-- =====================================================

create table if not exists public.compras (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  proveedor_id uuid not null
    references public.proveedores(id)
    on delete restrict,

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

  fecha_compra date not null default current_date,

  fecha_vencimiento date,

  tipo_comprobante text not null default 'factura'
    check (
      tipo_comprobante in (
        'factura',
        'remito',
        'ticket',
        'recibo',
        'otro'
      )
    ),

  numero_comprobante text,

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
    check (
      total_pagado >= 0
      and total_pagado <= total
    ),

  observaciones text,

  creado_por uuid
    references auth.users(id)
    on delete set null
    default auth.uid(),

  anulada_at timestamptz,

  anulada_por uuid
    references auth.users(id)
    on delete set null,

  motivo_anulacion text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (
    comercio_id,
    numero
  ),

  check (
    fecha_vencimiento is null
    or fecha_vencimiento >= fecha_compra
  )
);

-- =====================================================
-- ÍTEMS DE COMPRA
-- =====================================================

create table if not exists public.items_compra (
  id uuid primary key default gen_random_uuid(),

  compra_id uuid not null
    references public.compras(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  producto_id uuid not null
    references public.productos(id)
    on delete restrict,

  tipo text not null
    check (
      tipo in (
        'producto',
        'servicio'
      )
    ),

  codigo text,

  nombre text not null
    check (
      char_length(trim(nombre)) >= 2
    ),

  descripcion text,

  unidad_medida text not null default 'unidad',

  cantidad numeric(14,3) not null
    check (cantidad > 0),

  costo_unitario numeric(14,2) not null
    check (costo_unitario >= 0),

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

-- =====================================================
-- ÍNDICES
-- =====================================================

create index if not exists compras_comercio_fecha_idx
on public.compras (
  comercio_id,
  fecha_compra desc
);

create index if not exists compras_proveedor_idx
on public.compras (
  proveedor_id,
  fecha_compra desc
);

create index if not exists compras_estado_idx
on public.compras (
  comercio_id,
  estado
);

create index if not exists compras_estado_pago_idx
on public.compras (
  comercio_id,
  estado_pago
);

create index if not exists items_compra_compra_idx
on public.items_compra (
  compra_id,
  orden
);

create index if not exists items_compra_producto_idx
on public.items_compra (
  producto_id
);

-- =====================================================
-- UPDATED_AT
-- =====================================================

create or replace function
public.actualizar_compras_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();

  return new;
end;
$$;

drop trigger if exists compras_updated_at
on public.compras;

create trigger compras_updated_at
before update
on public.compras
for each row
execute function
public.actualizar_compras_updated_at();

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.compra_contadores
enable row level security;

alter table public.compras
enable row level security;

alter table public.items_compra
enable row level security;

-- =====================================================
-- POLÍTICAS DE LECTURA
-- =====================================================

drop policy if exists
"Miembros pueden ver contadores de compras"
on public.compra_contadores;

create policy
"Miembros pueden ver contadores de compras"
on public.compra_contadores
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

drop policy if exists
"Miembros pueden ver compras"
on public.compras;

create policy
"Miembros pueden ver compras"
on public.compras
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

drop policy if exists
"Miembros pueden ver items de compras"
on public.items_compra;

create policy
"Miembros pueden ver items de compras"
on public.items_compra
for select
to authenticated
using (
  public.pertenece_a_comercio(
    comercio_id
  )
);

-- Las escrituras se realizan únicamente mediante
-- funciones transaccionales.

-- =====================================================
-- CREAR COMPRA
-- =====================================================

create or replace function public.crear_compra(
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
returns table (
  compra_id uuid,
  numero_compra bigint,
  total_compra numeric,
  movimientos_generados integer,
  cantidad_total_ingresada numeric
)
language plpgsql
security definer
set search_path = public
as $$
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
  v_iva_porcentaje numeric(5,2);

  v_subtotal_linea numeric(14,2);
  v_descuento_linea numeric(14,2);
  v_neto_linea numeric(14,2);
  v_impuesto_linea numeric(14,2);
  v_total_linea numeric(14,2);

  v_subtotal numeric(14,2) := 0;
  v_descuento_items numeric(14,2) := 0;
  v_impuestos numeric(14,2) := 0;

  v_total_antes_descuento numeric(14,2);

  v_descuento_general_porcentaje numeric(5,2);
  v_descuento_general_importe numeric(14,2);

  v_total_compra numeric(14,2);

  v_stock_anterior numeric(14,3);
  v_stock_posterior numeric(14,3);

  v_movimientos_generados integer := 0;

  v_cantidad_total_ingresada numeric(14,3) := 0;

  v_orden integer := 0;

  v_tipo_comprobante text;
begin
  -- ===================================================
  -- AUTENTICACIÓN
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
      'El usuario no pertenece al comercio';
  end if;

  -- ===================================================
  -- PROVEEDOR
  -- ===================================================

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

  -- ===================================================
  -- FECHAS
  -- ===================================================

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

  -- ===================================================
  -- COMPROBANTE
  -- ===================================================

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

  -- ===================================================
  -- DESCUENTO GENERAL
  -- ===================================================

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

  -- ===================================================
  -- ÍTEMS
  -- ===================================================

  if (
    p_items is null
    or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) = 0
  ) then
    raise exception
      'La compra debe contener al menos un artículo';
  end if;

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

  -- ===================================================
  -- VALIDAR Y BLOQUEAR PRODUCTOS
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
  end loop;

  -- ===================================================
  -- GENERAR NÚMERO DE COMPRA
  -- ===================================================

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

  -- ===================================================
  -- CREAR CABECERA
  -- ===================================================

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

  -- ===================================================
  -- CREAR ÍTEMS, ACTUALIZAR COSTOS Y STOCK
  -- ===================================================

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
      orden
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

  -- ===================================================
  -- CALCULAR TOTALES
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

  v_total_compra :=
    greatest(
      v_total_antes_descuento
      - v_descuento_general_importe,
      0
    );

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

  -- ===================================================
  -- RESULTADO
  -- ===================================================

  return query
  select
    v_compra_id,
    v_numero_compra,
    v_total_compra,
    v_movimientos_generados,
    v_cantidad_total_ingresada;
end;
$$;

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on public.compra_contadores
from anon;

revoke all
on public.compras
from anon;

revoke all
on public.items_compra
from anon;

grant select
on public.compra_contadores
to authenticated;

grant select
on public.compras
to authenticated;

grant select
on public.items_compra
to authenticated;

revoke all
on function public.crear_compra(
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

grant execute
on function public.crear_compra(
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
to authenticated;