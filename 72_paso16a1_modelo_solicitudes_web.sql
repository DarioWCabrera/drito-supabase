-- ============================================================
-- DRITO
-- PASO 16A.1
-- MODELO BASE DE SOLICITUDES WEB
--
-- Objetivo:
--   catálogo / web -> SOL-xxxxxx -> revisión en Drito
--   -> futura conversión a cliente/cotización.
--
-- IMPORTANTE:
-- - Esta migración NO publica ninguna RPC para anon.
-- - Esta migración NO modifica la web pública.
-- - Esta migración NO modifica WhatsApp.
-- - Todas las configuraciones nacen DESHABILITADAS.
-- - No crea clientes ni cotizaciones automáticamente.
-- ============================================================


-- ============================================================
-- 1. PERMISOS DEL MÓDULO
-- ============================================================

insert into public.permisos_sistema (
  codigo,
  modulo,
  accion,
  nombre,
  descripcion,
  sensible,
  orden,
  activo
)
values

(
  'solicitudes_web.ver',
  'solicitudes_web',
  'ver',
  'Ver solicitudes web',
  'Permite consultar solicitudes de cotización recibidas desde canales web.',
  false,
  1600,
  true
),

(
  'solicitudes_web.gestionar',
  'solicitudes_web',
  'gestionar',
  'Gestionar solicitudes web',
  'Permite revisar y cambiar el estado operativo de solicitudes web.',
  false,
  1610,
  true
),

(
  'solicitudes_web.convertir',
  'solicitudes_web',
  'convertir',
  'Convertir solicitudes web',
  'Permite convertir una solicitud web revisada en una cotización de Drito.',
  false,
  1620,
  true
),

(
  'solicitudes_web.configurar',
  'solicitudes_web',
  'configurar',
  'Configurar solicitudes web',
  'Permite habilitar, deshabilitar y administrar el canal público de solicitudes web.',
  true,
  1630,
  true
)

on conflict (codigo)
do update set
  modulo = excluded.modulo,
  accion = excluded.accion,
  nombre = excluded.nombre,
  descripcion = excluded.descripcion,
  sensible = excluded.sensible,
  orden = excluded.orden,
  activo = excluded.activo,
  updated_at = now();


-- ============================================================
-- 2. PERMISOS PREDETERMINADOS POR ROL
--
-- Admin:
--   acceso completo.
--
-- Vendedor:
--   puede ver, gestionar y convertir.
--   NO puede habilitar/deshabilitar el canal público.
--
-- Empleado:
--   no recibe permisos automáticamente.
--   El admin podrá asignarlos individualmente.
-- ============================================================

insert into public.roles_permisos (
  rol,
  permiso_codigo,
  permitido
)
values
  ('admin', 'solicitudes_web.ver', true),
  ('admin', 'solicitudes_web.gestionar', true),
  ('admin', 'solicitudes_web.convertir', true),
  ('admin', 'solicitudes_web.configurar', true),

  ('vendedor', 'solicitudes_web.ver', true),
  ('vendedor', 'solicitudes_web.gestionar', true),
  ('vendedor', 'solicitudes_web.convertir', true)

on conflict do nothing;


-- ============================================================
-- 3. CONFIGURACIÓN DEL CANAL WEB
--
-- Cada comercio posee:
-- - identificador público independiente;
-- - bandera de activación;
-- - trazabilidad de activación.
--
-- habilitado nace SIEMPRE en false.
--
-- canal_publico NO es una contraseña.
-- Es un identificador público del canal.
-- La seguridad real del alta se implementará mediante
-- RPC/backend, validaciones, rate limiting y captcha.
-- ============================================================

create table public.configuraciones_solicitudes_web (

  comercio_id uuid primary key
    references public.comercios(id)
    on delete cascade,

  canal_publico uuid not null
    default gen_random_uuid(),

  habilitado boolean not null
    default false,

  habilitado_at timestamptz null,

  habilitado_por uuid null,

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),

  constraint configuraciones_solicitudes_web_canal_unique
    unique (canal_publico),

  constraint configuraciones_solicitudes_web_habilitacion_check
    check (
      habilitado = false
      or habilitado_at is not null
    )

);


-- ============================================================
-- 4. CONTADOR SOL-xxxxxx POR COMERCIO
-- ============================================================

create table public.solicitud_web_contadores (

  comercio_id uuid primary key
    references public.comercios(id)
    on delete cascade,

  ultimo_numero bigint not null
    default 0,

  updated_at timestamptz not null
    default now(),

  constraint solicitud_web_contadores_numero_check
    check (ultimo_numero >= 0)

);


-- ============================================================
-- 5. CABECERA DE SOLICITUD WEB
--
-- numero:
--   Se transformará en SOL-000001, SOL-000002, etc.
--
-- clave_idempotencia:
--   permitirá evitar duplicados por doble click,
--   reintentos o problemas de conexión.
--
-- La solicitud conserva los datos enviados por el interesado,
-- pero NO exige que exista todavía un cliente en Drito.
-- ============================================================

