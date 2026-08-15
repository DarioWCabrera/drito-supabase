-- =============================================================
-- DRITO - PASO 12B.2.3
-- FIX PERMANENTE DE NUMERACIÓN PAG
-- =============================================================
--
-- Problema detectado:
--
-- registrar_pago_compra()
--   usaba pago_compra_contadores
--
-- registrar_pago_cuenta_proveedor()
--   generaba PAG internos usando MAX(numero) + 1
--
-- Esto podía dejar el contador atrasado y provocar:
--
--   duplicate key value violates unique constraint
--   pagos_compras_comercio_id_numero_key
--
-- Solución:
--
--   UN SOLO generador:
--
--   __drito_siguiente_numero_pago_compra()
--
-- utilizado por:
--
--   - pago individual
--   - PAG interno de pago agrupado
--
-- =============================================================

begin;


-- =============================================================
-- 0. PRECONDICIONES
-- =============================================================

do $$
begin

  if to_regclass(
    'public.pagos_compras'
  ) is null then
    raise exception
      'Falta public.pagos_compras';
  end if;


  if to_regclass(
    'public.pago_compra_contadores'
  ) is null then
    raise exception
      'Falta public.pago_compra_contadores';
  end if;


  if to_regprocedure(
    'public.__drito_original_registrar_pago_compra_8ebed35a41(uuid,numeric,date,text,text,text)'
  ) is null then
    raise exception
      'No se encontró la función interna actual de registrar_pago_compra';
  end if;


  if to_regprocedure(
    'public.crear_pago_compra_interno_proveedor(uuid,uuid,bigint,date,numeric,text,text,text,uuid)'
  ) is null then
    raise exception
      'No se encontró crear_pago_compra_interno_proveedor';
  end if;

end;
$$;


-- =============================================================
-- 1. SINCRONIZAR CONTADORES EXISTENTES
-- =============================================================
--
-- Si el contador está atrasado respecto de los PAG reales,
-- lo llevamos al máximo número efectivamente utilizado.
--
-- Nunca retrocedemos un contador que eventualmente estuviera
-- por delante.
-- =============================================================

insert into public.pago_compra_contadores (
  comercio_id,
  ultimo_numero,
  updated_at
)

select

  pc.comercio_id,

  max(pc.numero),

  now()

from public.pagos_compras pc

group by pc.comercio_id

on conflict (comercio_id)

do update set

  ultimo_numero =
    greatest(
      public.pago_compra_contadores.ultimo_numero,
      excluded.ultimo_numero
    ),

  updated_at =
    now();


-- =============================================================
-- 2. GENERADOR CENTRAL Y SEGURO DE NÚMERO PAG
-- =============================================================

