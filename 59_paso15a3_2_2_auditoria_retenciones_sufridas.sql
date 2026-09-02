-- ============================================================
-- DRITO
-- PASO 15A.3.2.2
-- AUDITORÍA OPERACIONAL - RETENCIONES SUFRIDAS
--
-- Audita automáticamente:
-- - alta de una retención sufrida;
-- - anulación de una retención sufrida.
--
-- No modifica:
-- - registrar_cobro_venta_con_retenciones(...)
-- - anular_retencion_sufrida(...)
-- - Caja;
-- - saldo de ventas;
-- - motores de cancelación.
--
-- La auditoría se conecta mediante trigger sobre
-- public.retenciones_sufridas para evitar duplicar el evento
-- del pago en dinero, que ya se audita en registrar_pago_venta.
-- ============================================================


-- ============================================================
-- 0. PRECONDICIONES
-- ============================================================

do $$
begin

  if to_regclass(
    'public.retenciones_sufridas'
  ) is null then
    raise exception
      'Falta public.retenciones_sufridas';
  end if;


  if to_regclass(
    'public.auditoria_operaciones'
  ) is null then
    raise exception
      'Falta public.auditoria_operaciones';
  end if;


  if to_regprocedure(
    'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
  ) is null then
    raise exception
      'Falta el helper de auditoría operacional';
  end if;

end;
$$;


-- ============================================================
-- 1. FUNCIÓN INTERNA DE AUDITORÍA
-- ============================================================

create or replace function
public.__drito_auditar_retencion_sufrida()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$

declare

  v_referencia text;

  v_motivo_anulacion text;

begin

  -- ----------------------------------------------------------
  -- ALTA
  -- ----------------------------------------------------------

  if tg_op = 'INSERT' then

    v_referencia :=
      nullif(
        trim(
          coalesce(
            new.numero_certificado,
            ''
          )
        ),
        ''
      );


    perform public.__drito_registrar_auditoria_operacion(
      p_comercio_id  => new.comercio_id,
      p_modulo       => 'ventas',
      p_accion       => 'retencion_sufrida_registrada',
      p_entidad_tipo => 'retencion_sufrida',
      p_entidad_id   => new.id::text,
      p_referencia   => v_referencia,
      p_detalle      => jsonb_build_object(

        'venta_id',
          new.venta_id,

        'pago_venta_id',
          new.pago_venta_id,

        'cliente_id',
          new.cliente_id,

        'fecha_retencion',
          new.fecha_retencion,

        'impuesto',
          new.impuesto,

        'jurisdiccion',
          new.jurisdiccion,

        'numero_certificado',
          new.numero_certificado,

        'importe',
          new.importe,

        'moneda',
          new.moneda,

        'estado',
          new.estado

      )
    );


    return new;

  end if;


  -- ----------------------------------------------------------
  -- ANULACIÓN
  -- ----------------------------------------------------------

  if tg_op = 'UPDATE'
     and old.estado is distinct from new.estado
     and new.estado = 'anulada' then


    v_referencia :=
      nullif(
        trim(
          coalesce(
            new.numero_certificado,
            ''
          )
        ),
        ''
      );


    -- Se obtiene desde JSON para no acoplar la función
    -- a una columna opcional de motivo si el modelo cambia.

    v_motivo_anulacion :=
      nullif(
        trim(
          coalesce(
            to_jsonb(new)->>'motivo_anulacion',
            ''
          )
        ),
        ''
      );


    perform public.__drito_registrar_auditoria_operacion(
      p_comercio_id  => new.comercio_id,
      p_modulo       => 'ventas',
      p_accion       => 'retencion_sufrida_anulada',
      p_entidad_tipo => 'retencion_sufrida',
      p_entidad_id   => new.id::text,
      p_referencia   => v_referencia,
      p_detalle      => jsonb_build_object(

        'venta_id',
          new.venta_id,

        'pago_venta_id',
          new.pago_venta_id,

        'cliente_id',
          new.cliente_id,

        'impuesto',
          new.impuesto,

        'jurisdiccion',
          new.jurisdiccion,

        'numero_certificado',
          new.numero_certificado,

        'importe',
          new.importe,

        'moneda',
          new.moneda,

        'estado_anterior',
          old.estado,

        'estado_nuevo',
          new.estado,

        'motivo',
          v_motivo_anulacion,

        'anulado_por',
          to_jsonb(new)->>'anulado_por',

        'anulado_at',
          to_jsonb(new)->>'anulado_at'

      )
    );


    return new;

  end if;


  return new;

end;
$function$;


-- ============================================================
-- 2. FUNCIÓN EXCLUSIVAMENTE INTERNA
-- ============================================================

revoke all on function
public.__drito_auditar_retencion_sufrida()
from public, anon, authenticated;


-- ============================================================
-- 3. TRIGGER
-- ============================================================

drop trigger if exists
retenciones_sufridas_auditoria_operacional
on public.retenciones_sufridas;


create trigger
retenciones_sufridas_auditoria_operacional
after insert or update of estado
on public.retenciones_sufridas
for each row
execute function
public.__drito_auditar_retencion_sufrida();


-- ============================================================
-- 4. VERIFICACIÓN ESTRUCTURAL
-- ============================================================

select jsonb_build_object(

  'tabla_retenciones',
    to_regclass(
      'public.retenciones_sufridas'
    ) is not null,

  'tabla_auditoria',
    to_regclass(
      'public.auditoria_operaciones'
    ) is not null,

  'helper_auditoria',
    to_regprocedure(
      'public.__drito_registrar_auditoria_operacion(uuid,text,text,text,text,text,jsonb,uuid)'
    ) is not null,

  'funcion_trigger',
    to_regprocedure(
      'public.__drito_auditar_retencion_sufrida()'
    ) is not null,

  'trigger_instalado',
    exists (
      select 1
      from pg_trigger tg
      where tg.tgrelid =
        'public.retenciones_sufridas'::regclass

        and tg.tgname =
          'retenciones_sufridas_auditoria_operacional'

        and not tg.tgisinternal
    ),

  'registros_auditoria_actuales',
    (
      select count(*)
      from public.auditoria_operaciones
    )

) as verificacion_15a3_2_2;