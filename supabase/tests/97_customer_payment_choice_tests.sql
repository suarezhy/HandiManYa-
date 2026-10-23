-- El cliente dice cómo pagó (efectivo o QR) al marcar "Ya pagué". Corre después de 96.
\set ON_ERROR_STOP 1
\o /dev/null

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000097c1', 'pago-c@test.bo', '{"full_name": "Cliente Pago"}'),
  ('00000000-0000-0000-0000-0000000097a1', 'pago-p@test.bo', '{"full_name": "Profesional Pago"}'),
  ('00000000-0000-0000-0000-0000000097d1', 'pago-x@test.bo', '{"full_name": "Otra Persona"}');
insert into public.professional_profiles (user_id, display_name, primary_category_id, city_id, status)
values ('00000000-0000-0000-0000-0000000097a1', 'Profesional Pago', 1, 1, 'approved');
insert into public.bookings (id, customer_id, professional_id, category_id, city_id, mode, description, status, payment_method, final_amount)
values ('00000000-0000-0000-0000-0000000097b1', '00000000-0000-0000-0000-0000000097c1',
        '00000000-0000-0000-0000-0000000097a1', 1, 1, 'now', 'Arreglar la ducha', 'work_finished', 'cash', 200);

-- Un tercero no puede marcar el pago.
select test.login('00000000-0000-0000-0000-0000000097d1');
select test.expect_error($$select public.acknowledge_payment('00000000-0000-0000-0000-0000000097b1', 'qr')$$, 'HMY_FORBIDDEN');
select test.logout();

-- El profesional no cambia el método elegido por el cliente.
select test.login('00000000-0000-0000-0000-0000000097a1');
select public.acknowledge_payment('00000000-0000-0000-0000-0000000097b1', 'qr');
select test.logout();
select test.eq((select payment_method::text from public.bookings where id = '00000000-0000-0000-0000-0000000097b1'), 'cash',
               'pago: el profesional no cambia el método');

-- El cliente dice que pagó por QR.
select test.login('00000000-0000-0000-0000-0000000097c1');
select public.acknowledge_payment('00000000-0000-0000-0000-0000000097b1', 'qr');
select test.logout();
select test.eq((select payment_method::text from public.bookings where id = '00000000-0000-0000-0000-0000000097b1'), 'qr',
               'pago: el cliente elige QR al marcar que pagó');

-- Una segunda marca no lo cambia.
select test.login('00000000-0000-0000-0000-0000000097c1');
select public.acknowledge_payment('00000000-0000-0000-0000-0000000097b1', 'cash');
select test.logout();
select test.eq((select payment_method::text from public.bookings where id = '00000000-0000-0000-0000-0000000097b1'), 'qr',
               'pago: marcar otra vez no cambia el método');

-- No hay billetera para el cliente ni movimientos por el pago del servicio.
select test.eq((select count(*)::int from public.wallets where professional_id = '00000000-0000-0000-0000-0000000097c1'), 0,
               'pago: el cliente no tiene billetera');

\o
\echo 'PRUEBAS DE PAGO DIRECTO PASARON'
