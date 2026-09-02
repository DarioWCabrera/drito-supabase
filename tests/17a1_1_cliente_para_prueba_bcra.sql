select
  id,
  coalesce(
    nullif(trim(razon_social), ''),
    nullif(trim(nombre), ''),
    'Cliente sin nombre'
  ) as cliente,
  tipo_documento,
  length(
    regexp_replace(
      coalesce(documento, ''),
      '\D',
      '',
      'g'
    )
  ) as cantidad_digitos,
  activo
from public.clientes
where tipo_documento in ('CUIT', 'CUIL')
order by created_at desc
limit 10;