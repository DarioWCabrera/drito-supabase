-- =====================================================
-- DRITO - MÓDULO DE COTIZACIONES
-- =====================================================

-- =====================================================
-- CONTADOR DE COTIZACIONES POR COMERCIO
-- =====================================================

create table if not exists public.cotizacion_contadores (
  comercio_id uuid primary key
    references public.comercios(id) on delete cascade,

  ultimo_numero bigint not null default 0
    check (ultimo_numero >= 0),

  updated_at timestamptz not null default now()
);

-- =====================================================
-- COTIZACIONES
-- =====================================================

create table if not exists public.cotizaciones (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  cliente_id uuid not null
    references public.clientes(id) on delete restrict,

  numero bigint not null
    check (numero > 0),

  estado text not null default 'borrador'
    check (
      estado in (
        'borrador',
        'enviada',
        'aceptada',
        'rechazada',
        'vencida',
        'convertida',
        'anulada'
      )
    ),

  fecha_emision date not null default current_date,
  valida_hasta date,

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

  observaciones text,
  condiciones text,

  creado_por uuid
    references auth.users(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (comercio_id, numero),

  check (
    valida_hasta is null
    or valida_hasta >= fecha_emision
  )
);

create index if not exists cotizaciones_comercio_fecha_idx
on public.cotizaciones (
  comercio_id,
  created_at desc
);

create index if not exists cotizaciones_cliente_idx
on public.cotizaciones (
  cliente_id,
  created_at desc
);

create index if not exists cotizaciones_estado_idx
on public.cotizaciones (
  comercio_id,
  estado
);

-- =====================================================
-- ÍTEMS DE COTIZACIÓN
-- =====================================================

create table if not exists public.items_cotizacion (
  id uuid primary key default gen_random_uuid(),

  cotizacion_id uuid not null
    references public.cotizaciones(id) on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  producto_id uuid
    references public.productos(id) on delete set null,

  tipo text not null default 'producto'
    check (tipo in ('producto', 'servicio')),

  codigo text,
  nombre text not null
    check (char_length(trim(nombre)) >= 2),

  descripcion text,

  unidad_medida text not null default 'unidad',

  cantidad numeric(14,3) not null
    check (cantidad > 0),

  precio_unitario numeric(14,2) not null
    check (precio_unitario >= 0),

  descuento_porcentaje numeric(5,2)
    not null default 0
    check (
      descuento_porcentaje >= 0
      and descuento_porcentaje <= 100
    ),

  iva_porcentaje numeric(5,2)
    not null default 21
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

  orden integer not null default 0,

  created_at timestamptz not null default now()
);

create index if not exists items_cotizacion_cotizacion_idx
on public.items_cotizacion (
  cotizacion_id,
  orden
);

create index if not exists items_cotizacion_producto_idx
on public.items_cotizacion (
  producto_id
);

-- =====================================================
-- UPDATED_AT
-- =====================================================

drop trigger if exists cotizaciones_updated_at
on public.cotizaciones;

create trigger cotizaciones_updated_at
before update on public.cotizaciones
for each row
execute function public.actualizar_updated_at();

-- =====================================================
-- GUARDAR COTIZACIÓN DE MANERA TRANSACCIONAL
-- =====================================================

create or replace function public.guardar_cotizacion(
  p_cotizacion_id uuid,
  p_comercio_id uuid,
  p_cliente_id uuid,
  p_fecha_emision date,
  p_valida_hasta date,
  p_moneda text,
  p_descuento_general_porcentaje numeric,
  p_observaciones text,
  p_condiciones text,
  p_items jsonb
)
returns table (
  cotizacion_id uuid,
  numero bigint,
  subtotal numeric,
  descuento_items numeric,
  descuento_general_importe numeric,
  impuestos numeric,
  total numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cotizacion_id uuid;
  v_numero bigint;
  v_estado text;
  v_comercio_existente uuid;

  v_item jsonb;
  v_orden integer := 0;

  v_producto_id uuid;
  v_producto_comercio_id uuid;

  v_tipo text;
  v_codigo text;
  v_nombre text;
  v_descripcion text;
  v_unidad_medida text;

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
  v_total numeric(14,2);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if not public.pertenece_a_comercio(p_comercio_id) then
    raise exception
      'El usuario no pertenece al comercio indicado';
  end if;

  if p_fecha_emision is null then
    raise exception
      'La fecha de emisión es obligatoria';
  end if;

  if (
    p_valida_hasta is not null
    and p_valida_hasta < p_fecha_emision
  ) then
    raise exception
      'La fecha de validez no puede ser anterior a la emisión';
  end if;

  select c.comercio_id
into v_comercio_existente
from public.clientes as c
where c.id = p_cliente_id
  and c.activo = true;

  if not found then
    raise exception
      'El cliente no existe o se encuentra inactivo';
  end if;

  if v_comercio_existente <> p_comercio_id then
    raise exception
      'El cliente no pertenece al comercio';
  end if;

  if p_items is null
    or jsonb_typeof(p_items) <> 'array'
    or jsonb_array_length(p_items) = 0 then
    raise exception
      'La cotización debe contener al menos un artículo';
  end if;

  v_descuento_general_porcentaje :=
    coalesce(p_descuento_general_porcentaje, 0);

  if (
    v_descuento_general_porcentaje < 0
    or v_descuento_general_porcentaje > 100
  ) then
    raise exception
      'El descuento general debe estar entre 0 y 100';
  end if;

  -- Crear una cotización nueva.
  if p_cotizacion_id is null then
    insert into public.cotizacion_contadores (
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
        public.cotizacion_contadores.ultimo_numero + 1,
      updated_at = now()
    returning ultimo_numero
    into v_numero;

    insert into public.cotizaciones (
      comercio_id,
      cliente_id,
      numero,
      estado,
      fecha_emision,
      valida_hasta,
      moneda,
      observaciones,
      condiciones,
      creado_por
    )
    values (
      p_comercio_id,
      p_cliente_id,
      v_numero,
      'borrador',
      p_fecha_emision,
      p_valida_hasta,
      coalesce(
        nullif(trim(p_moneda), ''),
        'ARS'
      ),
      nullif(trim(coalesce(p_observaciones, '')), ''),
      nullif(trim(coalesce(p_condiciones, '')), ''),
      auth.uid()
    )
    returning id into v_cotizacion_id;

  -- Editar una cotización existente.
  else
    select
      c.comercio_id,
      c.numero,
      c.estado
    into
      v_comercio_existente,
      v_numero,
      v_estado
    from public.cotizaciones as c
    where c.id = p_cotizacion_id
    for update;

    if not found then
      raise exception 'Cotización no encontrada';
    end if;

    if v_comercio_existente <> p_comercio_id then
      raise exception
        'La cotización no pertenece al comercio';
    end if;

    if v_estado in ('convertida', 'anulada') then
      raise exception
        'La cotización ya no puede modificarse';
    end if;

    v_cotizacion_id := p_cotizacion_id;

    update public.cotizaciones as c
    set
      cliente_id = p_cliente_id,
      fecha_emision = p_fecha_emision,
      valida_hasta = p_valida_hasta,
      moneda = coalesce(
        nullif(trim(p_moneda), ''),
        'ARS'
      ),
      descuento_general_porcentaje =
        v_descuento_general_porcentaje,
      observaciones =
        nullif(trim(coalesce(p_observaciones, '')), ''),
      condiciones =
        nullif(trim(coalesce(p_condiciones, '')), '')
    where c.id = v_cotizacion_id;

    delete from public.items_cotizacion as ic
    where ic.cotizacion_id = v_cotizacion_id;
  end if;

  -- Procesar los artículos.
  for v_item in
    select value
    from jsonb_array_elements(p_items)
  loop
    v_orden := v_orden + 1;

    v_producto_id :=
      case
        when nullif(v_item ->> 'producto_id', '') is null
          then null
        else (v_item ->> 'producto_id')::uuid
      end;

    v_tipo :=
      coalesce(
        nullif(trim(v_item ->> 'tipo'), ''),
        'producto'
      );

    v_codigo :=
      nullif(trim(coalesce(v_item ->> 'codigo', '')), '');

    v_nombre :=
      trim(coalesce(v_item ->> 'nombre', ''));

    v_descripcion :=
      nullif(
        trim(coalesce(v_item ->> 'descripcion', '')),
        ''
      );

    v_unidad_medida :=
      coalesce(
        nullif(
          trim(v_item ->> 'unidad_medida'),
          ''
        ),
        'unidad'
      );

    v_cantidad :=
      coalesce(
        nullif(v_item ->> 'cantidad', '')::numeric,
        0
      );

    v_precio_unitario :=
      coalesce(
        nullif(v_item ->> 'precio_unitario', '')::numeric,
        0
      );

    v_descuento_porcentaje :=
      coalesce(
        nullif(
          v_item ->> 'descuento_porcentaje',
          ''
        )::numeric,
        0
      );

    v_iva_porcentaje :=
      coalesce(
        nullif(
          v_item ->> 'iva_porcentaje',
          ''
        )::numeric,
        0
      );

    if v_tipo not in ('producto', 'servicio') then
      raise exception
        'El tipo de artículo es inválido';
    end if;

    if char_length(v_nombre) < 2 then
      raise exception
        'Todos los artículos deben tener un nombre';
    end if;

    if v_cantidad <= 0 then
      raise exception
        'La cantidad debe ser mayor que cero';
    end if;

    if v_precio_unitario < 0 then
      raise exception
        'El precio no puede ser negativo';
    end if;

    if (
      v_descuento_porcentaje < 0
      or v_descuento_porcentaje > 100
    ) then
      raise exception
        'El descuento del artículo es inválido';
    end if;

    if (
      v_iva_porcentaje < 0
      or v_iva_porcentaje > 100
    ) then
      raise exception
        'El IVA del artículo es inválido';
    end if;

    -- Verificar que el producto pertenezca al comercio.
    if v_producto_id is not null then
      select p.comercio_id
      into v_producto_comercio_id
      from public.productos as p
      where p.id = v_producto_id
        and p.activo = true;

      if not found then
        raise exception
          'Uno de los productos no existe o está inactivo';
      end if;

      if v_producto_comercio_id <> p_comercio_id then
        raise exception
          'Uno de los productos pertenece a otro comercio';
      end if;
    end if;

    v_subtotal_linea :=
      round(v_cantidad * v_precio_unitario, 2);

    v_descuento_linea :=
      round(
        v_subtotal_linea
        * v_descuento_porcentaje
        / 100,
        2
      );

    v_neto_linea :=
      v_subtotal_linea - v_descuento_linea;

    v_impuesto_linea :=
      round(
        v_neto_linea
        * v_iva_porcentaje
        / 100,
        2
      );

    v_total_linea :=
      v_neto_linea + v_impuesto_linea;

    insert into public.items_cotizacion (
      cotizacion_id,
      comercio_id,
      producto_id,
      tipo,
      codigo,
      nombre,
      descripcion,
      unidad_medida,
      cantidad,
      precio_unitario,
      descuento_porcentaje,
      iva_porcentaje,
      subtotal,
      descuento_importe,
      neto,
      impuesto_importe,
      total,
      orden
    )
    values (
      v_cotizacion_id,
      p_comercio_id,
      v_producto_id,
      v_tipo,
      v_codigo,
      v_nombre,
      v_descripcion,
      v_unidad_medida,
      v_cantidad,
      v_precio_unitario,
      v_descuento_porcentaje,
      v_iva_porcentaje,
      v_subtotal_linea,
      v_descuento_linea,
      v_neto_linea,
      v_impuesto_linea,
      v_total_linea,
      v_orden
    );

    v_subtotal :=
      v_subtotal + v_subtotal_linea;

    v_descuento_items :=
      v_descuento_items + v_descuento_linea;

    v_impuestos :=
      v_impuestos + v_impuesto_linea;
      
  end loop;

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

  v_total :=
    greatest(
      v_total_antes_descuento
      - v_descuento_general_importe,
      0
    );

  update public.cotizaciones as c
  set
    subtotal = v_subtotal,
    descuento_items = v_descuento_items,
    descuento_general_porcentaje =
      v_descuento_general_porcentaje,
    descuento_general_importe =
      v_descuento_general_importe,
    impuestos = v_impuestos,
    total = v_total
  where c.id = v_cotizacion_id;

  return query
  select
    v_cotizacion_id,
    v_numero,
    v_subtotal,
    v_descuento_items,
    v_descuento_general_importe,
    v_impuestos,
    v_total;
end;
$$;

-- =====================================================
-- CAMBIAR ESTADO DE UNA COTIZACIÓN
-- =====================================================

create or replace function public.cambiar_estado_cotizacion(
  p_cotizacion_id uuid,
  p_estado text
)
returns public.cotizaciones
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cotizacion public.cotizaciones;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_estado not in (
    'borrador',
    'enviada',
    'aceptada',
    'rechazada',
    'vencida',
    'anulada'
  ) then
    raise exception
      'Estado de cotización inválido';
  end if;

  select *
  into v_cotizacion
  from public.cotizaciones
  where id = p_cotizacion_id
  for update;

  if not found then
    raise exception 'Cotización no encontrada';
  end if;

  if not public.pertenece_a_comercio(
    v_cotizacion.comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  if v_cotizacion.estado in (
    'convertida',
    'anulada'
  ) then
    raise exception
      'La cotización ya no puede cambiar de estado';
  end if;

  update public.cotizaciones
  set estado = p_estado
  where id = p_cotizacion_id
  returning *
  into v_cotizacion;

  return v_cotizacion;
end;
$$;

-- =====================================================
-- SEGURIDAD RLS
-- =====================================================

alter table public.cotizaciones
enable row level security;

alter table public.items_cotizacion
enable row level security;

alter table public.cotizacion_contadores
enable row level security;

drop policy if exists cotizaciones_select_miembro
on public.cotizaciones;

create policy cotizaciones_select_miembro
on public.cotizaciones
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

drop policy if exists items_cotizacion_select_miembro
on public.items_cotizacion;

create policy items_cotizacion_select_miembro
on public.items_cotizacion
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on public.cotizaciones
from anon, authenticated;

revoke all
on public.items_cotizacion
from anon, authenticated;

revoke all
on public.cotizacion_contadores
from anon, authenticated;

grant select
on public.cotizaciones
to authenticated;

grant select
on public.items_cotizacion
to authenticated;

revoke all
on function public.guardar_cotizacion(
  uuid,
  uuid,
  uuid,
  date,
  date,
  text,
  numeric,
  text,
  text,
  jsonb
)
from public;

grant execute
on function public.guardar_cotizacion(
  uuid,
  uuid,
  uuid,
  date,
  date,
  text,
  numeric,
  text,
  text,
  jsonb
)
to authenticated;

revoke all
on function public.cambiar_estado_cotizacion(
  uuid,
  text
)
from public;

grant execute
on function public.cambiar_estado_cotizacion(
  uuid,
  text
)
to authenticated;