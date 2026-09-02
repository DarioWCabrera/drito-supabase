-- =============================================================
-- DRITO - MÓDULO 12B.3.3
-- Anulación segura de retenciones practicadas
-- Archivo: 42_paso12b3_3_anulacion_retencion_practicada_segura.sql
--
-- Objetivos:
--   - anular una retención practicada sin borrarla;
--   - conservar trazabilidad (usuario, fecha, motivo y certificado);
--   - recalcular la cancelación de todas las compras afectadas;
--   - soportar retenciones directas y agrupadas;
--   - NO anular PAG/PPR ni movimientos de Caja;
--   - NO borrar aplicaciones agrupadas ni archivos de certificado.
--
-- Permisos:
--   - retención directa:
--       compras.anular_pagos
--   - retención agrupada PPR:
--       cuentas_proveedores.anular_pagos
--
-- Regla fiscal de seguridad:
--   - solo se permite anulación directa mientras la obligación
--     fiscal esté 'pendiente';
--   - si ya está 'presentada' o 'ingresada', debe resolverse mediante
--     un circuito futuro de reversión/rectificación fiscal.
-- =============================================================

begin;

-- -------------------------------------------------------------
-- 1. VALIDACIÓN DE DEPENDENCIAS
-- -------------------------------------------------------------