create table public.solicitudes_web (

  id uuid primary key
    default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  numero bigint not null,

  clave_idempotencia uuid not null,

  estado text not null
    default 'recibida',

  origen text not null
    default 'web',

  nombre_contacto text not null,

  empresa text null,

  telefono text null,

  email text null,

  cuit_cuil text null,

  mensaje text null,

  origen_url text null,

  cliente_id uuid null
    references public.clientes(id)
    on delete set null,

  cotizacion_id uuid null
    references public.cotizaciones(id)
    on delete set null,

  revisado_por uuid null,

  revisado_at timestamptz null,

  convertido_por uuid null,

  convertido_at timestamptz null,

  descartado_por uuid null,

  descartado_at timestamptz null,

  motivo_descarte text null,

  created_at timestamptz not null
    default now(),

  updated_at timestamptz not null
    default now(),

  constraint solicitudes_web_numero_unique
    unique (
      comercio_id,
      numero
    ),

  constraint solicitudes_web_id_comercio_unique
    unique (
      id,
      comercio_id
    ),

  constraint solicitudes_web_idempotencia_unique
    unique (
      comercio_id,
      clave_idempotencia
    ),

  constraint solicitudes_web_numero_check
    check (
      numero > 0
    ),

  constraint solicitudes_web_estado_check
    check (
      estado in (
        'recibida',
        'en_revision',
        'convertida',
        'descartada'
      )
    ),

  constraint solicitudes_web_origen_check
    check (
      origen in (
        'web',
        'catalogo',
        'api',
        'manual'
      )
    ),

  constraint solicitudes_web_nombre_check
    check (
      length(trim(nombre_contacto)) >= 2
    ),

  constraint solicitudes_web_contacto_check
    check (
      nullif(trim(coalesce(telefono, '')), '') is not null
      or
      nullif(trim(coalesce(email, '')), '') is not null
    ),

  constraint solicitudes_web_descarte_check
    check (
      estado <> 'descartada'
      or (
        descartado_at is not null
        and nullif(
          trim(coalesce(motivo_descarte, '')),
          ''
        ) is not null
      )
    )

);


-- ============================================================
-- 6. ÍTEMS DE LA SOLICITUD
--
-- Se conserva snapshot del producto.
--
-- Esto es importante porque el catálogo puede cambiar después:
-- nombre, código, descripción, precio o moneda.
--
-- producto_id es opcional para no perder la solicitud si
-- el producto luego es eliminado/desactivado.
-- ============================================================

create table public.items_solicitud_web (

  id uuid primary key
    default gen_random_uuid(),

  solicitud_id uuid not null,

  comercio_id uuid not null,

  producto_id uuid null
    references public.productos(id)
    on delete set null,

  cantidad numeric(18, 4) not null,

  codigo_snapshot text null,

  nombre_snapshot text not null,

  descripcion_snapshot text null,

  unidad_medida_snapshot text null,

  precio_referencia numeric(18, 4) null,

  moneda_snapshot text null,

  observaciones text null,

  created_at timestamptz not null
    default now(),

  constraint items_solicitud_web_solicitud_comercio_fkey
    foreign key (
      solicitud_id,
      comercio_id
    )
    references public.solicitudes_web(
      id,
      comercio_id
    )
    on delete cascade,

  constraint items_solicitud_web_cantidad_check
    check (
      cantidad > 0
    ),

  constraint items_solicitud_web_nombre_check
    check (
      length(trim(nombre_snapshot)) >= 1
    ),

  constraint items_solicitud_web_precio_check
    check (
      precio_referencia is null
      or precio_referencia >= 0
    )

);


-- ============================================================
-- 7. ÍNDICES
-- ============================================================

create index solicitudes_web_comercio_estado_fecha_idx
  on public.solicitudes_web (
    comercio_id,
    estado,
    created_at desc
  );


create index solicitudes_web_comercio_fecha_idx
  on public.solicitudes_web (
    comercio_id,
    created_at desc
  );


create index solicitudes_web_cliente_idx
  on public.solicitudes_web (
    cliente_id
  )
  where cliente_id is not null;


create index solicitudes_web_cotizacion_idx
  on public.solicitudes_web (
    cotizacion_id
  )
  where cotizacion_id is not null;


create index items_solicitud_web_solicitud_idx
  on public.items_solicitud_web (
    solicitud_id
  );


create index items_solicitud_web_producto_idx
  on public.items_solicitud_web (
    producto_id
  )
  where producto_id is not null;


-- ============================================================
-- 8. UPDATED_AT
--
-- Reutilizamos el trigger genérico ya existente en Drito.
-- La ejecución directa del helper continúa revocada;
-- eso NO impide su funcionamiento como trigger.
-- ============================================================

create trigger configuraciones_solicitudes_web_updated_at
before update
on public.configuraciones_solicitudes_web
for each row
execute function public.actualizar_updated_at();


create trigger solicitudes_web_updated_at
before update
on public.solicitudes_web
for each row
execute function public.actualizar_updated_at();


