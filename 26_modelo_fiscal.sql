-- ============================================================
-- DRITO - MODULO 26
-- MODELO FISCAL Y ESTRUCTURA PREVIA A ARCA
-- Archivo: 26_modelo_fiscal.sql
--
-- Este script NO se conecta con ARCA, NO solicita CAE/CAEA
-- y NO guarda certificados, claves privadas, Token ni Sign.
--
-- VTA-xxxx sigue siendo la venta interna de Drito.
-- El comprobante fiscal posee numeración fiscal independiente.
-- ============================================================

begin;

-- ============================================================
-- 0. DEPENDENCIAS
-- ============================================================

do $$
begin
  if to_regclass('public.comercios') is null then
    raise exception 'Falta public.comercios';
  end if;

  if to_regclass('public.clientes') is null then
    raise exception 'Falta public.clientes';
  end if;

  if to_regclass('public.ventas') is null then
    raise exception 'Falta public.ventas';
  end if;

  if to_regclass(
    'public.configuraciones_fiscales_comercio'
  ) is null then
    raise exception
      'Ejecutá primero 23_configuracion_comercio.sql';
  end if;

  if to_regclass('public.permisos_sistema') is null
     or to_regclass('public.roles_permisos') is null then
    raise exception
      'Ejecutá primero 24_usuarios_roles_permisos.sql';
  end if;

  if to_regprocedure(
    'public.tiene_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.tiene_permiso_comercio(uuid,text)';
  end if;
end;
$$;

-- ============================================================
-- 1. PERMISOS
-- ============================================================

insert into public.permisos_sistema (
  codigo, modulo, accion, nombre, descripcion,
  sensible, orden, activo
)
values
  ('facturacion.ver', 'facturacion', 'ver',
   'Ver facturación',
   'Consultar comprobantes fiscales y su estado.',
   false, 1200, true),

  ('facturacion.preparar', 'facturacion', 'preparar',
   'Preparar comprobantes',
   'Crear borradores fiscales desde operaciones comerciales.',
   true, 1210, true),

  ('facturacion.emitir', 'facturacion', 'emitir',
   'Emitir comprobantes',
   'Solicitar autorización fiscal de facturas y recibos.',
   true, 1220, true),

  ('facturacion.emitir_notas', 'facturacion', 'emitir_notas',
   'Emitir notas de crédito y débito',
   'Emitir documentos fiscales asociados.',
   true, 1230, true),

  ('facturacion.configurar', 'facturacion', 'configurar',
   'Configurar facturación',
   'Administrar puntos de venta y datos fiscales.',
   true, 1240, true),

  ('facturacion.consultar_arca', 'facturacion', 'consultar_arca',
   'Consultar ARCA',
   'Ejecutar consultas fiscales desde backend seguro.',
   true, 1250, true)
on conflict (codigo) do update
set
  modulo = excluded.modulo,
  accion = excluded.accion,
  nombre = excluded.nombre,
  descripcion = excluded.descripcion,
  sensible = excluded.sensible,
  orden = excluded.orden,
  activo = excluded.activo;

insert into public.roles_permisos (
  rol, permiso_codigo, permitido
)
select 'admin', ps.codigo, true
from public.permisos_sistema as ps
where ps.modulo = 'facturacion'
  and ps.activo = true
on conflict (rol, permiso_codigo) do update
set permitido = excluded.permitido;

-- ============================================================
-- 2. CATALOGOS ARCA
-- ============================================================
-- Son cache local. El backend deberá sincronizarlos con
-- los métodos paramétricos de WSFEv1 antes de producción.

create table if not exists
public.arca_tipos_comprobante (
  codigo smallint primary key,
  descripcion text not null,
  clase text not null
    check (clase in ('A', 'B', 'C', 'M')),
  familia text not null
    check (
      familia in (
        'factura', 'nota_debito',
        'nota_credito', 'recibo'
      )
    ),
  servicio text not null default 'wsfev1',
  activo boolean not null default true,
  fuente text not null default 'wsfev1',
  sincronizado_at timestamptz,
  updated_at timestamptz not null default now()
);

insert into public.arca_tipos_comprobante (
  codigo, descripcion, clase, familia,
  servicio, activo, fuente
)
values
  (1,  'Factura A',          'A', 'factura',      'wsfev1', true, 'seed_arca'),
  (2,  'Nota de Débito A',  'A', 'nota_debito',  'wsfev1', true, 'seed_arca'),
  (3,  'Nota de Crédito A', 'A', 'nota_credito', 'wsfev1', true, 'seed_arca'),
  (4,  'Recibo A',          'A', 'recibo',       'wsfev1', true, 'seed_arca'),
  (6,  'Factura B',          'B', 'factura',      'wsfev1', true, 'seed_arca'),
  (7,  'Nota de Débito B',  'B', 'nota_debito',  'wsfev1', true, 'seed_arca'),
  (8,  'Nota de Crédito B', 'B', 'nota_credito', 'wsfev1', true, 'seed_arca'),
  (9,  'Recibo B',          'B', 'recibo',       'wsfev1', true, 'seed_arca'),
  (11, 'Factura C',          'C', 'factura',      'wsfev1', true, 'seed_arca'),
  (12, 'Nota de Débito C',  'C', 'nota_debito',  'wsfev1', true, 'seed_arca'),
  (13, 'Nota de Crédito C', 'C', 'nota_credito', 'wsfev1', true, 'seed_arca'),
  (15, 'Recibo C',          'C', 'recibo',       'wsfev1', true, 'seed_arca'),
  (51, 'Factura M',          'M', 'factura',      'wsfev1', true, 'seed_arca'),
  (52, 'Nota de Débito M',  'M', 'nota_debito',  'wsfev1', true, 'seed_arca'),
  (53, 'Nota de Crédito M', 'M', 'nota_credito', 'wsfev1', true, 'seed_arca'),
  (54, 'Recibo M',          'M', 'recibo',       'wsfev1', true, 'seed_arca')
on conflict (codigo) do update
set
  descripcion = excluded.descripcion,
  clase = excluded.clase,
  familia = excluded.familia,
  servicio = excluded.servicio,
  activo = excluded.activo,
  fuente = excluded.fuente,
  updated_at = now();

create table if not exists
public.arca_condiciones_iva_receptor (
  codigo smallint primary key,
  descripcion text not null,
  activo boolean not null default true,
  fuente text not null default 'wsfev1',
  sincronizado_at timestamptz,
  updated_at timestamptz not null default now()
);

insert into public.arca_condiciones_iva_receptor (
  codigo, descripcion, activo, fuente
)
values
  (1, 'IVA Responsable Inscripto', true, 'seed_arca'),
  (4, 'IVA Sujeto Exento', true, 'seed_arca'),
  (5, 'Consumidor Final', true, 'seed_arca'),
  (6, 'Responsable Monotributo', true, 'seed_arca'),
  (7, 'Sujeto No Categorizado', true, 'seed_arca'),
  (8, 'Proveedor del Exterior', true, 'seed_arca'),
  (9, 'Cliente del Exterior', true, 'seed_arca'),
  (10, 'IVA Liberado - Ley 19.640', true, 'seed_arca'),
  (13, 'Monotributista Social', true, 'seed_arca'),
  (15, 'IVA No Alcanzado', true, 'seed_arca'),
  (16, 'Monotributo Trabajador Independiente Promovido',
   true, 'seed_arca')
on conflict (codigo) do update
set
  descripcion = excluded.descripcion,
  activo = excluded.activo,
  fuente = excluded.fuente,
  updated_at = now();

create table if not exists
public.arca_tipos_documento (
  codigo integer primary key,
  descripcion text not null,
  activo boolean not null default true,
  fuente text not null default 'wsfev1',
  sincronizado_at timestamptz,
  updated_at timestamptz not null default now()
);

insert into public.arca_tipos_documento (
  codigo, descripcion, activo, fuente
)
values
  (80, 'CUIT', true, 'seed_arca'),
  (86, 'CUIL', true, 'seed_arca'),
  (87, 'CDI', true, 'seed_arca'),
  (99, 'Consumidor Final / Sin identificar', true, 'seed_arca')
on conflict (codigo) do update
set
  descripcion = excluded.descripcion,
  activo = excluded.activo,
  fuente = excluded.fuente,
  updated_at = now();

create table if not exists
public.arca_alicuotas_iva (
  codigo smallint primary key,
  descripcion text not null,
  porcentaje numeric(6,3),
  activo boolean not null default true,
  fuente text not null default 'wsfev1',
  sincronizado_at timestamptz,
  updated_at timestamptz not null default now(),
  check (
    porcentaje is null
    or porcentaje between 0 and 100
  )
);

insert into public.arca_alicuotas_iva (
  codigo, descripcion, porcentaje, activo, fuente
)
values
  (3, 'IVA 0%',    0.000, true, 'seed_arca'),
  (4, 'IVA 10,5%', 10.500, true, 'seed_arca'),
  (5, 'IVA 21%',   21.000, true, 'seed_arca'),
  (6, 'IVA 27%',   27.000, true, 'seed_arca')
on conflict (codigo) do update
set
  descripcion = excluded.descripcion,
  porcentaje = excluded.porcentaje,
  activo = excluded.activo,
  fuente = excluded.fuente,
  updated_at = now();

create table if not exists
public.arca_monedas (
  codigo text primary key
    check (char_length(codigo) between 1 and 5),
  descripcion text not null,
  activo boolean not null default true,
  fuente text not null default 'wsfev1',
  sincronizado_at timestamptz,
  updated_at timestamptz not null default now()
);

insert into public.arca_monedas (
  codigo, descripcion, activo, fuente
)
values
  ('PES', 'Pesos argentinos', true, 'seed_arca')
on conflict (codigo) do update
set
  descripcion = excluded.descripcion,
  activo = excluded.activo,
  fuente = excluded.fuente,
  updated_at = now();

alter table public.configuraciones_fiscales_comercio
  add column if not exists
    catalogos_arca_sincronizados_at timestamptz,
  add column if not exists
    servicio_facturacion text not null default 'wsfev1';


-- ============================================================
-- 3. PUNTOS DE VENTA FISCALES
-- ============================================================

create table if not exists
public.puntos_venta_fiscales (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  numero integer not null
    check (numero between 1 and 99999),

  ambiente_arca text not null default 'homologacion'
    check (
      ambiente_arca in ('homologacion', 'produccion')
    ),

  servicio text not null default 'wsfev1'
    check (servicio in ('wsfev1')),

  descripcion text,
  activo boolean not null default true,
  es_predeterminado boolean not null default false,

  arca_habilitado boolean,
  ultimo_control_arca_at timestamptz,
  ultimo_error_arca text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (comercio_id, ambiente_arca, numero)
);

create unique index if not exists
puntos_venta_fiscales_predeterminado_idx
on public.puntos_venta_fiscales (
  comercio_id, ambiente_arca
)
where es_predeterminado = true
  and activo = true;

create index if not exists
puntos_venta_fiscales_comercio_idx
on public.puntos_venta_fiscales (
  comercio_id, ambiente_arca, activo
);

drop trigger if exists
puntos_venta_fiscales_updated_at
on public.puntos_venta_fiscales;

create trigger puntos_venta_fiscales_updated_at
before update on public.puntos_venta_fiscales
for each row
execute function public.actualizar_updated_at();

-- Migra el punto de venta único del módulo 23 sin eliminarlo.
insert into public.puntos_venta_fiscales (
  comercio_id, numero, ambiente_arca, servicio,
  descripcion, activo, es_predeterminado
)
select
  fis.comercio_id,
  fis.punto_venta,
  fis.ambiente_arca,
  'wsfev1',
  'Punto de venta principal',
  true,
  true
from public.configuraciones_fiscales_comercio as fis
where fis.punto_venta is not null
  and not exists (
    select 1
    from public.puntos_venta_fiscales as pv
    where pv.comercio_id = fis.comercio_id
      and pv.ambiente_arca = fis.ambiente_arca
  );

-- ============================================================
-- 4. DATOS FISCALES DEL CLIENTE
-- ============================================================
-- Tabla 1:1 separada para no romper clientes actuales.

create table if not exists
public.clientes_datos_fiscales (
  cliente_id uuid primary key
    references public.clientes(id) on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  condicion_iva_receptor_id smallint
    references public.arca_condiciones_iva_receptor(codigo),

  documento_tipo_arca integer,
  documento_numero text,

  razon_social_fiscal text,
  domicilio_fiscal text,
  email_fiscal text,

  datos_validados boolean not null default false,
  validado_arca_at timestamptz,

  origen_datos text not null default 'manual'
    check (
      origen_datos in ('manual', 'arca', 'importado')
    ),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (comercio_id, cliente_id)
);

create index if not exists
clientes_datos_fiscales_comercio_idx
on public.clientes_datos_fiscales (comercio_id);

create or replace function
public.validar_cliente_datos_fiscales_comercio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.clientes as c
    where c.id = new.cliente_id
      and c.comercio_id = new.comercio_id
  ) then
    raise exception
      'El cliente fiscal no pertenece al comercio indicado';
  end if;

  return new;