do $$
begin
  if to_regclass(
    'public.retenciones_practicadas'
  ) is null then
    raise exception
      'Falta public.retenciones_practicadas';
  end if;

  if to_regclass(
    'public.retenciones_practicadas_aplicaciones'
  ) is null then
    raise exception
      'Falta public.retenciones_practicadas_aplicaciones';
  end if;

  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta public.exigir_permiso_comercio(uuid,text)';
  end if;

  if to_regprocedure(
    'public.__drito_calcular_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_calcular_cancelacion_compra(uuid)';
  end if;

  if to_regprocedure(
    'public.__drito_sincronizar_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta public.__drito_sincronizar_cancelacion_compra(uuid)';
  end if;
end;
$$;


-- -------------------------------------------------------------
-- 2. RPC DE ANULACIÓN SEGURA
-- -------------------------------------------------------------

create or replace function
public.anular_retencion_practicada(
  p_retencion_id uuid,
  p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_usuario_id uuid;

  v_retencion
    public.retenciones_practicadas%rowtype;

  v_motivo text;

  v_origen text;
  v_permiso text;

  v_compras_afectadas uuid[] :=
    array[]::uuid[];

  v_compra_id uuid;

  v_anulado_at timestamptz;

  v_compras_recalculadas jsonb :=
    '[]'::jsonb;
begin

  -- ===========================================================
  -- AUTENTICACIÓN Y DATOS BÁSICOS
  -- ===========================================================

  v_usuario_id :=
    auth.uid();

  if v_usuario_id is null then
    raise exception
      'Debés iniciar sesión para anular una retención';
  end if;


  if p_retencion_id is null then
    raise exception
      'La retención es obligatoria';
  end if;


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


  -- ===========================================================
  -- RETENCIÓN
  -- Bloqueamos la fila para evitar dos anulaciones simultáneas.
  -- ===========================================================

  select r.*
  into v_retencion
  from public.retenciones_practicadas as r
  where r.id = p_retencion_id
  for update;


  if not found then
    raise exception
      'Retención practicada no encontrada';
  end if;


  -- ===========================================================
  -- ORIGEN + PERMISO
  --
  -- Directa:
  --   compra_id presente y sin pago_proveedor_id.
  --
  -- Agrupada:
  --   pago_proveedor_id presente y sin compra_id.
  -- ===========================================================

  if
    v_retencion.compra_id is not null
    and v_retencion.pago_proveedor_id is null
  then

    v_origen :=
      'individual';

    v_permiso :=
      'compras.anular_pagos';

  elsif
    v_retencion.compra_id is null
    and v_retencion.pago_proveedor_id is not null
  then

    v_origen :=
      'agrupada';

    v_permiso :=
      'cuentas_proveedores.anular_pagos';

  else

    raise exception
      'La retención tiene un origen inconsistente y no puede anularse de forma segura';

  end if;


  perform
    public.exigir_permiso_comercio(
      v_retencion.comercio_id,
      v_permiso
    );


  -- ===========================================================
  -- ESTADO
  -- ===========================================================

  if v_retencion.estado = 'anulada' then
    raise exception
      'La retención ya se encuentra anulada';
  end if;


  if v_retencion.estado <> 'registrada' then
    raise exception
      'La retención no se encuentra en un estado anulable';
  end if;


  -- Si la obligación ya salió del estado pendiente, una anulación
  -- simple dentro de Drito podría dejar inconsistencia frente al
  -- organismo fiscal. Ese caso se resolverá con un circuito
  -- específico de reversión/rectificación.
  if v_retencion.estado_obligacion <> 'pendiente' then
    raise exception
      'La obligación fiscal ya fue presentada o ingresada. Requiere una reversión o rectificación fiscal y no puede anularse directamente desde Drito';
  end if;


  -- ===========================================================
  -- COMPRAS AFECTADAS
  --
  -- Guardamos las relaciones ANTES del UPDATE.
  -- Las aplicaciones agrupadas se preservan como trazabilidad.
  -- ===========================================================

  if v_origen = 'individual' then

    v_compras_afectadas :=
      array[
        v_retencion.compra_id
      ]::uuid[];

  else

    select
      coalesce(
        array_agg(
          distinct a.compra_id
        ),
        array[]::uuid[]
      )
    into v_compras_afectadas
    from public.retenciones_practicadas_aplicaciones as a
    where a.retencion_id =
      v_retencion.id;

  end if;


  -- ===========================================================
  -- ANULACIÓN LÓGICA
  --
  -- NO se modifica:
  --   - numero_certificado
  --   - certificado_storage_path
  --   - pago_compra_id
  --   - pago_proveedor_id
  --   - aplicaciones
  --   - pagos
  --   - Caja
  -- ===========================================================

  v_anulado_at :=
    now();


  update public.retenciones_practicadas
  set
    estado = 'anulada',
    estado_obligacion = 'anulada',
    anulado_por = v_usuario_id,
    anulado_at = v_anulado_at,
    motivo_anulacion = v_motivo
  where id = v_retencion.id;


  -- ===========================================================
  -- RECÁLCULO EXPLÍCITO
  --
  -- El trigger de retenciones practicadas ya sincroniza las
  -- compras después del UPDATE. Repetimos explícitamente la
  -- sincronización para que esta RPC sea autosuficiente y deje
  -- garantizado el estado final de todas las compras afectadas.
  -- ===========================================================

  foreach v_compra_id
  in array v_compras_afectadas
  loop

    perform
      public.__drito_sincronizar_cancelacion_compra(
        v_compra_id
      );

  end loop;


  -- ===========================================================
  -- RESUMEN FINAL PARA FRONTEND / AUDITORÍA
  -- ===========================================================

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'compra_id',
            resumen.compra_id,

          'total_compra',
            resumen.total_compra,

          'dinero_pagado',
            resumen.dinero_pagado,

          'retenciones_directas',
            resumen.retenciones_directas,

          'retenciones_agrupadas',
            resumen.retenciones_agrupadas,

          'retenciones_practicadas',
            resumen.retenciones_practicadas,

          'total_cancelado',
            resumen.total_cancelado,

          'saldo_pendiente',
            resumen.saldo_pendiente,

          'estado_pago',
            resumen.estado_pago
        )
        order by
          resumen.compra_id::text
      ),
      '[]'::jsonb
    )
  into v_compras_recalculadas
  from unnest(
    v_compras_afectadas
  ) as afectada(compra_id)
  cross join lateral
    public.__drito_calcular_cancelacion_compra(
      afectada.compra_id
    ) as resumen;


  return
    jsonb_build_object(
      'ok',
        true,

      'retencion_id',
        v_retencion.id,

      'comercio_id',
        v_retencion.comercio_id,

      'proveedor_id',
        v_retencion.proveedor_id,

      'origen',
        v_origen,

      'permiso_aplicado',
        v_permiso,

      'importe_retencion',
        v_retencion.importe,

      'numero_certificado',
        v_retencion.numero_certificado,

      'certificado_storage_path',
        v_retencion.certificado_storage_path,

      'pago_compra_id',
        v_retencion.pago_compra_id,

      'pago_proveedor_id',
        v_retencion.pago_proveedor_id,

      'estado_anterior',
        v_retencion.estado,

      'estado_obligacion_anterior',
        v_retencion.estado_obligacion,

      'estado',
        'anulada',

      'estado_obligacion',
        'anulada',

      'motivo_anulacion',
        v_motivo,

      'anulado_por',
        v_usuario_id,

      'anulado_at',
        v_anulado_at,

      'compras_afectadas',
        to_jsonb(
          v_compras_afectadas
        ),

      'compras_recalculadas',
        v_compras_recalculadas
    );

end;
$function$;


-- -------------------------------------------------------------
-- 3. SEGURIDAD DE EJECUCIÓN
-- -------------------------------------------------------------

revoke all on function
public.anular_retencion_practicada(
  uuid,
  text
)
from public, anon, authenticated;


grant execute on function
public.anular_retencion_practicada(
  uuid,
  text
)
to authenticated;


-- Esta RPC usa una autoguardia dinámica porque el permiso correcto
-- depende del origen real de la retención. No corresponde envolverla
-- con una única entrada de rpc_permisos_drito.
comment on function
public.anular_retencion_practicada(
  uuid,
  text
)
is
  'DRITO_AUTOGUARDIA_DINAMICA: compras.anular_pagos para retención directa; cuentas_proveedores.anular_pagos para retención agrupada.';


-- Fuerza a PostgREST a refrescar el esquema para exponer la RPC nueva.
notify pgrst, 'reload schema';


commit;

-- =============================================================
-- FIN 12B.3.3
-- La verificación estructural y la prueba funcional con ROLLBACK
-- se ejecutan por separado.
-- =============================================================
