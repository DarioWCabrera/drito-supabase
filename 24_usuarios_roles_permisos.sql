-- =====================================================
-- DRITO - USUARIOS, ROLES Y PERMISOS
-- Archivo: 24_usuarios_roles_permisos.sql
--
-- Este módulo incorpora:
--   - Roles base: Administrador, Vendedor y Empleado
--   - Catálogo central de permisos
--   - Permisos predeterminados por rol
--   - Excepciones de permisos por usuario y comercio
--   - Invitaciones seguras por token
--   - Activación, desactivación y cambio de rol
--   - Protección del último administrador
--   - Auditoría de cambios de acceso
--
-- IMPORTANTE:
--   Este archivo crea el motor de autorización.
--   Las funciones operativas existentes de Ventas, Compras, Caja,
--   Stock, etc. se conectarán a este motor en el archivo 24b,
--   para aplicar cada permiso también en el backend.
-- =====================================================

begin;

create extension if not exists pgcrypto
with schema extensions;

-- =====================================================
-- 1. ROLES BASE DEL SISTEMA
-- =====================================================

create table if not exists public.roles_sistema (
  codigo text primary key
    check (
      codigo in (
        'admin',
        'vendedor',
        'empleado'
      )
    ),

  nombre text not null,
  descripcion text not null,
  orden integer not null default 0,
  activo boolean not null default true,
  es_administrador boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.roles_sistema (
  codigo,
  nombre,
  descripcion,
  orden,
  activo,
  es_administrador
)
values
  (
    'admin',
    'Administrador',
    'Control total del comercio, sus usuarios, configuración y operaciones.',
    10,
    true,
    true
  ),
  (
    'vendedor',
    'Vendedor',
    'Gestiona clientes, cotizaciones, ventas y cobros autorizados.',
    20,
    true,
    false
  ),
  (
    'empleado',
    'Empleado',
    'Acceso operativo limitado según las tareas asignadas por el administrador.',
    30,
    true,
    false
  )
on conflict (codigo) do update
set
  nombre = excluded.nombre,
  descripcion = excluded.descripcion,
  orden = excluded.orden,
  activo = excluded.activo,
  es_administrador = excluded.es_administrador,
  updated_at = now();

-- Conserva el campo usuarios_comercios.rol para no romper
-- el ComercioContext ni el frontend existente.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname =
      'usuarios_comercios_rol_sistema_fkey'
  ) then
    alter table public.usuarios_comercios
      add constraint
      usuarios_comercios_rol_sistema_fkey
      foreign key (rol)
      references public.roles_sistema(codigo)
      on update cascade
      on delete restrict;
  end if;
end;
$$;

-- =====================================================
-- 2. DATOS COMPLEMENTARIOS DE LA ASIGNACIÓN
-- =====================================================

alter table public.usuarios_comercios
  add column if not exists cargo text,
  add column if not exists invitado_por uuid
    references auth.users(id) on delete set null,
  add column if not exists ultimo_acceso_at timestamptz,
  add column if not exists desactivado_at timestamptz,
  add column if not exists desactivado_por uuid
    references auth.users(id) on delete set null;

create index if not exists
usuarios_comercios_comercio_activo_rol_idx
on public.usuarios_comercios (
  comercio_id,
  activo,
  rol,
  created_at
);

-- =====================================================
-- 3. CATÁLOGO DE PERMISOS
-- =====================================================

create table if not exists public.permisos_sistema (
  codigo text primary key
    check (
      codigo ~ '^[a-z0-9_]+\.[a-z0-9_]+$'
    ),

  modulo text not null,
  accion text not null,
  nombre text not null,
  descripcion text not null,

  sensible boolean not null default false,
  orden integer not null default 0,
  activo boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (modulo, accion)
);

