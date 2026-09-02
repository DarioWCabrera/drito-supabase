-- ============================================================
-- DRITO 12B.4.3
-- ALTA TRANSACCIONAL DE VENTAS CON PERCEPCIONES PRACTICADAS
-- Archivo: 45_paso12b4_3_alta_ventas_con_percepciones.sql
--
-- Objetivo:
--   - Crear ventas directas con percepciones en una sola transacción.
--   - Convertir cotizaciones en ventas con percepciones.
--   - Registrar el pago inicial DESPUÉS de sumar las percepciones,
--     para validarlo contra el total final a cobrar.
--   - Mantener Caja = únicamente dinero real cobrado.
--
-- Compatibilidad:
--   - NO reemplaza las RPC históricas:
--       crear_venta_directa(...)
--       convertir_cotizacion_en_venta(...)
--   - Se agregan RPC nuevas, por lo que el frontend actual
--     continúa funcionando sin cambios.
--
-- Regla económica:
--
--   total comercial
--   + percepciones practicadas
--   = total final a cobrar
--
-- La determinación de régimen/alícuota NO se hardcodea.
-- Para configuraciones de alícuota fija se usa la alícuota
-- configurada. Para padrón/externa la alícuota debe venir
-- informada por el circuito que corresponda.
-- ============================================================

begin;

