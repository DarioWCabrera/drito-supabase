-- ============================================================
-- DRITO
-- PASO 16A.3
-- CONVERSIÓN TRANSACCIONAL SOL -> COT
--
-- Objetivos:
-- - completar snapshot comercial de los ítems SOL;
-- - conservar tipo e IVA del producto al recibir la solicitud;
-- - convertir una SOL revisada en una cotización real;
-- - exigir cliente real seleccionado desde Drito;
-- - reutilizar guardar_cotizacion(...);
-- - no duplicar cálculos ni numeración COT;
-- - registrar auditoría;
-- - mantener completamente cerrada la recepción pública.
-- ============================================================


-- ============================================================
-- 1. COMPLETAR SNAPSHOT DE ÍTEMS
-- ============================================================

alter table public.items_solicitud_web
add column if not exists tipo_snapshot text null;

alter table public.items_solicitud_web
add column if not exists iva_porcentaje_snapshot numeric(5,2) null;


do $$
begin

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.items_solicitud_web'::regclass
      and conname = 'items_solicitud_web_tipo_snapshot_check'
  ) then

    alter table public.items_solicitud_web
    add constraint items_solicitud_web_tipo_snapshot_check
    check (
      tipo_snapshot is null
      or tipo_snapshot in (
        'producto',
        'servicio'
      )
    );

  end if;


  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.items_solicitud_web'::regclass
      and conname = 'items_solicitud_web_iva_snapshot_check'
  ) then

    alter table public.items_solicitud_web
    add constraint items_solicitud_web_iva_snapshot_check
    check (
      iva_porcentaje_snapshot is null
      or (
        iva_porcentaje_snapshot >= 0
        and iva_porcentaje_snapshot <= 100
      )
    );

  end if;

end;
$$;


-- ============================================================
-- 2. TRIGGER PARA SNAPSHOT COMERCIAL
--
-- Si el ítem tiene producto_id:
-- tipo e IVA se obtienen SIEMPRE del producto real.
--
-- Los ítems libres pueden permanecer NULL.
-- La conversión a cotización los bloqueará hasta que exista
-- información suficiente, en vez de inventarla.
-- ============================================================

create or replace function
public.__drito_completar_snapshot_item_solicitud_web()
returns trigger

language plpgsql
security definer
set search_path = public

as $$

declare

  v_producto public.productos%rowtype;

begin

  if new.producto_id is not null then

    select p.*
    into v_producto

    from public.productos p

    where p.id = new.producto_id
      and p.comercio_id = new.comercio_id;


    if not found then

      raise exception
        'El producto indicado no pertenece al comercio';

    end if;


    new.codigo_snapshot :=
      v_producto.codigo;

    new.nombre_snapshot :=
      v_producto.nombre;

    new.descripcion_snapshot :=
      v_producto.descripcion;

    new.unidad_medida_snapshot :=
      v_producto.unidad_medida;

    new.precio_referencia :=
      v_producto.precio_venta;

    new.moneda_snapshot :=
      v_producto.moneda;

    new.tipo_snapshot :=
      v_producto.tipo;

    new.iva_porcentaje_snapshot :=
      v_producto.iva_porcentaje;

  end if;


  return new;

end;

$$;


revoke all on function
public.__drito_completar_snapshot_item_solicitud_web()
from public, anon, authenticated;


drop trigger if exists
items_solicitud_web_completar_snapshot
on public.items_solicitud_web;


create trigger
items_solicitud_web_completar_snapshot

before insert
on public.items_solicitud_web

for each row

execute function
public.__drito_completar_snapshot_item_solicitud_web();


-- ============================================================
-- 3. RPC DE CONVERSIÓN SOL -> COT
-- ============================================================

create or replace function
public.convertir_solicitud_web_en_cotizacion(

  p_solicitud_id uuid,

  p_cliente_id uuid,

  p_fecha_emision date default current_date,

  p_valida_hasta date default null,

  p_descuento_general_porcentaje numeric default 0,

  p_observaciones text default null,

  p_condiciones text default null

)
returns jsonb

language plpgsql
security definer
set search_path = public

as $$

declare

  v_usuario uuid;

  v_solicitud public.solicitudes_web%rowtype;

  v_cliente_comercio uuid;

  v_cliente_activo boolean;

  v_items jsonb;

  v_moneda text;

  v_monedas_distintas integer;

  v_items_incompletos integer;

  v_resultado record;

