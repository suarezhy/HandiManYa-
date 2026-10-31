-- Foto de perfil: solo en la carpeta propia. Corre después de 97.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000098c1', 'foto-c@test.bo', '{"full_name": "Cliente Foto"}'),
  ('00000000-0000-0000-0000-0000000098a1', 'foto-p@test.bo', '{"full_name": "Profesional Foto"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id)
values ('00000000-0000-0000-0000-0000000098a1', 'Profesional Foto', 1, 1);

select test.login('00000000-0000-0000-0000-0000000098c1');
update public.profiles set avatar_path = '00000000-0000-0000-0000-0000000098c1/perfil-1.jpg'
 where id = '00000000-0000-0000-0000-0000000098c1';
select test.expect_error($$update public.profiles set avatar_path = '00000000-0000-0000-0000-0000000098a1/perfil-1.jpg'
                           where id = '00000000-0000-0000-0000-0000000098c1'$$, 'profiles_avatar_own_folder');
-- No puede cambiar la foto de otra persona (RLS: no ve su fila).
update public.profiles set avatar_path = null where id = '00000000-0000-0000-0000-0000000098a1';
select test.logout();
select test.eq((select avatar_path from public.profiles where id = '00000000-0000-0000-0000-0000000098c1'),
               '00000000-0000-0000-0000-0000000098c1/perfil-1.jpg', 'foto: el cliente guarda su foto');

select test.login('00000000-0000-0000-0000-0000000098a1');
select test.expect_error($$update public.professional_profiles set photo_path = 'otra-carpeta/x.jpg'
                           where user_id = '00000000-0000-0000-0000-0000000098a1'$$, 'professional_photo_own_folder');
update public.professional_profiles set photo_path = '00000000-0000-0000-0000-0000000098a1/perfil-2.jpg'
 where user_id = '00000000-0000-0000-0000-0000000098a1';
update public.profiles set avatar_path = null where id = '00000000-0000-0000-0000-0000000098a1';
select test.logout();
select test.eq((select photo_path from public.professional_profiles where user_id = '00000000-0000-0000-0000-0000000098a1'),
               '00000000-0000-0000-0000-0000000098a1/perfil-2.jpg', 'foto: el profesional guarda su foto pública');

\o
\echo 'PRUEBAS DE FOTO DE PERFIL PASARON'
