-- HandiMan ¡Ya! — 0050 catálogo: Mariachis en Eventos, junto a Banda.
insert into public.service_problems (category_id, name, icon, is_other, sort_order)
select id, 'Mariachis', 'music_note', false, 68 from public.service_categories where slug = 'eventos'
on conflict (category_id, name) do nothing;

update public.service_categories set description = 'Meseros, churrasqueros, bandas, mariachis, decoración y ayuda para fiestas'
where slug = 'eventos' and description = 'Meseros, churrasqueros, bandas, decoración y ayuda para fiestas';
