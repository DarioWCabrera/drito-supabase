-- =====================================================
-- DRITO - INTEGRACIÓN AUTOMÁTICA CON CAJA
--
-- COBROS DE VENTAS  -> INGRESOS
-- PAGOS DE COMPRAS  -> EGRESOS
-- =====================================================

-- =====================================================
-- OBTENER O CREAR CATEGORÍA DEL SISTEMA
-- =====================================================

create or replace function
public.obtener_o_crear_categoria_caja_sistema(
  p_comercio_id uuid,
  p_nombre text,
  p_tipo text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_categoria_id uuid;
  v_nombre text;
  v_tipo text;
begin
  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;

  v_nombre :=
    trim(
      coalesce(
        p_nombre,
        ''
      )
    );

  if char_length(v_nombre) < 2 then
    raise exception
      'El nombre de la categoría es inválido';
  end if;

  v_tipo :=
    lower(
      trim(
        coalesce(
          p_tipo,
          ''
        )
      )
    );

  if v_tipo not in (
    'ingreso',
    'egreso',
    'ambos'
  ) then
    raise exception
      'El tipo de categoría es inválido';
  end if;

  insert into public.categorias_caja (
    comercio_id,
    nombre,
    tipo,
    sistema,
    activo
  )
  values (
    p_comercio_id,
    v_nombre,
    v_tipo,
    true,
    true
  )
  on conflict (
    comercio_id,
    nombre
  )
  do update set
    tipo = excluded.tipo,
    sistema = true,
    activo = true

  returning id
  into v_categoria_id;

  return v_categoria_id;
end;
$$;

-- =====================================================
-- SINCRONIZAR UN PAGO CON CAJA
--
-- Recibe el pago convertido a JSON para poder utilizar
-- la misma función con pagos_ventas y pagos_compras.
-- =====================================================

create or replace function
public.sincronizar_pago_caja_desde_json(
  p_origen_pago text,
  p_pago jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_movimiento_id uuid;

  v_pago_id uuid;
  v_comercio_id uuid;
  v_operacion_id uuid;

  v_numero_pago bigint;
  v_numero_operacion bigint;

  v_fecha_pago date;
  v_importe numeric(14,2);

  v_medio_pago text;
  v_referencia text;
  v_observaciones text;

  v_estado_pago text;

  v_creado_por uuid;

  v_anulado_at timestamptz;
  v_anulado_por uuid;
  v_motivo_anulacion text;

  v_categoria_id uuid;
  v_categoria_nombre text;

  v_tipo_movimiento text;
  v_origen_movimiento text;

  v_referencia_tipo text;
  v_concepto text;
  v_referencia_predeterminada text;
begin
  -- ===================================================
  -- VALIDAR ORIGEN
  -- ===================================================

  if p_origen_pago not in (
    'pago_venta',
    'pago_compra'
  ) then
    raise exception
      'El origen del pago es inválido';
  end if;

  if p_pago is null then
    raise exception
      'Los datos del pago son obligatorios';
  end if;

  -- ===================================================
  -- DATOS GENERALES
  -- ===================================================

  begin
    v_pago_id :=
      (
        nullif(
          p_pago ->> 'id',
          ''
        )
      )::uuid;

    v_comercio_id :=
      (
        nullif(
          p_pago ->> 'comercio_id',
          ''
        )
      )::uuid;

    v_numero_pago :=
      coalesce(
        (
          nullif(
            p_pago ->> 'numero',
            ''
          )
        )::bigint,
        0
      );

    v_fecha_pago :=
      coalesce(
        (
          nullif(
            p_pago ->> 'fecha_pago',
            ''
          )
        )::date,
        current_date
      );

    v_importe :=
      round(
        coalesce(
          (
            nullif(
              p_pago ->> 'importe',
              ''
            )
          )::numeric,
          0
        ),
        2
      );

    v_creado_por :=
      (
        nullif(
          p_pago ->> 'creado_por',
          ''
        )
      )::uuid;

    v_anulado_at :=
      (
        nullif(
          p_pago ->> 'anulado_at',
          ''
        )
      )::timestamptz;

    v_anulado_por :=
      (
        nullif(
          p_pago ->> 'anulado_por',
          ''
        )
      )::uuid;

  exception
    when invalid_text_representation then
      raise exception
        'Los datos del pago tienen un formato inválido';
  end;

  if v_pago_id is null then
    raise exception
      'El identificador del pago es obligatorio';
  end if;

  if v_comercio_id is null then
    raise exception
      'El comercio del pago es obligatorio';
  end if;

  if v_importe <= 0 then
    raise exception
      'El importe del pago debe ser mayor que cero';
  end if;

  -- ===================================================
  -- MEDIO DE PAGO
  -- ===================================================

  v_medio_pago :=
    lower(
      trim(
        coalesce(
          p_pago ->> 'medio_pago',
          'efectivo'
        )
      )
    );

  -- Compatibilidad con posibles nombres anteriores.

  if v_medio_pago in (
    'debito',
    'tarjeta débito',
    'tarjeta debito'
  ) then
    v_medio_pago := 'tarjeta_debito';

  elsif v_medio_pago in (
    'credito',
    'tarjeta',
    'tarjeta crédito',
    'tarjeta credito'
  ) then
    v_medio_pago := 'tarjeta_credito';

  elsif v_medio_pago in (
    'mercado_pago',
    'mercadopago',
    'billetera'
  ) then
    v_medio_pago := 'billetera_virtual';

  elsif v_medio_pago in (
    'deposito_bancario',
    'depósito'
  ) then
    v_medio_pago := 'deposito';
  end if;

  if v_medio_pago not in (
    'efectivo',
    'transferencia',
    'tarjeta_debito',
    'tarjeta_credito',
    'billetera_virtual',
    'cheque',
    'deposito',
    'otro'
  ) then
    v_medio_pago := 'otro';
  end if;

  -- ===================================================
  -- ESTADO Y DATOS DE ANULACIÓN
  -- ===================================================

  v_estado_pago :=
    lower(
      trim(
        coalesce(
          p_pago ->> 'estado',
          'registrado'
        )
      )
    );

  if v_estado_pago not in (
    'registrado',
    'anulado'
  ) then
    v_estado_pago := 'registrado';
  end if;

  v_motivo_anulacion :=
    nullif(
      trim(
        coalesce(
          p_pago ->> 'motivo_anulacion',
          ''
        )
      ),
      ''
    );

  if v_estado_pago = 'registrado' then
    v_anulado_at := null;
    v_anulado_por := null;
    v_motivo_anulacion := null;
  else
    v_anulado_at :=
      coalesce(
        v_anulado_at,
        now()
      );

    v_anulado_por :=
      coalesce(
        v_anulado_por,
        auth.uid()
      );

    v_motivo_anulacion :=
      coalesce(
        v_motivo_anulacion,
        'Pago anulado desde la operación de origen'
      );
  end if;

  -- ===================================================
  -- REFERENCIA Y OBSERVACIONES
  -- ===================================================

  v_referencia :=
    nullif(
      trim(
        coalesce(
          p_pago ->> 'referencia',
          ''
        )
      ),
      ''
    );

  v_observaciones :=
    nullif(
      trim(
        coalesce(
          p_pago ->> 'observaciones',
          ''
        )
      ),
      ''
    );

  -- ===================================================
  -- CONFIGURAR COBRO DE VENTA
  -- ===================================================

  if p_origen_pago = 'pago_venta' then
    begin
      v_operacion_id :=
        (
          nullif(
            p_pago ->> 'venta_id',
            ''
          )
        )::uuid;

    exception
      when invalid_text_representation then
        raise exception
          'El identificador de la venta es inválido';
    end;

    if v_operacion_id is null then
      raise exception
        'La venta asociada es obligatoria';
    end if;

    select
      v.numero
    into
      v_numero_operacion
    from public.ventas as v
    where v.id = v_operacion_id;

    if not found then
      raise exception
        'La venta asociada al pago no existe';
    end if;

    v_categoria_nombre :=
      'Cobro de venta';

    v_tipo_movimiento :=
      'ingreso';

    v_origen_movimiento :=
      'venta';

    v_referencia_tipo :=
      'pago_venta';

    v_concepto :=
      format(
        'Cobro de venta VTA-%s',
        lpad(
          v_numero_operacion::text,
          6,
          '0'
        )
      );

    v_referencia_predeterminada :=
      format(
        'PAG-%s',
        lpad(
          v_numero_pago::text,
          6,
          '0'
        )
      );

  -- ===================================================
  -- CONFIGURAR PAGO DE COMPRA
  -- ===================================================

  else
    begin
      v_operacion_id :=
        (
          nullif(
            p_pago ->> 'compra_id',
            ''
          )
        )::uuid;

    exception
      when invalid_text_representation then
        raise exception
          'El identificador de la compra es inválido';
    end;

    if v_operacion_id is null then
      raise exception
        'La compra asociada es obligatoria';
    end if;

    select
      c.numero
    into
      v_numero_operacion
    from public.compras as c
    where c.id = v_operacion_id;

    if not found then
      raise exception
        'La compra asociada al pago no existe';
    end if;

    v_categoria_nombre :=
      'Pago a proveedor';

    v_tipo_movimiento :=
      'egreso';

    v_origen_movimiento :=
      'compra';

    v_referencia_tipo :=
      'pago_compra';

    v_concepto :=
      format(
        'Pago a proveedor COM-%s',
        lpad(
          v_numero_operacion::text,
          6,
          '0'
        )
      );

    v_referencia_predeterminada :=
      format(
        'PCO-%s',
        lpad(
          v_numero_pago::text,
          6,
          '0'
        )
      );
  end if;

  -- ===================================================
  -- OBTENER CATEGORÍA
  -- ===================================================

  v_categoria_id :=
    public.obtener_o_crear_categoria_caja_sistema(
      v_comercio_id,
      v_categoria_nombre,
      v_tipo_movimiento
    );

  -- ===================================================
  -- CREAR O ACTUALIZAR MOVIMIENTO DE CAJA
  -- ===================================================

  insert into public.movimientos_caja (
    comercio_id,
    categoria_id,
    tipo,
    origen,
    fecha,
    importe,
    medio_pago,
    concepto,
    referencia,
    observaciones,
    referencia_tipo,
    referencia_id,
    estado,
    creado_por,
    anulado_at,
    anulado_por,
    motivo_anulacion
  )
  values (
    v_comercio_id,
    v_categoria_id,
    v_tipo_movimiento,
    v_origen_movimiento,
    v_fecha_pago,
    v_importe,
    v_medio_pago,
    v_concepto,

    coalesce(
      v_referencia,
      v_referencia_predeterminada
    ),

    v_observaciones,
    v_referencia_tipo,
    v_pago_id,
    v_estado_pago,
    v_creado_por,
    v_anulado_at,
    v_anulado_por,
    v_motivo_anulacion
  )
  on conflict (
    comercio_id,
    referencia_tipo,
    referencia_id
  )
  where referencia_id is not null
  do update set
    categoria_id =
      excluded.categoria_id,

    tipo =
      excluded.tipo,

    origen =
      excluded.origen,

    fecha =
      excluded.fecha,

    importe =
      excluded.importe,

    medio_pago =
      excluded.medio_pago,

    concepto =
      excluded.concepto,

    referencia =
      excluded.referencia,

    observaciones =
      excluded.observaciones,

    estado =
      excluded.estado,

    creado_por =
      coalesce(
        public.movimientos_caja.creado_por,
        excluded.creado_por
      ),

    anulado_at =
      excluded.anulado_at,

    anulado_por =
      excluded.anulado_por,

    motivo_anulacion =
      excluded.motivo_anulacion

  returning id
  into v_movimiento_id;

  return v_movimiento_id;
end;
$$;

-- =====================================================
-- FUNCIÓN DE TRIGGER
-- =====================================================

create or replace function
public.sincronizar_pago_con_caja_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'pagos_ventas' then
    perform
      public.sincronizar_pago_caja_desde_json(
        'pago_venta',
        to_jsonb(new)
      );

  elsif tg_table_name = 'pagos_compras' then
    perform
      public.sincronizar_pago_caja_desde_json(
        'pago_compra',
        to_jsonb(new)
      );

  else
    raise exception
      'La tabla "%" no está soportada por la integración de Caja',
      tg_table_name;
  end if;

  return new;
end;
$$;

-- =====================================================
-- TRIGGER PARA COBROS DE VENTAS
-- =====================================================

drop trigger if exists
pagos_ventas_sincronizar_caja
on public.pagos_ventas;

create trigger
pagos_ventas_sincronizar_caja
after insert or update
on public.pagos_ventas
for each row
execute function
public.sincronizar_pago_con_caja_trigger();

-- =====================================================
-- TRIGGER PARA PAGOS DE COMPRAS
-- =====================================================

drop trigger if exists
pagos_compras_sincronizar_caja
on public.pagos_compras;

create trigger
pagos_compras_sincronizar_caja
after insert or update
on public.pagos_compras
for each row
execute function
public.sincronizar_pago_con_caja_trigger();

-- =====================================================
-- IMPORTAR PAGOS HISTÓRICOS
--
-- También actualiza movimientos si el script se ejecuta
-- nuevamente. El índice único evita duplicados.
-- =====================================================

do $$
declare
  v_pago record;
begin
  -- Cobros de ventas existentes.

  for v_pago in
    select
      to_jsonb(pv) as datos
    from public.pagos_ventas as pv
    order by pv.created_at
  loop
    perform
      public.sincronizar_pago_caja_desde_json(
        'pago_venta',
        v_pago.datos
      );
  end loop;

  -- Pagos de compras existentes.

  for v_pago in
    select
      to_jsonb(pc) as datos
    from public.pagos_compras as pc
    order by pc.created_at
  loop
    perform
      public.sincronizar_pago_caja_desde_json(
        'pago_compra',
        v_pago.datos
      );
  end loop;
end;
$$;

-- =====================================================
-- PERMISOS
--
-- Estas funciones son internas. Los usuarios no deben
-- ejecutarlas directamente.
-- =====================================================

revoke all
on function
public.obtener_o_crear_categoria_caja_sistema(
  uuid,
  text,
  text
)
from public;

revoke all
on function
public.sincronizar_pago_caja_desde_json(
  text,
  jsonb
)
from public;

revoke all
on function
public.sincronizar_pago_con_caja_trigger()
from public;