-- ============================================================
-- DRITO - MODULO 28 / PASO 10A
-- Persistencia + idempotencia para emisión fiscal WSFEv1
-- Fecha: 2026-08-09
--
-- Objetivo:
-- - distinguir una emisión en curso de un resultado incierto;
-- - impedir reenvíos automáticos peligrosos;
-- - guardar una clave estable de idempotencia por comprobante;
-- - guardar hash sanitizado de la solicitud y trazabilidad de intentos;
-- - mantener la inmutabilidad de comprobantes autorizados.
--
-- Este script NO emite comprobantes, NO solicita CAE y NO modifica
-- numeración fiscal de ARCA.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Metadatos de idempotencia / recuperación
-- ------------------------------------------------------------
alter table public.comprobantes_fiscales
  add column if not exists clave_idempotencia uuid,
  add column if not exists solicitud_hash text,
  add column if not exists envio_iniciado_at timestamptz,
  add column if not exists resultado_incierto_at timestamptz,
  add column if not exists ultima_recuperacion_at timestamptz,
  add column if not exists intentos_envio integer not null default 0;

-- Completa claves para filas previas, si existieran.
update public.comprobantes_fiscales
set clave_idempotencia = gen_random_uuid()
where clave_idempotencia is null;

alter table public.comprobantes_fiscales
  alter column clave_idempotencia set default gen_random_uuid(),
  alter column clave_idempotencia set not null;

alter table public.comprobantes_fiscales
  drop constraint if exists comprobantes_fiscales_intentos_envio_check;

alter table public.comprobantes_fiscales
  add constraint comprobantes_fiscales_intentos_envio_check
  check (intentos_envio >= 0);

alter table public.comprobantes_fiscales
  drop constraint if exists comprobantes_fiscales_solicitud_hash_check;

alter table public.comprobantes_fiscales
  add constraint comprobantes_fiscales_solicitud_hash_check
  check (
    solicitud_hash is null
    or solicitud_hash ~ '^[0-9a-f]{64}$'
  );

create unique index if not exists
comprobantes_fiscales_clave_idempotencia_uidx
on public.comprobantes_fiscales (clave_idempotencia);

comment on column public.comprobantes_fiscales.clave_idempotencia is
  'Identidad estable del intento lógico de facturación. Repetir una llamada para este comprobante nunca debe generar una segunda emisión.';

comment on column public.comprobantes_fiscales.solicitud_hash is
  'SHA-256 hexadecimal del payload fiscal canónico y sanitizado. No contiene Token, Sign, certificado ni clave privada.';

comment on column public.comprobantes_fiscales.envio_iniciado_at is
  'Momento en que el backend reclamó atómicamente el comprobante antes de FECAESolicitar.';

comment on column public.comprobantes_fiscales.resultado_incierto_at is
  'Se completa cuando la solicitud pudo haber llegado a ARCA pero no fue posible confirmar el resultado. Antes de reintentar debe ejecutarse recuperación/consulta.';

comment on column public.comprobantes_fiscales.ultima_recuperacion_at is
  'Último intento de reconciliación con ARCA mediante consulta del comprobante.';

comment on column public.comprobantes_fiscales.intentos_envio is
  'Cantidad de veces que el backend tomó el lock lógico para iniciar un envío. No habilita reintentos automáticos.';

-- ------------------------------------------------------------
-- 2. Estados de emisión
-- ------------------------------------------------------------
-- Conservamos pendiente_autorizacion del modelo original y agregamos:
--   enviando  = lock tomado inmediatamente antes del request a ARCA
--   incierto  = pudo llegar a ARCA; se prohíbe reemitir sin reconciliar

alter table public.comprobantes_fiscales
  drop constraint if exists comprobantes_fiscales_estado_check;

alter table public.comprobantes_fiscales
  add constraint comprobantes_fiscales_estado_check
  check (
    estado in (
      'borrador',
      'pendiente_autorizacion',
      'enviando',
      'incierto',
      'autorizado',
      'rechazado',
      'error',
      'descartado'
    )
  );

-- ------------------------------------------------------------
-- 3. Integridad fiscal actualizada
-- ------------------------------------------------------------
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

  if new.estado in (
      'pendiente_autorizacion',
      'enviando',
      'incierto',
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
      'enviando',
      'incierto',
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

  -- Si el request ya comenzó, la identidad exacta del payload debe quedar fija.
  if new.estado in ('enviando', 'incierto') then
    if new.solicitud_hash is null then
      raise exception
        'Una emisión iniciada requiere solicitud_hash para idempotencia';
    end if;

    if new.envio_iniciado_at is null then
      raise exception
        'Una emisión iniciada requiere envio_iniciado_at';
    end if;
  end if;

  if new.estado = 'incierto'
     and new.resultado_incierto_at is null then
    raise exception
      'Un resultado incierto requiere resultado_incierto_at';
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

-- El trigger original conserva el mismo nombre y seguirá llamando
-- a esta versión actualizada de la función.

-- ------------------------------------------------------------
-- 4. Máquina de estados: evita saltos inseguros
-- ------------------------------------------------------------
create or replace function
public.validar_transicion_estado_comprobante_fiscal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op <> 'UPDATE'
     or new.estado = old.estado then
    return new;
  end if;

  if old.estado = 'borrador'
     and new.estado in (
       'pendiente_autorizacion',
       'descartado'
     ) then
    return new;
  end if;

  if old.estado = 'pendiente_autorizacion'
     and new.estado in (
       'enviando',
       'error',
       'descartado'
     ) then
    return new;
  end if;

  if old.estado = 'enviando'
     and new.estado in (
       'autorizado',
       'rechazado',
       'incierto'
     ) then
    return new;
  end if;

  -- Desde incierto sólo se sale por reconciliación explícita.
  if old.estado = 'incierto'
     and new.estado in (
       'autorizado',
       'rechazado',
       'error'
     ) then
    return new;
  end if;

  -- error significa que no quedó una autorización confirmada. Para
  -- reintentar debe volver explícitamente a pendiente_autorizacion.
  if old.estado = 'error'
     and new.estado in (
       'pendiente_autorizacion',
       'descartado'
     ) then
    return new;
  end if;

  raise exception
    'Transición fiscal no permitida: % -> %',
    old.estado,
    new.estado;
end;
$$;

revoke all on function
public.validar_transicion_estado_comprobante_fiscal()
from public, anon, authenticated;

drop trigger if exists
comprobantes_fiscales_00_validar_transicion
on public.comprobantes_fiscales;

create trigger comprobantes_fiscales_00_validar_transicion
before update
on public.comprobantes_fiscales
for each row
execute function
public.validar_transicion_estado_comprobante_fiscal();

-- ------------------------------------------------------------
-- 5. Índices operativos para recuperación
-- ------------------------------------------------------------
create index if not exists
comprobantes_fiscales_recuperacion_idx
on public.comprobantes_fiscales (
  comercio_id,
  ambiente_arca,
  estado,
  envio_iniciado_at
)
where estado in ('enviando', 'incierto');

commit;

-- ============================================================
-- VERIFICACIÓN SEGURA (sólo estructura; no emite nada)
-- ============================================================
select
  column_name,
  data_type,
  is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name = 'comprobantes_fiscales'
  and column_name in (
    'clave_idempotencia',
    'solicitud_hash',
    'envio_iniciado_at',
    'resultado_incierto_at',
    'ultima_recuperacion_at',
    'intentos_envio'
  )
order by ordinal_position;