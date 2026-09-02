-- ============================================================
-- DRITO 12B.5.3
-- ALTA TRANSACCIONAL DE COMPRA + PERCEPCIONES SUFRIDAS
--
-- Archivo:
--   49_paso12b5_3_alta_compra_con_percepciones.sql
--
-- Objetivo:
--   - Reutilizar el circuito real existente de crear_compra(...)
--     para preservar:
--       * validaciones,
--       * numeración COM,
--       * actualización de costos,
--       * ingreso de stock,
--       * movimientos de stock,
--       * permiso compras.crear.
--   - Registrar percepciones sufridas dentro de la misma
--     transacción.
--   - Devolver total comercial, percepciones y total final.
--
-- Regla económica:
--
--   TOTAL COMERCIAL
--   + PERCEPCIONES SUFRIDAS
--   = TOTAL FINAL DE LA COMPRA
--
-- Caja:
--   Este flujo NO registra pagos y NO genera movimientos de Caja.
-- ============================================================

begin;


-- ============================================================
-- 0. DEPENDENCIAS
-- ============================================================

do $$
begin
  if to_regclass(
    'public.compras'
  ) is null then
    raise exception
      'Falta public.compras';
  end if;

  if to_regclass(
    'public.percepciones_sufridas'
  ) is null then
    raise exception
      'Falta public.percepciones_sufridas';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'crear_compra'
      and p.prokind = 'f'
  ) then
    raise exception
      'Falta public.crear_compra';
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
end;
$$;


-- ============================================================
-- 1. HELPER INTERNO
--    REGISTRAR PERCEPCIONES DE UNA COMPRA
-- ============================================================

