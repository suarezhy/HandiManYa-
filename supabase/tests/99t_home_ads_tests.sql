-- Publicidad propia en el inicio (0051). Cuentas propias (…9a9100…).
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000009a91001', 'ads-owner@test.bo', '{"full_name": "Dueño Anuncios"}'),
  ('00000000-0000-0000-0000-000009a91002', 'ads-c@test.bo', '{"full_name": "Cliente Anuncios"}');
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-000009a91001', 'admin');
-- Las pruebas no dependen de anuncios que ya existan en la base.
update public.ad_campaigns set status = 'paused' where status = 'approved';

create temp table t_ad (k text primary key, v text);
grant all on t_ad to authenticated, anon;

-- Sin anuncios aprobados, el inicio no recibe nada.
select test.login('00000000-0000-0000-0000-000009a91002');
select test.eq(public.home_ad(1::smallint) is null, true, 'publicidad: sin anuncios, el espacio no aparece');
-- El cliente no administra anuncios ni ve las tablas.
select test.expect_error($$select public.owner_save_ad(null, 'Ferretería', 'Oferta')$$, 'HMY_FORBIDDEN');
select test.expect_error($$select public.owner_ads()$$, 'HMY_FORBIDDEN');
select test.expect_error($$select * from public.ad_campaigns$$, 'permission denied');
select test.expect_error($$select * from public.ad_daily_stats$$, 'permission denied');
select test.logout();

select test.login(null);
select test.expect_error($$select public.home_ad(1::smallint)$$, 'permission denied');
select test.logout();

-- El Propietario crea, y un borrador no sale.
select test.login('00000000-0000-0000-0000-000009a91001');
insert into t_ad select 'a', public.owner_save_ad(null, 'Ferretería Ejemplo', '10% en herramientas', 'Solo esta semana',
  null, null, 'https://ferreteria.example.bo/oferta', 'Publicidad', null, null, null)::text;
insert into t_ad select 'b', public.owner_save_ad(null, 'Pinturas Ejemplo', 'Pintura lavable', null,
  null, null, null, 'Patrocinado', 1::smallint, null, null)::text;
insert into t_ad select 'otra', public.owner_save_ad(null, 'Solo La Paz', 'Anuncio de otra ciudad', null,
  null, null, null, 'Publicidad', 2::smallint, null, null)::text;
select test.expect_error($$select public.owner_save_ad(null, 'Tienda', 'Enlace raro', null, null, null, 'http://inseguro.bo')$$,
                         'ad_campaigns_link_url_check');
select test.expect_error($$select public.owner_save_ad(null, 'Tienda', 'Enlace raro', null, null, null, 'javascript:alert(1)')$$,
                         'ad_campaigns_link_url_check');
select test.expect_error($$select public.owner_save_ad(null, 'Tienda', 'Fechas al revés', null, null, null, null, 'Publicidad',
                           null, now() + interval '2 days', now() + interval '1 day')$$, 'check');
select test.expect_error($$select public.owner_save_ad(null, 'Tienda', 'Etiqueta', null, null, null, null, 'Oferta')$$,
                         'ad_campaigns_label_check');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a91002');
select test.eq(public.home_ad(1::smallint) is null, true, 'publicidad: un borrador no se muestra');
select test.logout();

-- Aprobado, sale; con la etiqueta y sin el enlace.
select test.login('00000000-0000-0000-0000-000009a91001');
select public.owner_set_ad_status((select v::int from t_ad where k = 'a'), 'approve');
select public.owner_set_ad_status((select v::int from t_ad where k = 'b'), 'approve');
select public.owner_set_ad_status((select v::int from t_ad where k = 'otra'), 'approve');
select test.expect_error(format('select public.owner_set_ad_status(%s, %L)', (select v from t_ad where k = 'a'), 'approve'),
                         'HMY_INVALID_STATE');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a91002');
