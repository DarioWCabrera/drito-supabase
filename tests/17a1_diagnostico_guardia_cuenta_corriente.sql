select
  funcion_nombre,
  argumentos_identidad,
  nombre_interno,
  permiso_codigo
from public.rpc_guardias_instaladas
where funcion_nombre = 'obtener_cuenta_corriente_cliente';