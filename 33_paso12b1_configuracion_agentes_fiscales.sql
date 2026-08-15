-- ============================================================
-- DRITO
-- PASO 12B.1.1
-- Configuración de agentes fiscales por comercio
--
-- Objetivo:
-- Definir de forma explícita cuándo un comercio está configurado
-- como agente de RETENCIÓN o PERCEPCIÓN.
--
-- REGLAS IMPORTANTES:
-- - Drito NO asume que un comercio es agente.
-- - La configuración siempre pertenece a un comercio_id.
-- - No se hardcodean alícuotas.
-- - Una alícuota puede provenir de:
--      * padrón
--      * configuración fija
--      * fuente externa
-- - Esta migración NO configura ningún comercio como agente.
-- - Esta migración NO genera retenciones/percepciones.
-- - Esta migración NO toca Caja.
-- - Esta migración NO modifica compras, ventas ni cuentas corrientes.
--
-- Seguridad:
-- La tabla queda cerrada al acceso directo de anon/authenticated.
-- En pasos posteriores se expondrán RPC controladas.
-- ============================================================


-- ============================================================
-- 1. TABLA PRINCIPAL
-- ============================================================

create table if not exists public.configuraciones_agentes_fiscales (
  id uuid primary key default gen_random_uuid(),

  comercio_id uuid not null
    references public.comercios(id)
    on delete cascade,

  -- Organismo que administra el régimen.
  -- Ejemplos futuros: ARBA, ARCA, AGIP, etc.
  organismo text not null,

  -- Impuesto involucrado.
  -- Ejemplos: IIBB, GANANCIAS, IVA, etc.
  impuesto text not null,

  -- Jurisdicción aplicable.
  -- Debe mantenerse genérico porque Drito es multiempresa.
  jurisdiccion text not null,

  -- Indica de qué forma actúa el comercio.
  tipo_agente text not null
    check (
      tipo_agente in (
        'retencion',
        'percepcion'
      )
    ),

  -- Identificación del régimen fiscal.
  regimen_codigo text,

  regimen_descripcion text not null,

  -- Número de inscripción del comercio como agente,
  -- cuando corresponda.
  numero_inscripcion_agente text,

  -- Vigencia de la configuración.
  vigencia_desde date not null,

  vigencia_hasta date,

  -- Fuente utilizada para obtener la alícuota.
  modo_alicuota text not null
    check (
      modo_alicuota in (
        'padron',
        'fija',
        'externa'
      )
    ),

  -- Solo debe utilizarse cuando modo_alicuota = 'fija'.
  alicuota_fija numeric(7,4),

  -- No se supone por defecto que siempre exista certificado.
  requiere_certificado boolean not null default false,

  -- Sistema mediante el cual posteriormente se informa/presenta
  -- el régimen. Se mantiene texto abierto para no atar Drito
  -- a ARBA/SIRE exclusivamente.
  sistema_presentacion text,

  activo boolean not null default true,

  observaciones text,

  -- Auditoría
  creado_por uuid
    references auth.users(id)
    on delete set null,

  actualizado_por uuid
    references auth.users(id)
    on delete set null,

  created_at timestamptz not null default now(),

  updated_at timestamptz not null default now(),


  -- ==========================================================
  -- VALIDACIONES
  -- ==========================================================

  constraint configuraciones_agentes_fiscales_organismo_chk
    check (length(btrim(organismo)) > 0),

  constraint configuraciones_agentes_fiscales_impuesto_chk
    check (length(btrim(impuesto)) > 0),

  constraint configuraciones_agentes_fiscales_jurisdiccion_chk
    check (length(btrim(jurisdiccion)) > 0),

  constraint configuraciones_agentes_fiscales_regimen_desc_chk
    check (length(btrim(regimen_descripcion)) > 0),

  constraint configuraciones_agentes_fiscales_vigencia_chk
    check (
      vigencia_hasta is null
      or vigencia_hasta >= vigencia_desde
    ),

  constraint configuraciones_agentes_fiscales_alicuota_rango_chk
    check (
      alicuota_fija is null
      or (
        alicuota_fija >= 0
        and alicuota_fija <= 100
      )
    ),

  constraint configuraciones_agentes_fiscales_modo_alicuota_chk
    check (
      (
        modo_alicuota = 'fija'
        and alicuota_fija is not null
      )
      or
      (
        modo_alicuota in ('padron', 'externa')
        and alicuota_fija is null
      )
    )
);