insert into public.permisos_sistema (
  codigo,
  modulo,
  accion,
  nombre,
  descripcion,
  sensible,
  orden
)
values
  ('dashboard.ver', 'dashboard', 'ver', 'Ver panel principal', 'Consultar el resumen general del comercio.', false, 10),

  ('clientes.ver', 'clientes', 'ver', 'Ver clientes', 'Consultar el listado y los datos de clientes.', false, 100),
  ('clientes.crear', 'clientes', 'crear', 'Crear clientes', 'Registrar nuevos clientes.', false, 110),
  ('clientes.editar', 'clientes', 'editar', 'Editar clientes', 'Modificar los datos de clientes existentes.', false, 120),
  ('clientes.desactivar', 'clientes', 'desactivar', 'Desactivar clientes', 'Desactivar o reactivar clientes.', true, 130),

  ('productos.ver', 'productos', 'ver', 'Ver productos', 'Consultar productos, servicios y precios.', false, 200),
  ('productos.crear', 'productos', 'crear', 'Crear productos', 'Registrar productos y servicios.', false, 210),
  ('productos.editar', 'productos', 'editar', 'Editar productos', 'Modificar datos generales de productos y servicios.', false, 220),
  ('productos.modificar_precios', 'productos', 'modificar_precios', 'Modificar precios', 'Cambiar costos, precios de venta y alícuotas.', true, 230),
  ('productos.cambiar_estado', 'productos', 'cambiar_estado', 'Activar o desactivar productos', 'Cambiar la disponibilidad de productos y servicios.', true, 240),

  ('stock.ver', 'stock', 'ver', 'Ver stock', 'Consultar existencias y movimientos.', false, 300),
  ('stock.registrar_ingreso', 'stock', 'registrar_ingreso', 'Registrar ingresos de stock', 'Cargar entradas reales de mercadería.', false, 310),
  ('stock.registrar_egreso', 'stock', 'registrar_egreso', 'Registrar egresos de stock', 'Cargar salidas manuales de mercadería.', true, 320),
  ('stock.ajustar', 'stock', 'ajustar', 'Realizar ajustes de stock', 'Corregir diferencias de inventario.', true, 330),

  ('cotizaciones.ver', 'cotizaciones', 'ver', 'Ver cotizaciones', 'Consultar cotizaciones y sus estados.', false, 400),
  ('cotizaciones.crear', 'cotizaciones', 'crear', 'Crear cotizaciones', 'Generar nuevas cotizaciones.', false, 410),
  ('cotizaciones.editar', 'cotizaciones', 'editar', 'Editar cotizaciones', 'Modificar cotizaciones editables.', false, 420),
  ('cotizaciones.cambiar_estado', 'cotizaciones', 'cambiar_estado', 'Cambiar estado de cotizaciones', 'Enviar, aceptar o rechazar cotizaciones.', false, 430),
  ('cotizaciones.anular', 'cotizaciones', 'anular', 'Anular cotizaciones', 'Anular cotizaciones conservando trazabilidad.', true, 440),

  ('ventas.ver', 'ventas', 'ver', 'Ver ventas', 'Consultar ventas, estados y detalles.', false, 500),
  ('ventas.crear', 'ventas', 'crear', 'Crear ventas', 'Registrar o convertir operaciones en ventas.', false, 510),
  ('ventas.registrar_cobros', 'ventas', 'registrar_cobros', 'Registrar cobros de ventas', 'Registrar pagos asociados a una venta.', true, 520),
  ('ventas.anular_pagos', 'ventas', 'anular_pagos', 'Anular pagos de ventas', 'Anular cobros y restaurar saldos.', true, 530),
  ('ventas.anular_ventas', 'ventas', 'anular_ventas', 'Anular ventas', 'Anular ventas y restaurar el stock correspondiente.', true, 540),

  ('proveedores.ver', 'proveedores', 'ver', 'Ver proveedores', 'Consultar proveedores y sus datos.', false, 600),
  ('proveedores.crear', 'proveedores', 'crear', 'Crear proveedores', 'Registrar nuevos proveedores.', false, 610),
  ('proveedores.editar', 'proveedores', 'editar', 'Editar proveedores', 'Modificar datos de proveedores.', false, 620),
  ('proveedores.desactivar', 'proveedores', 'desactivar', 'Desactivar proveedores', 'Desactivar o reactivar proveedores.', true, 630),

  ('compras.ver', 'compras', 'ver', 'Ver compras', 'Consultar compras y su estado de pago.', false, 700),
  ('compras.crear', 'compras', 'crear', 'Crear compras', 'Registrar compras e ingresos asociados.', false, 710),
  ('compras.registrar_pagos', 'compras', 'registrar_pagos', 'Registrar pagos de compras', 'Registrar pagos individuales de compras.', true, 720),
  ('compras.anular_pagos', 'compras', 'anular_pagos', 'Anular pagos de compras', 'Anular pagos y restaurar saldos.', true, 730),
  ('compras.anular_compras', 'compras', 'anular_compras', 'Anular compras', 'Anular compras y revertir sus efectos operativos.', true, 740),

  ('caja.ver', 'caja', 'ver', 'Ver Caja', 'Consultar ingresos, egresos y saldo.', true, 800),
  ('caja.registrar_manual', 'caja', 'registrar_manual', 'Registrar movimientos manuales', 'Registrar ingresos o egresos manuales de Caja.', true, 810),
  ('caja.anular_manual', 'caja', 'anular_manual', 'Anular movimientos manuales', 'Anular movimientos manuales de Caja.', true, 820),

  ('gastos.ver', 'gastos', 'ver', 'Ver gastos', 'Consultar gastos generales.', true, 900),
  ('gastos.registrar', 'gastos', 'registrar', 'Registrar gastos', 'Registrar gastos y su egreso automático en Caja.', true, 910),
  ('gastos.administrar_categorias', 'gastos', 'administrar_categorias', 'Administrar categorías de gastos', 'Crear, activar o desactivar categorías.', true, 920),
  ('gastos.anular', 'gastos', 'anular', 'Anular gastos', 'Anular gastos y su egreso asociado.', true, 930),

  ('cuentas_clientes.ver', 'cuentas_clientes', 'ver', 'Ver cuentas de clientes', 'Consultar saldos y movimientos de clientes.', true, 1000),
  ('cuentas_clientes.registrar_cobros', 'cuentas_clientes', 'registrar_cobros', 'Registrar cobros agrupados', 'Aplicar cobros sobre ventas pendientes.', true, 1010),
  ('cuentas_clientes.anular_cobros', 'cuentas_clientes', 'anular_cobros', 'Anular cobros agrupados', 'Anular cobros y restaurar saldos de ventas.', true, 1020),

  ('cuentas_proveedores.ver', 'cuentas_proveedores', 'ver', 'Ver cuentas de proveedores', 'Consultar saldos y movimientos de proveedores.', true, 1100),
  ('cuentas_proveedores.registrar_pagos', 'cuentas_proveedores', 'registrar_pagos', 'Registrar pagos agrupados', 'Aplicar pagos sobre compras pendientes.', true, 1110),
  ('cuentas_proveedores.anular_pagos', 'cuentas_proveedores', 'anular_pagos', 'Anular pagos agrupados', 'Anular pagos y restaurar saldos de compras.', true, 1120),

  ('reportes.ver', 'reportes', 'ver', 'Ver reportes financieros', 'Consultar ingresos, egresos, resultados y comparaciones.', true, 1200),

  ('configuracion.ver', 'configuracion', 'ver', 'Ver configuración', 'Consultar la configuración del comercio.', false, 1300),
  ('configuracion.editar_general', 'configuracion', 'editar_general', 'Editar configuración general', 'Modificar identidad, datos y preferencias operativas.', true, 1310),
  ('configuracion.editar_fiscal', 'configuracion', 'editar_fiscal', 'Editar datos fiscales', 'Modificar la preparación fiscal del comercio.', true, 1320),
  ('configuracion.editar_modulos', 'configuracion', 'editar_modulos', 'Activar o desactivar módulos', 'Modificar los módulos habilitados para el comercio.', true, 1330),

  ('usuarios.ver', 'usuarios', 'ver', 'Ver usuarios', 'Consultar usuarios, roles, permisos e invitaciones.', true, 1400),
  ('usuarios.invitar', 'usuarios', 'invitar', 'Invitar usuarios', 'Crear o revocar invitaciones al comercio.', true, 1410),
  ('usuarios.editar_rol', 'usuarios', 'editar_rol', 'Cambiar roles', 'Modificar el rol base de un usuario.', true, 1420),
  ('usuarios.editar_permisos', 'usuarios', 'editar_permisos', 'Editar permisos', 'Personalizar permisos individuales.', true, 1430),
  ('usuarios.desactivar', 'usuarios', 'desactivar', 'Desactivar usuarios', 'Bloquear o reactivar el acceso de un usuario.', true, 1440),

  ('facturacion.ver', 'facturacion', 'ver', 'Ver facturación electrónica', 'Consultar comprobantes fiscales y su estado.', true, 1500),
  ('facturacion.emitir', 'facturacion', 'emitir', 'Emitir comprobantes', 'Solicitar autorización fiscal y emitir comprobantes.', true, 1510),
  ('facturacion.notas_credito', 'facturacion', 'notas_credito', 'Emitir notas de crédito', 'Revertir comprobantes mediante notas de crédito.', true, 1520),
  ('facturacion.anular', 'facturacion', 'anular', 'Gestionar anulaciones fiscales', 'Gestionar correcciones permitidas sobre comprobantes fiscales.', true, 1530),
  ('facturacion.configurar_arca', 'facturacion', 'configurar_arca', 'Configurar ARCA', 'Administrar la conexión fiscal y sus credenciales seguras.', true, 1540)