begin

  -- ----------------------------------------------------------
  -- Usuario
  -- ----------------------------------------------------------

  v_usuario := auth.uid();


  if v_usuario is null then

    raise exception
      'Usuario no autenticado';

  end if;


  -- ----------------------------------------------------------
  -- Solicitud
  -- ----------------------------------------------------------

  select sw.*
  into v_solicitud

  from public.solicitudes_web sw

  where sw.id = p_solicitud_id

  for update;


  if not found then

    raise exception
      'Solicitud web no encontrada';

  end if;


  -- ----------------------------------------------------------
  -- Permisos
  -- ----------------------------------------------------------

  perform public.exigir_permiso_comercio(

    v_solicitud.comercio_id,

    'solicitudes_web.convertir'

  );


  perform public.exigir_permiso_comercio(

    v_solicitud.comercio_id,

    'cotizaciones.crear'

  );


  -- ----------------------------------------------------------
  -- Estado
  -- ----------------------------------------------------------

  if v_solicitud.estado = 'convertida' then

    raise exception
      'La solicitud ya fue convertida';

  end if;


  if v_solicitud.estado = 'descartada' then

    raise exception
      'Una solicitud descartada no puede convertirse';

  end if;


  if v_solicitud.estado <> 'en_revision' then

    raise exception
      'La solicitud debe estar en revisión antes de convertirla';

  end if;


  -- ----------------------------------------------------------
  -- Cliente
  -- ----------------------------------------------------------

  select
    c.comercio_id,
    c.activo

  into
    v_cliente_comercio,
    v_cliente_activo

  from public.clientes c

  where c.id = p_cliente_id;


  if not found then

    raise exception
      'Cliente no encontrado';

  end if;


  if v_cliente_activo is distinct from true then

    raise exception
      'El cliente se encuentra inactivo';

  end if;


  if v_cliente_comercio <> v_solicitud.comercio_id then

    raise exception
      'El cliente no pertenece al comercio de la solicitud';

  end if;


  -- ----------------------------------------------------------
  -- Fecha
  -- ----------------------------------------------------------

  if p_fecha_emision is null then

    raise exception
      'La fecha de emisión es obligatoria';

  end if;


  if
    p_valida_hasta is not null
    and p_valida_hasta < p_fecha_emision
  then

    raise exception
      'La fecha de validez no puede ser anterior a la emisión';

  end if;


  -- ----------------------------------------------------------
  -- Verificar que los snapshots estén completos
  --
  -- No inventamos tipo, IVA, precio ni moneda.
  -- ----------------------------------------------------------

  select count(*)
  into v_items_incompletos

  from public.items_solicitud_web i

  where i.solicitud_id = p_solicitud_id

    and (
      i.tipo_snapshot is null
      or i.iva_porcentaje_snapshot is null
      or i.precio_referencia is null
      or i.moneda_snapshot is null
    );


  if v_items_incompletos > 0 then

    raise exception
      'La solicitud contiene ítems sin información comercial suficiente para convertirlos';

  end if;


  if not exists (
    select 1
    from public.items_solicitud_web i
    where i.solicitud_id = p_solicitud_id
  ) then

    raise exception
      'La solicitud no contiene ítems';

  end if;


  -- ----------------------------------------------------------
  -- Moneda
  --
  -- Una cotización tiene una única moneda.
  -- No mezclamos monedas.
  -- ----------------------------------------------------------

  select
    count(distinct i.moneda_snapshot),
    min(i.moneda_snapshot)

  into
    v_monedas_distintas,
    v_moneda

  from public.items_solicitud_web i

  where i.solicitud_id = p_solicitud_id;


  if v_monedas_distintas <> 1 then

    raise exception
      'La solicitud contiene ítems en monedas diferentes';

  end if;


  -- ----------------------------------------------------------
  -- Construir JSON esperado por guardar_cotizacion(...)
  --
  -- producto_id:
  -- solo se conserva si actualmente sigue existiendo,
  -- activo y dentro del mismo comercio.
  --
  -- Si no, la cotización conserva igualmente el snapshot.
  -- ----------------------------------------------------------

  select jsonb_agg(

    jsonb_build_object(

      'producto_id',

        case
          when exists (
            select 1
            from public.productos p
            where p.id = i.producto_id
              and p.comercio_id = i.comercio_id
              and p.activo = true
          )
          then i.producto_id
          else null
        end,

      'tipo',
        i.tipo_snapshot,

      'codigo',
        i.codigo_snapshot,

      'nombre',
        i.nombre_snapshot,

      'descripcion',
        i.descripcion_snapshot,

      'unidad_medida',
        coalesce(
          nullif(
            trim(
              coalesce(
                i.unidad_medida_snapshot,
                ''
              )
            ),
            ''
          ),
          'unidad'
        ),

      'cantidad',
        i.cantidad,

      'precio_unitario',
        i.precio_referencia,

      'descuento_porcentaje',
        0,

      'iva_porcentaje',
        i.iva_porcentaje_snapshot

    )

    order by i.created_at, i.id

  )

  into v_items

  from public.items_solicitud_web i

  where i.solicitud_id = p_solicitud_id;


  -- ----------------------------------------------------------
  -- Crear cotización usando MOTOR REAL existente
  -- ----------------------------------------------------------

  select *
  into v_resultado

  from public.guardar_cotizacion(

    null,

    v_solicitud.comercio_id,

    p_cliente_id,

    p_fecha_emision,

    p_valida_hasta,

    v_moneda,

    coalesce(
      p_descuento_general_porcentaje,
      0
    ),

    coalesce(
      nullif(
        trim(
          coalesce(
            p_observaciones,
            ''
          )
        ),
        ''
      ),
      'Generada desde SOL-' ||
      lpad(
        v_solicitud.numero::text,
        6,
        '0'
      )
    ),

    p_condiciones,

    v_items

  );


  -- ----------------------------------------------------------
  -- Marcar SOL convertida
  -- ----------------------------------------------------------

  update public.solicitudes_web

  set
    estado = 'convertida',

    cliente_id = p_cliente_id,

    cotizacion_id = v_resultado.cotizacion_id,

    convertido_por = v_usuario,

    convertido_at = now(),

    revisado_por =
      coalesce(
        revisado_por,
        v_usuario
      ),

    revisado_at =
      coalesce(
        revisado_at,
        now()
      )

  where id = p_solicitud_id;


  -- ----------------------------------------------------------
  -- Auditoría
  -- ----------------------------------------------------------

  perform public.__drito_registrar_auditoria_operacion(

    v_solicitud.comercio_id,

    'solicitudes_web',

    'solicitud_web_convertida',

    'solicitud_web',

    p_solicitud_id::text,

    'SOL-' ||
      lpad(
        v_solicitud.numero::text,
        6,
        '0'
      ),

    jsonb_build_object(

      'solicitud_numero',
        v_solicitud.numero,

      'cotizacion_id',
        v_resultado.cotizacion_id,

      'cotizacion_numero',
        v_resultado.numero,

      'cliente_id',
        p_cliente_id,

      'total',
        v_resultado.total,

      'moneda',
        v_moneda

    ),

    v_usuario

  );


  return jsonb_build_object(

    'solicitud_id',
      p_solicitud_id,

    'solicitud_referencia',
      'SOL-' ||
      lpad(
        v_solicitud.numero::text,
        6,
        '0'
      ),

    'estado',
      'convertida',

    'cliente_id',
      p_cliente_id,

    'cotizacion_id',
      v_resultado.cotizacion_id,

    'cotizacion_numero',
      v_resultado.numero,

    'cotizacion_referencia',
      'COT-' ||
      lpad(
        v_resultado.numero::text,
        6,
        '0'
      ),

    'subtotal',
      v_resultado.subtotal,

    'descuento_items',
      v_resultado.descuento_items,

    'descuento_general_importe',
      v_resultado.descuento_general_importe,

    'impuestos',
      v_resultado.impuestos,

    'total',
      v_resultado.total,

    'moneda',
      v_moneda

  );

