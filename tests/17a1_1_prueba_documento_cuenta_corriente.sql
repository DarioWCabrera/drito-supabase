begin;

-- =====================================================
-- PREPARACIÓN TEMPORAL
-- =====================================================

update public.clientes
set
  tipo_documento = 'CUIT',
  documento = '20308282202'
where id = 'bfeae0b8-7117-4147-9fbd-9fa06ffe60b9';

-- =====================================================
-- SIMULAR USUARIO AUTENTICADO REAL
-- =====================================================

select set_config(
  'request.jwt.claim.sub',
  '6c189d52-242e-4130-b9a4-623b34576f2b',
  true
);

select set_config(
  'request.jwt.claim.role',
  'authenticated',
  true
);

set local role authenticated;

-- =====================================================
-- PROBAR LA RPC PÚBLICA, NO EL MOTOR INTERNO
-- =====================================================

select
  resultado -> 'cliente' ->> 'tipo_documento'
    as tipo_documento,

  resultado -> 'cliente' ->> 'documento'
    as documento

from (
  select public.obtener_cuenta_corriente_cliente(
    'bfeae0b8-7117-4147-9fbd-9fa06ffe60b9'::uuid,
    null,
    null
  ) as resultado
) as prueba;

rollback;