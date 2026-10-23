-- HandiMan ¡Ya! — la foto de perfil solo puede apuntar a la carpeta propia del
-- depósito público `avatars` (así nadie muestra como suya la foto de otra
-- persona). Los documentos de identidad siguen en el depósito privado.
-- NOT VALID: se exige desde ahora sin revisar filas viejas.
alter table public.profiles
  add constraint profiles_avatar_own_folder
  check (avatar_path is null or avatar_path like id::text || '/%') not valid;
alter table public.professional_profiles
  add constraint professional_photo_own_folder
  check (photo_path is null or photo_path like user_id::text || '/%') not valid;