end;

$$;


-- ============================================================
-- 4. SEGURIDAD RPC
-- ============================================================

revoke all on function
public.convertir_solicitud_web_en_cotizacion(
  uuid,
  uuid,
  date,
  date,
  numeric,
  text,
  text
)
from public, anon;


grant execute on function
public.convertir_solicitud_web_en_cotizacion(
  uuid,
  uuid,
  date,
  date,
  numeric,
  text,
  text
)
to authenticated;


-- ============================================================
-- 5. POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- 6. VERIFICACIÓN
-- ============================================================

select jsonb_build_object(

  'tipo_snapshot_existe',
    exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'items_solicitud_web'
        and column_name = 'tipo_snapshot'
    ),

  'iva_snapshot_existe',
    exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'items_solicitud_web'
        and column_name = 'iva_porcentaje_snapshot'
    ),

  'trigger_snapshot_existe',
    exists (
      select 1
      from pg_trigger
      where tgrelid =
        'public.items_solicitud_web'::regclass
        and tgname =
          'items_solicitud_web_completar_snapshot'
        and not tgisinternal
    ),

  'rpc_conversion_existe',
    to_regprocedure(
      'public.convertir_solicitud_web_en_cotizacion(uuid,uuid,date,date,numeric,text,text)'
    ) is not null,

  'anon_rpc_conversion',
    has_function_privilege(
      'anon',
      'public.convertir_solicitud_web_en_cotizacion(uuid,uuid,date,date,numeric,text,text)',
      'EXECUTE'
    ),

  'authenticated_rpc_conversion',
    has_function_privilege(
      'authenticated',
      'public.convertir_solicitud_web_en_cotizacion(uuid,uuid,date,date,numeric,text,text)',
      'EXECUTE'
    ),

  'motor_alta_sigue_cerrado_anon',
    not has_function_privilege(
      'anon',
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
    ),

  'motor_alta_sigue_cerrado_authenticated',
    not has_function_privilege(
      'authenticated',
      'public.__drito_crear_solicitud_web(uuid,uuid,text,text,text,text,text,text,text,text,jsonb)',
      'EXECUTE'
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
    )

) as verificacion_16a3;