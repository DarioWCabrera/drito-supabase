-- =====================================================
-- DRITO - APLICACIÓN REAL DE PERMISOS A LAS OPERACIONES
-- Archivo: 24b_aplicar_permisos_operaciones.sql
--
-- Requisito previo:
--   24_usuarios_roles_permisos.sql
--
-- Objetivos:
--   1. Proteger las RPC existentes sin reescribir su lógica.
--   2. Evitar que una llamada directa a Supabase saltee permisos.
--   3. Mantener intactas las firmas usadas por el frontend.
--   4. Revocar la ejecución directa de funciones auxiliares.
--   5. Auditar automáticamente cualquier RPC sensible no cubierta.
--
-- Estrategia:
--   - La función original se renombra internamente.
--   - Se crea una función envolvente con el nombre y firma originales.
--   - La envolvente resuelve el comercio, exige el permiso y recién
--     entonces ejecuta la lógica original.
--   - Las políticas RLS restrictivas protegen accesos REST directos.
--
-- El archivo es idempotente para una instalación normal.
-- =====================================================

begin;

-- =====================================================
-- 1. VALIDACIONES PREVIAS
-- =====================================================

do $$
begin
  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Primero debés ejecutar 24_usuarios_roles_permisos.sql';
  end if;

  if to_regclass('public.permisos_sistema') is null then
    raise exception
      'No existe el catálogo de permisos de Drito';
  end if;
end;
$$;

-- =====================================================
-- 2. CONFIGURACIÓN DE GUARDIAS RPC
-- =====================================================