create or replace function
public.__drito_registrar_percepciones_sufridas_compra(
  p_compra_id uuid,
  p_percepciones jsonb
)
returns table (
  percepciones_creadas integer,
  importe_percepciones numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_compra public.compras%rowtype;
  v_item jsonb;

  v_fecha_percepcion date;
  v_periodo_desde date;
  v_periodo_hasta date;

  v_organismo text;
  v_impuesto text;
  v_jurisdiccion text;

  v_regimen_codigo text;
  v_regimen_descripcion text;
  v_numero_inscripcion_agente text;

  v_base_calculo numeric(14,2);
  v_alicuota numeric(9,4);
  v_importe numeric(14,2);

  v_numero_certificado text;
  v_certificado_storage_path text;
  v_observaciones text;

  v_cantidad integer := 0;
  v_total numeric(18,2) := 0;
begin

  if p_compra_id is null then
    raise exception
      'La compra es obligatoria';
  end if;


  select c.*
  into v_compra
  from public.compras as c
  where c.id = p_compra_id
  for update;


  if not found then
    raise exception
      'Compra no encontrada';
  end if;


  if v_compra.estado <> 'confirmada' then
    raise exception
      'Solo se pueden registrar percepciones sobre compras confirmadas';
  end if;


  if p_percepciones is null then
    p_percepciones := '[]'::jsonb;
  end if;


  if jsonb_typeof(p_percepciones) <> 'array' then
    raise exception
      'Las percepciones deben enviarse como un arreglo JSON';
  end if;


  if jsonb_array_length(p_percepciones) = 0 then
    return query
    select
      0::integer,
      0::numeric(18,2);

    return;
  end if;


  for v_item in
    select elemento.value
    from jsonb_array_elements(p_percepciones)
      as elemento(value)
  loop

    -- ========================================================
    -- ORGANISMO / IMPUESTO
    -- ========================================================

    v_organismo :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'organismo',
            ''
          )
        ),
        ''
      );

    if v_organismo is null then
      raise exception
        'Cada percepción debe indicar el organismo';
    end if;


    v_impuesto :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'impuesto',
            ''
          )
        ),
        ''
      );

    if v_impuesto is null then
      raise exception
        'Cada percepción debe indicar el impuesto';
    end if;


    v_jurisdiccion :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'jurisdiccion',
            ''
          )
        ),
        ''
      );


    v_regimen_codigo :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'regimen_codigo',
            ''
          )
        ),
        ''
      );


    v_regimen_descripcion :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'regimen_descripcion',
            ''
          )
        ),
        ''
      );


    v_numero_inscripcion_agente :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'numero_inscripcion_agente',
            ''
          )
        ),
        ''
      );


    -- ========================================================
    -- FECHA
    -- ========================================================

    begin
      v_fecha_percepcion :=
        coalesce(
          nullif(
            trim(
              coalesce(
                v_item ->> 'fecha_percepcion',
                ''
              )
            ),
            ''
          )::date,
          v_compra.fecha_compra
        );
    exception
      when others then
        raise exception
          'La fecha de una percepción es inválida';
    end;


    if v_fecha_percepcion > current_date then
      raise exception
        'La fecha de una percepción no puede ser futura';
    end if;


    -- ========================================================
    -- PERÍODO
    -- ========================================================

    begin
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
    exception
      when others then
        raise exception
          'El período de una percepción es inválido';
    end;


    if
      v_periodo_desde is not null
      and v_periodo_hasta is not null
      and v_periodo_hasta < v_periodo_desde
    then
      raise exception
        'El período hasta no puede ser anterior al período desde';
    end if;


    -- ========================================================
    -- BASE
    -- ========================================================

    begin
      v_base_calculo :=
        nullif(
          trim(
            coalesce(
              v_item ->> 'base_calculo',
              ''
            )
          ),
          ''
        )::numeric;
    exception
      when others then
        raise exception
          'La base de cálculo de una percepción es inválida';
    end;


    if v_base_calculo is null then
      raise exception
        'Cada percepción debe indicar la base de cálculo';
    end if;


    v_base_calculo :=
      round(
        v_base_calculo,
        2
      );


    if v_base_calculo < 0 then
      raise exception
        'La base de cálculo de una percepción no puede ser negativa';
    end if;


    -- ========================================================
    -- ALÍCUOTA
    -- ========================================================

    begin
      v_alicuota :=
        nullif(
          trim(
            coalesce(
              v_item ->> 'alicuota',
              ''
            )
          ),
          ''
        )::numeric;
    exception
      when others then
        raise exception
          'La alícuota de una percepción es inválida';
    end;


    if v_alicuota is null then
      raise exception
        'Cada percepción debe indicar la alícuota';
    end if;


    v_alicuota :=
      round(
        v_alicuota,
        4
      );


    if
      v_alicuota < 0
      or v_alicuota > 100
    then
      raise exception
        'La alícuota de una percepción debe estar entre 0 y 100';
    end if;


    -- ========================================================
    -- IMPORTE
    -- ========================================================

    begin
      v_importe :=
        nullif(
          trim(
            coalesce(
              v_item ->> 'importe',
              ''
            )
          ),
          ''
        )::numeric;
    exception
      when others then
        raise exception
          'El importe de una percepción es inválido';
    end;


    if v_importe is null then
      raise exception
        'Cada percepción debe indicar el importe';
    end if;


    v_importe :=
      round(
        v_importe,
        2
      );


    if v_importe <= 0 then
      raise exception
        'El importe de una percepción debe ser mayor que cero';
    end if;


    -- ========================================================
    -- EVIDENCIA / OBSERVACIONES
    -- ========================================================

    v_numero_certificado :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'numero_certificado',
            ''
          )
        ),
        ''
      );


    v_certificado_storage_path :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'certificado_storage_path',
            ''
          )
        ),
        ''
      );


    v_observaciones :=
      nullif(
        trim(
          coalesce(
            v_item ->> 'observaciones',
            ''
          )
        ),
        ''
      );


    -- ========================================================
    -- REGISTRAR
    --
    -- El trigger creado en 48 recalcula automáticamente:
    --   total comercial
    --   + percepciones
    --   = total final
    -- ========================================================

    insert into public.percepciones_sufridas (
      comercio_id,
      compra_id,
      proveedor_id,
      fecha_percepcion,
      periodo_desde,
      periodo_hasta,
      organismo,
      impuesto,
      jurisdiccion,
      regimen_codigo,
      regimen_descripcion,
      numero_inscripcion_agente,
      base_calculo,
      alicuota,
      importe,
      moneda,
      numero_certificado,
      certificado_storage_path,
      estado,
      observaciones,
      creado_por
    )
    values (
      v_compra.comercio_id,
      v_compra.id,
      v_compra.proveedor_id,
      v_fecha_percepcion,
      v_periodo_desde,
      v_periodo_hasta,
      v_organismo,
      v_impuesto,
      v_jurisdiccion,
      v_regimen_codigo,
      v_regimen_descripcion,
      v_numero_inscripcion_agente,
      v_base_calculo,
      v_alicuota,
      v_importe,
      v_compra.moneda,
      v_numero_certificado,
      v_certificado_storage_path,
      'registrada',
      v_observaciones,
      auth.uid()
    );


    v_cantidad :=
      v_cantidad + 1;

    v_total :=
      round(
        v_total + v_importe,
        2
      );

  end loop;


  return query
  select
    v_cantidad,
    v_total::numeric(18,2);

