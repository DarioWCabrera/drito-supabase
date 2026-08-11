-- =====================================================
-- DRITO - CONFIGURACIÓN GENERAL DEL COMERCIO
-- Archivo: 23_configuracion_comercio.sql
--
-- Amplía la estructura existente sin reemplazarla.
-- Prepara Drito para:
--   - Datos comerciales
--   - Identidad visual
--   - Preferencias operativas
--   - Módulos habilitados
--   - Datos fiscales previos a ARCA
--   - Carga segura de logos en Supabase Storage
--
-- IMPORTANTE:
--   Este módulo NO almacena certificados ni claves privadas de ARCA.
--   Esos secretos se gestionarán más adelante desde un backend seguro.
-- =====================================================

begin;

-- =====================================================
-- 1. DATOS COMPLEMENTARIOS DEL COMERCIO
-- =====================================================

alter table public.comercios
  add column if not exists localidad text,
  add column if not exists provincia text,
  add column if not exists codigo_postal text,
  add column if not exists pais text not null default 'Argentina',
  add column if not exists sitio_web text;

comment on column public.comercios.modo_facturacion is
  'Modo operativo actual. manual hasta que el backend ARCA habilite producción.';

-- =====================================================
-- 2. AMPLIACIÓN DE CONFIGURACIONES GENERALES
-- =====================================================

