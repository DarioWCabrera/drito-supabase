-- ============================================================
-- DRITO 12B.5.5
-- ANULACIÓN SEGURA DE PERCEPCIONES SUFRIDAS EN COMPRAS
--
-- Archivo:
--   50_paso12b5_5_anulacion_percepcion_sufrida_segura.sql
--
-- Objetivos:
--   - anular una percepción sufrida sin borrarla;
--   - conservar trazabilidad: usuario, fecha y motivo;
--   - preservar certificado/evidencia;
--   - recalcular el total final de la compra;
--   - NO tratar la percepción como pago;
--   - NO generar ni anular movimientos de Caja;
--   - bloquear automáticamente una reducción del total si la
--     compra ya tiene más deuda cancelada que el nuevo total.
--
-- Permiso específico:
--   compras.anular_percepciones
--
-- Motivo del permiso específico:
--   anular una percepción sufrida no equivale a anular un pago
--   ni a anular la compra completa.
-- ============================================================

begin;


-- ============================================================
-- 0. DEPENDENCIAS
-- ============================================================

do $$
begin

  if to_regclass(
    'public.percepciones_sufridas'
  ) is null then
    raise exception
      'Falta public.percepciones_sufridas';
  end if;


  if to_regclass(
    'public.permisos_sistema'
  ) is null then
    raise exception
      'Falta public.permisos_sistema';
  end if;


  if to_regclass(
    'public.roles_permisos'
  ) is null then
    raise exception
      'Falta public.roles_permisos';
  end if;


  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.exigir_permiso_comercio(uuid,text)';
  end if;


  if to_regprocedure(
    'public.__drito_calcular_total_compra_con_percepciones(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_calcular_total_compra_con_percepciones(uuid)';
  end if;


  if to_regprocedure(
    'public.__drito_sincronizar_total_compra_percepciones(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_sincronizar_total_compra_percepciones(uuid)';
  end if;


  if to_regprocedure(
    'public.__drito_calcular_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_calcular_cancelacion_compra(uuid)';
  end if;


  if not exists (
    select 1
    from pg_trigger tg
    where tg.tgrelid =
      'public.percepciones_sufridas'::regclass
      and tg.tgname =
        'percepciones_sufridas_sincronizar_compra'
      and not tg.tgisinternal
  ) then
    raise exception
      'Falta trigger percepciones_sufridas_sincronizar_compra';
  end if;

end;
$$;


-- ============================================================
-- 1. PERMISO ESPECÍFICO
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
values (
  'compras.anular_percepciones',
  'compras',
  'anular_percepciones',
  'Anular percepciones de compras',
  'Anular percepciones sufridas conservando trazabilidad y recalculando la deuda de la compra.',
  true,
  745,
  true
)
on conflict (codigo) do update
set
  modulo = excluded.modulo,
  accion = excluded.accion,
  nombre = excluded.nombre,
  descripcion = excluded.descripcion,
  sensible = excluded.sensible,
  orden = excluded.orden,
  activo = true,
  updated_at = now();


-- Asignación predeterminada únicamente al rol admin.
insert into public.roles_permisos (
  rol,
  permiso_codigo,
  permitido
)
values (
  'admin',
  'compras.anular_percepciones',
  true
)
on conflict (rol, permiso_codigo) do update
set
  permitido = true;


-- ============================================================
-- 2. RPC DE ANULACIÓN SEGURA
-- ============================================================

create or replace function
public.anular_percepcion_sufrida(
  p_percepcion_id uuid,
  p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_usuario_id uuid;

  v_percepcion
    public.percepciones_sufridas%rowtype;

  v_motivo text;
  v_anulado_at timestamptz;

  v_total record;
  v_cancelacion record;
begin

  -- ==========================================================
  -- AUTENTICACIÓN
  -- ==========================================================

  v_usuario_id :=
    auth.uid();


  if v_usuario_id is null then
    raise exception
      'Debés iniciar sesión para anular una percepción';
  end if;


  if p_percepcion_id is null then
    raise exception
      'La percepción es obligatoria';
  end if;


  -- ==========================================================
  -- MOTIVO
  -- ==========================================================

  v_motivo :=
    nullif(
      trim(
        coalesce(
          p_motivo,
          ''
        )
      ),
      ''
    );


  if
    v_motivo is null
    or char_length(v_motivo) < 3
  then
    raise exception
      'Ingresá un motivo de anulación de al menos 3 caracteres';
  end if;


  if char_length(v_motivo) > 250 then
    raise exception
      'El motivo de anulación no puede superar los 250 caracteres';
  end if;


  -- ==========================================================
  -- PERCEPCIÓN
  -- Bloqueo de fila para evitar anulaciones simultáneas.
  -- ==========================================================

  select p.*
  into v_percepcion
  from public.percepciones_sufridas as p
  where p.id = p_percepcion_id
  for update;


  if not found then
    raise exception
      'Percepción sufrida no encontrada';
  end if;


  if v_percepcion.estado = 'anulada' then
    raise exception
      'La percepción sufrida ya se encuentra anulada';
  end if;


  if v_percepcion.estado <> 'registrada' then
    raise exception
      'La percepción sufrida no se encuentra en un estado anulable';
  end if;


  -- ==========================================================
  -- PERMISO
  --
  -- No reutilizamos compras.anular_pagos porque una percepción
  -- sufrida NO es un pago.
  -- ==========================================================

  perform public.exigir_permiso_comercio(
    v_percepcion.comercio_id,
    'compras.anular_percepciones'
  );


  -- ==========================================================
  -- ANULACIÓN LÓGICA
  --
  -- NO se modifica:
  --   - numero_certificado
  --   - certificado_storage_path
  --   - compra_id
  --   - proveedor_id
  --   - datos snapshot del agente/proveedor
  --   - importe/base/alícuota
  --   - pagos
  --   - Caja
  -- ==========================================================

  v_anulado_at :=
    now();


  update public.percepciones_sufridas
  set
    estado = 'anulada',
    anulado_por = v_usuario_id,
    anulado_at = v_anulado_at,
    motivo_anulacion = v_motivo
  where id = v_percepcion.id;


  -- ==========================================================
  -- RECÁLCULO EXPLÍCITO
  --
  -- El trigger AFTER UPDATE ya ejecuta este motor.
  -- Lo repetimos para que la RPC sea autosuficiente.
  --
  -- IMPORTANTE:
  -- Si quitar la percepción deja el nuevo total de la compra
  -- por debajo de lo ya cancelado por dinero + retenciones
  -- practicadas, el motor lanza excepción y TODA esta anulación
  -- se revierte automáticamente.
  -- ==========================================================

  perform
    public.__drito_sincronizar_total_compra_percepciones(
      v_percepcion.compra_id
    );


  select *
  into v_total
  from public.__drito_calcular_total_compra_con_percepciones(
    v_percepcion.compra_id
  );


  select *
  into v_cancelacion
  from public.__drito_calcular_cancelacion_compra(
    v_percepcion.compra_id
  );


  -- ==========================================================
  -- RESULTADO
  -- ==========================================================

  return jsonb_build_object(
    'ok',
      true,

    'percepcion_id',
      v_percepcion.id,

    'comercio_id',
      v_percepcion.comercio_id,

    'compra_id',
      v_percepcion.compra_id,

    'proveedor_id',
      v_percepcion.proveedor_id,

    'importe_percepcion',
      v_percepcion.importe,

    'numero_certificado',
      v_percepcion.numero_certificado,

    'certificado_storage_path',
      v_percepcion.certificado_storage_path,

    'estado_anterior',
      v_percepcion.estado,

    'estado',
      'anulada',

    'motivo_anulacion',
      v_motivo,

    'anulado_por',
      v_usuario_id,

    'anulado_at',
      v_anulado_at,

    'total_comercial',
      v_total.total_comercial,

    'percepciones_sufridas_vigentes',
      v_total.percepciones_sufridas,

    'total_final_compra',
      v_total.total_final,

    'total_cancelado',
      v_cancelacion.total_cancelado,

    'saldo_pendiente',
      v_cancelacion.saldo_pendiente,

    'estado_pago',
      v_cancelacion.estado_pago
  );

end;
$function$;


-- ============================================================
-- 3. SEGURIDAD DE EJECUCIÓN
-- ============================================================

revoke all
on function
public.anular_percepcion_sufrida(
  uuid,
  text
)
from public, anon, authenticated;


grant execute
on function
public.anular_percepcion_sufrida(
  uuid,
  text
)
to authenticated;


comment on function
public.anular_percepcion_sufrida(
  uuid,
  text
)
is
'DRITO_AUTOGUARDIA: requiere compras.anular_percepciones. Anula lógicamente una percepción sufrida, preserva evidencia y recalcula el total de la compra sin tocar Caja.';


-- Fuerza a PostgREST a refrescar el esquema.
notify pgrst, 'reload schema';


commit;


-- ============================================================
-- FIN 12B.5.5
-- Verificación estructural y prueba funcional con ROLLBACK
-- se ejecutan por separado.
-- ============================================================