do $$
begin
  if to_regclass('public.percepciones_practicadas') is null then
    raise exception
      'Falta public.percepciones_practicadas. Ejecutá primero la migración 43.';
  end if;

  if to_regprocedure(
    'public.__drito_calcular_total_venta_con_percepciones(uuid)'
  ) is null then
    raise exception
      'Falta el motor de totalización de percepciones. Ejecutá primero la migración 44.';
  end if;

  if to_regprocedure(
    'public.__drito_calcular_cancelacion_venta(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_calcular_cancelacion_venta(uuid)';
  end if;

  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.exigir_permiso_comercio(uuid,text)';
  end if;

  if to_regprocedure(
    'public.__drito_original_crear_venta_directa_f4f43d8f40(uuid,uuid,date,text,numeric,text,jsonb,numeric,text,text,text)'
  ) is null then
    raise exception
      'Falta el motor interno original de venta directa';
  end if;

  if to_regprocedure(
    'public.__drito_original_convertir_cotizacion_en_venta_9dd87aa956(uuid,date,text)'
  ) is null then
    raise exception
      'Falta el motor interno original de conversión de cotización';
  end if;

  if to_regprocedure(
    'public.registrar_pago_venta(uuid,numeric,date,text,text,text)'
  ) is null then
    raise exception
      'Falta public.registrar_pago_venta(uuid,numeric,date,text,text,text)';
  end if;
end;
$$;


create or replace function
public.__drito_registrar_percepciones_venta(
  p_venta_id uuid,
  p_percepciones jsonb default '[]'::jsonb
)
returns table (
  percepciones_creadas integer,
  percepciones_total numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venta public.ventas%rowtype;
  v_item jsonb;
  v_config public.configuraciones_agentes_fiscales%rowtype;
  v_configuracion_id uuid;
  v_base_calculo numeric(14,2);
  v_alicuota numeric(9,4);
  v_alicuota_informada numeric(9,4);
  v_importe numeric(14,2);
  v_periodo_desde date;
  v_periodo_hasta date;
  v_observaciones text;
  v_cantidad integer := 0;
  v_total numeric(18,2) := 0;
begin
  if p_venta_id is null then
    raise exception 'La venta es obligatoria';
  end if;

  p_percepciones := coalesce(p_percepciones, '[]'::jsonb);

  if jsonb_typeof(p_percepciones) <> 'array' then
    raise exception
      'Las percepciones deben enviarse como un arreglo JSON';
  end if;

  select v.*
  into v_venta
  from public.ventas as v
  where v.id = p_venta_id
  for update;

  if not found then
    raise exception 'Venta no encontrada';
  end if;

  if v_venta.estado <> 'confirmada' then
    raise exception
      'Solo se pueden registrar percepciones sobre ventas confirmadas';
  end if;

  for v_item in
    select elemento.value
    from jsonb_array_elements(p_percepciones) as elemento(value)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception
        'Cada percepción debe ser un objeto JSON';
    end if;

    if nullif(
      trim(coalesce(v_item ->> 'configuracion_agente_id', '')),
      ''
    ) is null then
      raise exception
        'Cada percepción debe indicar configuracion_agente_id';
    end if;

    begin
      v_configuracion_id :=
        (v_item ->> 'configuracion_agente_id')::uuid;
    exception
      when invalid_text_representation then
        raise exception
          'Una percepción contiene configuracion_agente_id inválido';
    end;

    select c.*
    into v_config
    from public.configuraciones_agentes_fiscales as c
    where c.id = v_configuracion_id
    for share;

    if not found then
      raise exception 'Configuración de agente fiscal inexistente';
    end if;

    if v_config.comercio_id <> v_venta.comercio_id then
      raise exception
        'La configuración fiscal pertenece a otro comercio';
    end if;

    if v_config.tipo_agente <> 'percepcion' then
      raise exception
        'La configuración fiscal seleccionada no corresponde a un agente de percepción';
    end if;

    if v_config.activo is not true then
      raise exception
        'La configuración del agente de percepción no está activa';
    end if;

    if v_venta.fecha_venta < v_config.vigencia_desde then
      raise exception
        'La configuración fiscal todavía no estaba vigente en la fecha de venta';
    end if;

    if v_config.vigencia_hasta is not null
       and v_venta.fecha_venta > v_config.vigencia_hasta then
      raise exception
        'La configuración fiscal ya no estaba vigente en la fecha de venta';
    end if;

    if exists (
      select 1
      from public.percepciones_practicadas as p
      where p.venta_id = v_venta.id
        and p.configuracion_agente_id = v_configuracion_id
        and p.estado = 'registrada'
    ) then
      raise exception
        'La venta ya tiene una percepción vigente para la configuración fiscal indicada';
    end if;

    if nullif(
      trim(coalesce(v_item ->> 'base_calculo', '')),
      ''
    ) is null then
      raise exception
        'Cada percepción debe indicar base_calculo';
    end if;

    begin
      v_base_calculo :=
        round((v_item ->> 'base_calculo')::numeric, 2);
    exception
      when invalid_text_representation then
        raise exception
          'Una percepción contiene una base de cálculo inválida';
    end;

    if v_base_calculo < 0 then
      raise exception
        'La base de cálculo de una percepción no puede ser negativa';
    end if;

    v_alicuota_informada := null;

    if nullif(
      trim(coalesce(v_item ->> 'alicuota', '')),
      ''
    ) is not null then
      begin
        v_alicuota_informada :=
          round((v_item ->> 'alicuota')::numeric, 4);
      exception
        when invalid_text_representation then
          raise exception
            'Una percepción contiene una alícuota inválida';
      end;
    end if;

    if v_config.modo_alicuota = 'fija' then
      if v_config.alicuota_fija is null then
        raise exception
          'La configuración fiscal fija no tiene alícuota definida';
      end if;

      v_alicuota := round(v_config.alicuota_fija, 4);

      if v_alicuota_informada is not null
         and round(v_alicuota_informada, 4) <> round(v_alicuota, 4) then
        raise exception
          'La alícuota informada (%) no coincide con la alícuota fija configurada (%)',
          v_alicuota_informada,
          v_alicuota;
      end if;
    else
      if v_alicuota_informada is null then
        raise exception
          'La alícuota debe informarse para configuraciones de tipo padrón o externa';
      end if;

      v_alicuota := v_alicuota_informada;
    end if;

    if v_alicuota < 0 or v_alicuota > 100 then
      raise exception
        'La alícuota de una percepción debe estar entre 0 y 100';
    end if;

    if nullif(
      trim(coalesce(v_item ->> 'importe', '')),
      ''
    ) is null then
      raise exception
        'Cada percepción debe indicar importe';
    end if;

    begin
      v_importe :=
        round((v_item ->> 'importe')::numeric, 2);
    exception
      when invalid_text_representation then
        raise exception
          'Una percepción contiene un importe inválido';
    end;

    if v_importe <= 0 then
      raise exception
        'El importe de una percepción debe ser mayor que cero';
    end if;

    v_periodo_desde := null;
    v_periodo_hasta := null;

    if nullif(
      trim(coalesce(v_item ->> 'periodo_desde', '')),
      ''
    ) is not null then
      begin
        v_periodo_desde :=
          (v_item ->> 'periodo_desde')::date;
      exception
        when invalid_datetime_format then
          raise exception
            'Una percepción contiene periodo_desde inválido';
      end;
    end if;

    if nullif(
      trim(coalesce(v_item ->> 'periodo_hasta', '')),
      ''
    ) is not null then
      begin
        v_periodo_hasta :=
          (v_item ->> 'periodo_hasta')::date;
      exception
        when invalid_datetime_format then
          raise exception
            'Una percepción contiene periodo_hasta inválido';
      end;
    end if;

    v_observaciones :=
      nullif(
        trim(coalesce(v_item ->> 'observaciones', '')),
        ''
      );

    insert into public.percepciones_practicadas (
      comercio_id,
      configuracion_agente_id,
      venta_id,
      cliente_id,
      fecha_percepcion,
      periodo_desde,
      periodo_hasta,
      base_calculo,
      alicuota,
      importe,
      moneda,
      estado,
      estado_obligacion,
      observaciones,
      creado_por
    )
    values (
      v_venta.comercio_id,
      v_configuracion_id,
      v_venta.id,
      v_venta.cliente_id,
      v_venta.fecha_venta,
      v_periodo_desde,
      v_periodo_hasta,
      v_base_calculo,
      v_alicuota,
      v_importe,
      v_venta.moneda,
      'registrada',
      'pendiente',
      v_observaciones,
      auth.uid()
    );

    v_cantidad := v_cantidad + 1;
    v_total := round(v_total + v_importe, 2);
  end loop;

  return query
  select v_cantidad, v_total;
end;
$$;


create or replace function
public.crear_venta_directa_con_percepciones(
  p_comercio_id uuid,
  p_cliente_id uuid,
  p_fecha_venta date,
  p_moneda text,
  p_descuento_general_porcentaje numeric,
  p_observaciones text,
  p_items jsonb,
  p_pago_inicial numeric default 0,
  p_medio_pago text default 'efectivo',
  p_referencia_pago text default null,
  p_observaciones_pago text default null,
  p_percepciones jsonb default '[]'::jsonb
)
returns table (
  venta_id uuid,
  numero_venta bigint,
  total_comercial numeric,
  percepciones_total numeric,
  total_venta numeric,
  total_pagado numeric,
  saldo_pendiente numeric,
  estado_pago text,
  pago_id uuid,
  numero_pago bigint,
  movimientos_generados integer,
  percepciones_creadas integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_original record;
  v_percepciones record;
  v_cancelacion record;
  v_pago record;
  v_pago_inicial numeric(14,2);
  v_pago_id uuid := null;
  v_numero_pago bigint := null;
  v_total_final numeric(18,2);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_comercio_id is null then
    raise exception 'El comercio es obligatorio';
  end if;

  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'ventas.crear'
  );

  v_pago_inicial :=
    round(coalesce(p_pago_inicial, 0), 2);

  if v_pago_inicial < 0 then
    raise exception
      'El pago inicial no puede ser negativo';
  end if;

  select *
  into v_original
  from public.__drito_original_crear_venta_directa_f4f43d8f40(
    p_comercio_id,
    p_cliente_id,
    p_fecha_venta,
    p_moneda,
    p_descuento_general_porcentaje,
    p_observaciones,
    p_items,
    0,
    p_medio_pago,
    p_referencia_pago,
    p_observaciones_pago
  );

  if v_original.venta_id is null then
    raise exception 'No se pudo crear la venta';
  end if;

  select *
  into v_percepciones
  from public.__drito_registrar_percepciones_venta(
    v_original.venta_id,
    p_percepciones
  );

  select v.total
  into v_total_final
  from public.ventas as v
  where v.id = v_original.venta_id;

  if v_pago_inicial > 0 then
    select *
    into v_pago
    from public.registrar_pago_venta(
      v_original.venta_id,
      v_pago_inicial,
      p_fecha_venta,
      p_medio_pago,
      p_referencia_pago,
      p_observaciones_pago
    );

    v_pago_id := v_pago.pago_id;
    v_numero_pago := v_pago.numero_pago;
  end if;

  select *
  into v_cancelacion
  from public.__drito_calcular_cancelacion_venta(
    v_original.venta_id
  );

  return query
  select
    v_original.venta_id::uuid,
    v_original.numero_venta::bigint,
    round(v_original.total_venta, 2)::numeric,
    round(
      coalesce(v_percepciones.percepciones_total, 0),
      2
    )::numeric,
    round(v_total_final, 2)::numeric,
    round(v_cancelacion.total_cancelado, 2)::numeric,
    round(v_cancelacion.saldo_pendiente, 2)::numeric,
    v_cancelacion.estado_pago::text,
    v_pago_id,
    v_numero_pago,
    v_original.movimientos_generados::integer,
    coalesce(
      v_percepciones.percepciones_creadas,
      0
    )::integer;
end;
$$;


create or replace function
public.convertir_cotizacion_en_venta_con_percepciones(
  p_cotizacion_id uuid,
  p_fecha_venta date default current_date,
  p_observaciones text default null,
  p_percepciones jsonb default '[]'::jsonb
)
returns table (
  venta_id uuid,
  numero bigint,
  total_comercial numeric,
  percepciones_total numeric,
  total numeric,
  movimientos_generados integer,
  percepciones_creadas integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comercio_id uuid;
  v_original record;
  v_percepciones record;
  v_total_final numeric(18,2);
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_cotizacion_id is null then
    raise exception 'La cotización es obligatoria';
  end if;

  select c.comercio_id
  into v_comercio_id
  from public.cotizaciones as c
  where c.id = p_cotizacion_id;

  if v_comercio_id is null then
    raise exception
      'No se pudo determinar el comercio de la operación';
  end if;

  perform public.exigir_permiso_comercio(
    v_comercio_id,
    'ventas.crear'
  );

  select *
  into v_original
  from public.__drito_original_convertir_cotizacion_en_venta_9dd87aa956(
    p_cotizacion_id,
    p_fecha_venta,
    p_observaciones
  );

  if v_original.venta_id is null then
    raise exception
      'No se pudo convertir la cotización en venta';
  end if;

  select *
  into v_percepciones
  from public.__drito_registrar_percepciones_venta(
    v_original.venta_id,
    p_percepciones
  );

  select v.total
  into v_total_final
  from public.ventas as v
  where v.id = v_original.venta_id;

  return query
  select
    v_original.venta_id::uuid,
    v_original.numero::bigint,
    round(v_original.total, 2)::numeric,
    round(
      coalesce(v_percepciones.percepciones_total, 0),
      2
    )::numeric,
    round(v_total_final, 2)::numeric,
    v_original.movimientos_generados::integer,
    coalesce(
      v_percepciones.percepciones_creadas,
      0
    )::integer;
end;
$$;


revoke all
on function
public.__drito_registrar_percepciones_venta(uuid,jsonb)
from public, anon, authenticated;


revoke all
on function
public.crear_venta_directa_con_percepciones(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  jsonb,
  numeric,
  text,
  text,
  text,
  jsonb
)
from public, anon, authenticated;

grant execute
on function
public.crear_venta_directa_con_percepciones(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  jsonb,
  numeric,
  text,
  text,
  text,
  jsonb
)
to authenticated;


revoke all
on function
public.convertir_cotizacion_en_venta_con_percepciones(
  uuid,
  date,
  text,
  jsonb
)
from public, anon, authenticated;

grant execute
on function
public.convertir_cotizacion_en_venta_con_percepciones(
  uuid,
  date,
  text,
  jsonb
)
to authenticated;


comment on function
public.__drito_registrar_percepciones_venta(uuid,jsonb)
is
'Helper interno que registra percepciones practicadas sobre una venta confirmada usando configuraciones fiscales vigentes. No genera Caja.';

comment on function
public.crear_venta_directa_con_percepciones(
  uuid,
  uuid,
  date,
  text,
  numeric,
  text,
  jsonb,
  numeric,
  text,
  text,
  text,
  jsonb
)
is
'Crea una venta directa, registra percepciones y recién después procesa el pago inicial contra el total final. Caja conserva únicamente dinero real.';

comment on function
public.convertir_cotizacion_en_venta_con_percepciones(
  uuid,
  date,
  text,
  jsonb
)
is
'Convierte una cotización aceptada en venta y registra percepciones practicadas dentro de la misma transacción.';

commit;
