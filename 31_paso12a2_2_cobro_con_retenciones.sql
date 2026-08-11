-- =============================================================
-- DRITO - PASO 12A.2.2
-- COBRO INDIVIDUAL + RETENCIONES SUFRIDAS (TRANSACCIONAL)
-- =============================================================
--
-- Objetivo:
--   - Una venta puede cancelarse con dinero + retenciones sufridas.
--   - Caja recibe SOLO el dinero efectivamente cobrado.
--   - Las retenciones NO generan movimientos de Caja.
--   - ventas.total_pagado representa el TOTAL CANCELADO de la deuda
--     (dinero + retenciones vigentes).
--   - La operación completa es atómica: si falla una retención,
--     también se revierte el pago creado en esa misma llamada.
--
-- Este paso no modifica el frontend todavía.
-- =============================================================

begin;

do $$
begin
  if to_regclass('public.ventas') is null then
    raise exception 'Falta public.ventas';
  end if;

  if to_regclass('public.pagos_ventas') is null then
    raise exception 'Falta public.pagos_ventas';
  end if;

  if to_regclass('public.retenciones_sufridas') is null then
    raise exception 'Falta public.retenciones_sufridas';
  end if;

  if to_regprocedure(
    'public.__drito_calcular_cancelacion_venta(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_calcular_cancelacion_venta(uuid). Ejecutá primero el paso 12A.2.1';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'registrar_pago_venta'
      and p.prokind = 'f'
  ) then
    raise exception 'Falta public.registrar_pago_venta';
  end if;

  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.exigir_permiso_comercio(uuid,text)';
  end if;
end;
$$;