end;
$$;

revoke all on function
public.validar_cliente_datos_fiscales_comercio()
from public, anon, authenticated;

drop trigger if exists
clientes_datos_fiscales_validar_comercio
on public.clientes_datos_fiscales;

create trigger clientes_datos_fiscales_validar_comercio
before insert or update
on public.clientes_datos_fiscales
for each row
execute function
public.validar_cliente_datos_fiscales_comercio();

drop trigger if exists
clientes_datos_fiscales_updated_at
on public.clientes_datos_fiscales;

create trigger clientes_datos_fiscales_updated_at
before update
on public.clientes_datos_fiscales
for each row
execute function public.actualizar_updated_at();

-- ============================================================
-- 5. CABECERA DEL COMPROBANTE FISCAL
-- ============================================================
-- No existe estado "anulado". Un autorizado se corrige con
-- Nota de Crédito/Débito, no editando o borrando la factura.

create table if not exists
public.comprobantes_fiscales (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  venta_id uuid
    references public.ventas(id) on delete set null,

  cliente_id uuid
    references public.clientes(id) on delete set null,

  origen text not null default 'venta'
    check (origen in ('venta', 'manual', 'importado')),

  punto_venta_id uuid
    references public.puntos_venta_fiscales(id)
    on delete restrict,

  punto_venta_numero integer
    check (
      punto_venta_numero is null
      or punto_venta_numero between 1 and 99999
    ),

  ambiente_arca text
    check (
      ambiente_arca is null
      or ambiente_arca in ('homologacion', 'produccion')
    ),

  servicio_arca text not null default 'wsfev1'
    check (servicio_arca in ('wsfev1')),

  tipo_comprobante_arca smallint
    references public.arca_tipos_comprobante(codigo),

  clase text
    check (
      clase is null
      or clase in ('A', 'B', 'C', 'M')
    ),

  familia text
    check (
      familia is null
      or familia in (
        'factura', 'nota_debito',
        'nota_credito', 'recibo'
      )
    ),

  concepto_arca smallint not null default 3
    check (concepto_arca in (1, 2, 3)),

  numero_comprobante bigint
    check (
      numero_comprobante is null
      or numero_comprobante > 0
    ),

  estado text not null default 'borrador'
    check (
      estado in (
        'borrador',
        'pendiente_autorizacion',
        'autorizado',
        'rechazado',
        'error',
        'descartado'
      )
    ),

  fecha_emision date not null default current_date,
  fecha_servicio_desde date,
  fecha_servicio_hasta date,
  fecha_vencimiento_pago date,

  periodo_asociado_desde date,
  periodo_asociado_hasta date,

  -- Snapshot emisor.
  emisor_razon_social text,
  emisor_nombre_comercial text,
  emisor_cuit text,
  emisor_condicion_iva text,
  emisor_ingresos_brutos text,
  emisor_inicio_actividades date,
  emisor_domicilio_fiscal text,

  -- Snapshot receptor.
  receptor_nombre text,
  receptor_documento_tipo_arca integer,
  receptor_documento_numero bigint,
  receptor_documento_original text,

  receptor_condicion_iva_id smallint
    references public.arca_condiciones_iva_receptor(codigo),

  receptor_domicilio text,
  receptor_email text,

  -- Moneda.
  moneda_id_arca text not null default 'PES',
  moneda_cotizacion numeric(18,6) not null default 1
    check (moneda_cotizacion > 0),

  cancela_misma_moneda_extranjera boolean,

  -- Totales WSFEv1.
  imp_total numeric(18,2) not null default 0
    check (imp_total >= 0),

  imp_tot_conc numeric(18,2) not null default 0
    check (imp_tot_conc >= 0),

  imp_neto numeric(18,2) not null default 0
    check (imp_neto >= 0),

  imp_op_ex numeric(18,2) not null default 0
    check (imp_op_ex >= 0),

  imp_trib numeric(18,2) not null default 0
    check (imp_trib >= 0),

  imp_iva numeric(18,2) not null default 0
    check (imp_iva >= 0),

  tipo_autorizacion text
    check (
      tipo_autorizacion is null
      or tipo_autorizacion in ('cae', 'caea')
    ),

  codigo_autorizacion text,
  autorizacion_vencimiento date,

  resultado_arca text,
  arca_fecha_proceso timestamptz,
  reproceso boolean,

  -- Solamente datos sanitizados.
  arca_request_resumen jsonb,
  arca_response_resumen jsonb,

  observaciones text,
  leyenda_factura text,

  solicitado_at timestamptz,
  autorizado_at timestamptz,
  rechazado_at timestamptz,

  creado_por uuid
    references auth.users(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (
    fecha_servicio_hasta is null
    or fecha_servicio_desde is null
    or fecha_servicio_hasta >= fecha_servicio_desde
  ),

  check (
    fecha_vencimiento_pago is null
    or fecha_vencimiento_pago >= fecha_emision
  ),

  check (
    periodo_asociado_hasta is null
    or periodo_asociado_desde is null
    or periodo_asociado_hasta >= periodo_asociado_desde
  )
);

create index if not exists
comprobantes_fiscales_comercio_fecha_idx
on public.comprobantes_fiscales (
  comercio_id, fecha_emision desc, created_at desc
);

create index if not exists
comprobantes_fiscales_venta_idx
on public.comprobantes_fiscales (venta_id);

create index if not exists
comprobantes_fiscales_cliente_idx
on public.comprobantes_fiscales (
  cliente_id, fecha_emision desc
);

create index if not exists
comprobantes_fiscales_estado_idx
on public.comprobantes_fiscales (
  comercio_id, estado
);

create unique index if not exists
comprobantes_fiscales_numeracion_unica_idx
on public.comprobantes_fiscales (
  comercio_id,
  ambiente_arca,
  punto_venta_numero,
  tipo_comprobante_arca,
  numero_comprobante
)
where numero_comprobante is not null
  and estado <> 'descartado';

comment on table public.comprobantes_fiscales is
  'Capa fiscal independiente de VTA. Un comprobante autorizado es inmutable.';

comment on column
public.comprobantes_fiscales.arca_request_resumen is
  'Payload sanitizado. Nunca Token, Sign, certificado o clave privada.';

comment on column
public.comprobantes_fiscales.arca_response_resumen is
  'Respuesta sanitizada. Nunca secretos de autenticación.';

drop trigger if exists
comprobantes_fiscales_updated_at
on public.comprobantes_fiscales;

create trigger comprobantes_fiscales_updated_at
before update
on public.comprobantes_fiscales
for each row
execute function public.actualizar_updated_at();

-- Completa snapshots de punto y tipo.
create or replace function
public.completar_referencias_comprobante_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_punto public.puntos_venta_fiscales;
  v_tipo public.arca_tipos_comprobante;
begin
  if new.punto_venta_id is not null then
    select pv.*
    into v_punto
    from public.puntos_venta_fiscales as pv
    where pv.id = new.punto_venta_id;

    if not found then
      raise exception 'Punto de venta fiscal inexistente';
    end if;

    if v_punto.comercio_id <> new.comercio_id then
      raise exception
        'El punto de venta no pertenece al comercio';
    end if;

    new.punto_venta_numero := v_punto.numero;
    new.ambiente_arca := v_punto.ambiente_arca;
    new.servicio_arca := v_punto.servicio;
  end if;

  if new.tipo_comprobante_arca is not null then
    select tc.*
    into v_tipo
    from public.arca_tipos_comprobante as tc
    where tc.codigo = new.tipo_comprobante_arca
      and tc.activo = true;

    if not found then
      raise exception
        'Tipo de comprobante ARCA inexistente o inactivo';
    end if;

    new.clase := v_tipo.clase;
    new.familia := v_tipo.familia;
  end if;

  if new.venta_id is not null
     and not exists (
       select 1
       from public.ventas as v
       where v.id = new.venta_id
         and v.comercio_id = new.comercio_id
     ) then
    raise exception
      'La venta de origen no pertenece al comercio';
  end if;

  if new.cliente_id is not null
     and not exists (
       select 1
       from public.clientes as c
       where c.id = new.cliente_id
         and c.comercio_id = new.comercio_id
     ) then
    raise exception
      'El cliente no pertenece al comercio';
  end if;

  return new;
end;
$$;

revoke all on function
public.completar_referencias_comprobante_fiscal()
from public, anon, authenticated;

drop trigger if exists
comprobantes_fiscales_completar_referencias
on public.comprobantes_fiscales;

create trigger comprobantes_fiscales_completar_referencias
before insert or update
on public.comprobantes_fiscales
for each row
execute function
public.completar_referencias_comprobante_fiscal();


-- ============================================================
-- 6. INTEGRIDAD E INMUTABILIDAD
-- ============================================================

create or replace function
public.validar_integridad_comprobante_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_suma numeric(18,2);
  v_tolerancia numeric(18,6);
begin
  if tg_op = 'UPDATE'
     and old.estado = 'autorizado' then
    raise exception
      'Un comprobante autorizado es inmutable. Emití una Nota de Crédito o Débito.';
  end if;

  if tg_op = 'UPDATE'
     and old.numero_comprobante is not null
     and new.numero_comprobante
       is distinct from old.numero_comprobante then
    raise exception
      'El número fiscal asignado no puede modificarse';
  end if;

  if new.estado not in ('borrador', 'descartado')
     and new.concepto_arca in (2, 3) then
    if new.fecha_servicio_desde is null
       or new.fecha_servicio_hasta is null
       or new.fecha_vencimiento_pago is null then
      raise exception
        'Concepto servicios requiere fechas de servicio y vencimiento';
    end if;
  end if;

  if new.fecha_servicio_desde is not null
     and new.fecha_servicio_hasta is not null
     and new.fecha_servicio_hasta
       < new.fecha_servicio_desde then
    raise exception
      'La fecha de fin del servicio no puede ser anterior al inicio';
  end if;

  if new.fecha_vencimiento_pago is not null
     and new.fecha_vencimiento_pago
       < new.fecha_emision then
    raise exception
      'El vencimiento no puede ser anterior a la emisión';
  end if;

  if new.moneda_id_arca = 'PES'
     and abs(new.moneda_cotizacion - 1) > 0.000001 then
    raise exception
      'Para PES la cotización debe ser 1';
  end if;

  -- Drito lo exige desde ahora antes de enviar para quedar
  -- preparado para la obligatoriedad de CondicionIVAReceptorId.
  if new.estado in (
      'pendiente_autorizacion',
      'autorizado',
      'rechazado',
      'error'
    )
    and new.receptor_condicion_iva_id is null then
    raise exception
      'Falta la condición frente al IVA del receptor';
  end if;

  if new.estado in (
      'pendiente_autorizacion',
      'autorizado',
      'rechazado',
      'error'
    )
    and (
      new.punto_venta_id is null
      or new.punto_venta_numero is null
      or new.tipo_comprobante_arca is null
      or new.ambiente_arca is null
      or new.emisor_cuit is null
      or new.receptor_documento_tipo_arca is null
      or new.receptor_documento_numero is null
    ) then
    raise exception
      'Faltan datos mínimos para autorización fiscal';
  end if;

  v_suma :=
    new.imp_tot_conc
    + new.imp_neto
    + new.imp_op_ex
    + new.imp_trib
    + new.imp_iva;

  v_tolerancia :=
    greatest(
      0.01,
      abs(new.imp_total) * 0.0001
    );

  if new.estado not in ('borrador', 'descartado')
     and abs(new.imp_total - v_suma) > v_tolerancia then
    raise exception
      'El total no coincide con la composición fiscal';
  end if;

  if new.estado = 'autorizado' then
    if new.numero_comprobante is null
       or nullif(
         trim(coalesce(new.codigo_autorizacion, '')),
         ''
       ) is null
       or new.tipo_autorizacion is null
       or new.autorizacion_vencimiento is null then
      raise exception
        'Un autorizado requiere número y código de autorización';
    end if;

    if new.autorizado_at is null then
      new.autorizado_at := now();
    end if;
  end if;

  if new.estado = 'rechazado'
     and new.rechazado_at is null then
    new.rechazado_at := now();
  end if;

  return new;
end;
$$;

revoke all on function
public.validar_integridad_comprobante_fiscal()
from public, anon, authenticated;

drop trigger if exists
comprobantes_fiscales_validar_integridad
on public.comprobantes_fiscales;

create trigger comprobantes_fiscales_validar_integridad
before insert or update
on public.comprobantes_fiscales
for each row
execute function
public.validar_integridad_comprobante_fiscal();

create or replace function
public.proteger_borrado_comprobante_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.estado = 'autorizado' then
    raise exception
      'No se puede eliminar un comprobante fiscal autorizado';
  end if;

  return old;
end;
$$;

revoke all on function
public.proteger_borrado_comprobante_fiscal()
from public, anon, authenticated;

drop trigger if exists
comprobantes_fiscales_proteger_borrado
on public.comprobantes_fiscales;

create trigger comprobantes_fiscales_proteger_borrado
before delete
on public.comprobantes_fiscales
for each row
execute function
public.proteger_borrado_comprobante_fiscal();

-- ============================================================
-- 7. ITEMS
-- ============================================================
-- WSFEv1 autoriza con importes agregados, pero Drito conserva
-- ítems como snapshot para PDF, representación y auditoría.

create table if not exists
public.items_comprobantes_fiscales (
  id uuid primary key default gen_random_uuid(),

  comprobante_fiscal_id uuid not null
    references public.comprobantes_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  producto_id uuid
    references public.productos(id) on delete set null,

  tipo text not null default 'producto'
    check (tipo in ('producto', 'servicio')),

  codigo text,
  nombre text not null,
  descripcion text,
  unidad_medida text not null default 'unidad',

  cantidad numeric(18,6) not null
    check (cantidad > 0),

  precio_unitario numeric(18,6) not null
    check (precio_unitario >= 0),

  descuento_porcentaje numeric(7,4)
    not null default 0
    check (
      descuento_porcentaje >= 0
      and descuento_porcentaje <= 100
    ),

  subtotal numeric(18,2) not null default 0
    check (subtotal >= 0),

  descuento_importe numeric(18,2)
    not null default 0
    check (descuento_importe >= 0),

  clasificacion_fiscal text not null default 'gravado'
    check (
      clasificacion_fiscal in (
        'gravado', 'exento', 'no_gravado'
      )
    ),

  iva_id_arca smallint
    references public.arca_alicuotas_iva(codigo),

  iva_porcentaje numeric(6,3)
    check (
      iva_porcentaje is null
      or iva_porcentaje between 0 and 100
    ),

  neto numeric(18,2) not null default 0
    check (neto >= 0),

  iva_importe numeric(18,2) not null default 0
    check (iva_importe >= 0),

  total numeric(18,2) not null default 0
    check (total >= 0),

  orden integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists
items_comprobantes_fiscales_comprobante_idx
on public.items_comprobantes_fiscales (
  comprobante_fiscal_id, orden
);

-- ============================================================
-- 8. IVA AGREGADO
-- ============================================================

create table if not exists
public.iva_comprobantes_fiscales (
  id uuid primary key default gen_random_uuid(),

  comprobante_fiscal_id uuid not null
    references public.comprobantes_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  alicuota_id_arca smallint not null
    references public.arca_alicuotas_iva(codigo),

  base_imponible numeric(18,2) not null
    check (base_imponible >= 0),

  importe numeric(18,2) not null
    check (importe >= 0),

  created_at timestamptz not null default now(),

  unique (
    comprobante_fiscal_id,
    alicuota_id_arca
  )
);

-- ============================================================
-- 9. TRIBUTOS
-- ============================================================

create table if not exists
public.tributos_comprobantes_fiscales (
  id uuid primary key default gen_random_uuid(),

  comprobante_fiscal_id uuid not null
    references public.comprobantes_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  tributo_id_arca integer not null,
  descripcion text,

  base_imponible numeric(18,2) not null default 0
    check (base_imponible >= 0),

  alicuota numeric(8,4) not null default 0,

  importe numeric(18,2) not null default 0
    check (importe >= 0),

  periodo_desde date,
  periodo_hasta date,

  created_at timestamptz not null default now(),

  check (
    periodo_hasta is null
    or periodo_desde is null
    or periodo_hasta >= periodo_desde
  )
);

create index if not exists
tributos_comprobantes_fiscales_comprobante_idx
on public.tributos_comprobantes_fiscales (
  comprobante_fiscal_id
);

-- ============================================================
-- 10. COMPROBANTES ASOCIADOS
-- ============================================================

create table if not exists
public.comprobantes_fiscales_asociados (
  id uuid primary key default gen_random_uuid(),

  comprobante_fiscal_id uuid not null
    references public.comprobantes_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  comprobante_asociado_id uuid
    references public.comprobantes_fiscales(id)
    on delete restrict,

  tipo_comprobante_arca smallint not null
    references public.arca_tipos_comprobante(codigo),

  punto_venta integer not null
    check (punto_venta between 1 and 99999),

  numero_comprobante bigint not null
    check (numero_comprobante > 0),

  cuit_emisor text,
  fecha_comprobante date,

  created_at timestamptz not null default now(),

  unique (
    comprobante_fiscal_id,
    tipo_comprobante_arca,
    punto_venta,
    numero_comprobante
  ),

  check (
    comprobante_asociado_id is null
    or comprobante_asociado_id
      <> comprobante_fiscal_id
  )
);

create index if not exists
comprobantes_fiscales_asociados_origen_idx
on public.comprobantes_fiscales_asociados (
  comprobante_asociado_id
);

-- ============================================================
-- 11. OPCIONALES Y ACTIVIDADES
-- ============================================================

create table if not exists
public.opcionales_comprobantes_fiscales (
  id uuid primary key default gen_random_uuid(),

  comprobante_fiscal_id uuid not null
    references public.comprobantes_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  opcional_id_arca integer not null,
  valor text not null,

  created_at timestamptz not null default now(),

  unique (
    comprobante_fiscal_id,
    opcional_id_arca
  )
);

create table if not exists
public.actividades_comprobantes_fiscales (
  id uuid primary key default gen_random_uuid(),

  comprobante_fiscal_id uuid not null
    references public.comprobantes_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  actividad_id_arca bigint not null,
  orden smallint not null default 0,

  created_at timestamptz not null default now(),

  unique (
    comprobante_fiscal_id,
    actividad_id_arca
  )
);

-- ============================================================
-- 12. CACHE DE NUMERACION
-- ============================================================
-- No es fuente de verdad. Antes de emitir, el backend deberá
-- consultar FECompUltimoAutorizado.

create table if not exists
public.numeracion_fiscal_cache (
  punto_venta_id uuid not null
    references public.puntos_venta_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  tipo_comprobante_arca smallint not null
    references public.arca_tipos_comprobante(codigo),

  ultimo_numero_autorizado bigint not null default 0
    check (ultimo_numero_autorizado >= 0),

  consultado_arca_at timestamptz,
  updated_at timestamptz not null default now(),

  primary key (
    punto_venta_id,
    tipo_comprobante_arca
  )
);

comment on table public.numeracion_fiscal_cache is
  'Cache informativa; confirmar siempre con FECompUltimoAutorizado.';

drop trigger if exists
numeracion_fiscal_cache_updated_at
on public.numeracion_fiscal_cache;

create trigger numeracion_fiscal_cache_updated_at
before update
on public.numeracion_fiscal_cache
for each row
execute function public.actualizar_updated_at();

-- ============================================================
-- 13. EVENTOS TECNICOS
-- ============================================================

create table if not exists
public.eventos_comprobantes_fiscales (
  id uuid primary key default gen_random_uuid(),

  comprobante_fiscal_id uuid not null
    references public.comprobantes_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  etapa text not null
    check (
      etapa in (
        'borrador', 'validacion', 'wsaa', 'wsfe',
        'autorizacion', 'consulta', 'documento', 'sistema'
      )
    ),

  nivel text not null default 'info'
    check (nivel in ('info', 'warning', 'error')),

  codigo text,
  mensaje text not null,
  payload_resumen jsonb,

  usuario_id uuid
    references auth.users(id) on delete set null,

  created_at timestamptz not null default now()
);

create index if not exists
eventos_comprobantes_fiscales_comprobante_idx
on public.eventos_comprobantes_fiscales (
  comprobante_fiscal_id, created_at
);

comment on column
public.eventos_comprobantes_fiscales.payload_resumen is
  'Sólo datos sanitizados. Nunca Token, Sign ni secretos.';

-- ============================================================
-- 14. PDF / QR GENERADOS
-- ============================================================
-- Separado de la cabecera para mantener el autorizado inmutable.

create table if not exists
public.documentos_fiscales_generados (
  comprobante_fiscal_id uuid primary key
    references public.comprobantes_fiscales(id)
    on delete cascade,

  comercio_id uuid not null
    references public.comercios(id) on delete cascade,

  qr_payload jsonb,
  qr_url text,

  pdf_storage_path text,
  pdf_generado_at timestamptz,

  version_documento integer not null default 1
    check (version_documento > 0),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists
documentos_fiscales_generados_updated_at
on public.documentos_fiscales_generados;

create trigger documentos_fiscales_generados_updated_at
before update
on public.documentos_fiscales_generados
for each row
execute function public.actualizar_updated_at();


-- ============================================================
-- 14B. INMUTABILIDAD DEL CONTENIDO FISCAL
-- ============================================================
-- Ítems, IVA, tributos, asociaciones, opcionales y actividades
-- no pueden cambiar cuando la cabecera ya fue autorizada.
-- Eventos y PDF/QR sí pueden agregarse luego.

create or replace function
public.proteger_contenido_comprobante_autorizado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comprobante_id uuid;
  v_estado text;
begin
  if tg_op = 'DELETE' then
    v_comprobante_id := old.comprobante_fiscal_id;
  else
    v_comprobante_id := new.comprobante_fiscal_id;
  end if;

  select cf.estado
  into v_estado
  from public.comprobantes_fiscales as cf
  where cf.id = v_comprobante_id;

  if v_estado = 'autorizado' then
    raise exception
      'El contenido de un comprobante fiscal autorizado es inmutable';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

revoke all on function
public.proteger_contenido_comprobante_autorizado()
from public, anon, authenticated;

do $$
declare
  v_tabla text;
  v_trigger text;
begin
  foreach v_tabla in array array[
    'items_comprobantes_fiscales',
    'iva_comprobantes_fiscales',
    'tributos_comprobantes_fiscales',
    'comprobantes_fiscales_asociados',
    'opcionales_comprobantes_fiscales',
    'actividades_comprobantes_fiscales'
  ]
  loop
    v_trigger :=
      left('proteger_autorizado_' || v_tabla, 63);

    execute format(
      'drop trigger if exists %I on public.%I',
      v_trigger,
      v_tabla
    );

    execute format(
      'create trigger %I
       before insert or update or delete
       on public.%I
       for each row
       execute function
       public.proteger_contenido_comprobante_autorizado()',
      v_trigger,
      v_tabla
    );
  end loop;
end;
$$;

-- ============================================================
-- 15. CONSISTENCIA MULTIEMPRESA DE TABLAS HIJAS
-- ============================================================

create or replace function
public.validar_comercio_hijo_comprobante_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
begin
  select cf.comercio_id
  into v_comercio_id
  from public.comprobantes_fiscales as cf
  where cf.id = new.comprobante_fiscal_id;

  if not found then
    raise exception 'Comprobante fiscal inexistente';
  end if;

  if v_comercio_id <> new.comercio_id then
    raise exception
      'El registro fiscal hijo no pertenece al mismo comercio';
  end if;

  return new;
end;
$$;

revoke all on function
public.validar_comercio_hijo_comprobante_fiscal()
from public, anon, authenticated;

do $$
declare
  v_tabla text;
  v_trigger text;
begin
  foreach v_tabla in array array[
    'items_comprobantes_fiscales',
    'iva_comprobantes_fiscales',
    'tributos_comprobantes_fiscales',
    'comprobantes_fiscales_asociados',
    'opcionales_comprobantes_fiscales',
    'actividades_comprobantes_fiscales',
    'eventos_comprobantes_fiscales',
    'documentos_fiscales_generados'
  ]
  loop
    v_trigger :=
      left('validar_comercio_' || v_tabla, 63);

    execute format(
      'drop trigger if exists %I on public.%I',
      v_trigger,
      v_tabla
    );

    execute format(
      'create trigger %I
       before insert or update
       on public.%I
       for each row
       execute function
       public.validar_comercio_hijo_comprobante_fiscal()',
      v_trigger,
      v_tabla
    );
  end loop;
end;
$$;

create or replace function
public.validar_comercio_numeracion_fiscal_cache()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
begin
  select pv.comercio_id
  into v_comercio_id
  from public.puntos_venta_fiscales as pv
  where pv.id = new.punto_venta_id;

  if not found then
    raise exception 'Punto de venta fiscal inexistente';
  end if;

  if v_comercio_id <> new.comercio_id then
    raise exception
      'La numeración no pertenece al comercio del punto de venta';
  end if;

  return new;
end;
$$;

revoke all on function
public.validar_comercio_numeracion_fiscal_cache()
from public, anon, authenticated;

drop trigger if exists
numeracion_fiscal_cache_validar_comercio
on public.numeracion_fiscal_cache;

create trigger numeracion_fiscal_cache_validar_comercio
before insert or update
on public.numeracion_fiscal_cache
for each row
execute function
public.validar_comercio_numeracion_fiscal_cache();

-- ============================================================
-- 16. RLS
-- ============================================================

alter table public.arca_tipos_comprobante
  enable row level security;
alter table public.arca_condiciones_iva_receptor
  enable row level security;
alter table public.arca_tipos_documento
  enable row level security;
alter table public.arca_alicuotas_iva
  enable row level security;
alter table public.arca_monedas
  enable row level security;

drop policy if exists arca_tipos_comprobante_select
on public.arca_tipos_comprobante;
create policy arca_tipos_comprobante_select
on public.arca_tipos_comprobante
for select to authenticated
using (true);

drop policy if exists arca_condiciones_iva_receptor_select
on public.arca_condiciones_iva_receptor;
create policy arca_condiciones_iva_receptor_select
on public.arca_condiciones_iva_receptor
for select to authenticated
using (true);

drop policy if exists arca_tipos_documento_select
on public.arca_tipos_documento;
create policy arca_tipos_documento_select
on public.arca_tipos_documento
for select to authenticated
using (true);

drop policy if exists arca_alicuotas_iva_select
on public.arca_alicuotas_iva;
create policy arca_alicuotas_iva_select
on public.arca_alicuotas_iva
for select to authenticated
using (true);

drop policy if exists arca_monedas_select
on public.arca_monedas;
create policy arca_monedas_select
on public.arca_monedas
for select to authenticated
using (true);

alter table public.puntos_venta_fiscales
  enable row level security;
alter table public.clientes_datos_fiscales
  enable row level security;
alter table public.comprobantes_fiscales
  enable row level security;
alter table public.items_comprobantes_fiscales
  enable row level security;
alter table public.iva_comprobantes_fiscales
  enable row level security;
alter table public.tributos_comprobantes_fiscales
  enable row level security;
alter table public.comprobantes_fiscales_asociados
  enable row level security;
alter table public.opcionales_comprobantes_fiscales
  enable row level security;
alter table public.actividades_comprobantes_fiscales
  enable row level security;
alter table public.numeracion_fiscal_cache
  enable row level security;
alter table public.eventos_comprobantes_fiscales
  enable row level security;
alter table public.documentos_fiscales_generados
  enable row level security;

drop policy if exists puntos_venta_fiscales_select
on public.puntos_venta_fiscales;
create policy puntos_venta_fiscales_select
on public.puntos_venta_fiscales
for select to authenticated
using (
  public.tiene_permiso_comercio(
    comercio_id, 'facturacion.ver'
  )
  or public.tiene_permiso_comercio(
    comercio_id, 'configuracion.ver'
  )
);

drop policy if exists clientes_datos_fiscales_select
on public.clientes_datos_fiscales;
create policy clientes_datos_fiscales_select
on public.clientes_datos_fiscales
for select to authenticated
using (
  public.tiene_permiso_comercio(
    comercio_id, 'facturacion.ver'
  )
  or public.tiene_permiso_comercio(
    comercio_id, 'clientes.ver'
  )
);

do $$
declare
  v_tabla text;
  v_policy text;
begin
  foreach v_tabla in array array[
    'comprobantes_fiscales',
    'items_comprobantes_fiscales',
    'iva_comprobantes_fiscales',
    'tributos_comprobantes_fiscales',
    'comprobantes_fiscales_asociados',
    'opcionales_comprobantes_fiscales',
    'actividades_comprobantes_fiscales',
    'numeracion_fiscal_cache',
    'eventos_comprobantes_fiscales',
    'documentos_fiscales_generados'
  ]
  loop
    v_policy :=
      left('facturacion_select_' || v_tabla, 63);

    execute format(
      'drop policy if exists %I on public.%I',
      v_policy,
      v_tabla
    );

    execute format(
      'create policy %I
       on public.%I
       for select
       to authenticated
       using (
         public.tiene_permiso_comercio(
           comercio_id, %L
         )
       )',
      v_policy,
      v_tabla,
      'facturacion.ver'
    );
  end loop;
end;
$$;

-- ============================================================
-- 17. PRIVILEGIOS
-- ============================================================
-- React queda en sólo lectura. Las escrituras se implementarán
-- mediante RPC/backend seguro en los módulos siguientes.

revoke all on table
  public.arca_tipos_comprobante,
  public.arca_condiciones_iva_receptor,
  public.arca_tipos_documento,
  public.arca_alicuotas_iva,
  public.arca_monedas,
  public.puntos_venta_fiscales,
  public.clientes_datos_fiscales,
  public.comprobantes_fiscales,
  public.items_comprobantes_fiscales,
  public.iva_comprobantes_fiscales,
  public.tributos_comprobantes_fiscales,
  public.comprobantes_fiscales_asociados,
  public.opcionales_comprobantes_fiscales,
  public.actividades_comprobantes_fiscales,
  public.numeracion_fiscal_cache,
  public.eventos_comprobantes_fiscales,
  public.documentos_fiscales_generados
from anon;

revoke insert, update, delete on table
  public.arca_tipos_comprobante,
  public.arca_condiciones_iva_receptor,
  public.arca_tipos_documento,
  public.arca_alicuotas_iva,
  public.arca_monedas,
  public.puntos_venta_fiscales,
  public.clientes_datos_fiscales,
  public.comprobantes_fiscales,
  public.items_comprobantes_fiscales,
  public.iva_comprobantes_fiscales,
  public.tributos_comprobantes_fiscales,
  public.comprobantes_fiscales_asociados,
  public.opcionales_comprobantes_fiscales,
  public.actividades_comprobantes_fiscales,
  public.numeracion_fiscal_cache,
  public.eventos_comprobantes_fiscales,
  public.documentos_fiscales_generados
from authenticated;

grant select on table
  public.arca_tipos_comprobante,
  public.arca_condiciones_iva_receptor,
  public.arca_tipos_documento,
  public.arca_alicuotas_iva,
  public.arca_monedas,
  public.puntos_venta_fiscales,
  public.clientes_datos_fiscales,
  public.comprobantes_fiscales,
  public.items_comprobantes_fiscales,
  public.iva_comprobantes_fiscales,
  public.tributos_comprobantes_fiscales,
  public.comprobantes_fiscales_asociados,
  public.opcionales_comprobantes_fiscales,
  public.actividades_comprobantes_fiscales,
  public.numeracion_fiscal_cache,
  public.eventos_comprobantes_fiscales,
  public.documentos_fiscales_generados
to authenticated;

notify pgrst, 'reload schema';

commit;

-- ============================================================
-- 18. VERIFICACION FINAL
-- ============================================================

select jsonb_build_object(
  'modulo', 26,
  'nombre', 'Modelo fiscal previo a ARCA',

  'tablas_fiscales',
    (
      select jsonb_agg(t.tabla order by t.tabla)
      from (
        values
          ('puntos_venta_fiscales'),
          ('clientes_datos_fiscales'),
          ('comprobantes_fiscales'),
          ('items_comprobantes_fiscales'),
          ('iva_comprobantes_fiscales'),
          ('tributos_comprobantes_fiscales'),
          ('comprobantes_fiscales_asociados'),
          ('opcionales_comprobantes_fiscales'),
          ('actividades_comprobantes_fiscales'),
          ('numeracion_fiscal_cache'),
          ('eventos_comprobantes_fiscales'),
          ('documentos_fiscales_generados')
      ) as t(tabla)
      where to_regclass(
        'public.' || t.tabla
      ) is not null
    ),

  'catalogos',
    (
      select jsonb_agg(t.tabla order by t.tabla)
      from (
        values
          ('arca_tipos_comprobante'),
          ('arca_condiciones_iva_receptor'),
          ('arca_tipos_documento'),
          ('arca_alicuotas_iva'),
          ('arca_monedas')
      ) as t(tabla)
      where to_regclass(
        'public.' || t.tabla
      ) is not null
    ),

  'permisos_facturacion',
    (
      select jsonb_agg(ps.codigo order by ps.orden)
      from public.permisos_sistema as ps
      where ps.modulo = 'facturacion'
        and ps.activo = true
    ),

  'puntos_venta_migrados',
    (
      select count(*)
      from public.puntos_venta_fiscales
    ),

  'comprobantes_fiscales',
    (
      select count(*)
      from public.comprobantes_fiscales
    )
) as modulo_26_instalado;

-- ============================================================
-- FIN MODULO 26
-- ==========================================================