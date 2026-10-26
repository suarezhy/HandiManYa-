-- Catálogo: Mariachis en Eventos (0050).
\set ON_ERROR_STOP 1
\o /dev/null
select test.eq((select array_agg(p.name order by p.sort_order) from public.service_problems p
                join public.service_categories c on c.id = p.category_id
                where c.slug = 'eventos' and p.name in ('Churrasquero (parrillero)', 'Banda', 'Mariachis', 'Atención de invitados'))::text,
               '{"Churrasquero (parrillero)",Banda,Mariachis,"Atención de invitados"}', 'eventos: Mariachis va junto a Banda');
select test.eq((select description from public.service_categories where slug = 'eventos') like '%mariachis%', true,
               'eventos: la búsqueda encuentra mariachis');
\o
\echo 'PRUEBAS DE MARIACHIS PASARON'