-- ============================================================
-- 2. ÍNDICES
-- ============================================================

create index if not exists
  idx_config_agentes_fiscales_comercio
on public.configuraciones_agentes_fiscales (
  comercio_id
);


create index if not exists
  idx_config_agentes_fiscales_comercio_activo
on public.configuraciones_agentes_fiscales (
  comercio_id,
  activo
);


create index if not exists
  idx_config_agentes_fiscales_tipo
on public.configuraciones_agentes_fiscales (
  comercio_id,
  tipo_agente
);


create index if not exists
  idx_config_agentes_fiscales_vigencia
on public.configuraciones_agentes_fiscales (
  comercio_id,
  vigencia_desde,
  vigencia_hasta
);


-- ============================================================
-- 3. EVITAR DUPLICADOS ACTIVOS
--
-- Un comercio no puede tener dos configuraciones activas
-- para la misma combinación:
--
-- comercio
-- + organismo
-- + impuesto
-- + jurisdicción
-- + tipo de agente
-- + régimen
--
-- Se utilizan expresiones normalizadas para evitar duplicados
-- solo por diferencias de mayúsculas o espacios.
-- ============================================================

create unique index if not exists
  uq_config_agentes_fiscales_activa
on public.configuraciones_agentes_fiscales (
  comercio_id,
  lower(btrim(organismo)),
  lower(btrim(impuesto)),
  lower(btrim(jurisdiccion)),
  tipo_agente,
  coalesce(lower(btrim(regimen_codigo)), '')
)
where activo = true;


-- ============================================================
-- 4. AUDITORÍA AUTOMÁTICA
-- ============================================================

create or replace function
  public.__drito_config_agentes_fiscales_auditoria()
returns trigger
language plpgsql
set search_path = public, auth
as $$
begin

  if tg_op = 'INSERT' then

    new.created_at :=
      coalesce(new.created_at, now());

    new.updated_at := now();

    if new.creado_por is null then
      new.creado_por := auth.uid();
    end if;

    if new.actualizado_por is null then
      new.actualizado_por := auth.uid();
    end if;

  elsif tg_op = 'UPDATE' then

    new.updated_at := now();

    if auth.uid() is not null then
      new.actualizado_por := auth.uid();
    end if;

  end if;

  return new;

end;
$$;


revoke all
on function public.__drito_config_agentes_fiscales_auditoria()
from public;


drop trigger if exists
  trg_config_agentes_fiscales_auditoria
on public.configuraciones_agentes_fiscales;


create trigger
  trg_config_agentes_fiscales_auditoria
before insert or update
on public.configuraciones_agentes_fiscales
for each row
execute function
  public.__drito_config_agentes_fiscales_auditoria();


-- ============================================================
-- 5. SEGURIDAD
--
-- La tabla queda deliberadamente cerrada.
--
-- NO damos SELECT/INSERT/UPDATE/DELETE directo al frontend.
-- La lectura y modificación se harán posteriormente mediante
-- RPCs controladas por permisos.
--
-- Para configuración fiscal utilizaremos el permiso existente:
--
-- facturacion.configurar
--
-- Esto evita abrir una tabla fiscal sensible prematuramente.
-- ============================================================

alter table
  public.configuraciones_agentes_fiscales
enable row level security;


revoke all
on table public.configuraciones_agentes_fiscales
from anon;


revoke all
on table public.configuraciones_agentes_fiscales
from authenticated;


-- ============================================================
-- FIN PASO 12B.1.1
-- ============================================================