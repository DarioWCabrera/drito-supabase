-- =============================================================
-- DRITO - PASO 12B.2.4.2
-- PAGO AGRUPADO DE PROVEEDOR + RETENCIONES PRACTICADAS
-- =============================================================
--
-- Regla económica:
--
--   dinero real pagado
-- + retenciones practicadas
-- = deuda cancelada
--
-- Caja:
--   solamente dinero real.
--
-- Una retención agrupada se registra UNA sola vez en:
--
--   retenciones_practicadas
--
-- vinculada al PPR mediante:
--
--   pago_proveedor_id
--
-- Luego se distribuye entre compras mediante:
--
--   retenciones_practicadas_aplicaciones
--
-- evitando duplicar el certificado fiscal.
--
-- Requiere:
--   36_paso12b2_2_motor_cancelacion_compras_retenciones.sql
--   37_paso12b2_3_pago_compra_con_retenciones.sql
--   38_paso12b2_3_fix_numeracion_pag.sql
--   39_paso12b2_4_1_motor_pago_agrupado_saldo_central.sql
-- =============================================================


begin;


-- =============================================================
-- 0. PRECONDICIONES
-- =============================================================

do $$
begin

  if to_regclass(
    'public.retenciones_practicadas'
  ) is null then
    raise exception
      'Falta la tabla retenciones_practicadas';
  end if;


  if to_regclass(
    'public.retenciones_practicadas_aplicaciones'
  ) is null then
    raise exception
      'Falta la tabla retenciones_practicadas_aplicaciones';
  end if;


  if to_regclass(
    'public.configuraciones_agentes_fiscales'
  ) is null then
    raise exception
      'Falta la tabla configuraciones_agentes_fiscales';
  end if;


  if to_regprocedure(
    'public.registrar_pago_cuenta_proveedor(uuid,date,numeric,text,text,text)'
  ) is null then
    raise exception
      'Falta registrar_pago_cuenta_proveedor';
  end if;


  if to_regprocedure(
    'public.__drito_calcular_cancelacion_compra(uuid)'
  ) is null then
    raise exception
      'Falta __drito_calcular_cancelacion_compra';
  end if;


  if to_regprocedure(
    'public.exigir_permiso_comercio(uuid,text)'
  ) is null then
    raise exception
      'Falta exigir_permiso_comercio';
  end if;

end;
$$;


-- =============================================================
-- 1. RPC PÚBLICA
-- =============================================================

create or replace function
public.registrar_pago_cuenta_proveedor_con_retenciones(

  p_proveedor_id uuid,

  p_importe_dinero numeric,

  p_fecha_pago date
    default current_date,

  p_medio_pago text
    default 'transferencia',

  p_referencia text
    default null,

  p_observaciones text
    default null,

  p_retenciones jsonb
    default '[]'::jsonb

)
returns table (

  pago_proveedor_id uuid,

  numero_pago_proveedor bigint,

  comprobante text,

  nombre_proveedor text,

  dinero_operacion numeric,

  retenciones_operacion numeric,

  total_aplicado_operacion numeric,

  compras_afectadas_dinero integer,

  pagos_generados integer,

  retenciones_creadas integer,

  aplicaciones_retencion_creadas integer,

  saldo_anterior numeric,

  saldo_final numeric,

  movimiento_caja_id uuid

)
language plpgsql
security definer
set search_path = public
as $$
declare

  -- ===========================================================
  -- ENTIDADES
  -- ===========================================================

  v_proveedor
    public.proveedores%rowtype;

  v_comercio
    public.comercios%rowtype;

  v_cfg
    public.configuraciones_agentes_fiscales%rowtype;


  -- ===========================================================
  -- CONTEXTO GENERAL
  -- ===========================================================

  v_comercio_id uuid;

  v_nombre_proveedor text;

  v_moneda_operacion text;


  -- ===========================================================
  -- SALDOS
  -- ===========================================================

  v_saldo_anterior numeric(14,2) := 0;

  v_saldo_final numeric(14,2) := 0;

  v_saldo_esperado numeric(14,2) := 0;


  -- ===========================================================
  -- RETENCIONES
  -- ===========================================================

  v_retenciones_json jsonb;

  v_item jsonb;

  v_total_retenciones numeric(14,2) := 0;

  v_importe_retencion numeric(14,2);

  v_restante_retencion numeric(14,2);

  v_aplicado numeric(14,2);

  v_configuracion_id uuid;

  v_retencion_id uuid;

  v_fecha_retencion date;

  v_periodo_desde date;

  v_periodo_hasta date;

  v_base_calculo numeric(14,2);

  v_alicuota numeric(9,6);

  v_numero_certificado text;

  v_observaciones_retencion text;

  v_moneda_retencion text;


  -- ===========================================================
  -- SNAPSHOT FISCAL
  -- ===========================================================

  v_numero_inscripcion_agente text;

  v_sistema_presentacion text;

  v_agente_cuit text;

  v_agente_razon_social text;

  v_sujeto_retenido_cuit text;

  v_sujeto_retenido_razon_social text;


  -- ===========================================================
  -- PPR
  -- ===========================================================

  v_ppr record;


  -- ===========================================================
  -- CONTADORES FUNCIONALES
  -- ===========================================================

  v_retenciones_creadas integer := 0;

  v_aplicaciones_creadas integer := 0;


  -- ===========================================================
  -- FIFO
  -- ===========================================================

  v_compra record;