alter table public.configuraciones_comercio
  add column if not exists color_acento text
    not null default '#0ea5e9',

  add column if not exists zona_horaria text
    not null default 'America/Argentina/Buenos_Aires',

  add column if not exists idioma text
    not null default 'es-AR',

  add column if not exists cotizacion_validez_dias integer
    not null default 15,

  add column if not exists decimales_cantidad smallint
    not null default 2,

  add column if not exists alerta_stock_bajo boolean
    not null default true,

  add column if not exists permitir_stock_negativo boolean
    not null default false,

  add column if not exists controla_stock_por_defecto boolean
    not null default true,

  add column if not exists formato_fecha text
    not null default 'DD/MM/YYYY',

  add column if not exists mostrar_logo_comprobantes boolean
    not null default true,

  add column if not exists mostrar_datos_comercio_comprobantes boolean
    not null default true,

  add column if not exists modulos_habilitados jsonb
    not null default jsonb_build_object(
      'clientes', true,
      'productos', true,
      'stock', true,
      'cotizaciones', true,
      'ventas', true,
      'proveedores', true,
      'compras', true,
      'caja', true,
      'cuentas_corrientes', true,
      'gastos', true,
      'reportes', true,
      'facturacion_electronica', false
    );

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname =
      'configuraciones_comercio_cotizacion_validez_check'
  ) then
    alter table public.configuraciones_comercio
      add constraint
      configuraciones_comercio_cotizacion_validez_check
      check (
        cotizacion_validez_dias between 1 and 365
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname =
      'configuraciones_comercio_decimales_check'
  ) then
    alter table public.configuraciones_comercio
      add constraint
      configuraciones_comercio_decimales_check
      check (
        decimales_cantidad between 0 and 3
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname =
      'configuraciones_comercio_formato_fecha_check'
  ) then
    alter table public.configuraciones_comercio
      add constraint
      configuraciones_comercio_formato_fecha_check
      check (
        formato_fecha in (
          'DD/MM/YYYY',
          'YYYY-MM-DD'
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname =
      'configuraciones_comercio_modulos_json_check'
  ) then
    alter table public.configuraciones_comercio
      add constraint
      configuraciones_comercio_modulos_json_check
      check (
        jsonb_typeof(modulos_habilitados) = 'object'
      );
  end if;
end;
$$;

-- =====================================================
-- 3. CONFIGURACIÓN FISCAL PREVIA A ARCA
-- =====================================================

create table if not exists
public.configuraciones_fiscales_comercio (
  comercio_id uuid primary key
    references public.comercios(id) on delete cascade,

  condicion_iva text not null default 'no_configurada'
    check (
      condicion_iva in (
        'no_configurada',
        'responsable_inscripto',
        'monotributista',
        'exento',
        'no_responsable'
      )
    ),

  ingresos_brutos text,
  inicio_actividades date,

  domicilio_fiscal text,
  localidad_fiscal text,
  provincia_fiscal text,
  codigo_postal_fiscal text,

  concepto_facturacion text
    not null default 'productos_y_servicios'
    check (
      concepto_facturacion in (
        'productos',
        'servicios',
        'productos_y_servicios'
      )
    ),

  punto_venta integer
    check (
      punto_venta is null
      or punto_venta between 1 and 99999
    ),

  ambiente_arca text not null default 'homologacion'
    check (
      ambiente_arca in (
        'homologacion',
        'produccion'
      )
    ),

  tipos_comprobante_habilitados jsonb
    not null default '[]'::jsonb
    check (
      jsonb_typeof(tipos_comprobante_habilitados) = 'array'
    ),

  leyenda_factura text,

  facturacion_electronica_activa boolean
    not null default false,

  estado_arca text not null default 'datos_incompletos'
    check (
      estado_arca in (
        'no_configurado',
        'datos_incompletos',
        'credenciales_pendientes',
        'homologacion',
        'produccion',
        'error'
      )
    ),

  certificado_alias text,
  certificado_vencimiento date,
  certificado_identificador text,

  ultimo_control_arca_at timestamptz,
  ultimo_error_arca text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.configuraciones_fiscales_comercio is
  'Datos fiscales y metadatos de ARCA. No almacena certificados ni claves privadas.';

comment on column
public.configuraciones_fiscales_comercio.certificado_identificador is
  'Identificador o huella informativa. Nunca contiene la clave privada.';

-- =====================================================
-- 4. FILAS INICIALES PARA COMERCIOS EXISTENTES
-- =====================================================

insert into public.configuraciones_comercio (
  comercio_id
)
select c.id
from public.comercios as c
on conflict (comercio_id) do nothing;

insert into public.configuraciones_fiscales_comercio (
  comercio_id
)
select c.id
from public.comercios as c
on conflict (comercio_id) do nothing;

-- =====================================================
-- 5. INICIALIZACIÓN AUTOMÁTICA PARA COMERCIOS NUEVOS
-- =====================================================

create or replace function
public.inicializar_configuraciones_comercio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.configuraciones_comercio (
    comercio_id
  )
  values (
    new.id
  )
  on conflict (comercio_id) do nothing;

  insert into public.configuraciones_fiscales_comercio (
    comercio_id
  )
  values (
    new.id
  )
  on conflict (comercio_id) do nothing;

  return new;
end;
$$;

drop trigger if exists
comercios_inicializar_configuraciones
on public.comercios;

create trigger comercios_inicializar_configuraciones
after insert on public.comercios
for each row
execute function
public.inicializar_configuraciones_comercio();

-- =====================================================
-- 6. UPDATED_AT DE LA CONFIGURACIÓN FISCAL
-- =====================================================

drop trigger if exists
configuraciones_fiscales_comercio_updated_at
on public.configuraciones_fiscales_comercio;

create trigger
configuraciones_fiscales_comercio_updated_at
before update
on public.configuraciones_fiscales_comercio
for each row
execute function public.actualizar_updated_at();

-- =====================================================
-- 7. RLS DE LA CONFIGURACIÓN FISCAL
-- =====================================================

alter table public.configuraciones_fiscales_comercio
  enable row level security;

drop policy if exists
configuracion_fiscal_select_miembro
on public.configuraciones_fiscales_comercio;

create policy configuracion_fiscal_select_miembro
on public.configuraciones_fiscales_comercio
for select
to authenticated
using (
  public.pertenece_a_comercio(comercio_id)
);

drop policy if exists
configuracion_fiscal_insert_admin
on public.configuraciones_fiscales_comercio;

create policy configuracion_fiscal_insert_admin
on public.configuraciones_fiscales_comercio
for insert
to authenticated
with check (
  public.es_admin_comercio(comercio_id)
);

drop policy if exists
configuracion_fiscal_update_admin
on public.configuraciones_fiscales_comercio;

create policy configuracion_fiscal_update_admin
on public.configuraciones_fiscales_comercio
for update
to authenticated
using (
  public.es_admin_comercio(comercio_id)
)
with check (
  public.es_admin_comercio(comercio_id)
);

-- =====================================================
-- 8. BUCKET PÚBLICO PARA LOGOS
-- =====================================================

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'logos-comercios',
  'logos-comercios',
  true,
  5242880,
  array[
    'image/png',
    'image/jpeg',
    'image/webp'
  ]
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- La primera carpeta del archivo debe ser el UUID del comercio.
-- Ejemplo:
--   <comercio_id>/logo-1720000000000.webp

drop policy if exists
logos_comercios_select_miembro
on storage.objects;

create policy logos_comercios_select_miembro
on storage.objects
for select
to authenticated
using (
  bucket_id = 'logos-comercios'
  and split_part(name, '/', 1) ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and public.pertenece_a_comercio(
    split_part(name, '/', 1)::uuid
  )
);

drop policy if exists
logos_comercios_insert_admin
on storage.objects;

create policy logos_comercios_insert_admin
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'logos-comercios'
  and split_part(name, '/', 1) ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and public.es_admin_comercio(
    split_part(name, '/', 1)::uuid
  )
);

drop policy if exists
logos_comercios_update_admin
on storage.objects;

create policy logos_comercios_update_admin
on storage.objects
for update
to authenticated
using (
  bucket_id = 'logos-comercios'
  and split_part(name, '/', 1) ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and public.es_admin_comercio(
    split_part(name, '/', 1)::uuid
  )
)
with check (
  bucket_id = 'logos-comercios'
  and split_part(name, '/', 1) ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and public.es_admin_comercio(
    split_part(name, '/', 1)::uuid
  )
);

drop policy if exists
logos_comercios_delete_admin
on storage.objects;

create policy logos_comercios_delete_admin
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'logos-comercios'
  and split_part(name, '/', 1) ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  and public.es_admin_comercio(
    split_part(name, '/', 1)::uuid
  )
);

