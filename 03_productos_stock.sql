-- =====================================================
-- DRITO - PRODUCTOS, CATEGORÍAS Y MOVIMIENTOS DE STOCK
-- =====================================================

-- =====================================================
-- CATEGORÍAS
-- =====================================================

create table if not exists public.categorias_productos (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  nombre text not null
    check (char_length(trim(nombre)) >= 2),

  descripcion text,

  activo boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists categorias_nombre_unique_idx
on public.categorias_productos (
  comercio_id,
  lower(trim(nombre))
);

create index if not exists categorias_comercio_activo_idx
on public.categorias_productos (
  comercio_id,
  activo
);

-- =====================================================
-- PRODUCTOS Y SERVICIOS
-- =====================================================

create table if not exists public.productos (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  categoria_id uuid
    references public.categorias_productos(id) on delete set null,

  tipo text not null default 'producto'
    check (tipo in ('producto', 'servicio')),

  codigo text,
  codigo_barras text,

  nombre text not null
    check (char_length(trim(nombre)) >= 2),

  descripcion text,

  unidad_medida text not null default 'unidad'
    check (
      unidad_medida in (
        'unidad',
        'kg',
        'gramo',
        'litro',
        'ml',
        'metro',
        'm2',
        'm3',
        'hora',
        'servicio',
        'otro'
      )
    ),

  costo numeric(14,2) not null default 0
    check (costo >= 0),

  precio_venta numeric(14,2) not null default 0
    check (precio_venta >= 0),

  iva_porcentaje numeric(5,2) not null default 21
    check (
      iva_porcentaje >= 0
      and iva_porcentaje <= 100
    ),

  moneda text not null default 'ARS',

  controla_stock boolean not null default true,

  stock_actual numeric(14,3) not null default 0
    check (stock_actual >= 0),

  stock_minimo numeric(14,3) not null default 0
    check (stock_minimo >= 0),

  activo boolean not null default true,

  creado_por uuid
    references auth.users(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (
    tipo <> 'servicio'
    or controla_stock = false
  )
);

create unique index if not exists productos_codigo_unique_idx
on public.productos (
  comercio_id,
  lower(trim(codigo))
)
where codigo is not null
  and trim(codigo) <> '';

create unique index if not exists productos_codigo_barras_unique_idx
on public.productos (
  comercio_id,
  trim(codigo_barras)
)
where codigo_barras is not null
  and trim(codigo_barras) <> '';

create index if not exists productos_comercio_activo_idx
on public.productos (
  comercio_id,
  activo
);

create index if not exists productos_comercio_nombre_idx
on public.productos (
  comercio_id,
  lower(nombre)
);

create index if not exists productos_categoria_idx
on public.productos (
  categoria_id
);

-- =====================================================
-- MOVIMIENTOS DE STOCK
-- =====================================================

create table if not exists public.movimientos_stock (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  producto_id uuid not null
    references public.productos(id) on delete restrict,

  tipo text not null
    check (
      tipo in (
        'entrada',
        'salida',
        'ajuste_positivo',
        'ajuste_negativo',
        'venta',
        'devolucion_cliente',
        'devolucion_proveedor'
      )
    ),

  cantidad numeric(14,3) not null
    check (cantidad > 0),

  stock_anterior numeric(14,3) not null,
  stock_posterior numeric(14,3) not null,

  motivo text,

  referencia_tipo text,
  referencia_id uuid,

  creado_por uuid
    references auth.users(id) on delete set null,

  created_at timestamptz not null default now()
);

create index if not exists movimientos_stock_producto_fecha_idx
on public.movimientos_stock (
  producto_id,
  created_at desc
);

create index if not exists movimientos_stock_comercio_fecha_idx
on public.movimientos_stock (
  comercio_id,
  created_at desc
);

-- =====================================================
-- UPDATED_AT
-- =====================================================

drop trigger if exists categorias_productos_updated_at
on public.categorias_productos;

create trigger categorias_productos_updated_at
before update on public.categorias_productos
for each row
execute function public.actualizar_updated_at();

drop trigger if exists productos_updated_at
on public.productos;

create trigger productos_updated_at
before update on public.productos
for each row
execute function public.actualizar_updated_at();

-- =====================================================
-- PREPARAR PRODUCTO NUEVO
-- =====================================================

create or replace function public.preparar_producto_nuevo()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.nombre = trim(new.nombre);

  new.codigo = nullif(trim(coalesce(new.codigo, '')), '');
  new.codigo_barras =
    nullif(trim(coalesce(new.codigo_barras, '')), '');

  new.creado_por =
    coalesce(new.creado_por, auth.uid());

  -- El stock siempre comienza en cero.
  -- Después se registra mediante un movimiento.
  new.stock_actual = 0;

  if new.tipo = 'servicio' then
    new.controla_stock = false;
    new.stock_actual = 0;
    new.stock_minimo = 0;
    new.unidad_medida = 'servicio';
  end if;

  return new;
end;
$$;

drop trigger if exists productos_preparar_insert
on public.productos;

create trigger productos_preparar_insert
before insert on public.productos
for each row
execute function public.preparar_producto_nuevo();

-- =====================================================
-- PROTEGER CAMPOS INTERNOS
-- =====================================================

create or replace function public.proteger_campos_producto()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.comercio_id <> old.comercio_id then
    raise exception
      'No se puede cambiar un producto de comercio';
  end if;

  new.creado_por = old.creado_por;

  if new.tipo = 'servicio' then
    if old.stock_actual <> 0 then
      raise exception
        'No se puede convertir en servicio un producto con stock';
    end if;

    new.controla_stock = false;
    new.stock_actual = 0;
    new.stock_minimo = 0;
    new.unidad_medida = 'servicio';
  end if;

  return new;
end;
$$;

drop trigger if exists productos_proteger_campos
on public.productos;

create trigger productos_proteger_campos
before update on public.productos
for each row
execute function public.proteger_campos_producto();

-- =====================================================
-- FUNCIÓN SEGURA PARA REGISTRAR STOCK
-- =====================================================

create or replace function public.registrar_movimiento_stock(
  p_producto_id uuid,
  p_tipo text,
  p_cantidad numeric,
  p_motivo text default null,
  p_referencia_tipo text default null,
  p_referencia_id uuid default null
)
returns table (
  movimiento_id uuid,
  stock_anterior numeric,
  stock_posterior numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
  v_tipo_producto text;
  v_controla_stock boolean;

  v_stock_anterior numeric(14,3);
  v_stock_posterior numeric(14,3);

  v_movimiento_id uuid;
  v_signo integer;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_cantidad is null or p_cantidad <= 0 then
    raise exception
      'La cantidad debe ser mayor que cero';
  end if;

  if p_tipo not in (
    'entrada',
    'salida',
    'ajuste_positivo',
    'ajuste_negativo',
    'venta',
    'devolucion_cliente',
    'devolucion_proveedor'
  ) then
    raise exception
      'Tipo de movimiento inválido';
  end if;

  select
    comercio_id,
    tipo,
    controla_stock,
    stock_actual
  into
    v_comercio_id,
    v_tipo_producto,
    v_controla_stock,
    v_stock_anterior
  from public.productos
  where id = p_producto_id
  for update;

  if not found then
    raise exception 'Producto no encontrado';
  end if;

  if not public.pertenece_a_comercio(v_comercio_id) then
    raise exception
      'El usuario no pertenece al comercio';
  end if;

  if v_tipo_producto = 'servicio'
    or v_controla_stock = false then
    raise exception
      'Este artículo no administra stock';
  end if;

  if p_tipo in (
    'entrada',
    'ajuste_positivo',
    'devolucion_cliente'
  ) then
    v_signo = 1;
  else
    v_signo = -1;
  end if;

  v_stock_posterior =
    v_stock_anterior + (p_cantidad * v_signo);

  if v_stock_posterior < 0 then
    raise exception
      'El movimiento dejaría el stock en negativo';
  end if;

  update public.productos
  set stock_actual = v_stock_posterior
  where id = p_producto_id;

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
    v_comercio_id,
    p_producto_id,
    p_tipo,
    p_cantidad,
    v_stock_anterior,
    v_stock_posterior,
    nullif(trim(coalesce(p_motivo, '')), ''),
    nullif(trim(coalesce(p_referencia_tipo, '')), ''),
    p_referencia_id,
    auth.uid()
  )
  returning id into v_movimiento_id;

  return query
  select
    v_movimiento_id,
    v_stock_anterior,
    v_stock_posterior;
end;
$$;

revoke all
on function public.registrar_movimiento_stock(
  uuid,
  text,
  numeric,
  text,
  text,
  uuid
)
from public;

grant execute
on function public.registrar_movimiento_stock(
  uuid,
  text,
  numeric,
  text,
  text,
  uuid
)
to authenticated;

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

alter table public.categorias_productos
enable row level security;

alter table public.productos
enable row level security;

alter table public.movimientos_stock
enable row level security;

-- CATEGORÍAS

drop policy if exists categorias_select_miembro
on public.categorias_productos;

create policy categorias_select_miembro
on public.categorias_productos
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

drop policy if exists categorias_insert_miembro
on public.categorias_productos;

create policy categorias_insert_miembro
on public.categorias_productos
for insert
to authenticated
with check (
  public.pertenece_a_comercio(comercio_id)
);

drop policy if exists categorias_update_miembro
on public.categorias_productos;

create policy categorias_update_miembro
on public.categorias_productos
for update
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
)
with check (
  public.pertenece_a_comercio(comercio_id)
);

drop policy if exists categorias_delete_admin
on public.categorias_productos;

create policy categorias_delete_admin
on public.categorias_productos
for delete
to authenticated
using (
  public.es_admin_comercio(comercio_id)
);

-- PRODUCTOS

drop policy if exists productos_select_miembro
on public.productos;

create policy productos_select_miembro
on public.productos
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

drop policy if exists productos_insert_miembro
on public.productos;

create policy productos_insert_miembro
on public.productos
for insert
to authenticated
with check (
  public.pertenece_a_comercio(comercio_id)
  and creado_por = (select auth.uid())
);

drop policy if exists productos_update_miembro
on public.productos;

create policy productos_update_miembro
on public.productos
for update
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
)
with check (
  public.pertenece_a_comercio(comercio_id)
);

drop policy if exists productos_delete_admin
on public.productos;

create policy productos_delete_admin
on public.productos
for delete
to authenticated
using (
  public.es_admin_comercio(comercio_id)
);

-- MOVIMIENTOS

drop policy if exists movimientos_stock_select_miembro
on public.movimientos_stock;

create policy movimientos_stock_select_miembro
on public.movimientos_stock
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

-- =====================================================
-- PERMISOS
-- =====================================================

revoke all
on public.categorias_productos
from anon;

revoke all
on public.productos
from anon;

revoke all
on public.movimientos_stock
from anon;

revoke all
on public.categorias_productos
from authenticated;

grant select, insert, update, delete
on public.categorias_productos
to authenticated;

revoke all
on public.productos
from authenticated;

grant select, insert, delete
on public.productos
to authenticated;

grant update (
  categoria_id,
  tipo,
  codigo,
  codigo_barras,
  nombre,
  descripcion,
  unidad_medida,
  costo,
  precio_venta,
  iva_porcentaje,
  moneda,
  controla_stock,
  stock_minimo,
  activo
)
on public.productos
to authenticated;

revoke all
on public.movimientos_stock
from authenticated;

grant select
on public.movimientos_stock
to authenticated;