begin

  -- ===========================================================
  -- 2. AUTENTICACIÓN
  -- ===========================================================

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;


  -- ===========================================================
  -- 3. VALIDACIONES BÁSICAS
  -- ===========================================================

  if p_proveedor_id is null then
    raise exception
      'El proveedor es obligatorio';
  end if;


  if p_fecha_pago is null then
    raise exception
      'La fecha del pago es obligatoria';
  end if;


  if p_fecha_pago > current_date then
    raise exception
      'La fecha del pago no puede ser futura';
  end if;


  -- Este circuito representa PPR + retenciones.
  --
  -- pagos_proveedores conserva su regla histórica:
  -- importe > 0.
  --
  -- Por eso esta RPC exige dinero real.
  -- El circuito individual ya admite retención sin dinero.

  if p_importe_dinero is null
    or round(
      p_importe_dinero,
      2
    ) <= 0 then

    raise exception
      'El pago agrupado con retenciones debe incluir dinero real mayor a cero';

  end if;


  if nullif(
    trim(
      coalesce(
        p_medio_pago,
        ''
      )
    ),
    ''
  ) is null then

    raise exception
      'El medio de pago es obligatorio';

  end if;


  v_retenciones_json :=
    coalesce(
      p_retenciones,
      '[]'::jsonb
    );


  if jsonb_typeof(
    v_retenciones_json
  ) <> 'array' then

    raise exception
      'Las retenciones deben enviarse como un array JSON';

  end if;


  if jsonb_array_length(
    v_retenciones_json
  ) = 0 then

    raise exception
      'Debe informarse al menos una retención practicada';

  end if;


  -- ===========================================================
  -- 4. PROVEEDOR
  -- ===========================================================

  select *
  into v_proveedor

  from public.proveedores

  where id =
    p_proveedor_id;


  if not found then
    raise exception
      'Proveedor no encontrado';
  end if;


  v_comercio_id :=
    v_proveedor.comercio_id;


  -- ===========================================================
  -- 5. PERMISO
  --
  -- Igual que el pago agrupado histórico.
  --
  -- No se exige facturacion.configurar para efectuar el pago:
  -- la configuración fiscal debe existir y ser válida,
  -- pero pagar no equivale a editar la configuración.
  -- ===========================================================

  perform public.exigir_permiso_comercio(

    v_comercio_id,

    'cuentas_proveedores.registrar_pagos'

  );


  -- ===========================================================
  -- 6. COMERCIO
  -- ===========================================================

  select *
  into v_comercio

  from public.comercios

  where id =
    v_comercio_id;


  if not found then
    raise exception
      'Comercio no encontrado';
  end if;


  -- ===========================================================
  -- 7. NOMBRES / DATOS FISCALES SNAPSHOT
  -- ===========================================================

  v_nombre_proveedor :=

    coalesce(

      nullif(
        trim(
          to_jsonb(v_proveedor)
          ->> 'razon_social'
        ),
        ''
      ),

      nullif(
        trim(
          to_jsonb(v_proveedor)
          ->> 'nombre'
        ),
        ''
      ),

      'Proveedor sin nombre'

    );


  v_agente_razon_social :=

    coalesce(

      nullif(
        trim(
          to_jsonb(v_comercio)
          ->> 'razon_social'
        ),
        ''
      ),

      nullif(
        trim(
          to_jsonb(v_comercio)
          ->> 'nombre_comercial'
        ),
        ''
      )

    );


  v_agente_cuit :=

    nullif(

      regexp_replace(

        coalesce(
          to_jsonb(v_comercio)
          ->> 'cuit',
          ''
        ),

        '[^0-9]',

        '',

        'g'

      ),

      ''

    );


  v_sujeto_retenido_razon_social :=
    v_nombre_proveedor;


  v_sujeto_retenido_cuit :=

    nullif(

      regexp_replace(

        coalesce(
          to_jsonb(v_proveedor)
          ->> 'documento',
          ''
        ),

        '[^0-9]',

        '',

        'g'

      ),

      ''

    );


  -- Si el documento informado no tiene formato de CUIT,
  -- no se inventa un CUIT.

  if v_sujeto_retenido_cuit is not null
    and char_length(
      v_sujeto_retenido_cuit
    ) <> 11 then

    v_sujeto_retenido_cuit :=
      null;

  end if;


  -- ===========================================================
  -- 8. SERIALIZAR CUENTA DEL PROVEEDOR
  -- ===========================================================

  perform pg_advisory_xact_lock(

    hashtextextended(

      v_comercio_id::text
      || ':'
      || p_proveedor_id::text,

      0

    )

  );


  -- ===========================================================
  -- 9. MONEDA BASE DE LA OPERACIÓN
  --
  -- Se toma de la primera compra pendiente según FIFO.
  -- No se hardcodea ARS.
  -- ===========================================================

  select
    c.moneda

  into
    v_moneda_operacion

  from public.compras c

  cross join lateral

    public.__drito_calcular_cancelacion_compra(
      c.id
    ) r

  where c.comercio_id =
    v_comercio_id

    and c.proveedor_id =
      p_proveedor_id

    and c.estado =
      'confirmada'

    and r.saldo_pendiente > 0

  order by

    c.fecha_compra asc,

    c.numero asc,

    c.created_at asc,

    c.id asc

  limit 1;


  if v_moneda_operacion is null then
    raise exception
      'El proveedor no posee compras confirmadas con saldo pendiente';
  end if;


  -- ===========================================================
  -- 10. SALDO TOTAL ANTES DE LA OPERACIÓN
  -- ===========================================================

  select

    coalesce(
      sum(r.saldo_pendiente),
      0
    )::numeric(14,2)

  into
    v_saldo_anterior

  from public.compras c

  cross join lateral

    public.__drito_calcular_cancelacion_compra(
      c.id
    ) r

  where c.comercio_id =
    v_comercio_id

    and c.proveedor_id =
      p_proveedor_id

    and c.estado =
      'confirmada';


  if v_saldo_anterior <= 0 then
    raise exception
      'El proveedor no posee saldo pendiente';
  end if;


  -- ===========================================================
  -- 11. PRECALCULAR TOTAL DE RETENCIONES
  -- ===========================================================

  for v_item in

    select value

    from jsonb_array_elements(
      v_retenciones_json
    )

  loop

    if jsonb_typeof(
      v_item
    ) <> 'object' then

      raise exception
        'Cada retención debe ser un objeto JSON';

    end if;


    if nullif(
      trim(
        coalesce(
          v_item ->> 'importe',
          ''
        )
      ),
      ''
    ) is null then

      raise exception
        'Cada retención debe informar un importe';

    end if;


    begin

      v_importe_retencion :=

        round(

          replace(
            trim(
              v_item ->> 'importe'
            ),
            ',',
            '.'
          )::numeric,

          2

        );

    exception
      when others then

        raise exception
          'El importe de una retención no es válido';

    end;


    if v_importe_retencion <= 0 then
      raise exception
        'El importe de cada retención debe ser mayor a cero';
    end if;


    v_total_retenciones :=

      round(

        v_total_retenciones
        + v_importe_retencion,

        2

      );

  end loop;


  -- ===========================================================
  -- 12. VALIDAR TOTAL DE LA OPERACIÓN
  -- ===========================================================

  if round(
    p_importe_dinero
    + v_total_retenciones,
    2
  ) > v_saldo_anterior then

    raise exception
      'El dinero más las retenciones supera el saldo del proveedor. Saldo disponible: %',
      v_saldo_anterior;

  end if;


  -- ===========================================================
  -- 13. REGISTRAR DINERO REAL MEDIANTE EL CIRCUITO PPR EXISTENTE
  --
  -- El paso 39 garantiza:
  --
  --   - saldo central
  --   - FIFO correcto
  --   - PAG únicos
  --   - un solo movimiento de Caja
  -- ===========================================================

  select *
  into v_ppr

  from public.registrar_pago_cuenta_proveedor(

    p_proveedor_id =>
      p_proveedor_id,

    p_fecha_pago =>
      p_fecha_pago,

    p_importe =>
      round(
        p_importe_dinero,
        2
      ),

    p_medio_pago =>
      trim(
        p_medio_pago
      ),

    p_referencia =>
      p_referencia,

    p_observaciones =>
      p_observaciones

  );


  if v_ppr.pago_proveedor_id is null then
    raise exception
      'No se pudo generar el PPR';
  end if;


  -- ===========================================================
  -- 14. PROCESAR RETENCIONES
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
          v_item ->> 'configuracion_agente_id',
          ''
        )
      ),
      ''
    ) is null then

      raise exception
        'Cada retención debe informar configuracion_agente_id';

    end if;


    begin

      v_configuracion_id :=

        trim(
          v_item
          ->> 'configuracion_agente_id'
        )::uuid;

    exception
      when others then

        raise exception
          'configuracion_agente_id no es un UUID válido';

    end;


    select *
    into v_cfg

    from public.configuraciones_agentes_fiscales

    where id =
      v_configuracion_id;


    if not found then
      raise exception
        'Configuración fiscal inexistente';
    end if;


    if v_cfg.comercio_id <>
      v_comercio_id then

      raise exception
        'La configuración fiscal no pertenece al comercio del pago';

    end if;


    if v_cfg.tipo_agente <>
      'retencion' then

      raise exception
        'La configuración fiscal indicada no corresponde a retenciones';

    end if;


    if not v_cfg.activo then
      raise exception
        'La configuración fiscal indicada está inactiva';
    end if;


    -- ---------------------------------------------------------
    -- FECHA
    -- ---------------------------------------------------------

    v_fecha_retencion :=

      coalesce(

        nullif(
          trim(
            coalesce(
              v_item ->> 'fecha_retencion',
              ''
            )
          ),
          ''
        )::date,

        p_fecha_pago

      );


    if v_fecha_retencion >
      current_date then

      raise exception
        'La fecha de retención no puede ser futura';

    end if;


    if v_fecha_retencion <
      v_cfg.vigencia_desde then

      raise exception
        'La configuración fiscal todavía no estaba vigente en la fecha de retención';

    end if;


    if v_cfg.vigencia_hasta is not null
      and v_fecha_retencion >
        v_cfg.vigencia_hasta then

      raise exception
        'La configuración fiscal ya no estaba vigente en la fecha de retención';

    end if;


    -- ---------------------------------------------------------
    -- PERÍODO
    -- ---------------------------------------------------------

    v_periodo_desde :=

      nullif(
        trim(
          coalesce(
            v_item ->> 'periodo_desde',
            ''
          )
        ),
        ''
      )::date;


    v_periodo_hasta :=

      nullif(
        trim(
          coalesce(
            v_item ->> 'periodo_hasta',
            ''
          )
        ),
        ''
      )::date;


    if v_periodo_desde is not null
      and v_periodo_hasta is not null
      and v_periodo_hasta <
        v_periodo_desde then

      raise exception
        'El período de la retención es inválido';

    end if;


    -- ---------------------------------------------------------
    -- BASE
    -- ---------------------------------------------------------

    v_base_calculo :=
      null;


    if nullif(
      trim(
        coalesce(
          v_item ->> 'base_calculo',
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
                v_item
                ->> 'base_calculo'
              ),
              ',',
              '.'
            )::numeric,

            2

          );

      exception
        when others then

          raise exception
            'La base de cálculo de la retención no es válida';

      end;


      if v_base_calculo < 0 then
        raise exception
          'La base de cálculo no puede ser negativa';
      end if;

    end if;


    -- ---------------------------------------------------------
    -- ALÍCUOTA
    -- ---------------------------------------------------------

    v_alicuota :=
      null;


    if nullif(
      trim(
        coalesce(
          v_item ->> 'alicuota',
          ''
        )
      ),
      ''
    ) is not null then

      begin

        v_alicuota :=

          replace(
            trim(
              v_item
              ->> 'alicuota'
            ),
            ',',
            '.'
          )::numeric(9,6);

      exception
        when others then

          raise exception
            'La alícuota informada no es válida';

      end;

    end if;


    -- Si es una configuración fija, la fuente de verdad
    -- continúa siendo la configuración del comercio.

    if v_cfg.modo_alicuota =
      'fija' then

      if v_cfg.alicuota_fija is null then
        raise exception
          'La configuración fija no posee alícuota configurada';
      end if;


      if v_alicuota is null then

        v_alicuota :=
          v_cfg.alicuota_fija;

      elsif abs(
        v_alicuota
        - v_cfg.alicuota_fija
      ) > 0.000001 then

        raise exception
          'La alícuota informada no coincide con la configuración fiscal vigente';

      end if;

    end if;


    if v_alicuota is not null
      and (
        v_alicuota < 0
        or v_alicuota > 100
      ) then

      raise exception
        'La alícuota debe estar entre 0 y 100';

    end if;


    -- ---------------------------------------------------------
    -- IMPORTE
    -- ---------------------------------------------------------

    v_importe_retencion :=

      round(

        replace(
          trim(
            v_item ->> 'importe'
          ),
          ',',
          '.'
        )::numeric,

        2

      );


    if v_importe_retencion <= 0 then
      raise exception
        'El importe de la retención debe ser mayor a cero';
    end if;


    -- ---------------------------------------------------------
    -- CERTIFICADO
    -- ---------------------------------------------------------

    v_numero_certificado :=

      nullif(
        trim(
          coalesce(
            v_item
            ->> 'numero_certificado',
            ''
          )
        ),
        ''
      );


    if v_cfg.requiere_certificado
      and v_numero_certificado is null then

      raise exception
        'La configuración fiscal exige número de certificado';

    end if;


    -- ---------------------------------------------------------
    -- OBSERVACIONES
    -- ---------------------------------------------------------

    v_observaciones_retencion :=

      nullif(
        trim(
          coalesce(
            v_item ->> 'observaciones',
            ''
          )
        ),
        ''
      );


    -- ---------------------------------------------------------
    -- MONEDA
    -- ---------------------------------------------------------

    v_moneda_retencion :=

      coalesce(

        nullif(
          trim(
            coalesce(
              v_item ->> 'moneda',
              ''
            )
          ),
          ''
        ),

        v_moneda_operacion

      );


    if char_length(
      trim(
        v_moneda_retencion
      )
    ) < 3 then

      raise exception
        'La moneda de la retención no es válida';

    end if;


    -- ---------------------------------------------------------
    -- DATOS OPCIONALES DE CONFIGURACIÓN
    --
    -- Se leen mediante to_jsonb para conservar compatibilidad
    -- aunque sean campos opcionales.
    -- ---------------------------------------------------------

    v_numero_inscripcion_agente :=

      coalesce(

        nullif(
          trim(
            to_jsonb(v_cfg)
            ->> 'numero_inscripcion_agente'
          ),
          ''
        ),

        nullif(
          trim(
            to_jsonb(v_cfg)
            ->> 'numero_inscripcion'
          ),
          ''
        )

      );


    v_sistema_presentacion :=

      nullif(
        trim(
          coalesce(
            to_jsonb(v_cfg)
            ->> 'sistema_presentacion',
            ''
          )
        ),
        ''
      );


    -- =========================================================
    -- 15. CREAR UNA SOLA RETENCIÓN PARA EL PPR
    -- =========================================================

    begin

      insert into public.retenciones_practicadas (

        comercio_id,

        configuracion_agente_id,

        proveedor_id,

        compra_id,

        pago_compra_id,

        pago_proveedor_id,

        fecha_retencion,

        periodo_desde,

        periodo_hasta,

        organismo,

        impuesto,

        jurisdiccion,

        regimen_codigo,

        regimen_descripcion,

        numero_inscripcion_agente,

        sistema_presentacion,

        agente_retencion_cuit,

        agente_retencion_razon_social,

        sujeto_retenido_cuit,

        sujeto_retenido_razon_social,

        numero_certificado,

        certificado_storage_path,

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

        v_comercio_id,

        v_cfg.id,

        p_proveedor_id,

        null,

        null,

        v_ppr.pago_proveedor_id,

        v_fecha_retencion,

        v_periodo_desde,

        v_periodo_hasta,

        v_cfg.organismo,

        v_cfg.impuesto,

        v_cfg.jurisdiccion,

        v_cfg.regimen_codigo,

        v_cfg.regimen_descripcion,

        v_numero_inscripcion_agente,

        v_sistema_presentacion,

        v_agente_cuit,

        v_agente_razon_social,

        v_sujeto_retenido_cuit,

        v_sujeto_retenido_razon_social,

        v_numero_certificado,

        null,

        v_base_calculo,

        v_alicuota,

        v_importe_retencion,

        v_moneda_retencion,

        v_observaciones_retencion,

        'registrada',

        'pendiente',

        auth.uid()

      )

      returning id

      into v_retencion_id;


    exception

      when unique_violation then

        raise exception
          'El certificado de retención "%" ya se encuentra registrado',
          coalesce(
            v_numero_certificado,
            'sin número'
          );

    end;


    v_retenciones_creadas :=
      v_retenciones_creadas + 1;


    -- =========================================================
    -- 16. DISTRIBUIR RETENCIÓN ENTRE COMPRAS
    --
    -- Se hace DESPUÉS de aplicar el dinero del PPR.
    --
    -- Por eso el saldo central ya refleja:
    --
    --   pagos anteriores
    -- + dinero del PPR actual
    -- + retenciones anteriores de esta misma operación
    -- =========================================================

    v_restante_retencion :=
      v_importe_retencion;


    for v_compra in

      select

        c.id,

        c.numero,

        c.fecha_compra,

        c.moneda,

        c.created_at,

        r.saldo_pendiente::numeric(14,2)
          as saldo_pendiente

      from public.compras c

      cross join lateral

        public.__drito_calcular_cancelacion_compra(
          c.id
        ) r

      where c.comercio_id =
        v_comercio_id

        and c.proveedor_id =
          p_proveedor_id

        and c.estado =
          'confirmada'

        and r.saldo_pendiente > 0

      order by

        c.fecha_compra asc,

        c.numero asc,

        c.created_at asc,

        c.id asc

      for update of c

    loop

      exit when
        v_restante_retencion <= 0;


      -- Una misma retención/certificado no debe aplicarse
      -- simultáneamente a compras de monedas diferentes.

      if upper(
        trim(
          v_compra.moneda
        )
      ) <>
      upper(
        trim(
          v_moneda_retencion
        )
      ) then

        raise exception
          'La retención no puede distribuirse entre compras de monedas diferentes';

      end if;


      v_aplicado :=

        least(

          v_restante_retencion,

          v_compra.saldo_pendiente

        );


      insert into
      public.retenciones_practicadas_aplicaciones (

        comercio_id,

        retencion_id,

        compra_id,

        importe_aplicado,

        creado_por

      )
      values (

        v_comercio_id,

        v_retencion_id,

        v_compra.id,

        v_aplicado,

        auth.uid()

      );


      -- El trigger:
      --
      -- retenciones_practicadas_aplicaciones_sincronizar
      --
      -- actualiza automáticamente el resumen de la compra.

      v_aplicaciones_creadas :=
        v_aplicaciones_creadas + 1;


      v_restante_retencion :=

        round(

          v_restante_retencion
          - v_aplicado,

          2

        );

    end loop;


    -- =========================================================
    -- 17. CONTROL DE INTEGRIDAD DE LA RETENCIÓN
    -- =========================================================

    if v_restante_retencion > 0 then

      raise exception
        'No se pudo aplicar completamente la retención. Importe pendiente de distribuir: %',
        v_restante_retencion;

    end if;

  end loop;


  -- ===========================================================
  -- 18. RECALCULAR SALDO FINAL REAL
  -- ===========================================================

  select

    coalesce(
      sum(r.saldo_pendiente),
      0
    )::numeric(14,2)

  into
    v_saldo_final

  from public.compras c

  cross join lateral

    public.__drito_calcular_cancelacion_compra(
      c.id
    ) r

  where c.comercio_id =
    v_comercio_id

    and c.proveedor_id =
      p_proveedor_id

    and c.estado =
      'confirmada';


  -- ===========================================================
  -- 19. CONTROL ECONÓMICO FINAL
  -- ===========================================================

  v_saldo_esperado :=

    greatest(

      round(

        v_saldo_anterior

        - round(
            p_importe_dinero,
            2
          )

        - v_total_retenciones,

        2

      ),

      0

    );


  if abs(
    v_saldo_final
    - v_saldo_esperado
  ) > 0.01 then

    raise exception
      'Inconsistencia al cancelar deuda del proveedor. Saldo esperado: %, saldo calculado: %',
      v_saldo_esperado,
      v_saldo_final;

  end if;


  -- ===========================================================
  -- 20. RESULTADO
  -- ===========================================================

  return query

  select

    v_ppr.pago_proveedor_id::uuid,

    v_ppr.numero_pago_proveedor::bigint,

    v_ppr.comprobante::text,

    v_nombre_proveedor,

    round(
      p_importe_dinero,
      2
    ),

    v_total_retenciones,

    round(
      p_importe_dinero
      + v_total_retenciones,
      2
    ),

    v_ppr.compras_afectadas::integer,

    v_ppr.pagos_generados::integer,

    v_retenciones_creadas,

    v_aplicaciones_creadas,

    v_saldo_anterior,

    v_saldo_final,

    v_ppr.movimiento_caja_id::uuid;

end;
$$;


-- =============================================================
-- 21. SEGURIDAD
-- =============================================================

revoke all
on function
public.registrar_pago_cuenta_proveedor_con_retenciones(
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
public.registrar_pago_cuenta_proveedor_con_retenciones(
  uuid,
  numeric,
  date,
  text,
  text,
  text,
  jsonb
)
to authenticated;


comment on function
public.registrar_pago_cuenta_proveedor_con_retenciones(
  uuid,
  numeric,
  date,
  text,
  text,
  text,
  jsonb
)
is
  'DRITO 12B.2.4.2 - Pago agrupado de proveedor con retenciones practicadas. Caja registra solamente dinero real y las retenciones se distribuyen por aplicaciones entre compras.';


notify pgrst, 'reload schema';


commit;


-- =============================================================
-- FIN 12B.2.4.2
-- =============================================================