-- =====================================================
-- 9. OBTENER TODA LA CONFIGURACIÓN
-- =====================================================

create or replace function
public.obtener_configuracion_comercio(
  p_comercio_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_resultado jsonb;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_comercio_id is null then
    raise exception 'El comercio es obligatorio';
  end if;

  if not public.pertenece_a_comercio(
    p_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio indicado';
  end if;

  select jsonb_build_object(
    'comercio',
      jsonb_build_object(
        'id', c.id,
        'nombre_comercial', c.nombre_comercial,
        'razon_social', c.razon_social,
        'cuit', c.cuit,
        'email', c.email,
        'telefono', c.telefono,
        'direccion', c.direccion,
        'localidad', c.localidad,
        'provincia', c.provincia,
        'codigo_postal', c.codigo_postal,
        'pais', c.pais,
        'sitio_web', c.sitio_web,
        'slug', c.slug,
        'activo', c.activo,
        'modo_facturacion', c.modo_facturacion
      ),

    'apariencia',
      jsonb_build_object(
        'logo_url', cfg.logo_url,
        'color_primario', cfg.color_primario,
        'color_secundario', cfg.color_secundario,
        'color_acento', cfg.color_acento
      ),

    'preferencias',
      jsonb_build_object(
        'moneda', cfg.moneda,
        'zona_horaria', cfg.zona_horaria,
        'idioma', cfg.idioma,
        'cotizacion_validez_dias',
          cfg.cotizacion_validez_dias,
        'decimales_cantidad',
          cfg.decimales_cantidad,
        'alerta_stock_bajo',
          cfg.alerta_stock_bajo,
        'permitir_stock_negativo',
          cfg.permitir_stock_negativo,
        'controla_stock_por_defecto',
          cfg.controla_stock_por_defecto,
        'formato_fecha',
          cfg.formato_fecha,
        'mostrar_logo_comprobantes',
          cfg.mostrar_logo_comprobantes,
        'mostrar_datos_comercio_comprobantes',
          cfg.mostrar_datos_comercio_comprobantes,
        'texto_cotizacion',
          cfg.texto_cotizacion,
        'texto_comprobante',
          cfg.texto_comprobante
      ),

    'modulos',
      cfg.modulos_habilitados,

    'fiscal',
      jsonb_build_object(
        'condicion_iva', fis.condicion_iva,
        'ingresos_brutos', fis.ingresos_brutos,
        'inicio_actividades', fis.inicio_actividades,
        'domicilio_fiscal', fis.domicilio_fiscal,
        'localidad_fiscal', fis.localidad_fiscal,
        'provincia_fiscal', fis.provincia_fiscal,
        'codigo_postal_fiscal',
          fis.codigo_postal_fiscal,
        'concepto_facturacion',
          fis.concepto_facturacion,
        'punto_venta', fis.punto_venta,
        'ambiente_arca', fis.ambiente_arca,
        'tipos_comprobante_habilitados',
          fis.tipos_comprobante_habilitados,
        'leyenda_factura', fis.leyenda_factura,
        'facturacion_electronica_activa',
          fis.facturacion_electronica_activa,
        'estado_arca', fis.estado_arca,
        'certificado_alias',
          fis.certificado_alias,
        'certificado_vencimiento',
          fis.certificado_vencimiento,
        'ultimo_control_arca_at',
          fis.ultimo_control_arca_at,
        'ultimo_error_arca',
          fis.ultimo_error_arca
      ),

    'permisos',
      jsonb_build_object(
        'puede_editar',
          public.es_admin_comercio(p_comercio_id)
      ),

    'estado_configuracion',
      jsonb_build_object(
        'datos_comerciales_completos',
          (
            nullif(trim(c.nombre_comercial), '') is not null
            and nullif(trim(coalesce(c.email, '')), '')
              is not null
            and nullif(trim(coalesce(c.telefono, '')), '')
              is not null
          ),

        'datos_fiscales_completos',
          (
            c.cuit ~ '^[0-9]{11}$'
            and fis.condicion_iva <> 'no_configurada'
            and fis.punto_venta is not null
            and nullif(
              trim(coalesce(fis.domicilio_fiscal, '')),
              ''
            ) is not null
          ),

        'logo_configurado',
          nullif(trim(coalesce(cfg.logo_url, '')), '')
            is not null,

        'arca_lista_para_credenciales',
          (
            c.cuit ~ '^[0-9]{11}$'
            and fis.condicion_iva <> 'no_configurada'
            and fis.punto_venta is not null
          )
      )
  )
  into v_resultado
  from public.comercios as c
  inner join public.configuraciones_comercio as cfg
    on cfg.comercio_id = c.id
  inner join public.configuraciones_fiscales_comercio as fis
    on fis.comercio_id = c.id
  where c.id = p_comercio_id;

  if v_resultado is null then
    raise exception
      'No se encontró la configuración del comercio';
  end if;

  return v_resultado;
end;
$$;

-- =====================================================
-- 10. GUARDAR DATOS COMERCIALES
-- =====================================================

create or replace function
public.guardar_datos_comercio(
  p_comercio_id uuid,
  p_datos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actual public.comercios;
  v_nombre_comercial text;
  v_razon_social text;
  v_cuit text;
  v_email text;
  v_telefono text;
  v_direccion text;
  v_localidad text;
  v_provincia text;
  v_codigo_postal text;
  v_pais text;
  v_sitio_web text;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if not public.es_admin_comercio(
    p_comercio_id
  ) then
    raise exception
      'Solo un administrador puede modificar la configuración';
  end if;

  if p_datos is null
    or jsonb_typeof(p_datos) <> 'object' then
    raise exception
      'Los datos comerciales deben enviarse como un objeto';
  end if;

  select c.*
  into v_actual
  from public.comercios as c
  where c.id = p_comercio_id
  for update;

  if not found then
    raise exception 'Comercio no encontrado';
  end if;

  v_nombre_comercial :=
    case
      when p_datos ? 'nombre_comercial' then
        trim(coalesce(
          p_datos->>'nombre_comercial',
          ''
        ))
      else v_actual.nombre_comercial
    end;

  if char_length(v_nombre_comercial) < 2 then
    raise exception
      'El nombre comercial debe tener al menos 2 caracteres';
  end if;

  v_razon_social :=
    case
      when p_datos ? 'razon_social' then
        nullif(trim(coalesce(
          p_datos->>'razon_social',
          ''
        )), '')
      else v_actual.razon_social
    end;

  v_cuit :=
    case
      when p_datos ? 'cuit' then
        nullif(
          regexp_replace(
            coalesce(p_datos->>'cuit', ''),
            '[^0-9]',
            '',
            'g'
          ),
          ''
        )
      else v_actual.cuit
    end;

  if v_cuit is not null
    and v_cuit !~ '^[0-9]{11}$' then
    raise exception
      'El CUIT debe contener exactamente 11 números';
  end if;

  v_email :=
    case
      when p_datos ? 'email' then
        nullif(lower(trim(coalesce(
          p_datos->>'email',
          ''
        ))), '')
      else v_actual.email
    end;

  if v_email is not null
    and v_email !~*
      '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' then
    raise exception
      'El correo electrónico no tiene un formato válido';
  end if;

  v_telefono :=
    case
      when p_datos ? 'telefono' then
        nullif(trim(coalesce(
          p_datos->>'telefono',
          ''
        )), '')
      else v_actual.telefono
    end;

  v_direccion :=
    case
      when p_datos ? 'direccion' then
        nullif(trim(coalesce(
          p_datos->>'direccion',
          ''
        )), '')
      else v_actual.direccion
    end;

  v_localidad :=
    case
      when p_datos ? 'localidad' then
        nullif(trim(coalesce(
          p_datos->>'localidad',
          ''
        )), '')
      else v_actual.localidad
    end;

  v_provincia :=
    case
      when p_datos ? 'provincia' then
        nullif(trim(coalesce(
          p_datos->>'provincia',
          ''
        )), '')
      else v_actual.provincia
    end;

  v_codigo_postal :=
    case
      when p_datos ? 'codigo_postal' then
        nullif(trim(coalesce(
          p_datos->>'codigo_postal',
          ''
        )), '')
      else v_actual.codigo_postal
    end;

  v_pais :=
    case
      when p_datos ? 'pais' then
        coalesce(
          nullif(trim(coalesce(
            p_datos->>'pais',
            ''
          )), ''),
          'Argentina'
        )
      else v_actual.pais
    end;

  v_sitio_web :=
    case
      when p_datos ? 'sitio_web' then
        nullif(trim(coalesce(
          p_datos->>'sitio_web',
          ''
        )), '')
      else v_actual.sitio_web
    end;

  update public.comercios as c
  set
    nombre_comercial = v_nombre_comercial,
    razon_social = v_razon_social,
    cuit = v_cuit,
    email = v_email,
    telefono = v_telefono,
    direccion = v_direccion,
    localidad = v_localidad,
    provincia = v_provincia,
    codigo_postal = v_codigo_postal,
    pais = v_pais,
    sitio_web = v_sitio_web
  where c.id = p_comercio_id;

  return public.obtener_configuracion_comercio(
    p_comercio_id
  );
end;
$$;

-- =====================================================
-- 11. GUARDAR APARIENCIA Y PREFERENCIAS
-- =====================================================

create or replace function
public.guardar_preferencias_comercio(
  p_comercio_id uuid,
  p_datos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actual public.configuraciones_comercio;
  v_logo_url text;
  v_color_primario text;
  v_color_secundario text;
  v_color_acento text;
  v_moneda text;
  v_zona_horaria text;
  v_idioma text;
  v_validez integer;
  v_decimales smallint;
  v_formato_fecha text;
  v_modulos jsonb;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if not public.es_admin_comercio(
    p_comercio_id
  ) then
    raise exception
      'Solo un administrador puede modificar la configuración';
  end if;

  if p_datos is null
    or jsonb_typeof(p_datos) <> 'object' then
    raise exception
      'Las preferencias deben enviarse como un objeto';
  end if;

  insert into public.configuraciones_comercio (
    comercio_id
  )
  values (
    p_comercio_id
  )
  on conflict (comercio_id) do nothing;

  select cfg.*
  into v_actual
  from public.configuraciones_comercio as cfg
  where cfg.comercio_id = p_comercio_id
  for update;

  v_logo_url :=
    case
      when p_datos ? 'logo_url' then
        nullif(trim(coalesce(
          p_datos->>'logo_url',
          ''
        )), '')
      else v_actual.logo_url
    end;

  v_color_primario :=
    case
      when p_datos ? 'color_primario' then
        lower(trim(coalesce(
          p_datos->>'color_primario',
          ''
        )))
      else v_actual.color_primario
    end;

  v_color_secundario :=
    case
      when p_datos ? 'color_secundario' then
        lower(trim(coalesce(
          p_datos->>'color_secundario',
          ''
        )))
      else v_actual.color_secundario
    end;

  v_color_acento :=
    case
      when p_datos ? 'color_acento' then
        lower(trim(coalesce(
          p_datos->>'color_acento',
          ''
        )))
      else v_actual.color_acento
    end;

  if v_color_primario !~ '^#[0-9a-f]{6}$'
    or v_color_secundario !~ '^#[0-9a-f]{6}$'
    or v_color_acento !~ '^#[0-9a-f]{6}$' then
    raise exception
      'Los colores deben tener formato hexadecimal, por ejemplo #4f46e5';
  end if;

  v_moneda :=
    case
      when p_datos ? 'moneda' then
        upper(trim(coalesce(
          p_datos->>'moneda',
          ''
        )))
      else v_actual.moneda
    end;

  if v_moneda !~ '^[A-Z]{3}$' then
    raise exception
      'La moneda debe tener un código de 3 letras';
  end if;

  v_zona_horaria :=
    case
      when p_datos ? 'zona_horaria' then
        coalesce(
          nullif(trim(coalesce(
            p_datos->>'zona_horaria',
            ''
          )), ''),
          v_actual.zona_horaria
        )
      else v_actual.zona_horaria
    end;

  if not exists (
    select 1
    from pg_timezone_names
    where name = v_zona_horaria
  ) then
    raise exception
      'La zona horaria indicada no es válida';
  end if;

  v_idioma :=
    case
      when p_datos ? 'idioma' then
        coalesce(
          nullif(trim(coalesce(
            p_datos->>'idioma',
            ''
          )), ''),
          v_actual.idioma
        )
      else v_actual.idioma
    end;

  v_validez :=
    case
      when p_datos ? 'cotizacion_validez_dias' then
        (p_datos->>'cotizacion_validez_dias')::integer
      else v_actual.cotizacion_validez_dias
    end;

  if v_validez not between 1 and 365 then
    raise exception
      'La validez de cotización debe estar entre 1 y 365 días';
  end if;

  v_decimales :=
    case
      when p_datos ? 'decimales_cantidad' then
        (p_datos->>'decimales_cantidad')::smallint
      else v_actual.decimales_cantidad
    end;

  if v_decimales not between 0 and 3 then
    raise exception
      'Los decimales de cantidad deben estar entre 0 y 3';
  end if;

  v_formato_fecha :=
    case
      when p_datos ? 'formato_fecha' then
        trim(coalesce(
          p_datos->>'formato_fecha',
          ''
        ))
      else v_actual.formato_fecha
    end;

  if v_formato_fecha not in (
    'DD/MM/YYYY',
    'YYYY-MM-DD'
  ) then
    raise exception
      'El formato de fecha seleccionado no está permitido';
  end if;

  v_modulos := v_actual.modulos_habilitados;

  if p_datos ? 'modulos_habilitados' then
    if jsonb_typeof(
      p_datos->'modulos_habilitados'
    ) <> 'object' then
      raise exception
        'La configuración de módulos debe ser un objeto';
    end if;

    v_modulos :=
      coalesce(v_modulos, '{}'::jsonb)
      || p_datos->'modulos_habilitados';
  end if;

  update public.configuraciones_comercio as cfg
  set
    logo_url = v_logo_url,
    color_primario = v_color_primario,
    color_secundario = v_color_secundario,
    color_acento = v_color_acento,
    moneda = v_moneda,
    zona_horaria = v_zona_horaria,
    idioma = v_idioma,
    cotizacion_validez_dias = v_validez,
    decimales_cantidad = v_decimales,

    alerta_stock_bajo =
      case
        when p_datos ? 'alerta_stock_bajo' then
          coalesce(
            (p_datos->>'alerta_stock_bajo')::boolean,
            cfg.alerta_stock_bajo
          )
        else cfg.alerta_stock_bajo
      end,

    permitir_stock_negativo =
      case
        when p_datos ? 'permitir_stock_negativo' then
          coalesce(
            (p_datos->>'permitir_stock_negativo')::boolean,
            cfg.permitir_stock_negativo
          )
        else cfg.permitir_stock_negativo
      end,

    controla_stock_por_defecto =
      case
        when p_datos ? 'controla_stock_por_defecto' then
          coalesce(
            (p_datos->>'controla_stock_por_defecto')::boolean,
            cfg.controla_stock_por_defecto
          )
        else cfg.controla_stock_por_defecto
      end,

    formato_fecha = v_formato_fecha,

    mostrar_logo_comprobantes =
      case
        when p_datos ? 'mostrar_logo_comprobantes' then
          coalesce(
            (p_datos->>'mostrar_logo_comprobantes')::boolean,
            cfg.mostrar_logo_comprobantes
          )
        else cfg.mostrar_logo_comprobantes
      end,

    mostrar_datos_comercio_comprobantes =
      case
        when p_datos ?
          'mostrar_datos_comercio_comprobantes' then
          coalesce(
            (
              p_datos
              ->>'mostrar_datos_comercio_comprobantes'
            )::boolean,
            cfg.mostrar_datos_comercio_comprobantes
          )
        else
          cfg.mostrar_datos_comercio_comprobantes
      end,

    texto_cotizacion =
      case
        when p_datos ? 'texto_cotizacion' then
          nullif(trim(coalesce(
            p_datos->>'texto_cotizacion',
            ''
          )), '')
        else cfg.texto_cotizacion
      end,

    texto_comprobante =
      case
        when p_datos ? 'texto_comprobante' then
          nullif(trim(coalesce(
            p_datos->>'texto_comprobante',
            ''
          )), '')
        else cfg.texto_comprobante
      end,

    modulos_habilitados = v_modulos
  where cfg.comercio_id = p_comercio_id;

  return public.obtener_configuracion_comercio(
    p_comercio_id
  );
exception
  when invalid_text_representation then
    raise exception
      'Una preferencia numérica o booleana tiene un formato inválido';
end;
$$;

-- =====================================================
-- 12. GUARDAR DATOS FISCALES PREVIOS A ARCA
-- =====================================================

create or replace function
public.guardar_configuracion_fiscal_comercio(
  p_comercio_id uuid,
  p_datos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actual public.configuraciones_fiscales_comercio;
  v_comercio public.comercios;

  v_condicion_iva text;
  v_concepto_facturacion text;
  v_punto_venta integer;
  v_ambiente_arca text;
  v_tipos jsonb;
  v_estado_arca text;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if not public.es_admin_comercio(
    p_comercio_id
  ) then
    raise exception
      'Solo un administrador puede modificar la configuración fiscal';
  end if;

  if p_datos is null
    or jsonb_typeof(p_datos) <> 'object' then
    raise exception
      'Los datos fiscales deben enviarse como un objeto';
  end if;

  select c.*
  into v_comercio
  from public.comercios as c
  where c.id = p_comercio_id;

  if not found then
    raise exception 'Comercio no encontrado';
  end if;

  insert into public.configuraciones_fiscales_comercio (
    comercio_id
  )
  values (
    p_comercio_id
  )
  on conflict (comercio_id) do nothing;

  select fis.*
  into v_actual
  from public.configuraciones_fiscales_comercio as fis
  where fis.comercio_id = p_comercio_id
  for update;

  v_condicion_iva :=
    case
      when p_datos ? 'condicion_iva' then
        lower(trim(coalesce(
          p_datos->>'condicion_iva',
          ''
        )))
      else v_actual.condicion_iva
    end;

  if v_condicion_iva not in (
    'no_configurada',
    'responsable_inscripto',
    'monotributista',
    'exento',
    'no_responsable'
  ) then
    raise exception
      'La condición frente al IVA no es válida';
  end if;

  v_concepto_facturacion :=
    case
      when p_datos ? 'concepto_facturacion' then
        lower(trim(coalesce(
          p_datos->>'concepto_facturacion',
          ''
        )))
      else v_actual.concepto_facturacion
    end;

  if v_concepto_facturacion not in (
    'productos',
    'servicios',
    'productos_y_servicios'
  ) then
    raise exception
      'El concepto de facturación no es válido';
  end if;

  v_punto_venta :=
    case
      when p_datos ? 'punto_venta' then
        nullif(
          trim(coalesce(
            p_datos->>'punto_venta',
            ''
          )),
          ''
        )::integer
      else v_actual.punto_venta
    end;

  if v_punto_venta is not null
    and v_punto_venta not between 1 and 99999 then
    raise exception
      'El punto de venta debe estar entre 1 y 99999';
  end if;

  v_ambiente_arca :=
    case
      when p_datos ? 'ambiente_arca' then
        lower(trim(coalesce(
          p_datos->>'ambiente_arca',
          ''
        )))
      else v_actual.ambiente_arca
    end;

  if v_ambiente_arca not in (
    'homologacion',
    'produccion'
  ) then
    raise exception
      'El ambiente de ARCA no es válido';
  end if;

  v_tipos := v_actual.tipos_comprobante_habilitados;

  if p_datos ? 'tipos_comprobante_habilitados' then
    if jsonb_typeof(
      p_datos->'tipos_comprobante_habilitados'
    ) <> 'array' then
      raise exception
        'Los comprobantes habilitados deben enviarse como una lista';
    end if;

    v_tipos :=
      p_datos->'tipos_comprobante_habilitados';
  end if;

  v_estado_arca :=
    case
      when v_comercio.cuit ~ '^[0-9]{11}$'
        and v_condicion_iva <> 'no_configurada'
        and v_punto_venta is not null
      then 'credenciales_pendientes'
      else 'datos_incompletos'
    end;

  update public.configuraciones_fiscales_comercio as fis
  set
    condicion_iva = v_condicion_iva,

    ingresos_brutos =
      case
        when p_datos ? 'ingresos_brutos' then
          nullif(trim(coalesce(
            p_datos->>'ingresos_brutos',
            ''
          )), '')
        else fis.ingresos_brutos
      end,

    inicio_actividades =
      case
        when p_datos ? 'inicio_actividades' then
          nullif(trim(coalesce(
            p_datos->>'inicio_actividades',
            ''
          )), '')::date
        else fis.inicio_actividades
      end,

    domicilio_fiscal =
      case
        when p_datos ? 'domicilio_fiscal' then
          nullif(trim(coalesce(
            p_datos->>'domicilio_fiscal',
            ''
          )), '')
        else fis.domicilio_fiscal
      end,

    localidad_fiscal =
      case
        when p_datos ? 'localidad_fiscal' then
          nullif(trim(coalesce(
            p_datos->>'localidad_fiscal',
            ''
          )), '')
        else fis.localidad_fiscal
      end,

    provincia_fiscal =
      case
        when p_datos ? 'provincia_fiscal' then
          nullif(trim(coalesce(
            p_datos->>'provincia_fiscal',
            ''
          )), '')
        else fis.provincia_fiscal
      end,

    codigo_postal_fiscal =
      case
        when p_datos ? 'codigo_postal_fiscal' then
          nullif(trim(coalesce(
            p_datos->>'codigo_postal_fiscal',
            ''
          )), '')
        else fis.codigo_postal_fiscal
      end,

    concepto_facturacion =
      v_concepto_facturacion,

    punto_venta = v_punto_venta,
    ambiente_arca = v_ambiente_arca,

    tipos_comprobante_habilitados =
      v_tipos,

    leyenda_factura =
      case
        when p_datos ? 'leyenda_factura' then
          nullif(trim(coalesce(
            p_datos->>'leyenda_factura',
            ''
          )), '')
        else fis.leyenda_factura
      end,

    estado_arca = v_estado_arca,

    -- Estos campos los controlará el backend seguro de ARCA.
    facturacion_electronica_activa = false,
    ultimo_error_arca = null
  where fis.comercio_id = p_comercio_id;

  return public.obtener_configuracion_comercio(
    p_comercio_id
  );
exception
  when invalid_text_representation then
    raise exception
      'Una fecha o el punto de venta tiene un formato inválido';
end;
$$;

-- =====================================================
-- 13. RESTABLECER COLORES DE DRITO
-- =====================================================

create or replace function
public.restablecer_colores_comercio(
  p_comercio_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if not public.es_admin_comercio(
    p_comercio_id
  ) then
    raise exception
      'Solo un administrador puede modificar la configuración';
  end if;

  update public.configuraciones_comercio
  set
    color_primario = '#4f46e5',
    color_secundario = '#111827',
    color_acento = '#0ea5e9'
  where comercio_id = p_comercio_id;

  return public.obtener_configuracion_comercio(
    p_comercio_id
  );
end;
$$;

-- =====================================================
-- 14. PERMISOS DE FUNCIONES
-- =====================================================

revoke all on function
public.obtener_configuracion_comercio(uuid)
from public, anon, authenticated;

revoke all on function
public.guardar_datos_comercio(uuid, jsonb)
from public, anon, authenticated;

revoke all on function
public.guardar_preferencias_comercio(uuid, jsonb)
from public, anon, authenticated;

revoke all on function
public.guardar_configuracion_fiscal_comercio(uuid, jsonb)
from public, anon, authenticated;

revoke all on function
public.restablecer_colores_comercio(uuid)
from public, anon, authenticated;

grant execute on function
public.obtener_configuracion_comercio(uuid)
to authenticated;

grant execute on function
public.guardar_datos_comercio(uuid, jsonb)
to authenticated;

grant execute on function
public.guardar_preferencias_comercio(uuid, jsonb)
to authenticated;

grant execute on function
public.guardar_configuracion_fiscal_comercio(uuid, jsonb)
to authenticated;

grant execute on function
public.restablecer_colores_comercio(uuid)
to authenticated;

-- Las tablas siguen protegidas por RLS.
grant select on table
public.configuraciones_fiscales_comercio
to authenticated;

-- =====================================================
-- 15. VERIFICACIÓN FINAL
-- =====================================================

select jsonb_build_object(
  'columnas_comercio_agregadas',
    (
      select jsonb_agg(column_name order by ordinal_position)
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'comercios'
        and column_name in (
          'localidad',
          'provincia',
          'codigo_postal',
          'pais',
          'sitio_web'
        )
    ),

  'columnas_configuracion_agregadas',
    (
      select jsonb_agg(column_name order by ordinal_position)
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'configuraciones_comercio'
        and column_name in (
          'color_acento',
          'zona_horaria',
          'idioma',
          'cotizacion_validez_dias',
          'decimales_cantidad',
          'alerta_stock_bajo',
          'permitir_stock_negativo',
          'controla_stock_por_defecto',
          'formato_fecha',
          'mostrar_logo_comprobantes',
          'mostrar_datos_comercio_comprobantes',
          'modulos_habilitados'
        )
    ),

  'tabla_fiscal',
    to_regclass(
      'public.configuraciones_fiscales_comercio'
    ) is not null,

  'bucket_logos',
    exists (
      select 1
      from storage.buckets
      where id = 'logos-comercios'
    ),

  'funciones',
    (
      select jsonb_agg(p.proname order by p.proname)
      from pg_proc as p
      inner join pg_namespace as n
        on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in (
          'obtener_configuracion_comercio',
          'guardar_datos_comercio',
          'guardar_preferencias_comercio',
          'guardar_configuracion_fiscal_comercio',
          'restablecer_colores_comercio'
        )
    )
) as configuracion_instalada;

commit;

-- =====================================================
-- FIN DEL MÓDULO DE CONFIGURACIÓN
-- =====================================================