create or replace function
public.__drito_siguiente_numero_pago_compra(
  p_comercio_id uuid
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare

  v_maximo_usado bigint;

  v_contador bigint;

  v_siguiente bigint;

begin

  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;


  -- ===========================================================
  -- SERIALIZAR NUMERACIÓN PAG POR COMERCIO
  -- ===========================================================

  perform pg_advisory_xact_lock(

    hashtextextended(
      p_comercio_id::text
        || ':pagos_compras',
      0
    )

  );


  -- ===========================================================
  -- MÁXIMO REAL YA UTILIZADO
  -- ===========================================================

  select
    coalesce(
      max(pc.numero),
      0
    )

  into v_maximo_usado

  from public.pagos_compras pc

  where pc.comercio_id =
    p_comercio_id;


  -- ===========================================================
  -- CONTADOR GUARDADO
  -- ===========================================================

  select
    coalesce(
      pcc.ultimo_numero,
      0
    )

  into v_contador

  from public.pago_compra_contadores pcc

  where pcc.comercio_id =
    p_comercio_id;


  if not found then
    v_contador := 0;
  end if;


  -- ===========================================================
  -- SIGUIENTE NÚMERO
  --
  -- Tomamos siempre el mayor valor conocido.
  -- ===========================================================

  v_siguiente :=

    greatest(
      v_maximo_usado,
      v_contador
    ) + 1;


  -- ===========================================================
  -- ACTUALIZAR CONTADOR
  -- ===========================================================

  insert into public.pago_compra_contadores (

    comercio_id,

    ultimo_numero,

    updated_at

  )
  values (

    p_comercio_id,

    v_siguiente,

    now()

  )

  on conflict (comercio_id)

  do update set

    ultimo_numero =
      excluded.ultimo_numero,

    updated_at =
      now();


  return v_siguiente;

end;
$$;


revoke all
on function
public.__drito_siguiente_numero_pago_compra(uuid)
from public, anon, authenticated;


comment on function
public.__drito_siguiente_numero_pago_compra(uuid)
is
  'DRITO_FUNCION_INTERNA_NO_RPC - Generador único y serializado de números PAG por comercio.';


-- =============================================================
-- 3. CORREGIR PAGO INDIVIDUAL
-- =============================================================
--
-- Conservamos:
--
--   misma función interna
--   misma firma
--   mismo retorno
--   mismo wrapper público
--
-- Solamente reemplazamos la forma de obtener numero_pago.
-- =============================================================

create or replace function
public.__drito_original_registrar_pago_compra_8ebed35a41(

  p_compra_id uuid,

  p_importe numeric,

  p_fecha_pago date,

  p_medio_pago text,

  p_referencia text,

  p_observaciones text

)
returns table (

  pago_id uuid,

  numero_pago bigint,

  total_pagado numeric,

  saldo_pendiente numeric,

  estado_pago text

)
language plpgsql
security definer
set search_path = public
as $$
declare

  v_comercio_id uuid;

  v_proveedor_id uuid;

  v_numero_compra bigint;

  v_estado_compra text;

  v_fecha_compra date;

  v_total_compra numeric(14,2);

  v_total_pagado_actual numeric(14,2);

  v_importe numeric(14,2);

  v_saldo_anterior numeric(14,2);

  v_nuevo_total_pagado numeric(14,2);

  v_nuevo_saldo_pendiente numeric(14,2);

  v_nuevo_estado_pago text;

  v_medio_pago text;

  v_pago_id uuid;

  v_numero_pago bigint;

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

  select

    c.comercio_id,

    c.proveedor_id,

    c.numero,

    c.estado,

    c.fecha_compra,

    c.total,

    c.total_pagado

  into

    v_comercio_id,

    v_proveedor_id,

    v_numero_compra,

    v_estado_compra,

    v_fecha_compra,

    v_total_compra,

    v_total_pagado_actual

  from public.compras c

  where c.id = p_compra_id

  for update;


  if not found then
    raise exception
      'Compra no encontrada';
  end if;


  if not public.pertenece_a_comercio(
    v_comercio_id
  ) then
    raise exception
      'El usuario no pertenece al comercio de la compra';
  end if;


  if v_estado_compra <> 'confirmada' then
    raise exception
      'La compra no admite nuevos pagos';
  end if;


  -- ===========================================================
  -- FECHA
  -- ===========================================================

  if p_fecha_pago is null then
    raise exception
      'La fecha de pago es obligatoria';
  end if;


  if p_fecha_pago > current_date then
    raise exception
      'La fecha de pago no puede ser futura';
  end if;


  if p_fecha_pago < v_fecha_compra then
    raise exception
      'La fecha de pago no puede ser anterior a la compra';
  end if;


  -- ===========================================================
  -- IMPORTE
  -- ===========================================================

  v_importe :=
    round(
      coalesce(
        p_importe,
        0
      ),
      2
    );


  if v_importe <= 0 then
    raise exception
      'El importe debe ser mayor que cero';
  end if;


  v_saldo_anterior :=

    greatest(

      v_total_compra
      - v_total_pagado_actual,

      0

    );


  if v_saldo_anterior <= 0 then
    raise exception
      'La compra ya se encuentra totalmente pagada';
  end if;


  if v_importe > v_saldo_anterior then
    raise exception
      'El importe supera el saldo pendiente. Saldo disponible: %',
      v_saldo_anterior;
  end if;


  -- ===========================================================
  -- MEDIO DE PAGO
  -- ===========================================================

  v_medio_pago :=

    lower(

      trim(

        coalesce(
          p_medio_pago,
          'efectivo'
        )

      )

    );


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

    raise exception
      'El medio de pago es inválido';

  end if;


  -- ===========================================================
  -- NÚMERO PAG
  --
  -- ÚNICA FUENTE DE NUMERACIÓN DESDE ESTE PASO.
  -- ===========================================================

  v_numero_pago :=
    public.__drito_siguiente_numero_pago_compra(
      v_comercio_id
    );


  -- ===========================================================
  -- REGISTRAR PAGO
  -- ===========================================================

  insert into public.pagos_compras (

    comercio_id,

    compra_id,

    proveedor_id,

    numero,

    fecha_pago,

    importe,

    medio_pago,

    referencia,

    observaciones,

    estado,

    creado_por

  )
  values (

    v_comercio_id,

    p_compra_id,

    v_proveedor_id,

    v_numero_pago,

    p_fecha_pago,

    v_importe,

    v_medio_pago,

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
    ),

    'registrado',

    auth.uid()

  )

  returning
    id,
    numero

  into
    v_pago_id,
    v_numero_pago;


  -- ===========================================================
  -- ACTUALIZAR COMPRA
  -- ===========================================================

  v_nuevo_total_pagado :=

    round(

      v_total_pagado_actual
      + v_importe,

      2

    );


  v_nuevo_saldo_pendiente :=

    greatest(

      v_total_compra
      - v_nuevo_total_pagado,

      0

    );


  if v_nuevo_saldo_pendiente = 0 then

    v_nuevo_estado_pago :=
      'pagada';

  else

    v_nuevo_estado_pago :=
      'parcial';

  end if;


  update public.compras c

  set

    total_pagado =
      v_nuevo_total_pagado,

    estado_pago =
      v_nuevo_estado_pago

  where c.id =
    p_compra_id;


  -- ===========================================================
  -- RESULTADO
  -- ===========================================================

  return query

  select

    v_pago_id,

    v_numero_pago,

    v_nuevo_total_pagado,

    v_nuevo_saldo_pendiente,

    v_nuevo_estado_pago;