on conflict (codigo) do update
set
  modulo = excluded.modulo,
  accion = excluded.accion,
  nombre = excluded.nombre,
  descripcion = excluded.descripcion,
  sensible = excluded.sensible,
  orden = excluded.orden,
  activo = true,
  updated_at = now();

-- =====================================================
-- 4. PERMISOS PREDETERMINADOS POR ROL
-- =====================================================

create table if not exists public.roles_permisos (
  rol text not null
    references public.roles_sistema(codigo)
    on update cascade
    on delete cascade,

  permiso_codigo text not null
    references public.permisos_sistema(codigo)
    on update cascade
    on delete cascade,

  permitido boolean not null default true,
  created_at timestamptz not null default now(),

  primary key (rol, permiso_codigo)
);

-- En cada ejecución se restablecen las matrices base.
-- Las personalizaciones individuales permanecen en usuarios_permisos.
delete from public.roles_permisos
where rol in (
  'admin',
  'vendedor',
  'empleado'
);

-- Administrador: todos los permisos activos.
insert into public.roles_permisos (
  rol,
  permiso_codigo,
  permitido
)
select
  'admin',
  ps.codigo,
  true
from public.permisos_sistema as ps
where ps.activo = true
on conflict (rol, permiso_codigo) do update
set permitido = excluded.permitido;

-- Vendedor: circuito comercial y cobros.
insert into public.roles_permisos (
  rol,
  permiso_codigo,
  permitido
)
select
  'vendedor',
  p.codigo,
  true
from public.permisos_sistema as p
where p.codigo = any (
  array[
    'dashboard.ver',
    'clientes.ver',
    'clientes.crear',
    'clientes.editar',
    'productos.ver',
    'stock.ver',
    'cotizaciones.ver',
    'cotizaciones.crear',
    'cotizaciones.editar',
    'cotizaciones.cambiar_estado',
    'ventas.ver',
    'ventas.crear',
    'ventas.registrar_cobros',
    'cuentas_clientes.ver',
    'cuentas_clientes.registrar_cobros',
    'configuracion.ver'
  ]::text[]
)
on conflict (rol, permiso_codigo) do update
set permitido = excluded.permitido;

-- Empleado: consulta general y tareas operativas de stock/compras.
insert into public.roles_permisos (
  rol,
  permiso_codigo,
  permitido
)
select
  'empleado',
  p.codigo,
  true
from public.permisos_sistema as p
where p.codigo = any (
  array[
    'dashboard.ver',
    'clientes.ver',
    'productos.ver',
    'stock.ver',
    'stock.registrar_ingreso',
    'proveedores.ver',
    'compras.ver',
    'compras.crear',
    'gastos.ver',
    'gastos.registrar',
    'configuracion.ver'
  ]::text[]
)
on conflict (rol, permiso_codigo) do update
set permitido = excluded.permitido;

-- =====================================================
-- 5. EXCEPCIONES INDIVIDUALES
-- =====================================================

create table if not exists public.usuarios_permisos (
  usuario_comercio_id uuid not null
    references public.usuarios_comercios(id)
    on delete cascade,

  permiso_codigo text not null
    references public.permisos_sistema(codigo)
    on update cascade
    on delete cascade,

  permitido boolean not null,

  actualizado_por uuid
    references auth.users(id)
    on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  primary key (
    usuario_comercio_id,
    permiso_codigo
  )
);

create index if not exists
usuarios_permisos_permiso_idx
on public.usuarios_permisos (
  permiso_codigo,
  usuario_comercio_id
);

-- =====================================================
-- 6. INVITACIONES
-- =====================================================

create table if not exists public.invitaciones_comercio (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  email text not null,
  rol text not null
    references public.roles_sistema(codigo)
    on update cascade
    on delete restrict,

  cargo text,

  token_hash text not null unique,
  estado text not null default 'pendiente'
    check (
      estado in (
        'pendiente',
        'aceptada',
        'revocada',
        'vencida'
      )
    ),

  vence_at timestamptz not null,
  invitado_por uuid not null
    references auth.users(id)
    on delete restrict,

  aceptado_por uuid
    references auth.users(id)
    on delete set null,

  aceptado_at timestamptz,
  revocado_por uuid
    references auth.users(id)
    on delete set null,

  revocado_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (
    email = lower(trim(email))
  )
);

create unique index if not exists
invitaciones_comercio_email_pendiente_uq
on public.invitaciones_comercio (
  comercio_id,
  email
)
where estado = 'pendiente';

create index if not exists
invitaciones_comercio_estado_idx
on public.invitaciones_comercio (
  comercio_id,
  estado,
  vence_at
);

-- =====================================================
-- 7. AUDITORÍA
-- =====================================================

create table if not exists
public.auditoria_usuarios_comercio (
  id bigint generated by default as identity primary key,

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  usuario_comercio_id uuid
    references public.usuarios_comercios(id)
    on delete set null,

  accion text not null,
  detalle jsonb not null default '{}'::jsonb,

  realizado_por uuid
    references auth.users(id)
    on delete set null,

  created_at timestamptz not null default now()
);

create index if not exists
auditoria_usuarios_comercio_fecha_idx
on public.auditoria_usuarios_comercio (
  comercio_id,
  created_at desc
);

-- =====================================================
-- 8. TRIGGERS UPDATED_AT
-- =====================================================

drop trigger if exists roles_sistema_updated_at
on public.roles_sistema;

create trigger roles_sistema_updated_at
before update on public.roles_sistema
for each row
execute function public.actualizar_updated_at();

drop trigger if exists permisos_sistema_updated_at
on public.permisos_sistema;

create trigger permisos_sistema_updated_at
before update on public.permisos_sistema
for each row
execute function public.actualizar_updated_at();

drop trigger if exists usuarios_permisos_updated_at
on public.usuarios_permisos;

create trigger usuarios_permisos_updated_at
before update on public.usuarios_permisos
for each row
execute function public.actualizar_updated_at();

drop trigger if exists invitaciones_comercio_updated_at
on public.invitaciones_comercio;

create trigger invitaciones_comercio_updated_at
before update on public.invitaciones_comercio
for each row
execute function public.actualizar_updated_at();

-- =====================================================
-- 9. PROTEGER IDENTIDAD Y ÚLTIMO ADMINISTRADOR
-- =====================================================