end;
$$;


-- ============================================================
-- 2. RPC PÚBLICA
--    CREAR COMPRA + PERCEPCIONES
-- ============================================================

create or replace function
public.crear_compra_con_percepciones(
  p_comercio_id uuid,
  p_proveedor_id uuid,
  p_fecha_compra date,
  p_fecha_vencimiento date,
  p_tipo_comprobante text,
  p_numero_comprobante text,
  p_moneda text,
  p_descuento_general_porcentaje numeric,
  p_observaciones text,
  p_actualizar_costos boolean,
  p_items jsonb,
  p_percepciones jsonb default '[]'::jsonb
)
returns table (
  compra_id uuid,
  numero_compra bigint,
  total_comercial numeric,
  percepciones_sufridas numeric,
  total_compra numeric,
  percepciones_creadas integer,
  movimientos_generados integer,
  cantidad_total_ingresada numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_compra record;
  v_percepciones record;
  v_total record;
begin

  if auth.uid() is null then
    raise exception
      'Usuario no autenticado';
  end if;


  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;


  -- Guardia explícita del nuevo RPC.
  perform public.exigir_permiso_comercio(
    p_comercio_id,
    'compras.crear'
  );


  -- ==========================================================
  -- REUTILIZAR EL CIRCUITO HISTÓRICO REAL
  --
  -- crear_compra(...) conserva:
  --   - validaciones,
  --   - guardia compras.crear,
  --   - numeración,
  --   - items,
  --   - actualización de costos,
  --   - stock,
  --   - movimientos de stock.
  -- ==========================================================

  select *
  into v_compra
  from public.crear_compra(
    p_comercio_id,
    p_proveedor_id,
    p_fecha_compra,
    p_fecha_vencimiento,
    p_tipo_comprobante,
    p_numero_comprobante,
    p_moneda,
    p_descuento_general_porcentaje,
    p_observaciones,
    p_actualizar_costos,
    p_items
  );


  if v_compra.compra_id is null then
    raise exception
      'La compra fue creada sin identificador';
  end if;


  -- ==========================================================
  -- PERCEPCIONES
  -- ==========================================================

  select *
  into v_percepciones
  from public.__drito_registrar_percepciones_sufridas_compra(
    v_compra.compra_id,
    coalesce(
      p_percepciones,
      '[]'::jsonb
    )
  );


  -- ==========================================================
  -- TOTAL FINAL
  -- ==========================================================

  select *
  into v_total
  from public.__drito_calcular_total_compra_con_percepciones(
    v_compra.compra_id
  );


  return query
  select
    v_compra.compra_id::uuid,
    v_compra.numero_compra::bigint,
    v_total.total_comercial::numeric,
    v_total.percepciones_sufridas::numeric,
    v_total.total_final::numeric,
    coalesce(
      v_percepciones.percepciones_creadas,
      0
    )::integer,
    v_compra.movimientos_generados::integer,
    v_compra.cantidad_total_ingresada::numeric;

end;
$$;


-- ============================================================
-- 3. SEGURIDAD
-- ============================================================

revoke all
on function
public.__drito_registrar_percepciones_sufridas_compra(
  uuid,
  jsonb
)
from public, anon, authenticated;


revoke all
on function
public.crear_compra_con_percepciones(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb,
  jsonb
)
from public, anon;


grant execute
on function
public.crear_compra_con_percepciones(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb,
  jsonb
)
to authenticated;


-- ============================================================
-- 4. COMENTARIOS
-- ============================================================

comment on function
public.__drito_registrar_percepciones_sufridas_compra(
  uuid,
  jsonb
)
is
'Helper interno: registra percepciones sufridas de una compra sin hardcodear organismo, régimen, base, alícuota o importe.';


comment on function
public.crear_compra_con_percepciones(
  uuid,
  uuid,
  date,
  date,
  text,
  text,
  text,
  numeric,
  text,
  boolean,
  jsonb,
  jsonb
)
is
'Crea una compra mediante el circuito histórico real y registra percepciones sufridas en la misma transacción. Requiere compras.crear. No genera pagos ni movimientos de Caja.';


commit;