end;
$$;


revoke all
on function
public.__drito_original_registrar_pago_compra_8ebed35a41(
  uuid,
  numeric,
  date,
  text,
  text,
  text
)
from public, anon, authenticated;


-- =============================================================
-- 4. CORREGIR PAG INTERNO DE PAGO AGRUPADO
-- =============================================================
--
-- Conservamos la firma histórica porque
-- registrar_pago_cuenta_proveedor() ya la utiliza.
--
-- p_numero queda únicamente por compatibilidad.
--
-- El número real se obtiene siempre mediante:
--
--   __drito_siguiente_numero_pago_compra()
--
-- =============================================================

create or replace function
public.crear_pago_compra_interno_proveedor(

  p_comercio_id uuid,

  p_compra_id uuid,

  p_numero bigint,

  p_fecha_pago date,

  p_importe numeric,

  p_medio_pago text,

  p_referencia text,

  p_observaciones text,

  p_pago_proveedor_id uuid

)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare

  v_proveedor_id uuid;

  v_numero_pago bigint;

  v_pago_compra_id uuid;

begin

  if p_comercio_id is null then
    raise exception
      'El comercio es obligatorio';
  end if;


  select c.proveedor_id

  into v_proveedor_id

  from public.compras c

  where c.id =
    p_compra_id

    and c.comercio_id =
      p_comercio_id;


  if not found then
    raise exception
      'La compra no existe o no pertenece al comercio indicado';
  end if;


  if v_proveedor_id is null then
    raise exception
      'La compra no tiene un proveedor asociado';
  end if;


  -- ===========================================================
  -- NÚMERO PAG CENTRALIZADO
  -- ===========================================================

  v_numero_pago :=
    public.__drito_siguiente_numero_pago_compra(
      p_comercio_id
    );


  -- ===========================================================
  -- PAG INTERNO
  -- ===========================================================

  insert into public.pagos_compras (

    comercio_id,

    compra_id,

    proveedor_id,

    numero,

    fecha_pago,

    importe,

    medio_pago,

    referencia,

    observaciones,

    estado,

    pago_proveedor_id,

    creado_por

  )
  values (

    p_comercio_id,

    p_compra_id,

    v_proveedor_id,

    v_numero_pago,

    p_fecha_pago,

    round(
      p_importe,
      2
    ),

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
    ),

    'registrado',

    p_pago_proveedor_id,

    auth.uid()

  )

  returning id
  into v_pago_compra_id;


  return v_pago_compra_id;

end;
$$;


revoke all
on function
public.crear_pago_compra_interno_proveedor(
  uuid,
  uuid,
  bigint,
  date,
  numeric,
  text,
  text,
  text,
  uuid
)
from public, anon, authenticated;


comment on function
public.crear_pago_compra_interno_proveedor(
  uuid,
  uuid,
  bigint,
  date,
  numeric,
  text,
  text,
  text,
  uuid
)
is
  'DRITO_FUNCION_INTERNA_NO_RPC - Crea PAG interno de un pago agrupado utilizando numeración PAG centralizada.';


notify pgrst, 'reload schema';


commit;


-- =============================================================
-- FIN FIX NUMERACIÓN PAG
-- =============================================================