create table if not exists
public.rpc_permisos_drito (
  funcion_nombre text primary key,
  permiso_codigo text not null
    references public.permisos_sistema(codigo)
    on update cascade
    on delete restrict,

  resolver_tipo text not null
    check (
      resolver_tipo in (
        'argumento_comercio',
        'entidad'
      )
    ),

  argumentos_referencia text[] not null,
  tablas_referencia text[],
  columna_id text not null default 'id',
  columna_comercio text not null default 'comercio_id',

  obligatorio boolean not null default false,
  descripcion text,

  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists rpc_permisos_drito_updated_at
on public.rpc_permisos_drito;

create trigger rpc_permisos_drito_updated_at
before update on public.rpc_permisos_drito
for each row
execute function public.actualizar_updated_at();

create table if not exists
public.rpc_guardias_instaladas (
  funcion_nombre text not null,
  argumentos_identidad text not null,
  nombre_interno text not null unique,
  permiso_codigo text not null,
  oid_original oid,
  oid_wrapper oid,
  instalada_at timestamptz not null default now(),
  actualizada_at timestamptz not null default now(),

  primary key (
    funcion_nombre,
    argumentos_identidad
  )
);

-- =====================================================
-- 3. MAPA DE OPERACIONES
-- =====================================================

insert into public.rpc_permisos_drito (
  funcion_nombre,
  permiso_codigo,
  resolver_tipo,
  argumentos_referencia,
  tablas_referencia,
  obligatorio,
  descripcion
)
values
  -- Panel
  (
    'obtener_dashboard_comercio',
    'dashboard.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Resumen del panel principal'
  ),

  -- Clientes
  (
    'obtener_clientes',
    'clientes.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de clientes'
  ),
  (
    'crear_cliente',
    'clientes.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta de cliente'
  ),
  (
    'guardar_cliente',
    'clientes.editar',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta o edición transaccional de cliente'
  ),
  (
    'actualizar_cliente',
    'clientes.editar',
    'entidad',
    array['p_cliente_id', 'p_id'],
    array['clientes'],
    false,
    'Edición de cliente'
  ),
  (
    'cambiar_estado_cliente',
    'clientes.desactivar',
    'entidad',
    array['p_cliente_id', 'p_id'],
    array['clientes'],
    false,
    'Activación o desactivación de cliente'
  ),

  -- Productos
  (
    'obtener_productos',
    'productos.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de productos'
  ),
  (
    'crear_categoria_producto',
    'productos.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta de categoría de productos'
  ),
  (
    'crear_categoria',
    'productos.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta de categoría de productos'
  ),
  (
    'crear_producto',
    'productos.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta de producto'
  ),
  (
    'guardar_producto',
    'productos.editar',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta o edición transaccional de producto'
  ),
  (
    'actualizar_producto',
    'productos.editar',
    'entidad',
    array['p_producto_id', 'p_id'],
    array['productos'],
    false,
    'Edición de producto'
  ),
  (
    'cambiar_estado_producto',
    'productos.cambiar_estado',
    'entidad',
    array['p_producto_id', 'p_id'],
    array['productos'],
    false,
    'Activación o desactivación de producto'
  ),

  -- Stock
  (
    'obtener_movimientos_stock',
    'stock.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Movimientos de stock'
  ),
  (
    'obtener_resumen_stock',
    'stock.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Resumen de stock'
  ),
  (
    'registrar_ingreso_stock',
    'stock.registrar_ingreso',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Ingreso manual de stock'
  ),
  (
    'registrar_egreso_stock',
    'stock.registrar_egreso',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Egreso manual de stock'
  ),
  (
    'ajustar_stock',
    'stock.ajustar',
    'entidad',
    array['p_producto_id', 'p_id'],
    array['productos'],
    false,
    'Ajuste manual de stock'
  ),
  (
    'registrar_movimiento_stock',
    'stock.ajustar',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Movimiento manual genérico de stock'
  ),

  -- Cotizaciones
  (
    'guardar_cotizacion',
    'cotizaciones.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Alta o edición de cotización'
  ),
  (
    'cambiar_estado_cotizacion',
    'cotizaciones.cambiar_estado',
    'entidad',
    array['p_cotizacion_id', 'p_id'],
    array['cotizaciones'],
    true,
    'Cambio de estado de cotización'
  ),
  (
    'obtener_cotizaciones',
    'cotizaciones.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de cotizaciones'
  ),

  -- Ventas
  (
    'convertir_cotizacion_a_venta',
    'ventas.crear',
    'entidad',
    array['p_cotizacion_id'],
    array['cotizaciones'],
    false,
    'Conversión de cotización a venta'
  ),
  (
    'convertir_cotizacion_en_venta',
    'ventas.crear',
    'entidad',
    array['p_cotizacion_id'],
    array['cotizaciones'],
    false,
    'Conversión de cotización a venta'
  ),
  (
    'crear_venta',
    'ventas.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta de venta'
  ),
  (
    'registrar_venta',
    'ventas.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta de venta'
  ),
  (
    'obtener_ventas',
    'ventas.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de ventas'
  ),
  (
    'obtener_items_venta',
    'ventas.ver',
    'entidad',
    array['p_venta_id'],
    array['ventas'],
    false,
    'Detalle de venta'
  ),
  (
    'obtener_pagos_venta',
    'ventas.ver',
    'entidad',
    array['p_venta_id'],
    array['ventas'],
    false,
    'Pagos de venta'
  ),
  (
    'registrar_pago_venta',
    'ventas.registrar_cobros',
    'entidad',
    array['p_venta_id'],
    array['ventas'],
    false,
    'Cobro individual de venta'
  ),
  (
    'anular_pago_venta',
    'ventas.anular_pagos',
    'entidad',
    array['p_pago_id', 'p_pago_venta_id'],
    array['pagos_ventas', 'pagos_venta'],
    false,
    'Anulación de cobro de venta'
  ),
  (
    'anular_venta',
    'ventas.anular_ventas',
    'entidad',
    array['p_venta_id'],
    array['ventas'],
    false,
    'Anulación de venta'
  ),

  -- Proveedores
  (
    'obtener_proveedores',
    'proveedores.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de proveedores'
  ),
  (
    'crear_proveedor',
    'proveedores.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta de proveedor'
  ),
  (
    'guardar_proveedor',
    'proveedores.editar',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta o edición de proveedor'
  ),
  (
    'actualizar_proveedor',
    'proveedores.editar',
    'entidad',
    array['p_proveedor_id', 'p_id'],
    array['proveedores'],
    false,
    'Edición de proveedor'
  ),
  (
    'cambiar_estado_proveedor',
    'proveedores.desactivar',
    'entidad',
    array['p_proveedor_id', 'p_id'],
    array['proveedores'],
    false,
    'Activación o desactivación de proveedor'
  ),

  -- Compras
  (
    'guardar_compra',
    'compras.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta o edición de compra'
  ),
  (
    'registrar_compra',
    'compras.crear',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Alta de compra'
  ),
  (
    'obtener_compras',
    'compras.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de compras'
  ),
  (
    'obtener_items_compra',
    'compras.ver',
    'entidad',
    array['p_compra_id'],
    array['compras'],
    false,
    'Detalle de compra'
  ),
  (
    'obtener_pagos_compra',
    'compras.ver',
    'entidad',
    array['p_compra_id'],
    array['compras'],
    false,
    'Pagos de compra'
  ),
  (
    'registrar_pago_compra',
    'compras.registrar_pagos',
    'entidad',
    array['p_compra_id'],
    array['compras'],
    false,
    'Pago individual de compra'
  ),
  (
    'anular_pago_compra',
    'compras.anular_pagos',
    'entidad',
    array['p_pago_id', 'p_pago_compra_id'],
    array['pagos_compras', 'pagos_compra'],
    false,
    'Anulación de pago de compra'
  ),
  (
    'anular_compra',
    'compras.anular_compras',
    'entidad',
    array['p_compra_id'],
    array['compras'],
    false,
    'Anulación de compra'
  ),

  -- Caja
  (
    'obtener_movimientos_caja',
    'caja.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Movimientos de Caja'
  ),
  (
    'obtener_resumen_caja',
    'caja.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Resumen de Caja'
  ),
  (
    'registrar_movimiento_caja',
    'caja.registrar_manual',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Movimiento manual de Caja'
  ),
  (
    'registrar_movimiento_manual_caja',
    'caja.registrar_manual',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Movimiento manual de Caja'
  ),
  (
    'anular_movimiento_caja',
    'caja.anular_manual',
    'entidad',
    array['p_movimiento_id', 'p_id'],
    array['movimientos_caja'],
    false,
    'Anulación de movimiento manual de Caja'
  ),

  -- Cuentas corrientes de clientes
  (
    'obtener_cuentas_corrientes_clientes',
    'cuentas_clientes.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de cuentas corrientes de clientes'
  ),
  (
    'obtener_cuentas_corrientes_clientes_clientes',
    'cuentas_clientes.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de cuentas corrientes de clientes'
  ),
  (
    'obtener_cuenta_corriente_cliente',
    'cuentas_clientes.ver',
    'entidad',
    array['p_cliente_id'],
    array['clientes'],
    false,
    'Extracto de cliente'
  ),
  (
    'registrar_pago_cuenta_cliente',
    'cuentas_clientes.registrar_cobros',
    'entidad',
    array['p_cliente_id'],
    array['clientes'],
    false,
    'Cobro agrupado de cliente'
  ),
  (
    'registrar_cobro_cuenta_cliente',
    'cuentas_clientes.registrar_cobros',
    'entidad',
    array['p_cliente_id'],
    array['clientes'],
    false,
    'Cobro agrupado de cliente'
  ),
  (
    'obtener_pagos_cliente',
    'cuentas_clientes.ver',
    'entidad',
    array['p_cliente_id'],
    array['clientes'],
    false,
    'Comprobantes agrupados de cliente'
  ),
  (
    'anular_pago_cuenta_cliente',
    'cuentas_clientes.anular_cobros',
    'entidad',
    array['p_pago_cliente_id', 'p_pago_id'],
    array['pagos_clientes', 'cobros_clientes'],
    false,
    'Anulación de cobro agrupado de cliente'
  ),

  -- Cuentas corrientes de proveedores
  (
    'obtener_cuentas_corrientes_proveedores',
    'cuentas_proveedores.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    false,
    'Listado de cuentas corrientes de proveedores'
  ),
  (
    'obtener_cuenta_corriente_proveedor',
    'cuentas_proveedores.ver',
    'entidad',
    array['p_proveedor_id'],
    array['proveedores'],
    false,
    'Extracto de proveedor'
  ),
  (
    'registrar_pago_cuenta_proveedor',
    'cuentas_proveedores.registrar_pagos',
    'entidad',
    array['p_proveedor_id'],
    array['proveedores'],
    true,
    'Pago agrupado de proveedor'
  ),
  (
    'obtener_pagos_proveedor',
    'cuentas_proveedores.ver',
    'entidad',
    array['p_proveedor_id'],
    array['proveedores'],
    true,
    'Comprobantes agrupados de proveedor'
  ),
  (
    'anular_pago_cuenta_proveedor',
    'cuentas_proveedores.anular_pagos',
    'entidad',
    array['p_pago_proveedor_id', 'p_pago_id'],
    array['pagos_proveedores'],
    true,
    'Anulación de pago agrupado de proveedor'
  ),

  -- Gastos
  (
    'crear_categoria_gasto',
    'gastos.administrar_categorias',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Alta de categoría de gasto'
  ),
  (
    'cambiar_estado_categoria_gasto',
    'gastos.administrar_categorias',
    'entidad',
    array['p_categoria_id'],
    array['categorias_gastos'],
    true,
    'Activación o desactivación de categoría de gasto'
  ),
  (
    'registrar_gasto_general',
    'gastos.registrar',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Registro de gasto general'
  ),
  (
    'anular_gasto_general',
    'gastos.anular',
    'entidad',
    array['p_gasto_id'],
    array['gastos_generales'],
    true,
    'Anulación de gasto general'
  ),
  (
    'obtener_gastos_generales',
    'gastos.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Listado de gastos'
  ),
  (
    'obtener_resumen_gastos_generales',
    'gastos.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Resumen de gastos'
  ),

  -- Reportes
  (
    'obtener_reporte_financiero',
    'reportes.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Reporte financiero'
  ),

  -- Configuración
  (
    'obtener_configuracion_comercio',
    'configuracion.ver',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Consulta de configuración'
  ),
  (
    'guardar_datos_comercio',
    'configuracion.editar_general',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Edición de datos comerciales'
  ),
  (
    'guardar_preferencias_comercio',
    'configuracion.editar_general',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Edición de apariencia y preferencias'
  ),
  (
    'guardar_configuracion_fiscal_comercio',
    'configuracion.editar_fiscal',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Edición de datos fiscales'
  ),
  (
    'restablecer_colores_comercio',
    'configuracion.editar_general',
    'argumento_comercio',
    array['p_comercio_id'],
    null,
    true,
    'Restablecimiento de colores'
  )
on conflict (funcion_nombre) do update
set
  permiso_codigo = excluded.permiso_codigo,
  resolver_tipo = excluded.resolver_tipo,
  argumentos_referencia =
    excluded.argumentos_referencia,
  tablas_referencia =
    excluded.tablas_referencia,
  columna_id = excluded.columna_id,
  columna_comercio =
    excluded.columna_comercio,
  obligatorio = excluded.obligatorio,
  descripcion = excluded.descripcion,
  activo = true,
  updated_at = now();

-- =====================================================
-- 4. INSTALADOR GENÉRICO DE GUARDIAS RPC
-- =====================================================

create or replace function
public.instalar_guardia_rpc_drito(
  p_funcion_nombre text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mapa public.rpc_permisos_drito;
  v_publica record;
  v_interna record;
  v_instalada public.rpc_guardias_instaladas;

  v_argumentos_identidad text;
  v_argumentos_declaracion text;
  v_retorno text;
  v_llamada_argumentos text;
  v_nombre_interno text;

  v_posicion integer;
  v_argumento_candidato text;
  v_tabla_candidata text;
  v_tabla_resuelta text;
  v_resolver text;
  v_retorno_body text;
  v_body text;
  v_create_sql text;
  v_oid_wrapper oid;

  v_instaladas integer := 0;
  v_omitidas integer := 0;
begin
  select *
  into v_mapa
  from public.rpc_permisos_drito
  where funcion_nombre = p_funcion_nombre
    and activo = true;

  if not found then
    raise exception
      'No existe un mapeo activo para la función %',
      p_funcion_nombre;
  end if;

  for v_publica in
    select
      p.oid,
      p.proname,
      p.pronargs,
      p.proargnames,
      p.proretset,
      p.prokind,
      pg_get_function_identity_arguments(
        p.oid
      ) as argumentos_identidad
    from pg_proc as p
    inner join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = p_funcion_nombre
      and p.prokind = 'f'
    order by p.oid
  loop
    v_argumentos_identidad :=
      v_publica.argumentos_identidad;

    select *
    into v_instalada
    from public.rpc_guardias_instaladas as gi
    where gi.funcion_nombre =
      p_funcion_nombre
      and gi.argumentos_identidad =
        v_argumentos_identidad;

    if found then
      select
        p.oid,
        p.pronargs,
        p.proargnames,
        p.proretset,
        pg_get_function_arguments(
          p.oid
        ) as argumentos_declaracion,
        pg_get_function_result(
          p.oid
        ) as retorno
      into v_interna
      from pg_proc as p
      inner join pg_namespace as n
        on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname =
          v_instalada.nombre_interno
        and pg_get_function_identity_arguments(
          p.oid
        ) = v_argumentos_identidad;

      if not found then
        raise exception
          'No se encontró la función interna % (%)',
          v_instalada.nombre_interno,
          v_argumentos_identidad;
      end if;

      v_nombre_interno :=
        v_instalada.nombre_interno;
    else
      v_nombre_interno :=
        '__drito_original_' ||
        left(p_funcion_nombre, 35) ||
        '_' ||
        substr(
          md5(v_argumentos_identidad),
          1,
          10
        );

      if exists (
        select 1
        from pg_proc as p
        inner join pg_namespace as n
          on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = v_nombre_interno
          and pg_get_function_identity_arguments(
            p.oid
          ) = v_argumentos_identidad
      ) then
        raise exception
          'Ya existe la función interna %, pero no figura registrada',
          v_nombre_interno;
      end if;

      execute format(
        'alter function public.%I(%s) rename to %I',
        p_funcion_nombre,
        v_argumentos_identidad,
        v_nombre_interno
      );

      select
        p.oid,
        p.pronargs,
        p.proargnames,
        p.proretset,
        pg_get_function_arguments(
          p.oid
        ) as argumentos_declaracion,
        pg_get_function_result(
          p.oid
        ) as retorno
      into v_interna
      from pg_proc as p
      inner join pg_namespace as n
        on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname = v_nombre_interno
        and pg_get_function_identity_arguments(
          p.oid
        ) = v_argumentos_identidad;

      insert into
      public.rpc_guardias_instaladas (
        funcion_nombre,
        argumentos_identidad,
        nombre_interno,
        permiso_codigo,
        oid_original
      )
      values (
        p_funcion_nombre,
        v_argumentos_identidad,
        v_nombre_interno,
        v_mapa.permiso_codigo,
        v_interna.oid
      );
    end if;

    v_argumentos_declaracion :=
      v_interna.argumentos_declaracion;
    v_retorno := v_interna.retorno;

    select string_agg(
      format('$%s', gs),
      ', '
      order by gs
    )
    into v_llamada_argumentos
    from generate_series(
      1,
      v_interna.pronargs
    ) as gs;

    v_llamada_argumentos :=
      coalesce(v_llamada_argumentos, '');

    v_posicion := null;

    foreach v_argumento_candidato
    in array v_mapa.argumentos_referencia
    loop
      select gs
      into v_posicion
      from generate_subscripts(
        v_interna.proargnames,
        1
      ) as gs
      where gs <= v_interna.pronargs
        and v_interna.proargnames[gs] =
          v_argumento_candidato
      limit 1;

      if v_posicion is not null then
        exit;
      end if;
    end loop;

    if v_posicion is null then
      v_omitidas := v_omitidas + 1;

      update public.rpc_guardias_instaladas
      set
        permiso_codigo =
          v_mapa.permiso_codigo,
        actualizada_at = now()
      where funcion_nombre =
        p_funcion_nombre
        and argumentos_identidad =
          v_argumentos_identidad;

      continue;
    end if;

    if v_mapa.resolver_tipo =
      'argumento_comercio' then

      v_resolver := format(
        'v_comercio_id := $%s::uuid;',
        v_posicion
      );
    else
      v_tabla_resuelta := null;

      foreach v_tabla_candidata
      in array v_mapa.tablas_referencia
      loop
        if to_regclass(
          'public.' || v_tabla_candidata
        ) is not null
        and exists (
          select 1
          from information_schema.columns
          where table_schema = 'public'
            and table_name =
              v_tabla_candidata
            and column_name =
              v_mapa.columna_id
        )
        and exists (
          select 1
          from information_schema.columns
          where table_schema = 'public'
            and table_name =
              v_tabla_candidata
            and column_name =
              v_mapa.columna_comercio
        ) then
          v_tabla_resuelta :=
            v_tabla_candidata;
          exit;
        end if;
      end loop;

      if v_tabla_resuelta is null then
        v_omitidas := v_omitidas + 1;
        continue;
      end if;

      v_resolver := format(
        'select t.%I into v_comercio_id
         from public.%I as t
         where t.%I = $%s;',
        v_mapa.columna_comercio,
        v_tabla_resuelta,
        v_mapa.columna_id,
        v_posicion
      );
    end if;

    if v_interna.proretset then
      v_retorno_body := format(
        'return query
         select *
         from public.%I(%s);',
        v_nombre_interno,
        v_llamada_argumentos
      );
    elsif lower(v_retorno) = 'void' then
      v_retorno_body := format(
        'perform public.%I(%s);
         return;',
        v_nombre_interno,
        v_llamada_argumentos
      );
    else
      v_retorno_body := format(
        'return public.%I(%s);',
        v_nombre_interno,
        v_llamada_argumentos
      );
    end if;

    v_body := format(
      'declare
         v_comercio_id uuid;
       begin
         %s

         if v_comercio_id is null then
           raise exception
             ''No se pudo determinar el comercio de la operación'';
         end if;

         perform public.exigir_permiso_comercio(
           v_comercio_id,
           %L
         );

         %s
       end;',
      v_resolver,
      v_mapa.permiso_codigo,
      v_retorno_body
    );

    v_create_sql := format(
      'create or replace function public.%I(%s)
       returns %s
       language plpgsql
       security definer
       set search_path = public
       as %L',
      p_funcion_nombre,
      v_argumentos_declaracion,
      v_retorno,
      v_body
    );

    execute v_create_sql;

    execute format(
      'revoke all on function public.%I(%s)
       from public, anon, authenticated',
      p_funcion_nombre,
      v_argumentos_identidad
    );

    execute format(
      'grant execute on function public.%I(%s)
       to authenticated',
      p_funcion_nombre,
      v_argumentos_identidad
    );

    execute format(
      'revoke all on function public.%I(%s)
       from public, anon, authenticated',
      v_nombre_interno,
      v_argumentos_identidad
    );

    execute format(
      'comment on function public.%I(%s)
       is %L',
      p_funcion_nombre,
      v_argumentos_identidad,
      'DRITO_GUARDIA_PERMISO:' ||
      v_mapa.permiso_codigo
    );

    -- pg_get_function_identity_arguments puede devolver nombres
    -- junto con los tipos (por ejemplo: "p_compra_id uuid").
    -- to_regprocedure solo acepta tipos, por eso resolvemos el OID
    -- directamente desde pg_proc.
    select p.oid
    into v_oid_wrapper
    from pg_proc as p
    inner join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = p_funcion_nombre
      and pg_get_function_identity_arguments(
        p.oid
      ) = v_argumentos_identidad
    limit 1;

    if v_oid_wrapper is null then
      raise exception
        'No se pudo identificar la función protegida % (%)',
        p_funcion_nombre,
        v_argumentos_identidad;
    end if;

    update public.rpc_guardias_instaladas
    set
      permiso_codigo =
        v_mapa.permiso_codigo,
      oid_wrapper = v_oid_wrapper,
      actualizada_at = now()
    where funcion_nombre =
      p_funcion_nombre
      and argumentos_identidad =
        v_argumentos_identidad;

    v_instaladas := v_instaladas + 1;
  end loop;

  return jsonb_build_object(
    'funcion', p_funcion_nombre,
    'instaladas', v_instaladas,
    'omitidas', v_omitidas
  );
end;
$$;

revoke all on function
public.instalar_guardia_rpc_drito(text)
from public, anon, authenticated;

-- Instala todas las guardias cuyos RPC existen actualmente.
do $$
declare
  v_mapa record;
begin
  for v_mapa in
    select funcion_nombre
    from public.rpc_permisos_drito
    where activo = true
    order by funcion_nombre
  loop
    if exists (
      select 1
      from pg_proc as p
      inner join pg_namespace as n
        on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname =
          v_mapa.funcion_nombre
        and p.prokind = 'f'
    ) then
      perform public.instalar_guardia_rpc_drito(
        v_mapa.funcion_nombre
      );
    end if;
  end loop;
end;
$$;

-- =====================================================
-- 5. FUNCIONES AUXILIARES QUE NO DEBEN SER RPC PÚBLICAS
-- =====================================================

do $$
declare
  v_funcion record;
begin
  for v_funcion in
    select
      p.proname,
      pg_get_function_identity_arguments(
        p.oid
      ) as argumentos
    from pg_proc as p
    inner join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (
        array[
          'actualizar_resumen_pago_compra',
          'crear_pago_compra_interno_proveedor',
          'registrar_caja_pago_proveedor',
          'anular_caja_pago_proveedor',
          'registrar_caja_gasto_general',
          'crear_categorias_gastos_predeterminadas',
          'inicializar_categorias_gastos_comercio',
          'inicializar_configuraciones_comercio'
        ]::text[]
      )
  loop
    execute format(
      'revoke all on function public.%I(%s)
       from public, anon, authenticated',
      v_funcion.proname,
      v_funcion.argumentos
    );
  end loop;
end;
$$;

-- =====================================================
-- 6. POLÍTICAS RLS RESTRICTIVAS PARA ACCESO REST DIRECTO
-- =====================================================

create or replace function
public.instalar_politica_permiso_drito(
  p_tabla text,
  p_operacion text,
  p_permiso text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_politica text;
  v_sql text;
begin
  if to_regclass(
    'public.' || p_tabla
  ) is null then
    return false;
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = p_tabla
      and column_name = 'comercio_id'
  ) then
    return false;
  end if;

  if not exists (
    select 1
    from public.permisos_sistema
    where codigo = p_permiso
      and activo = true
  ) then
    raise exception
      'El permiso % no existe',
      p_permiso;
  end if;

  execute format(
    'alter table public.%I enable row level security',
    p_tabla
  );

  v_politica :=
    left(
      'drito_perm_' ||
      p_tabla || '_' ||
      lower(p_operacion),
      63
    );

  execute format(
    'drop policy if exists %I on public.%I',
    v_politica,
    p_tabla
  );

  case lower(p_operacion)
    when 'select' then
      v_sql := format(
        'create policy %I
         on public.%I
         as restrictive
         for select
         to authenticated
         using (
           public.tiene_permiso_comercio(
             comercio_id,
             %L
           )
         )',
        v_politica,
        p_tabla,
        p_permiso
      );

    when 'insert' then
      v_sql := format(
        'create policy %I
         on public.%I
         as restrictive
         for insert
         to authenticated
         with check (
           public.tiene_permiso_comercio(
             comercio_id,
             %L
           )
         )',
        v_politica,
        p_tabla,
        p_permiso
      );

    when 'update' then
      v_sql := format(
        'create policy %I
         on public.%I
         as restrictive
         for update
         to authenticated
         using (
           public.tiene_permiso_comercio(
             comercio_id,
             %L
           )
         )
         with check (
           public.tiene_permiso_comercio(
             comercio_id,
             %L
           )
         )',
        v_politica,
        p_tabla,
        p_permiso,
        p_permiso
      );

    when 'delete' then
      v_sql := format(
        'create policy %I
         on public.%I
         as restrictive
         for delete
         to authenticated
         using (
           public.tiene_permiso_comercio(
             comercio_id,
             %L
           )
         )',
        v_politica,
        p_tabla,
        p_permiso
      );

    else
      raise exception
        'Operación RLS no admitida: %',
        p_operacion;
  end case;

  execute v_sql;
  return true;
end;
$$;

revoke all on function
public.instalar_politica_permiso_drito(
  text,
  text,
  text
)
from public, anon, authenticated;

-- Lecturas directas.
select public.instalar_politica_permiso_drito(
  tabla,
  'select',
  permiso
)
from (
  values
    ('clientes', 'clientes.ver'),
    ('categorias_productos', 'productos.ver'),
    ('categorias', 'productos.ver'),
    ('productos', 'productos.ver'),
    ('movimientos_stock', 'stock.ver'),
    ('cotizaciones', 'cotizaciones.ver'),
    ('items_cotizacion', 'cotizaciones.ver'),
    ('ventas', 'ventas.ver'),
    ('items_venta', 'ventas.ver'),
    ('pagos_ventas', 'ventas.ver'),
    ('pagos_venta', 'ventas.ver'),
    ('proveedores', 'proveedores.ver'),
    ('compras', 'compras.ver'),
    ('items_compra', 'compras.ver'),
    ('pagos_compras', 'compras.ver'),
    ('pagos_compra', 'compras.ver'),
    ('movimientos_caja', 'caja.ver'),
    ('categorias_gastos', 'gastos.ver'),
    ('gastos_generales', 'gastos.ver'),
    ('pagos_proveedores', 'cuentas_proveedores.ver'),
    ('configuraciones_comercio', 'configuracion.ver'),
    (
      'configuraciones_fiscales_comercio',
      'configuracion.ver'
    )
) as p(tabla, permiso);

-- Altas y ediciones maestras que pueden realizarse por REST.
select public.instalar_politica_permiso_drito(
  tabla,
  operacion,
  permiso
)
from (
  values
    ('clientes', 'insert', 'clientes.crear'),
    ('clientes', 'update', 'clientes.editar'),

    (
      'categorias_productos',
      'insert',
      'productos.crear'
    ),
    (
      'categorias_productos',
      'update',
      'productos.editar'
    ),
    ('categorias', 'insert', 'productos.crear'),
    ('categorias', 'update', 'productos.editar'),

    ('productos', 'insert', 'productos.crear'),
    ('productos', 'update', 'productos.editar'),

    ('proveedores', 'insert', 'proveedores.crear'),
    ('proveedores', 'update', 'proveedores.editar')
) as p(tabla, operacion, permiso);

-- Las operaciones transaccionales deben pasar por RPC.
do $$
declare
  v_tabla text;
begin
  foreach v_tabla in array array[
    'movimientos_stock',
    'cotizaciones',
    'items_cotizacion',
    'ventas',
    'items_venta',
    'pagos_ventas',
    'pagos_venta',
    'compras',
    'items_compra',
    'pagos_compras',
    'pagos_compra',
    'movimientos_caja',
    'categorias_gastos',
    'gastos_generales',
    'pagos_proveedores',
    'pagos_proveedores_aplicaciones',
    'configuraciones_comercio',
    'configuraciones_fiscales_comercio'
  ]
  loop
    if to_regclass(
      'public.' || v_tabla
    ) is not null then
      execute format(
        'revoke insert, update, delete
         on table public.%I
         from authenticated',
        v_tabla
      );
    end if;
  end loop;
end;
$$;

-- Política restrictiva especial para aplicaciones de pagos,
-- cuya tabla no necesita tener comercio_id propio.
do $$
begin
  if to_regclass(
    'public.pagos_proveedores_aplicaciones'
  ) is not null
  and to_regclass(
    'public.pagos_proveedores'
  ) is not null then

    drop policy if exists
    drito_perm_pagos_proveedores_aplicaciones_select
    on public.pagos_proveedores_aplicaciones;

    create policy
    drito_perm_pagos_proveedores_aplicaciones_select
    on public.pagos_proveedores_aplicaciones
    as restrictive
    for select
    to authenticated
    using (
      exists (
        select 1
        from public.pagos_proveedores as pp
        where pp.id = pago_proveedor_id
          and public.tiene_permiso_comercio(
            pp.comercio_id,
            'cuentas_proveedores.ver'
          )
      )
    );
  end if;
end;
$$;

-- =====================================================
-- 7. VALIDACIÓN DE CAMBIOS SENSIBLES
-- =====================================================

create or replace function
public.validar_cambio_sensible_drito()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_comercio_id uuid;
begin
  -- Permite tareas administrativas ejecutadas desde SQL Editor,
  -- migraciones y procesos internos sin JWT de usuario.
  if auth.uid() is null then
    return new;
  end if;

  if tg_table_name = 'comercios' then
    v_comercio_id := new.id;

    perform public.exigir_permiso_comercio(
      v_comercio_id,
      'configuracion.editar_general'
    );

    return new;
  end if;

  v_comercio_id :=
    coalesce(
      nullif(
        v_new->>'comercio_id',
        ''
      )::uuid,
      nullif(
        v_old->>'comercio_id',
        ''
      )::uuid
    );

  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio del cambio';
  end if;

  case tg_table_name
    when 'clientes' then
      if (v_old->'activo')
        is distinct from
        (v_new->'activo') then

        perform public.exigir_permiso_comercio(
          v_comercio_id,
          'clientes.desactivar'
        );
      end if;

    when 'productos' then
      if (v_old->'costo')
          is distinct from
          (v_new->'costo')
        or (v_old->'precio_venta')
          is distinct from
          (v_new->'precio_venta')
        or (v_old->'iva_porcentaje')
          is distinct from
          (v_new->'iva_porcentaje') then

        perform public.exigir_permiso_comercio(
          v_comercio_id,
          'productos.modificar_precios'
        );
      end if;

      if (v_old->'activo')
        is distinct from
        (v_new->'activo') then

        perform public.exigir_permiso_comercio(
          v_comercio_id,
          'productos.cambiar_estado'
        );
      end if;

    when 'proveedores' then
      if (v_old->'activo')
        is distinct from
        (v_new->'activo') then

        perform public.exigir_permiso_comercio(
          v_comercio_id,
          'proveedores.desactivar'
        );
      end if;

    when 'cotizaciones' then
      if (v_old->'estado')
        is distinct from
        (v_new->'estado') then

        if v_new->>'estado' = 'anulada' then
          perform public.exigir_permiso_comercio(
            v_comercio_id,
            'cotizaciones.anular'
          );
        else
          perform public.exigir_permiso_comercio(
            v_comercio_id,
            'cotizaciones.cambiar_estado'
          );
        end if;
      end if;

    when 'configuraciones_comercio' then
      perform public.exigir_permiso_comercio(
        v_comercio_id,
        'configuracion.editar_general'
      );

      if (v_old->'modulos')
        is distinct from
        (v_new->'modulos') then

        perform public.exigir_permiso_comercio(
          v_comercio_id,
          'configuracion.editar_modulos'
        );
      end if;

    when 'configuraciones_fiscales_comercio' then
      perform public.exigir_permiso_comercio(
        v_comercio_id,
        'configuracion.editar_fiscal'
      );

    else
      null;
  end case;

  return new;
end;
$$;

revoke all on function
public.validar_cambio_sensible_drito()
from public, anon, authenticated;

do $$
declare
  v_tabla text;
  v_trigger text;
begin
  foreach v_tabla in array array[
    'comercios',
    'clientes',
    'productos',
    'proveedores',
    'cotizaciones',
    'configuraciones_comercio',
    'configuraciones_fiscales_comercio'
  ]
  loop
    if to_regclass(
      'public.' || v_tabla
    ) is not null then

      v_trigger :=
        left(
          'drito_validar_permiso_' ||
          v_tabla,
          63
        );

      execute format(
        'drop trigger if exists %I
         on public.%I',
        v_trigger,
        v_tabla
      );

      execute format(
        'create trigger %I
         before update
         on public.%I
         for each row
         execute function
         public.validar_cambio_sensible_drito()',
        v_trigger,
        v_tabla
      );
    end if;
  end loop;
end;
$$;

-- =====================================================
-- 8. PRIVILEGIOS DE LAS TABLAS DE INFRAESTRUCTURA
-- =====================================================

alter table public.rpc_permisos_drito
  enable row level security;

alter table public.rpc_guardias_instaladas
  enable row level security;

drop policy if exists
rpc_permisos_drito_select_admin
on public.rpc_permisos_drito;

create policy
rpc_permisos_drito_select_admin
on public.rpc_permisos_drito
for select
to authenticated
using (
  exists (
    select 1
    from public.usuarios_comercios as uc
    where uc.usuario_id = auth.uid()
      and uc.rol = 'admin'
      and uc.activo = true
  )
);

drop policy if exists
rpc_guardias_instaladas_select_admin
on public.rpc_guardias_instaladas;

create policy
rpc_guardias_instaladas_select_admin
on public.rpc_guardias_instaladas
for select
to authenticated
using (
  exists (
    select 1
    from public.usuarios_comercios as uc
    where uc.usuario_id = auth.uid()
      and uc.rol = 'admin'
      and uc.activo = true
  )
);

revoke all on table
public.rpc_permisos_drito,
public.rpc_guardias_instaladas
from anon;

grant select on table
public.rpc_permisos_drito,
public.rpc_guardias_instaladas
to authenticated;

-- Fuerza la actualización de la caché de PostgREST.
notify pgrst, 'reload schema';

commit;

-- =====================================================
-- 9. VERIFICACIÓN FINAL
-- =====================================================

with funciones_expuestas_sin_guardia as (
  select
    p.proname,
    pg_get_function_identity_arguments(
      p.oid
    ) as argumentos
  from pg_proc as p
  inner join pg_namespace as n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind = 'f'
    and p.prosecdef = true
    and pg_get_function_result(p.oid) <> 'trigger'
    and p.proname not like
      '__drito_original_%'
    and has_function_privilege(
      'authenticated',
      p.oid,
      'EXECUTE'
    )
    and not exists (
      select 1
      from public.rpc_guardias_instaladas as gi
      where gi.funcion_nombre =
        p.proname
        and gi.argumentos_identidad =
          pg_get_function_identity_arguments(
            p.oid
          )
    )
    and p.proname <> all (
      array[
        'aceptar_invitacion_comercio',
        'cambiar_estado_usuario_comercio',
        'cambiar_rol_usuario_comercio',
        'crear_invitacion_comercio',
        'es_admin_comercio',
        'exigir_permiso_comercio',
        'guardar_permisos_usuario',
        'obtener_mis_permisos',
        'obtener_usuarios_comercio',
        'pertenece_a_comercio',
        'registrar_acceso_comercio',
        'restablecer_permisos_usuario',
        'revocar_invitacion_comercio',
        'tiene_permiso_comercio',
        'usuario_tiene_permiso_comercio'
      ]::text[]
    )
),
obligatorias_faltantes as (
  select
    m.funcion_nombre
  from public.rpc_permisos_drito as m
  where m.obligatorio = true
    and not exists (
      select 1
      from public.rpc_guardias_instaladas as gi
      where gi.funcion_nombre =
        m.funcion_nombre
    )
)
select jsonb_build_object(
  'guardias_instaladas',
    (
      select count(*)
      from public.rpc_guardias_instaladas
    ),

  'funciones_protegidas',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'funcion',
              gi.funcion_nombre,
            'argumentos',
              gi.argumentos_identidad,
            'permiso',
              gi.permiso_codigo
          )
          order by
            gi.funcion_nombre,
            gi.argumentos_identidad
        )
        from public.rpc_guardias_instaladas as gi
      ),
      '[]'::jsonb
    ),

  'obligatorias_faltantes',
    coalesce(
      (
        select jsonb_agg(
          funcion_nombre
          order by funcion_nombre
        )
        from obligatorias_faltantes
      ),
      '[]'::jsonb
    ),

  'rpc_expuestas_sin_guardia',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'funcion', proname,
            'argumentos', argumentos
          )
          order by proname, argumentos
        )
        from funciones_expuestas_sin_guardia
      ),
      '[]'::jsonb
    ),

  'politicas_restrictivas',
    (
      select count(*)
      from pg_policies
      where schemaname = 'public'
        and policyname like
          'drito_perm_%'
    ),

  'triggers_sensibles',
    (
      select count(*)
      from information_schema.triggers
      where event_object_schema = 'public'
        and trigger_name like
          'drito_validar_permiso_%'
    )
) as permisos_operaciones_aplicados;