-- ============================================================
-- 9. CREAR CONFIGURACIÓN DESHABILITADA PARA COMERCIOS EXISTENTES
-- ============================================================

insert into public.configuraciones_solicitudes_web (
  comercio_id
)
select
  c.id
from public.comercios c
on conflict (comercio_id)
do nothing;


-- ============================================================
-- 10. RLS
-- ============================================================

alter table public.configuraciones_solicitudes_web
enable row level security;

alter table public.solicitud_web_contadores
enable row level security;

alter table public.solicitudes_web
enable row level security;

alter table public.items_solicitud_web
enable row level security;


-- ============================================================
-- 11. SIN ACCESO DIRECTO DE ESCRITURA
--
-- El alta pública se implementará más adelante mediante una
-- entrada controlada.
--
-- Hasta ese momento:
-- anon NO puede leer ni escribir nada.
-- authenticated NO puede escribir directamente.
-- ============================================================

revoke all
on public.configuraciones_solicitudes_web
from public, anon, authenticated;

revoke all
on public.solicitud_web_contadores
from public, anon, authenticated;

revoke all
on public.solicitudes_web
from public, anon, authenticated;

revoke all
on public.items_solicitud_web
from public, anon, authenticated;


-- ============================================================
-- 12. LECTURA INTERNA CONTROLADA
-- ============================================================

grant select
on public.solicitudes_web
to authenticated;

grant select
on public.items_solicitud_web
to authenticated;

grant select
on public.configuraciones_solicitudes_web
to authenticated;


-- ============================================================
-- 13. POLÍTICAS DE LECTURA
-- ============================================================

create policy drito_perm_solicitudes_web_select
on public.solicitudes_web
for select
to authenticated
using (
  public.tiene_permiso_comercio(
    comercio_id,
    'solicitudes_web.ver'
  )
);


create policy drito_perm_items_solicitud_web_select
on public.items_solicitud_web
for select
to authenticated
using (
  public.tiene_permiso_comercio(
    comercio_id,
    'solicitudes_web.ver'
  )
);


create policy drito_perm_config_solicitudes_web_select
on public.configuraciones_solicitudes_web
for select
to authenticated
using (
  public.tiene_permiso_comercio(
    comercio_id,
    'solicitudes_web.configurar'
  )
);


-- ============================================================
-- 14. POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 15. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

select jsonb_build_object(

  'tabla_configuracion_existe',
    to_regclass(
      'public.configuraciones_solicitudes_web'
    ) is not null,

  'tabla_contador_existe',
    to_regclass(
      'public.solicitud_web_contadores'
    ) is not null,

  'tabla_solicitudes_existe',
    to_regclass(
      'public.solicitudes_web'
    ) is not null,

  'tabla_items_existe',
    to_regclass(
      'public.items_solicitud_web'
    ) is not null,

  'rls_configuracion',
    (
      select relrowsecurity
      from pg_class
      where oid =
        'public.configuraciones_solicitudes_web'::regclass
    ),

  'rls_contador',
    (
      select relrowsecurity
      from pg_class
      where oid =
        'public.solicitud_web_contadores'::regclass
    ),

  'rls_solicitudes',
    (
      select relrowsecurity
      from pg_class
      where oid =
        'public.solicitudes_web'::regclass
    ),

  'rls_items',
    (
      select relrowsecurity
      from pg_class
      where oid =
        'public.items_solicitud_web'::regclass
    ),

  'permisos_modulo',
    (
      select count(*)
      from public.permisos_sistema
      where codigo in (
        'solicitudes_web.ver',
        'solicitudes_web.gestionar',
        'solicitudes_web.convertir',
        'solicitudes_web.configurar'
      )
      and activo = true
    ),

  'permisos_admin',
    (
      select count(*)
      from public.roles_permisos
      where rol = 'admin'
        and permiso_codigo like 'solicitudes_web.%'
        and permitido = true
    ),

  'permisos_vendedor',
    (
      select count(*)
      from public.roles_permisos
      where rol = 'vendedor'
        and permiso_codigo in (
          'solicitudes_web.ver',
          'solicitudes_web.gestionar',
          'solicitudes_web.convertir'
        )
        and permitido = true
    ),

  'configuraciones_creadas',
    (
      select count(*)
      from public.configuraciones_solicitudes_web
    ),

  'configuraciones_habilitadas',
    (
      select count(*)
      from public.configuraciones_solicitudes_web
      where habilitado = true
    ),

  'solicitudes_actuales',
    (
      select count(*)
      from public.solicitudes_web
    ),

  'items_actuales',
    (
      select count(*)
      from public.items_solicitud_web
    ),

  'anon_select_solicitudes',
    has_table_privilege(
      'anon',
      'public.solicitudes_web',
      'SELECT'
    ),

  'anon_insert_solicitudes',
    has_table_privilege(
      'anon',
      'public.solicitudes_web',
      'INSERT'
    ),

  'authenticated_insert_solicitudes',
    has_table_privilege(
      'authenticated',
      'public.solicitudes_web',
      'INSERT'
    )

) as verificacion_16a1;