create or replace function
public.proteger_usuario_comercio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_otros_admin integer;
begin
  if new.usuario_id <> old.usuario_id
    or new.comercio_id <> old.comercio_id then
    raise exception
      'No se puede cambiar la identidad ni el comercio de una asignación';
  end if;

  if old.usuario_id = auth.uid()
    and old.activo = true
    and new.activo = false then
    raise exception
      'No podés desactivar tu propio acceso';
  end if;

  if old.usuario_id = auth.uid()
    and old.rol <> new.rol
    and not (
      old.activo = false
      and new.activo = true
    ) then
    raise exception
      'No podés cambiar tu propio rol';
  end if;

  if old.rol = 'admin'
    and old.activo = true
    and (
      new.rol <> 'admin'
      or new.activo = false
    ) then

    select count(*)
    into v_otros_admin
    from public.usuarios_comercios as uc
    where uc.comercio_id = old.comercio_id
      and uc.id <> old.id
      and uc.rol = 'admin'
      and uc.activo = true;

    if v_otros_admin = 0 then
      raise exception
        'El comercio debe conservar al menos un administrador activo';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists
usuarios_comercios_proteger_admin
on public.usuarios_comercios;

create trigger
usuarios_comercios_proteger_admin
before update on public.usuarios_comercios
for each row
execute function public.proteger_usuario_comercio();

-- =====================================================
-- 10. MOTOR INTERNO DE PERMISOS
-- =====================================================

create or replace function
public.usuario_tiene_permiso_comercio(
  p_usuario_id uuid,
  p_comercio_id uuid,
  p_permiso_codigo text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select
        case
          when uc.rol = 'admin' then true
          when up.permitido is not null then up.permitido
          else coalesce(rp.permitido, false)
        end
      from public.usuarios_comercios as uc
      left join public.usuarios_permisos as up
        on up.usuario_comercio_id = uc.id
       and up.permiso_codigo = p_permiso_codigo
      left join public.roles_permisos as rp
        on rp.rol = uc.rol
       and rp.permiso_codigo = p_permiso_codigo
      inner join public.permisos_sistema as ps
        on ps.codigo = p_permiso_codigo
       and ps.activo = true
      where uc.usuario_id = p_usuario_id
        and uc.comercio_id = p_comercio_id
        and uc.activo = true
      limit 1
    ),
    false
  );
$$;

revoke all on function
public.usuario_tiene_permiso_comercio(
  uuid,
  uuid,
  text
)
from public, anon, authenticated;

create or replace function
public.tiene_permiso_comercio(
  p_comercio_id uuid,
  p_permiso_codigo text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    auth.uid() is not null
    and public.usuario_tiene_permiso_comercio(
      auth.uid(),
      p_comercio_id,
      p_permiso_codigo
    );
$$;

create or replace function
public.exigir_permiso_comercio(
  p_comercio_id uuid,
  p_permiso_codigo text
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if not exists (
    select 1
    from public.permisos_sistema as ps
    where ps.codigo = p_permiso_codigo
      and ps.activo = true
  ) then
    raise exception
      'El permiso solicitado no existe o está inactivo';
  end if;

  if not public.usuario_tiene_permiso_comercio(
    auth.uid(),
    p_comercio_id,
    p_permiso_codigo
  ) then
    raise exception
      'No tenés permiso para realizar esta operación';
  end if;
end;
$$;

-- =====================================================
-- 11. AUDITORÍA INTERNA
-- =====================================================

create or replace function
public.registrar_auditoria_usuario_comercio(
  p_comercio_id uuid,
  p_usuario_comercio_id uuid,
  p_accion text,
  p_detalle jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.auditoria_usuarios_comercio (
    comercio_id,
    usuario_comercio_id,
    accion,
    detalle,
    realizado_por
  )
  values (
    p_comercio_id,
    p_usuario_comercio_id,
    trim(p_accion),
    coalesce(p_detalle, '{}'::jsonb),
    auth.uid()
  );
end;
$$;

revoke all on function
public.registrar_auditoria_usuario_comercio(
  uuid,
  uuid,
  text,
  jsonb
)
from public, anon, authenticated;

-- =====================================================
-- 12. MIS PERMISOS
-- =====================================================

create or replace function
public.obtener_mis_permisos(
  p_comercio_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_usuario_comercio public.usuarios_comercios;
  v_resultado jsonb;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  select uc.*
  into v_usuario_comercio
  from public.usuarios_comercios as uc
  where uc.usuario_id = auth.uid()
    and uc.comercio_id = p_comercio_id
    and uc.activo = true;

  if not found then
    raise exception
      'El usuario no posee acceso activo al comercio';
  end if;

  select jsonb_build_object(
    'comercio_id',
      p_comercio_id,
    'usuario_comercio_id',
      v_usuario_comercio.id,
    'rol',
      v_usuario_comercio.rol,
    'cargo',
      v_usuario_comercio.cargo,
    'es_admin',
      v_usuario_comercio.rol = 'admin',
    'permisos',
      coalesce(
        (
          select jsonb_object_agg(
            ps.codigo,
            public.usuario_tiene_permiso_comercio(
              auth.uid(),
              p_comercio_id,
              ps.codigo
            )
            order by ps.orden
          )
          from public.permisos_sistema as ps
          where ps.activo = true
        ),
        '{}'::jsonb
      ),
    'codigos_habilitados',
      coalesce(
        (
          select jsonb_agg(
            ps.codigo
            order by ps.orden
          )
          from public.permisos_sistema as ps
          where ps.activo = true
            and public.usuario_tiene_permiso_comercio(
              auth.uid(),
              p_comercio_id,
              ps.codigo
            )
        ),
        '[]'::jsonb
      )
  )
  into v_resultado;

  return v_resultado;
end;
$$;

-- =====================================================
-- 13. LISTADO ADMINISTRATIVO
-- =====================================================

create or replace function
public.obtener_usuarios_comercio(
  p_comercio_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resultado jsonb;
begin
  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'usuarios.ver'
  );

  update public.invitaciones_comercio as ic
  set estado = 'vencida'
  where ic.comercio_id = p_comercio_id
    and ic.estado = 'pendiente'
    and ic.vence_at <= now();

  select jsonb_build_object(
    'usuarios',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'usuario_comercio_id', uc.id,
              'usuario_id', uc.usuario_id,
              'nombre_completo', p.nombre_completo,
              'email', p.email,
              'rol', uc.rol,
              'rol_nombre', rs.nombre,
              'cargo', uc.cargo,
              'activo', uc.activo,
              'ultimo_acceso_at', uc.ultimo_acceso_at,
              'created_at', uc.created_at,
              'desactivado_at', uc.desactivado_at,
              'permisos_personalizados',
                exists (
                  select 1
                  from public.usuarios_permisos as up0
                  where up0.usuario_comercio_id = uc.id
                ),
              'permisos_efectivos',
                coalesce(
                  (
                    select jsonb_object_agg(
                      ps.codigo,
                      public.usuario_tiene_permiso_comercio(
                        uc.usuario_id,
                        p_comercio_id,
                        ps.codigo
                      )
                      order by ps.orden
                    )
                    from public.permisos_sistema as ps
                    where ps.activo = true
                  ),
                  '{}'::jsonb
                )
            )
            order by
              uc.activo desc,
              rs.orden,
              coalesce(p.nombre_completo, p.email)
          )
          from public.usuarios_comercios as uc
          inner join public.roles_sistema as rs
            on rs.codigo = uc.rol
          left join public.perfiles as p
            on p.id = uc.usuario_id
          where uc.comercio_id = p_comercio_id
        ),
        '[]'::jsonb
      ),

    'roles',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'codigo', rs.codigo,
              'nombre', rs.nombre,
              'descripcion', rs.descripcion,
              'es_administrador', rs.es_administrador
            )
            order by rs.orden
          )
          from public.roles_sistema as rs
          where rs.activo = true
        ),
        '[]'::jsonb
      ),

    'permisos_catalogo',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'codigo', ps.codigo,
              'modulo', ps.modulo,
              'accion', ps.accion,
              'nombre', ps.nombre,
              'descripcion', ps.descripcion,
              'sensible', ps.sensible
            )
            order by ps.orden
          )
          from public.permisos_sistema as ps
          where ps.activo = true
        ),
        '[]'::jsonb
      ),

    'invitaciones',
      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'id', ic.id,
              'email', ic.email,
              'rol', ic.rol,
              'cargo', ic.cargo,
              'estado', ic.estado,
              'vence_at', ic.vence_at,
              'created_at', ic.created_at
            )
            order by ic.created_at desc
          )
          from public.invitaciones_comercio as ic
          where ic.comercio_id = p_comercio_id
        ),
        '[]'::jsonb
      )
  )
  into v_resultado;

  return v_resultado;
