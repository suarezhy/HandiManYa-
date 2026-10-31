-- Deshace 0052: vuelve la opción "Grúa" dentro de Mecánica y el aviso anterior.
begin;
update public.service_problems
set is_active = true
where name = 'Grúa'
  and category_id = (select id from public.service_categories where slug = 'mecanica')
  and opens_category_id = (select id from public.service_categories where slug = 'grua');
update public.service_categories
set safety_note = 'Si tu auto se quedó en la calle o la carretera, espera en un lugar seguro con las luces de emergencia '
                  || 'encendidas y comparte tu solicitud con alguien de confianza. El mecánico no debe llevarse tu '
                  || 'vehículo sin que lo acuerden por el chat.',
    description = case when description = 'Mecánico a domicilio y auxilio'
                       then 'Mecánico a domicilio, auxilio y grúa' else description end
where slug = 'mecanica';
commit;