create temp table t_seen (id int);
grant all on t_seen to authenticated;
insert into t_seen select (public.home_ad(1::smallint) ->> 'id')::int from generate_series(1, 6);
select test.eq((select count(distinct id)::int from t_seen), 2, 'publicidad: rota entre los anunciantes de la ciudad');
select test.eq((select count(*)::int from t_seen where id = (select v::int from t_ad where k = 'a')), 3,
               'publicidad: rotación justa (3 y 3)');
select test.eq((select count(*)::int from t_seen where id = (select v::int from t_ad where k = 'otra')), 0,
               'publicidad: un anuncio de otra ciudad no sale');
select test.eq((select public.home_ad(1::smallint) ?& array['label', 'title', 'advertiser', 'has_link']), true,
               'publicidad: llega con su etiqueta');
select test.eq((select public.home_ad(1::smallint)::text not like '%https://%'), true,
               'publicidad: el enlace no viaja con el anuncio');
select test.eq(public.ad_click((select v::int from t_ad where k = 'a')), 'https://ferreteria.example.bo/oferta',
               'publicidad: el toque devuelve el enlace');
select test.logout();

-- Cuentas sin datos personales: solo totales por anuncio y día.
select test.eq((select string_agg(column_name, ',' order by column_name) from information_schema.columns
                where table_schema = 'public' and table_name = 'ad_daily_stats'),
               'campaign_id,clicks,day,impressions', 'publicidad: las cuentas no guardan quién vio o tocó');

select test.login('00000000-0000-0000-0000-000009a91001');
select test.eq((select (x ->> 'impressions')::int >= 3 and (x ->> 'clicks')::int = 1
                from jsonb_array_elements(public.owner_ads()) x where (x ->> 'id')::int = (select v::int from t_ad where k = 'a')),
               true, 'publicidad: el Propietario ve vistas y toques');
-- Pausar y quitar lo sacan del inicio.
select public.owner_set_ad_status((select v::int from t_ad where k = 'a'), 'pause');
select public.owner_set_ad_status((select v::int from t_ad where k = 'b'), 'remove');
select test.expect_error(format('select public.owner_save_ad(%s, %L, %L)', (select v from t_ad where k = 'b'), 'Pinturas', 'Otra'),
                         'HMY_NOT_FOUND');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a91002');
select test.eq(public.home_ad(1::smallint) is null, true, 'publicidad: pausado o quitado no sale');
select test.expect_error(format('select public.ad_click(%s)', (select v from t_ad where k = 'a')), 'HMY_NOT_FOUND');
select test.logout();

-- Editar uno aprobado lo vuelve a borrador; programado para mañana no sale hoy.
select test.login('00000000-0000-0000-0000-000009a91001');
select public.owner_set_ad_status((select v::int from t_ad where k = 'a'), 'approve');
select public.owner_save_ad((select v::int from t_ad where k = 'a'), 'Ferretería Ejemplo', '20% en herramientas', null,
  null, null, null, 'Publicidad', null, now() + interval '1 day', null);
select test.eq((select x ->> 'status' from jsonb_array_elements(public.owner_ads()) x
                where (x ->> 'id')::int = (select v::int from t_ad where k = 'a')), 'draft',
               'publicidad: un cambio necesita aprobarse otra vez');
select public.owner_set_ad_status((select v::int from t_ad where k = 'a'), 'approve');
select test.logout();

select test.login('00000000-0000-0000-0000-000009a91002');
select test.eq(public.home_ad(1::smallint) is null, true, 'publicidad: programado, sale recién desde su fecha');
select test.logout();

select test.eq((select count(*)::int from public.admin_audit_log where target_table = 'ad_campaigns'
                and target_id = (select v from t_ad where k = 'a')) >= 3, true, 'publicidad: cada cambio queda en la auditoría');
select test.eq(has_function_privilege('authenticated', 'public.hmy_ad_live(public.ad_campaigns)', 'execute'), false,
               'publicidad: las funciones internas no se llaman desde la app');
select test.eq((select public from storage.buckets where id = 'ads'), true, 'publicidad: imágenes públicas');
\o
\echo 'PRUEBAS DE PUBLICIDAD PASARON'