create or replace function
public.__drito_sincronizar_cancelacion_venta(
  p_venta_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resumen record;
  v_estado_venta text;
begin
  if p_venta_id is null then
    return;
  end if;

  select v.estado
  into v_estado_venta
  from public.ventas as v
  where v.id = p_venta_id;

  if not found then
    return;
  end if;

  if v_estado_venta <> 'confirmada' then
    return;
  end if;

  select *
  into v_resumen
  from public.__drito_calcular_cancelacion_venta(
    p_venta_id
  );

  update public.ventas as v
  set
    total_pagado = v_resumen.total_cancelado,
    estado_pago = v_resumen.estado_pago
  where v.id = p_venta_id;
end;
$$;

revoke all on function
public.__drito_sincronizar_cancelacion_venta(uuid)
from public, anon, authenticated;

create or replace function
public.__drito_normalizar_resumen_cancelacion_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resumen record;
begin
  if new.estado <> 'confirmada' then
    return new;
  end if;

  select *
  into v_resumen
  from public.__drito_calcular_cancelacion_venta(
    new.id
  );

  new.total_pagado :=
    v_resumen.total_cancelado;

  new.estado_pago :=
    v_resumen.estado_pago;

  return new;
end;
$$;

revoke all on function
public.__drito_normalizar_resumen_cancelacion_venta()
from public, anon, authenticated;

drop trigger if exists
ventas_normalizar_resumen_cancelacion
on public.ventas;

create trigger
ventas_normalizar_resumen_cancelacion
before update of total_pagado, estado_pago
on public.ventas
for each row
execute function
public.__drito_normalizar_resumen_cancelacion_venta();

create or replace function
public.__drito_retencion_sincronizar_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venta_nueva uuid;
  v_venta_anterior uuid;
begin
  if tg_op in ('INSERT', 'UPDATE') then
    v_venta_nueva := new.venta_id;

    if v_venta_nueva is null
       and new.pago_venta_id is not null then
      select pv.venta_id
      into v_venta_nueva
      from public.pagos_ventas as pv
      where pv.id = new.pago_venta_id;
    end if;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    v_venta_anterior := old.venta_id;

    if v_venta_anterior is null
       and old.pago_venta_id is not null then
      select pv.venta_id
      into v_venta_anterior
      from public.pagos_ventas as pv
      where pv.id = old.pago_venta_id;
    end if;
  end if;

  if v_venta_anterior is not null then
    perform
      public.__drito_sincronizar_cancelacion_venta(
        v_venta_anterior
      );
  end if;

  if v_venta_nueva is not null
     and v_venta_nueva is distinct from v_venta_anterior then
    perform
      public.__drito_sincronizar_cancelacion_venta(
        v_venta_nueva
      );
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

revoke all on function
public.__drito_retencion_sincronizar_venta()
from public, anon, authenticated;

drop trigger if exists
retenciones_sufridas_sincronizar_venta
on public.retenciones_sufridas;

create trigger
retenciones_sufridas_sincronizar_venta
after insert or update or delete
on public.retenciones_sufridas
for each row
execute function
public.__drito_retencion_sincronizar_venta();

create or replace function
public.registrar_cobro_venta_con_retenciones(
  p_venta_id uuid,
  p_importe_dinero numeric default 0,
  p_fecha_pago date default current_date,
  p_medio_pago text default 'transferencia',
  p_referencia text default null,
  p_observaciones text default null,
  p_retenciones jsonb default '[]'::jsonb
)
returns table (
  pago_id uuid,
  numero_pago bigint,
  venta_id uuid,
  dinero_operacion numeric,
  retenciones_operacion numeric,
  total_aplicado_operacion numeric,
  dinero_recibido_acumulado numeric,
  retenciones_acumuladas numeric,
  total_cancelado numeric,
  saldo_pendiente numeric,
  estado_pago text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venta public.ventas%rowtype;
  v_resumen_antes record;
  v_resumen_final record;

  v_pago_id uuid;
  v_numero_pago bigint;

  v_importe_dinero numeric(18,2);
  v_retenciones_json jsonb;
  v_total_retenciones numeric(18,2) := 0;
  v_total_operacion numeric(18,2);

  v_item jsonb;
  v_importe_retencion numeric(18,2);
  v_base_calculo numeric(18,2);
  v_alicuota numeric(9,6);

  v_impuesto text;
  v_jurisdiccion text;
  v_regimen_codigo text;
  v_regimen_descripcion text;
  v_numero_certificado text;

  v_fecha_retencion date;
  v_periodo_desde date;
  v_periodo_hasta date;

  v_agente_cuit text;
  v_agente_razon_social text;
  v_observaciones_retencion text;
begin
  if auth.uid() is null then
    raise exception 'Usuario no autenticado';
  end if;

  if p_venta_id is null then
    raise exception 'La venta es obligatoria';
  end if;

  select v.*
  into v_venta
  from public.ventas as v
  where v.id = p_venta_id
  for update;

  if not found then
    raise exception 'Venta no encontrada';
  end if;

  perform public.exigir_permiso_comercio(
    v_venta.comercio_id,
    'ventas.registrar_cobros'
  );

  if v_venta.estado <> 'confirmada' then
    raise exception
      'No se pueden registrar cobros en una venta anulada';
  end if;

  if v_venta.cliente_id is null then
    raise exception
      'Una retención sufrida requiere una venta asociada a un cliente';
  end if;

  if p_fecha_pago is null then
    raise exception
      'La fecha de la cobranza es obligatoria';
  end if;

  if p_fecha_pago > current_date then
    raise exception
      'La fecha de la cobranza no puede ser futura';
  end if;

  if p_fecha_pago < v_venta.fecha_venta then
    raise exception
      'La fecha de la cobranza no puede ser anterior a la venta';
  end if;

  v_importe_dinero :=
    round(coalesce(p_importe_dinero, 0), 2);

  if v_importe_dinero < 0 then
    raise exception
      'El dinero recibido no puede ser negativo';
  end if;

  v_retenciones_json :=
    coalesce(p_retenciones, '[]'::jsonb);

  if jsonb_typeof(v_retenciones_json) <> 'array' then
    raise exception
      'Las retenciones deben enviarse como un arreglo JSON';
  end if;

  for v_item in
    select value
    from jsonb_array_elements(v_retenciones_json)
  loop
    v_impuesto :=
      nullif(trim(coalesce(v_item->>'impuesto', '')), '');

    v_numero_certificado :=
      nullif(trim(coalesce(v_item->>'numero_certificado', '')), '');

    if v_impuesto is null
       or char_length(v_impuesto) < 2 then
      raise exception
        'Cada retención debe indicar el impuesto';
    end if;

    if v_numero_certificado is null then
      raise exception
        'Cada retención debe indicar el número de certificado';
    end if;

    if nullif(trim(coalesce(v_item->>'importe', '')), '') is null then
      raise exception
        'Cada retención debe indicar su importe';
    end if;

    begin
      v_importe_retencion :=
        round(
          replace(trim(v_item->>'importe'), ',', '.')::numeric,
          2
        );
    exception
      when invalid_text_representation then
        raise exception
          'El importe de una retención no es numérico';
    end;

    if v_importe_retencion <= 0 then
      raise exception
        'El importe de cada retención debe ser mayor que cero';
    end if;

    v_fecha_retencion :=
      coalesce(
        nullif(trim(coalesce(v_item->>'fecha_retencion', '')), '')::date,
        p_fecha_pago
      );

    if v_fecha_retencion > current_date then
      raise exception
        'La fecha de una retención no puede ser futura';
    end if;

    if v_fecha_retencion < v_venta.fecha_venta then
      raise exception
        'La fecha de una retención no puede ser anterior a la venta';
    end if;

    v_total_retenciones :=
      round(
        v_total_retenciones + v_importe_retencion,
        2
      );
  end loop;

  v_total_operacion :=
    round(
      v_importe_dinero + v_total_retenciones,
      2
    );

  if v_total_operacion <= 0 then
    raise exception
      'La cobranza debe incluir dinero recibido, al menos una retención o ambos';
  end if;

  select *
  into v_resumen_antes
  from public.__drito_calcular_cancelacion_venta(
    v_venta.id
  );

  if v_resumen_antes.saldo_pendiente <= 0 then
    raise exception
      'La venta ya se encuentra pagada';
  end if;

  if v_total_operacion
     > v_resumen_antes.saldo_pendiente then
    raise exception
      'La cobranza supera el saldo pendiente. Saldo disponible: %',
      v_resumen_antes.saldo_pendiente;
  end if;

  if v_importe_dinero > 0 then
    select
      r.pago_id,
      r.numero_pago
    into
      v_pago_id,
      v_numero_pago
    from public.registrar_pago_venta(
      v_venta.id,
      v_importe_dinero,
      p_fecha_pago,
      p_medio_pago,
      p_referencia,
      p_observaciones
    ) as r;
  end if;

  for v_item in
    select value
    from jsonb_array_elements(v_retenciones_json)
  loop
    v_impuesto := trim(v_item->>'impuesto');

    v_jurisdiccion :=
      nullif(trim(coalesce(v_item->>'jurisdiccion', '')), '');

    v_regimen_codigo :=
      nullif(trim(coalesce(v_item->>'regimen_codigo', '')), '');

    v_regimen_descripcion :=
      nullif(trim(coalesce(v_item->>'regimen_descripcion', '')), '');

    v_numero_certificado :=
      trim(v_item->>'numero_certificado');

    v_importe_retencion :=
      round(
        replace(trim(v_item->>'importe'), ',', '.')::numeric,
        2
      );

    v_fecha_retencion :=
      coalesce(
        nullif(trim(coalesce(v_item->>'fecha_retencion', '')), '')::date,
        p_fecha_pago
      );

    v_periodo_desde :=
      nullif(trim(coalesce(v_item->>'periodo_desde', '')), '')::date;

    v_periodo_hasta :=
      nullif(trim(coalesce(v_item->>'periodo_hasta', '')), '')::date;

    v_base_calculo := null;
    if nullif(trim(coalesce(v_item->>'base_calculo', '')), '') is not null then
      v_base_calculo :=
        round(
          replace(trim(v_item->>'base_calculo'), ',', '.')::numeric,
          2
        );
    end if;

    v_alicuota := null;
    if nullif(trim(coalesce(v_item->>'alicuota', '')), '') is not null then
      v_alicuota :=
        replace(trim(v_item->>'alicuota'), ',', '.')::numeric(9,6);
    end if;

    v_agente_cuit :=
      nullif(trim(coalesce(v_item->>'agente_retencion_cuit', '')), '');

    v_agente_razon_social :=
      nullif(trim(coalesce(v_item->>'agente_retencion_razon_social', '')), '');

    v_observaciones_retencion :=
      nullif(trim(coalesce(v_item->>'observaciones', '')), '');

    begin
      insert into public.retenciones_sufridas (
        comercio_id,
        cliente_id,
        venta_id,
        pago_venta_id,
        fecha_retencion,
        periodo_desde,
        periodo_hasta,
        impuesto,
        jurisdiccion,
        regimen_codigo,
        regimen_descripcion,
        agente_retencion_cuit,
        agente_retencion_razon_social,
        numero_certificado,
        base_calculo,
        alicuota,
        importe,
        moneda,
        observaciones,
        estado,
        creado_por
      )
      values (
        v_venta.comercio_id,
        v_venta.cliente_id,
        v_venta.id,
        v_pago_id,
        v_fecha_retencion,
        v_periodo_desde,
        v_periodo_hasta,
        v_impuesto,
        v_jurisdiccion,
        v_regimen_codigo,
        v_regimen_descripcion,
        v_agente_cuit,
        v_agente_razon_social,
        v_numero_certificado,
        v_base_calculo,
        v_alicuota,
        v_importe_retencion,
        v_venta.moneda,
        v_observaciones_retencion,
        'registrada',
        auth.uid()
      );
    exception
      when unique_violation then
        raise exception
          'El certificado de retención "%" ya está registrado para este comercio',
          v_numero_certificado;
    end;
  end loop;

  perform
    public.__drito_sincronizar_cancelacion_venta(
      v_venta.id
    );

  select *
  into v_resumen_final
  from public.__drito_calcular_cancelacion_venta(
    v_venta.id
  );

  return query
  select
    v_pago_id,
    v_numero_pago,
    v_venta.id,
    v_importe_dinero,
    v_total_retenciones,
    v_total_operacion,
    v_resumen_final.dinero_recibido,
    v_resumen_final.retenciones_sufridas,
    v_resumen_final.total_cancelado,
    v_resumen_final.saldo_pendiente,
    v_resumen_final.estado_pago;
end;
$$;

revoke all on function
public.registrar_cobro_venta_con_retenciones(
  uuid,
  numeric,
  date,
  text,
  text,
  text,
  jsonb
)
from public, anon, authenticated;

grant execute on function
public.registrar_cobro_venta_con_retenciones(
  uuid,
  numeric,
  date,
  text,
  text,
  text,
  jsonb
)
to authenticated;

commit;

select
  'FUNCION' as tipo,
  p.proname as nombre
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    '__drito_sincronizar_cancelacion_venta',
    '__drito_normalizar_resumen_cancelacion_venta',
    '__drito_retencion_sincronizar_venta',
    'registrar_cobro_venta_con_retenciones'
  )

union all

select
  'TRIGGER' as tipo,
  tg.tgname as nombre
from pg_trigger tg
where not tg.tgisinternal
  and tg.tgname in (
    'ventas_normalizar_resumen_cancelacion',
    'retenciones_sufridas_sincronizar_venta'
  )

order by tipo, nombre;