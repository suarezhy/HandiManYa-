-- HandiMan ¡Ya! — 0052 Grúa solo como servicio propio.
--
-- 0049 puso "Grúa" dos veces: como categoría en "Todos los servicios" y como
-- opción dentro de Mecánica que llevaba a esa categoría. Se quita la opción de
-- Mecánica sin borrarla (queda inactiva, así los pedidos viejos no cambian) y
-- el aviso de seguridad de Mecánica queda más corto. Grúa, su pedido con
-- destino y tipo de vehículo, y el ¡Ya! no cambian.

update public.service_problems
set is_active = false
where name = 'Grúa'
  and category_id = (select id from public.service_categories where slug = 'mecanica')
  and opens_category_id = (select id from public.service_categories where slug = 'grua');

update public.service_categories
set safety_note = 'Si tu vehículo se averió, espera en un lugar seguro y enciende las luces de emergencia. '
                  || 'Nunca entregues tu vehículo sin acordarlo previamente con el profesional.',
    description = case when description = 'Mecánico a domicilio, auxilio y grúa'
                       then 'Mecánico a domicilio y auxilio' else description end
where slug = 'mecanica';