end;
$$;

-- =====================================================
-- 14. CREAR INVITACIÓN
-- =====================================================

create or replace function
public.crear_invitacion_comercio(
  p_comercio_id uuid,
  p_email text,
  p_rol text,
  p_cargo text default null,
  p_dias_vigencia integer default 7
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email text;
  v_token text;
  v_token_hash text;
  v_invitacion public.invitaciones_comercio;
begin
  if not public.es_admin_comercio(
    p_comercio_id
  ) then
    raise exception
      'Solo un administrador puede invitar usuarios';
  end if;

  v_email := lower(trim(coalesce(p_email, '')));

  if v_email = ''
    or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception
      'Ingresá un correo electrónico válido';
  end if;

  if not exists (
    select 1
    from public.roles_sistema as rs
    where rs.codigo = p_rol
      and rs.activo = true
  ) then
    raise exception 'El rol seleccionado no es válido';
  end if;

  if p_dias_vigencia not between 1 and 30 then
    raise exception
      'La invitación debe vencer entre 1 y 30 días';
  end if;

  if exists (
    select 1
    from public.usuarios_comercios as uc
    inner join public.perfiles as p
      on p.id = uc.usuario_id
    where uc.comercio_id = p_comercio_id
      and lower(p.email) = v_email
      and uc.activo = true
  ) then
    raise exception
      'Ese usuario ya posee acceso activo al comercio';
  end if;

  update public.invitaciones_comercio as ic
  set
    estado = 'revocada',
    revocado_por = auth.uid(),
    revocado_at = now()
  where ic.comercio_id = p_comercio_id
    and ic.email = v_email
    and ic.estado = 'pendiente';

  v_token := encode(gen_random_bytes(32), 'hex');
  v_token_hash :=
    encode(
      digest(v_token, 'sha256'),
      'hex'
    );

  insert into public.invitaciones_comercio (
    comercio_id,
    email,
    rol,
    cargo,
    token_hash,
    vence_at,
    invitado_por
  )
  values (
    p_comercio_id,
    v_email,
    p_rol,
    nullif(trim(coalesce(p_cargo, '')), ''),
    v_token_hash,
    now() + make_interval(days => p_dias_vigencia),
    auth.uid()
  )
  returning *
  into v_invitacion;

  perform public.registrar_auditoria_usuario_comercio(
    p_comercio_id,
    null,
    'invitacion_creada',
    jsonb_build_object(
      'invitacion_id', v_invitacion.id,
      'email', v_email,
      'rol', p_rol,
      'vence_at', v_invitacion.vence_at
    )
  );

  return jsonb_build_object(
    'id', v_invitacion.id,
    'email', v_invitacion.email,
    'rol', v_invitacion.rol,
    'cargo', v_invitacion.cargo,
    'vence_at', v_invitacion.vence_at,
    'token', v_token
  );
end;
$$;

-- =====================================================
-- 15. ACEPTAR INVITACIÓN
-- =====================================================

create or replace function
public.aceptar_invitacion_comercio(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_usuario auth.users;
  v_token_hash text;
  v_invitacion public.invitaciones_comercio;
  v_usuario_comercio public.usuarios_comercios;
  v_nombre text;
begin
  if auth.uid() is null then
    raise exception
      'Debés iniciar sesión para aceptar la invitación';
  end if;

  if nullif(trim(coalesce(p_token, '')), '') is null then
    raise exception 'La invitación no contiene un token válido';
  end if;

  select au.*
  into v_usuario
  from auth.users as au
  where au.id = auth.uid();

  if not found
    or nullif(trim(coalesce(v_usuario.email, '')), '') is null then
    raise exception
      'No se pudo identificar el correo del usuario';
  end if;

  v_token_hash :=
    encode(
      digest(trim(p_token), 'sha256'),
      'hex'
    );

  select ic.*
  into v_invitacion
  from public.invitaciones_comercio as ic
  where ic.token_hash = v_token_hash
  for update;

  if not found then
    raise exception
      'La invitación no existe o el enlace es inválido';
  end if;

  if v_invitacion.estado <> 'pendiente' then
    raise exception
      'La invitación ya no se encuentra disponible';
  end if;

  if v_invitacion.vence_at <= now() then
    raise exception 'La invitación se encuentra vencida';
  end if;

  if lower(v_usuario.email) <> v_invitacion.email then
    raise exception
      'La invitación fue emitida para otro correo electrónico';
  end if;

  v_nombre := coalesce(
    nullif(
      trim(
        coalesce(
          v_usuario.raw_user_meta_data->>'full_name',
          v_usuario.raw_user_meta_data->>'name',
          ''
        )
      ),
      ''
    ),
    split_part(v_usuario.email, '@', 1)
  );

  insert into public.perfiles (
    id,
    nombre_completo,
    email
  )
  values (
    v_usuario.id,
    v_nombre,
    lower(v_usuario.email)
  )
  on conflict (id) do update
  set
    nombre_completo = coalesce(
      nullif(public.perfiles.nombre_completo, ''),
      excluded.nombre_completo
    ),
    email = excluded.email;

  insert into public.usuarios_comercios (
    usuario_id,
    comercio_id,
    rol,
    activo,
    cargo,
    invitado_por,
    desactivado_at,
    desactivado_por,
    ultimo_acceso_at
  )
  values (
    v_usuario.id,
    v_invitacion.comercio_id,
    v_invitacion.rol,
    true,
    v_invitacion.cargo,
    v_invitacion.invitado_por,
    null,
    null,
    now()
  )
  on conflict (usuario_id, comercio_id) do update
  set
    rol = excluded.rol,
    activo = true,
    cargo = excluded.cargo,
    invitado_por = excluded.invitado_por,
    desactivado_at = null,
    desactivado_por = null,
    ultimo_acceso_at = now()
  returning *
  into v_usuario_comercio;

  update public.invitaciones_comercio as ic
  set
    estado = 'aceptada',
    aceptado_por = v_usuario.id,
    aceptado_at = now()
  where ic.id = v_invitacion.id;

  perform public.registrar_auditoria_usuario_comercio(
    v_invitacion.comercio_id,
    v_usuario_comercio.id,
    'invitacion_aceptada',
    jsonb_build_object(
      'invitacion_id', v_invitacion.id,
      'email', v_invitacion.email,
      'rol', v_invitacion.rol
    )
  );

  return jsonb_build_object(
    'comercio_id', v_invitacion.comercio_id,
    'usuario_comercio_id', v_usuario_comercio.id,
    'rol', v_usuario_comercio.rol,
    'activo', v_usuario_comercio.activo
  );
end;
$$;

-- =====================================================
-- 16. REVOCAR INVITACIÓN
-- =====================================================

create or replace function
public.revocar_invitacion_comercio(
  p_invitacion_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invitacion public.invitaciones_comercio;
begin
  select ic.*
  into v_invitacion
  from public.invitaciones_comercio as ic
  where ic.id = p_invitacion_id
  for update;

  if not found then
    raise exception 'Invitación no encontrada';
  end if;

  if not public.es_admin_comercio(
    v_invitacion.comercio_id
  ) then
    raise exception
      'Solo un administrador puede revocar invitaciones';
  end if;

  if v_invitacion.estado <> 'pendiente' then
    raise exception
      'Solo se pueden revocar invitaciones pendientes';
  end if;

  update public.invitaciones_comercio as ic
  set
    estado = 'revocada',
    revocado_por = auth.uid(),
    revocado_at = now()
  where ic.id = p_invitacion_id
  returning *
  into v_invitacion;

  perform public.registrar_auditoria_usuario_comercio(
    v_invitacion.comercio_id,
    null,
    'invitacion_revocada',
    jsonb_build_object(
      'invitacion_id', v_invitacion.id,
      'email', v_invitacion.email
    )
  );

  return jsonb_build_object(
    'id', v_invitacion.id,
    'estado', v_invitacion.estado
  );
end;
$$;

-- =====================================================
-- 17. CAMBIAR ROL
-- =====================================================

create or replace function
public.cambiar_rol_usuario_comercio(
  p_usuario_comercio_id uuid,
  p_rol text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario public.usuarios_comercios;
  v_rol_anterior text;
begin
  select uc.*
  into v_usuario
  from public.usuarios_comercios as uc
  where uc.id = p_usuario_comercio_id
  for update;

  if not found then
    raise exception 'Usuario del comercio no encontrado';
  end if;

  if not public.es_admin_comercio(
    v_usuario.comercio_id
  ) then
    raise exception
      'Solo un administrador puede cambiar roles';
  end if;

  if v_usuario.usuario_id = auth.uid() then
    raise exception
      'No podés cambiar tu propio rol';
  end if;

  if not exists (
    select 1
    from public.roles_sistema as rs
    where rs.codigo = p_rol
      and rs.activo = true
  ) then
    raise exception 'El rol seleccionado no es válido';
  end if;

  v_rol_anterior := v_usuario.rol;

  update public.usuarios_comercios as uc
  set rol = p_rol
  where uc.id = p_usuario_comercio_id
  returning *
  into v_usuario;

  -- Al cambiar el rol, se limpian excepciones previas para que
  -- el nuevo rol comience con su matriz predeterminada.
  delete from public.usuarios_permisos as up
  where up.usuario_comercio_id = p_usuario_comercio_id;

  perform public.registrar_auditoria_usuario_comercio(
    v_usuario.comercio_id,
    v_usuario.id,
    'rol_modificado',
    jsonb_build_object(
      'rol_anterior', v_rol_anterior,
      'rol_nuevo', v_usuario.rol
    )
  );

  return jsonb_build_object(
    'usuario_comercio_id', v_usuario.id,
    'rol', v_usuario.rol,
    'activo', v_usuario.activo
  );
end;
$$;

-- =====================================================
-- 18. ACTIVAR O DESACTIVAR USUARIO
-- =====================================================

create or replace function
public.cambiar_estado_usuario_comercio(
  p_usuario_comercio_id uuid,
  p_activo boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario public.usuarios_comercios;
begin
  select uc.*
  into v_usuario
  from public.usuarios_comercios as uc
  where uc.id = p_usuario_comercio_id
  for update;

  if not found then
    raise exception 'Usuario del comercio no encontrado';
  end if;

  if not public.es_admin_comercio(
    v_usuario.comercio_id
  ) then
    raise exception
      'Solo un administrador puede activar o desactivar usuarios';
  end if;

  if v_usuario.usuario_id = auth.uid()
    and coalesce(p_activo, false) = false then
    raise exception
      'No podés desactivar tu propio acceso';
  end if;

  update public.usuarios_comercios as uc
  set
    activo = coalesce(p_activo, false),
    desactivado_at =
      case
        when coalesce(p_activo, false) then null
        else now()
      end,
    desactivado_por =
      case
        when coalesce(p_activo, false) then null
        else auth.uid()
      end
  where uc.id = p_usuario_comercio_id
  returning *
  into v_usuario;

  perform public.registrar_auditoria_usuario_comercio(
    v_usuario.comercio_id,
    v_usuario.id,
    case
      when v_usuario.activo then 'usuario_reactivado'
      else 'usuario_desactivado'
    end,
    jsonb_build_object(
      'activo', v_usuario.activo
    )
  );

  return jsonb_build_object(
    'usuario_comercio_id', v_usuario.id,
    'rol', v_usuario.rol,
    'activo', v_usuario.activo,
    'desactivado_at', v_usuario.desactivado_at
  );
end;
$$;

-- =====================================================
-- 19. GUARDAR PERMISOS INDIVIDUALES
-- =====================================================

create or replace function
public.guardar_permisos_usuario(
  p_usuario_comercio_id uuid,
  p_permisos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario public.usuarios_comercios;
  v_item record;
begin
  select uc.*
  into v_usuario
  from public.usuarios_comercios as uc
  where uc.id = p_usuario_comercio_id
  for update;

  if not found then
    raise exception 'Usuario del comercio no encontrado';
  end if;

  if not public.es_admin_comercio(
    v_usuario.comercio_id
  ) then
    raise exception
      'Solo un administrador puede modificar permisos';
  end if;

  if v_usuario.rol = 'admin' then
    raise exception
      'Los administradores poseen todos los permisos y no admiten restricciones individuales';
  end if;

  if p_permisos is null
    or jsonb_typeof(p_permisos) <> 'object' then
    raise exception
      'Los permisos deben enviarse como un objeto JSON';
  end if;

  for v_item in
    select key, value
    from jsonb_each(p_permisos)
  loop
    if not exists (
      select 1
      from public.permisos_sistema as ps
      where ps.codigo = v_item.key
        and ps.activo = true
    ) then
      raise exception
        'El permiso % no existe o está inactivo',
        v_item.key;
    end if;

    if v_item.value = 'null'::jsonb then
      delete from public.usuarios_permisos as up
      where up.usuario_comercio_id =
        p_usuario_comercio_id
        and up.permiso_codigo = v_item.key;
    else
      if jsonb_typeof(v_item.value) <> 'boolean' then
        raise exception
          'El permiso % debe ser verdadero, falso o nulo',
          v_item.key;
      end if;

      insert into public.usuarios_permisos (
        usuario_comercio_id,
        permiso_codigo,
        permitido,
        actualizado_por
      )
      values (
        p_usuario_comercio_id,
        v_item.key,
        (v_item.value #>> '{}')::boolean,
        auth.uid()
      )
      on conflict (
        usuario_comercio_id,
        permiso_codigo
      ) do update
      set
        permitido = excluded.permitido,
        actualizado_por = excluded.actualizado_por,
        updated_at = now();
    end if;
  end loop;

  perform public.registrar_auditoria_usuario_comercio(
    v_usuario.comercio_id,
    v_usuario.id,
    'permisos_modificados',
    jsonb_build_object(
      'cambios', p_permisos
    )
  );

  return jsonb_build_object(
    'usuario_comercio_id', v_usuario.id,
    'rol', v_usuario.rol,
    'permisos_efectivos',
      coalesce(
        (
          select jsonb_object_agg(
            ps.codigo,
            public.usuario_tiene_permiso_comercio(
              v_usuario.usuario_id,
              v_usuario.comercio_id,
              ps.codigo
            )
            order by ps.orden
          )
          from public.permisos_sistema as ps
          where ps.activo = true
        ),
        '{}'::jsonb
      )
  );
end;
$$;

create or replace function
public.restablecer_permisos_usuario(
  p_usuario_comercio_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario public.usuarios_comercios;
begin
  select uc.*
  into v_usuario
  from public.usuarios_comercios as uc
  where uc.id = p_usuario_comercio_id
  for update;

  if not found then
    raise exception 'Usuario del comercio no encontrado';
  end if;

  if not public.es_admin_comercio(
    v_usuario.comercio_id
  ) then
    raise exception
      'Solo un administrador puede restablecer permisos';
  end if;

  delete from public.usuarios_permisos as up
  where up.usuario_comercio_id =
    p_usuario_comercio_id;

  perform public.registrar_auditoria_usuario_comercio(
    v_usuario.comercio_id,
    v_usuario.id,
    'permisos_restablecidos',
    jsonb_build_object(
      'rol', v_usuario.rol
    )
  );

  return jsonb_build_object(
    'usuario_comercio_id', v_usuario.id,
    'rol', v_usuario.rol,
    'permisos_efectivos',
      coalesce(
        (
          select jsonb_object_agg(
            ps.codigo,
            public.usuario_tiene_permiso_comercio(
              v_usuario.usuario_id,
              v_usuario.comercio_id,
              ps.codigo
            )
            order by ps.orden
          )
          from public.permisos_sistema as ps
          where ps.activo = true
        ),
        '{}'::jsonb
      )
  );
end;
$$;

-- =====================================================
-- 20. REGISTRAR ÚLTIMO ACCESO
-- =====================================================

create or replace function
public.registrar_acceso_comercio(
  p_comercio_id uuid
)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fecha timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  update public.usuarios_comercios as uc
  set ultimo_acceso_at = now()
  where uc.usuario_id = auth.uid()
    and uc.comercio_id = p_comercio_id
    and uc.activo = true
  returning uc.ultimo_acceso_at
  into v_fecha;

  if not found then
    raise exception
      'El usuario no posee acceso activo al comercio';
  end if;

  return v_fecha;
end;
$$;

-- =====================================================
-- 21. ROW LEVEL SECURITY
-- =====================================================

alter table public.roles_sistema
  enable row level security;

alter table public.permisos_sistema
  enable row level security;

alter table public.roles_permisos
  enable row level security;

alter table public.usuarios_permisos
  enable row level security;

alter table public.invitaciones_comercio
  enable row level security;

alter table public.auditoria_usuarios_comercio
  enable row level security;

drop policy if exists
roles_sistema_select_authenticated
on public.roles_sistema;

create policy
roles_sistema_select_authenticated
on public.roles_sistema
for select
to authenticated
using (auth.uid() is not null);

drop policy if exists
permisos_sistema_select_authenticated
on public.permisos_sistema;

create policy
permisos_sistema_select_authenticated
on public.permisos_sistema
for select
to authenticated
using (auth.uid() is not null);

drop policy if exists
roles_permisos_select_authenticated
on public.roles_permisos;

create policy
roles_permisos_select_authenticated
on public.roles_permisos
for select
to authenticated
using (auth.uid() is not null);

drop policy if exists
usuarios_permisos_select
on public.usuarios_permisos;

create policy
usuarios_permisos_select
on public.usuarios_permisos
for select
to authenticated
using (
  exists (
    select 1
    from public.usuarios_comercios as uc
    where uc.id = usuario_comercio_id
      and (
        uc.usuario_id = auth.uid()
        or public.es_admin_comercio(
          uc.comercio_id
        )
      )
  )
);

drop policy if exists
usuarios_permisos_insert_admin
on public.usuarios_permisos;

create policy
usuarios_permisos_insert_admin
on public.usuarios_permisos
for insert
to authenticated
with check (
  exists (
    select 1
    from public.usuarios_comercios as uc
    where uc.id = usuario_comercio_id
      and public.es_admin_comercio(
        uc.comercio_id
      )
  )
);

drop policy if exists
usuarios_permisos_update_admin
on public.usuarios_permisos;

create policy
usuarios_permisos_update_admin
on public.usuarios_permisos
for update
to authenticated
using (
  exists (
    select 1
    from public.usuarios_comercios as uc
    where uc.id = usuario_comercio_id
      and public.es_admin_comercio(
        uc.comercio_id
      )
  )
)
with check (
  exists (
    select 1
    from public.usuarios_comercios as uc
    where uc.id = usuario_comercio_id
      and public.es_admin_comercio(
        uc.comercio_id
      )
  )
);

drop policy if exists
usuarios_permisos_delete_admin
on public.usuarios_permisos;

create policy
usuarios_permisos_delete_admin
on public.usuarios_permisos
for delete
to authenticated
using (
  exists (
    select 1
    from public.usuarios_comercios as uc
    where uc.id = usuario_comercio_id
      and public.es_admin_comercio(
        uc.comercio_id
      )
  )
);

drop policy if exists
invitaciones_comercio_select_admin
on public.invitaciones_comercio;

create policy
invitaciones_comercio_select_admin
on public.invitaciones_comercio
for select
to authenticated
using (
  public.es_admin_comercio(comercio_id)
);

drop policy if exists
auditoria_usuarios_select_admin
on public.auditoria_usuarios_comercio;

create policy
auditoria_usuarios_select_admin
on public.auditoria_usuarios_comercio
for select
to authenticated
using (
  public.es_admin_comercio(comercio_id)
);

-- Se elimina el borrado directo de asignaciones.
-- Los usuarios se desactivan para conservar trazabilidad.
drop policy if exists
usuarios_comercios_delete_admin
on public.usuarios_comercios;

-- =====================================================
-- 22. PRIVILEGIOS
-- =====================================================

revoke all on table
public.roles_sistema
from anon;

revoke all on table
public.permisos_sistema
from anon;

revoke all on table
public.roles_permisos
from anon;

revoke all on table
public.usuarios_permisos
from anon;

revoke all on table
public.invitaciones_comercio
from anon;

revoke all on table
public.auditoria_usuarios_comercio
from anon;

grant select on table
public.roles_sistema,
public.permisos_sistema,
public.roles_permisos,
public.usuarios_permisos,
public.invitaciones_comercio,
public.auditoria_usuarios_comercio
to authenticated;

revoke all on function
public.tiene_permiso_comercio(uuid, text)
from public, anon;

revoke all on function
public.exigir_permiso_comercio(uuid, text)
from public, anon;

revoke all on function
public.obtener_mis_permisos(uuid)
from public, anon;

revoke all on function
public.obtener_usuarios_comercio(uuid)
from public, anon;

revoke all on function
public.crear_invitacion_comercio(
  uuid,
  text,
  text,
  text,
  integer
)
from public, anon;

revoke all on function
public.aceptar_invitacion_comercio(text)
from public, anon;

revoke all on function
public.revocar_invitacion_comercio(uuid)
from public, anon;

revoke all on function
public.cambiar_rol_usuario_comercio(uuid, text)
from public, anon;

revoke all on function
public.cambiar_estado_usuario_comercio(uuid, boolean)
from public, anon;

revoke all on function
public.guardar_permisos_usuario(uuid, jsonb)
from public, anon;

revoke all on function
public.restablecer_permisos_usuario(uuid)
from public, anon;

revoke all on function
public.registrar_acceso_comercio(uuid)
from public, anon;

grant execute on function
public.tiene_permiso_comercio(uuid, text)
to authenticated;

grant execute on function
public.exigir_permiso_comercio(uuid, text)
to authenticated;

grant execute on function
public.obtener_mis_permisos(uuid)
to authenticated;

grant execute on function
public.obtener_usuarios_comercio(uuid)
to authenticated;

grant execute on function
public.crear_invitacion_comercio(
  uuid,
  text,
  text,
  text,
  integer
)
to authenticated;

grant execute on function
public.aceptar_invitacion_comercio(text)
to authenticated;

grant execute on function
public.revocar_invitacion_comercio(uuid)
to authenticated;

grant execute on function
public.cambiar_rol_usuario_comercio(uuid, text)
to authenticated;

grant execute on function
public.cambiar_estado_usuario_comercio(uuid, boolean)
to authenticated;

grant execute on function
public.guardar_permisos_usuario(uuid, jsonb)
to authenticated;

grant execute on function
public.restablecer_permisos_usuario(uuid)
to authenticated;

grant execute on function
public.registrar_acceso_comercio(uuid)
to authenticated;

commit;

-- =====================================================
-- 23. VERIFICACIÓN
-- =====================================================

select jsonb_build_object(
  'roles',
    (
      select count(*)
      from public.roles_sistema
      where activo = true
    ),
  'permisos',
    (
      select count(*)
      from public.permisos_sistema
      where activo = true
    ),
  'permisos_admin',
    (
      select count(*)
      from public.roles_permisos
      where rol = 'admin'
        and permitido = true
    ),
  'permisos_vendedor',
    (
      select count(*)
      from public.roles_permisos
      where rol = 'vendedor'
        and permitido = true
    ),
  'permisos_empleado',
    (
      select count(*)
      from public.roles_permisos
      where rol = 'empleado'
        and permitido = true
    ),
  'funciones',
    (
      select jsonb_agg(
        p.proname
        order by p.proname
      )
      from pg_proc as p
      inner join pg_namespace as n
        on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in (
          'aceptar_invitacion_comercio',
          'cambiar_estado_usuario_comercio',
          'cambiar_rol_usuario_comercio',
          'crear_invitacion_comercio',
          'exigir_permiso_comercio',
          'guardar_permisos_usuario',
          'obtener_mis_permisos',
          'obtener_usuarios_comercio',
          'registrar_acceso_comercio',
          'restablecer_permisos_usuario',
          'revocar_invitacion_comercio',
          'tiene_permiso_comercio'
        )
    )
) as usuarios_roles_permisos_instalados;