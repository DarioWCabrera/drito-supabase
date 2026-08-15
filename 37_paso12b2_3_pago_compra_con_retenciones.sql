-- =============================================================
-- DRITO - PASO 12B.2.3
-- PAGO INDIVIDUAL DE COMPRA + RETENCIONES PRACTICADAS
-- =============================================================
--
-- Regla económica:
--
--   dinero pagado
-- + retenciones practicadas
-- = deuda cancelada
--
-- Caja recibe SOLAMENTE el dinero efectivamente pagado.
--
-- La operación completa es atómica.
-- Si falla una retención, se revierte también el pago generado
-- en esta misma llamada.
--
-- =============================================================

begin;


-- =============================================================
-- 0. PRECONDICIONES
-- =============================================================

do $$
begin

  if to_regclass(
    'public.compras'
  ) is null then
    raise exception 'Falta public.compras';
  end if;


  if to_regclass(
    'public.retenciones_practicadas'
  ) is null then
    raise exception
      'Falta public.retenciones_practicadas';
  end if;


  if to_regclass(
    'public.configuraciones_agentes_fiscales'
  ) is null then
    raise exception
      'Falta public.configuraciones_agentes_fiscales';
  end if;


  if to_regprocedure(
    'public.__drito_calcular_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta __drito_calcular_cancelacion_compra(uuid). Ejecutá primero el paso 12B.2.2';
  end if;


  if to_regprocedure(
    'public.__drito_sincronizar_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta __drito_sincronizar_cancelacion_compra(uuid)';
  end if;


  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta exigir_permiso_comercio(uuid,text)';
  end if;

end;
$$;


-- =============================================================
-- 1. RPC TRANSACCIONAL
-- =============================================================

create or replace function
public.registrar_pago_compra_con_retenciones(

  p_compra_id uuid,

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

  compra_id uuid,

  dinero_operacion numeric,

  retenciones_operacion numeric,

  total_aplicado_operacion numeric,

  dinero_pagado_acumulado numeric,

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

  v_compra public.compras%rowtype;

  v_comercio public.comercios%rowtype;

  v_config
    public.configuraciones_agentes_fiscales%rowtype;


  v_resumen_antes record;

  v_resumen_final record;


  v_pago_id uuid;

  v_numero_pago bigint;


  v_importe_dinero numeric(18,2);

  v_retenciones_json jsonb;

  v_total_retenciones numeric(18,2) := 0;

  v_total_operacion numeric(18,2);


  v_item jsonb;

  v_configuracion_id uuid;

  v_importe_retencion numeric(18,2);

  v_base_calculo numeric(18,2);

  v_alicuota numeric(9,6);


  v_fecha_retencion date;

  v_periodo_desde date;

  v_periodo_hasta date;


  v_numero_certificado text;

  v_observaciones_retencion text;


  v_agente_cuit text;

  v_agente_razon_social text;

begin

  -- ===========================================================
  -- AUTENTICACIÓN
  -- ===========================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;


  if p_compra_id is null then
    raise exception
      'La compra es obligatoria';
  end if;


  -- ===========================================================
  -- COMPRA
  -- ===========================================================

  select c.*
  into v_compra
  from public.compras as c
  where c.id = p_compra_id
  for update;


  if not found then
    raise exception
      'Compra no encontrada';
  end if;


  perform public.exigir_permiso_comercio(
    v_compra.comercio_id,
    'compras.registrar_pagos'
  );


  if v_compra.estado <> 'confirmada' then
    raise exception
      'No se pueden registrar pagos o retenciones en una compra anulada';
  end if;


  if v_compra.proveedor_id is null then
    raise exception
      'La compra no posee proveedor asociado';
  end if;


  -- ===========================================================
  -- COMERCIO / DATOS DEL AGENTE
  -- ===========================================================

  select c.*
  into v_comercio
  from public.comercios as c
  where c.id = v_compra.comercio_id;


  if not found then
    raise exception
      'Comercio no encontrado';
  end if;


  v_agente_cuit :=
    nullif(
      trim(
        coalesce(
          v_comercio.cuit,
          ''
        )
      ),
      ''
    );


  v_agente_razon_social :=
    coalesce(

      nullif(
        trim(
          coalesce(
            v_comercio.razon_social,
            ''
          )
        ),
        ''
      ),

      nullif(
        trim(
          coalesce(
            v_comercio.nombre_comercial,
            ''
          )
        ),
        ''
      )

    );


  -- ===========================================================
  -- FECHA
  -- ===========================================================

  if p_fecha_pago is null then
    raise exception
      'La fecha del pago es obligatoria';
  end if;


  if p_fecha_pago > current_date then
    raise exception
      'La fecha del pago no puede ser futura';
  end if;


  if p_fecha_pago < v_compra.fecha_compra then
    raise exception
      'La fecha del pago no puede ser anterior a la compra';
  end if;


  -- ===========================================================
  -- DINERO
  -- ===========================================================

  v_importe_dinero :=
    round(
      coalesce(
        p_importe_dinero,
        0
      ),
      2
    );


  if v_importe_dinero < 0 then
    raise exception
      'El dinero pagado no puede ser negativo';
  end if;


  if
    v_importe_dinero > 0
    and nullif(
      trim(
        coalesce(
          p_medio_pago,
          ''
        )
      ),
      ''
    ) is null
  then
    raise exception
      'El medio de pago es obligatorio cuando existe dinero pagado';
  end if;


  -- ===========================================================
  -- RETENCIONES JSON
  -- ===========================================================

  v_retenciones_json :=
    coalesce(
      p_retenciones,
      '[]'::jsonb
    );


  if jsonb_typeof(
    v_retenciones_json
  ) <> 'array' then
    raise exception
      'Las retenciones deben enviarse como un arreglo JSON';
  end if;


  -- ===========================================================
  -- PRIMERA PASADA:
  -- VALIDAR Y TOTALIZAR RETENCIONES
  -- ===========================================================

  for v_item in

    select value
    from jsonb_array_elements(
      v_retenciones_json
    )

  loop

    -- ---------------------------------------------------------
    -- CONFIGURACIÓN
    -- ---------------------------------------------------------

    if nullif(
      trim(
        coalesce(
          v_item->>'configuracion_agente_id',
          ''
        )
      ),
      ''
    ) is null then

      raise exception
        'Cada retención debe indicar configuracion_agente_id';

    end if;


    begin

      v_configuracion_id :=
        trim(
          v_item->>'configuracion_agente_id'
        )::uuid;

    exception

      when invalid_text_representation then

        raise exception
          'configuracion_agente_id no posee un UUID válido';

    end;


    select cfg.*
    into v_config
    from public.configuraciones_agentes_fiscales as cfg
    where cfg.id = v_configuracion_id;


    if not found then
      raise exception
        'La configuración fiscal indicada no existe';
    end if;


    if
      v_config.comercio_id
        <> v_compra.comercio_id
    then
      raise exception
        'La configuración fiscal pertenece a otro comercio';
    end if;


    if v_config.tipo_agente <> 'retencion' then
      raise exception
        'La configuración seleccionada no corresponde a retenciones';
    end if;


    if v_config.activo is not true then
      raise exception
        'La configuración de agente de retención está desactivada';
    end if;


    -- ---------------------------------------------------------
    -- FECHA RETENCIÓN
    -- ---------------------------------------------------------

    begin

      v_fecha_retencion :=
        coalesce(

          nullif(
            trim(
              coalesce(
                v_item->>'fecha_retencion',
                ''
              )
            ),
            ''
          )::date,

          p_fecha_pago

        );

    exception

      when invalid_datetime_format
        or datetime_field_overflow then

        raise exception
          'La fecha de una retención no es válida';

    end;


    if v_fecha_retencion > current_date then
      raise exception
        'La fecha de una retención no puede ser futura';
    end if;


    if
      v_fecha_retencion
        < v_compra.fecha_compra
    then
      raise exception
        'La fecha de una retención no puede ser anterior a la compra';
    end if;


    if
      v_fecha_retencion
        < v_config.vigencia_desde
    then
      raise exception
        'La configuración fiscal todavía no estaba vigente en la fecha de retención';
    end if;


    if
      v_config.vigencia_hasta is not null
      and
      v_fecha_retencion
        > v_config.vigencia_hasta
    then
      raise exception
        'La configuración fiscal ya no estaba vigente en la fecha de retención';
    end if;


    -- ---------------------------------------------------------
    -- IMPORTE
    -- ---------------------------------------------------------

    if nullif(
      trim(
        coalesce(
          v_item->>'importe',
          ''
        )
      ),
      ''
    ) is null then

      raise exception
        'Cada retención debe indicar su importe';

    end if;


    begin

      v_importe_retencion :=
        round(
          replace(
            trim(
              v_item->>'importe'
            ),
            ',',
            '.'
          )::numeric,
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


    -- ---------------------------------------------------------
    -- BASE
    -- ---------------------------------------------------------

    v_base_calculo := null;


    if nullif(
      trim(
        coalesce(
          v_item->>'base_calculo',
          ''
        )
      ),
      ''
    ) is not null then

      begin

        v_base_calculo :=
          round(
            replace(
              trim(
                v_item->>'base_calculo'
              ),
              ',',
              '.'
            )::numeric,
            2
          );

      exception

        when invalid_text_representation then

          raise exception
            'La base de cálculo de una retención no es numérica';

      end;


      if v_base_calculo < 0 then
        raise exception
          'La base de cálculo no puede ser negativa';
      end if;

    end if;


    -- ---------------------------------------------------------
    -- ALÍCUOTA
    -- ---------------------------------------------------------

    v_alicuota := null;


    if nullif(
      trim(
        coalesce(
          v_item->>'alicuota',
          ''
        )
      ),
      ''
    ) is not null then

      begin

        v_alicuota :=
          replace(
            trim(
              v_item->>'alicuota'
            ),
            ',',
            '.'
          )::numeric(9,6);

      exception

        when invalid_text_representation then

          raise exception
            'La alícuota de una retención no es numérica';

      end;

    elsif
      v_config.modo_alicuota = 'fija'
    then

      v_alicuota :=
        v_config.alicuota_fija;

    end if;


    if
      v_alicuota is not null
      and (
        v_alicuota < 0
        or v_alicuota > 100
      )
    then
      raise exception
        'La alícuota debe estar entre 0 y 100';
    end if;


    if
      v_config.modo_alicuota = 'fija'
      and v_alicuota
        is distinct from
        v_config.alicuota_fija
    then
      raise exception
        'La alícuota no coincide con la configuración fiscal fija';
    end if;


    -- ---------------------------------------------------------
    -- PERÍODO
    -- ---------------------------------------------------------

    begin

      v_periodo_desde :=
        nullif(
          trim(
            coalesce(
              v_item->>'periodo_desde',
              ''
            )
          ),
          ''
        )::date;


      v_periodo_hasta :=
        nullif(
          trim(
            coalesce(
              v_item->>'periodo_hasta',
              ''
            )
          ),
          ''
        )::date;

    exception

      when invalid_datetime_format
        or datetime_field_overflow then

        raise exception
          'El período informado en una retención no es válido';

    end;


    if
      v_periodo_desde is not null
      and v_periodo_hasta is not null
      and v_periodo_hasta
        < v_periodo_desde
    then
      raise exception
        'El período hasta no puede ser anterior al período desde';
    end if;


    -- ---------------------------------------------------------
    -- ACUMULAR
    -- ---------------------------------------------------------

    v_total_retenciones :=
      round(
        v_total_retenciones
        + v_importe_retencion,
        2
      );

  end loop;


  -- ===========================================================
  -- TOTAL DE LA OPERACIÓN
  -- ===========================================================

  v_total_operacion :=
    round(
      v_importe_dinero
      + v_total_retenciones,
      2
    );


  if v_total_operacion <= 0 then
    raise exception
      'La operación debe incluir dinero pagado, al menos una retención o ambos';
  end if;


  -- ===========================================================
  -- SALDO ANTES DE OPERAR
  -- ===========================================================

  select *
  into v_resumen_antes
  from public.__drito_calcular_cancelacion_compra(
    v_compra.id
  );


  if
    v_resumen_antes.saldo_pendiente
      <= 0
  then
    raise exception
      'La compra ya se encuentra totalmente pagada';
  end if;


  if
    v_total_operacion
      > v_resumen_antes.saldo_pendiente
  then
    raise exception
      'El pago más las retenciones supera el saldo pendiente. Saldo disponible: %',
      v_resumen_antes.saldo_pendiente;
  end if;


  -- ===========================================================
  -- DINERO REAL
  --
  -- Únicamente esta parte genera Caja.
  -- ===========================================================

  if v_importe_dinero > 0 then

    select
      r.pago_id,
      r.numero_pago

    into
      v_pago_id,
      v_numero_pago

    from public.registrar_pago_compra(

      v_compra.id,

      v_importe_dinero,

      p_fecha_pago,

      trim(
        p_medio_pago
      ),

      nullif(
        trim(
          coalesce(
            p_referencia,
            ''
          )
        ),
        ''
      ),

      nullif(
        trim(
          coalesce(
            p_observaciones,
            ''
          )
        ),
        ''
      )

    ) as r;

  end if;


  -- ===========================================================
  -- SEGUNDA PASADA:
  -- CREAR RETENCIONES
  -- ===========================================================

  for v_item in

    select value
    from jsonb_array_elements(
      v_retenciones_json
    )

  loop

    v_configuracion_id :=
      trim(
        v_item->>'configuracion_agente_id'
      )::uuid;


    select cfg.*
    into v_config
    from public.configuraciones_agentes_fiscales as cfg
    where cfg.id = v_configuracion_id;


    v_importe_retencion :=
      round(
        replace(
          trim(
            v_item->>'importe'
          ),
          ',',
          '.'
        )::numeric,
        2
      );


    v_fecha_retencion :=
      coalesce(

        nullif(
          trim(
            coalesce(
              v_item->>'fecha_retencion',
              ''
            )
          ),
          ''
        )::date,

        p_fecha_pago

      );


    v_periodo_desde :=
      nullif(
        trim(
          coalesce(
            v_item->>'periodo_desde',
            ''
          )
        ),
        ''
      )::date;


    v_periodo_hasta :=
      nullif(
        trim(
          coalesce(
            v_item->>'periodo_hasta',
            ''
          )
        ),
        ''
      )::date;


    v_base_calculo := null;


    if nullif(
      trim(
        coalesce(
          v_item->>'base_calculo',
          ''
        )
      ),
      ''
    ) is not null then

      v_base_calculo :=
        round(
          replace(
            trim(
              v_item->>'base_calculo'
            ),
            ',',
            '.'
          )::numeric,
          2
        );

    end if;


    v_alicuota := null;


    if nullif(
      trim(
        coalesce(
          v_item->>'alicuota',
          ''
        )
      ),
      ''
    ) is not null then

      v_alicuota :=
        replace(
          trim(
            v_item->>'alicuota'
          ),
          ',',
          '.'
        )::numeric(9,6);

    elsif
      v_config.modo_alicuota = 'fija'
    then

      v_alicuota :=
        v_config.alicuota_fija;

    end if;


    v_numero_certificado :=
      nullif(
        trim(
          coalesce(
            v_item->>'numero_certificado',
            ''
          )
        ),
        ''
      );


    v_observaciones_retencion :=
      nullif(
        trim(
          coalesce(
            v_item->>'observaciones',
            ''
          )
        ),
        ''
      );


    insert into public.retenciones_practicadas (

      comercio_id,

      configuracion_agente_id,

      proveedor_id,

      compra_id,

      pago_compra_id,

      fecha_retencion,

      periodo_desde,

      periodo_hasta,

      agente_retencion_cuit,

      agente_retencion_razon_social,

      numero_certificado,

      base_calculo,

      alicuota,

      importe,

      moneda,

      observaciones,

      estado,

      estado_obligacion,

      creado_por

    )
    values (

      v_compra.comercio_id,

      v_configuracion_id,

      v_compra.proveedor_id,

      v_compra.id,

      v_pago_id,

      v_fecha_retencion,

      v_periodo_desde,

      v_periodo_hasta,

      v_agente_cuit,

      v_agente_razon_social,

      v_numero_certificado,

      v_base_calculo,

      v_alicuota,

      v_importe_retencion,

      v_compra.moneda,

      v_observaciones_retencion,

      'registrada',

      'pendiente',

      auth.uid()

    );

  end loop;


  -- ===========================================================
  -- SINCRONIZACIÓN FINAL
  -- ===========================================================

  perform
    public.__drito_sincronizar_cancelacion_compra(
      v_compra.id
    );


  select *
  into v_resumen_final
  from public.__drito_calcular_cancelacion_compra(
    v_compra.id
  );


  -- ===========================================================
  -- RESULTADO
  -- ===========================================================

  return query
  select

    v_pago_id,

    v_numero_pago,

    v_compra.id,

    v_importe_dinero,

    v_total_retenciones,

    v_total_operacion,

    v_resumen_final.dinero_pagado,

    v_resumen_final.retenciones_practicadas,

    v_resumen_final.total_cancelado,

    v_resumen_final.saldo_pendiente,

    v_resumen_final.estado_pago;

end;
$$;


-- =============================================================
-- 2. SEGURIDAD
-- =============================================================

revoke all
on function
public.registrar_pago_compra_con_retenciones(
  uuid,
  numeric,
  date,
  text,
  text,
  text,
  jsonb
)
from public, anon, authenticated;


grant execute
on function
public.registrar_pago_compra_con_retenciones(
  uuid,
  numeric,
  date,
  text,
  text,
  text,
  jsonb
)
to authenticated;


notify pgrst, 'reload schema';


commit;


-- =============================================================
-- FIN PASO 12B.2.3
-- =============================================================