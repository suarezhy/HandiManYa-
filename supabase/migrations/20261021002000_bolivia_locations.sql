-- Toda Bolivia: los 339 municipios de los 9 departamentos.
--
-- Fuente: límites oficiales de GeoBolivia (2015, dominio público) vía
-- geoBoundaries; ver supabase/data/bolivia_municipios.csv y
-- supabase/scripts/build_bolivia_locations.py. La coordenada de cada municipio
-- es un punto interior aproximado (en las capitales, la ciudad); solo sirve de
-- referencia, porque el emparejamiento usa el GPS del pedido y la base del
-- profesional.
--
-- Cambios:
--   1. cities.province y los municipios que faltaban, todos activos.
--   2. ¡Ya! con GPS empareja por distancia aunque el profesional esté
--      registrado en otro municipio (por ejemplo, Santa Cruz de la Sierra y
--      Warnes). Sin GPS sigue pidiendo el mismo municipio y la zona.
--   3. La búsqueda por municipio incluye a quien atiende ese lugar dentro de
--      su radio de servicio.

alter table public.cities add column if not exists province text;

insert into public.cities (department_id, province, name, slug, latitude, longitude, sort_order, is_active)
select v.department_id, v.province, v.name, v.slug, v.latitude, v.longitude, v.sort_order, true
from (values
  (7, 'Andrés Ibáñez', 'Santa Cruz de la Sierra', 'santa-cruz', -17.783300, -63.182100, 1),
  (3, 'Cercado', 'Cochabamba', 'cochabamba', -17.389500, -66.156800, 2),
  (2, 'Murillo', 'La Paz', 'la-paz', -16.500000, -68.150000, 3),
  (2, 'Murillo', 'El Alto', 'el-alto', -16.504700, -68.163300, 4),
  (1, 'Oropeza', 'Sucre', 'sucre', -19.033300, -65.262700, 5),
  (4, 'Cercado', 'Oruro', 'oruro', -17.966700, -67.116700, 6),
  (5, 'Tomás Frías', 'Potosí', 'potosi', -19.583600, -65.753100, 7),
  (6, 'Cercado', 'Tarija', 'tarija', -21.535500, -64.729600, 8),
  (8, 'Cercado', 'Trinidad', 'trinidad', -14.833300, -64.900000, 9),
  (9, 'Nicolás Suárez', 'Cobija', 'cobija', -11.026700, -68.769200, 10),
  (1, 'Tomina', 'Alcalá', 'alcala-ch', -19.432190, -64.373839, 100),
  (1, 'Azurduy', 'Azurduy', 'azurduy-ch', -20.181296, -64.432895, 100),
  (1, 'Nor Cinti', 'Camargo', 'camargo-ch', -20.602502, -65.156026, 100),
  (1, 'Sur Cinti', 'Culpina', 'culpina-ch', -20.869752, -64.572018, 100),
  (1, 'Tomina', 'El Villar', 'el-villar-ch', -19.691224, -64.275271, 100),
  (1, 'Hernando Siles', 'Huacareta', 'huacareta-ch', -20.594607, -64.009868, 100),
  (1, 'Luis Calvo', 'Huacaya', 'huacaya-ch', -20.716583, -63.594764, 100),
  (1, 'Nor Cinti', 'Incahuasi', 'incahuasi-ch', -20.590655, -64.572038, 100),
  (1, 'Sur Cinti', 'Las Carreras', 'las-carreras-ch', -21.295630, -65.320215, 100),
  (1, 'Luis Calvo', 'Macharetí', 'machareti-ch', -20.725427, -62.879044, 100),
  (1, 'Zudáñez', 'Mojocoya', 'mojocoya-ch', -18.780279, -64.644156, 100),
  (1, 'Hernando Siles', 'Monteagudo', 'monteagudo-ch', -20.014684, -64.075034, 100),
  (1, 'Tomina', 'Padilla', 'padilla-ch', -19.374809, -64.160813, 100),
  (1, 'Oropeza', 'Poroma', 'poroma-ch', -18.621868, -65.385122, 100),
  (1, 'Zudáñez', 'Presto', 'presto-ch', -18.755547, -64.893032, 100),
  (1, 'Nor Cinti', 'San Lucas', 'san-lucas-ch', -20.160668, -64.899379, 100),
  (1, 'Tomina', 'Sopachui', 'sopachui-ch', -19.462276, -64.535219, 100),
  (1, 'Yamparáez', 'Tarabuco', 'tarabuco-ch', -19.121524, -64.909836, 100),
  (1, 'Azurduy', 'Tarvita', 'tarvita-ch', -19.772184, -64.561781, 100),
  (1, 'Tomina', 'Tomina', 'tomina-ch', -19.160817, -64.494980, 100),
  (1, 'Sur Cinti', 'Villa Abecia', 'villa-abecia-ch', -20.986257, -65.287673, 100),
  (1, 'Nor Cinti', 'Villa Charcas', 'villa-charcas-ch', -20.572139, -64.820702, 100),
  (1, 'Zudáñez', 'Villa Ricardo Mugia - Icla', 'villa-ricardo-mugia-icla-ch', -19.465352, -64.746360, 100),
  (1, 'Belisario Boeto', 'Villa Serrano', 'villa-serrano-ch', -18.951898, -64.300020, 100),
  (1, 'Luis Calvo', 'Villa Vaca Guzmán', 'villa-vaca-guzman-ch', -19.892896, -63.802379, 100),
  (1, 'Yamparáez', 'Yamparáez', 'yamparaez-ch', -19.243597, -65.069976, 100),
  (1, 'Oropeza', 'Yotala', 'yotala-ch', -19.225029, -65.264817, 100),
  (1, 'Zudáñez', 'Zudañez', 'zudanez-ch', -19.127933, -64.688076, 100),
  (2, 'Omasuyos', 'Achacachi', 'achacachi-lp', -16.016854, -68.663448, 100),
  (2, 'Murillo', 'Achocalla', 'achocalla-lp', -16.662276, -68.125342, 100),
  (2, 'Caranavi', 'Alto Beni', 'alto-beni-lp', -15.605633, -67.389506, 100),
  (2, 'Franz Tamayo', 'Apolo', 'apolo-lp', -14.658589, -68.232658, 100),
  (2, 'Muñecas', 'Aucapata', 'aucapata-lp', -15.438146, -68.699535, 100),
  (2, 'Muñecas', 'Ayata', 'ayata-lp', -15.319932, -68.710950, 100),
  (2, 'Aroma', 'Ayo Ayo', 'ayo-ayo-lp', -17.076745, -68.019623, 100),
  (2, 'Los Andes', 'Batallas', 'batallas-lp', -16.164294, -68.433560, 100),
  (2, 'Loayza', 'Cairoma', 'cairoma-lp', -16.845749, -67.576914, 100),
  (2, 'Inquisivi', 'Cajuata', 'cajuata-lp', -16.637465, -67.247462, 100),
  (2, 'Pacajes', 'Calacoto', 'calacoto-lp', -17.562356, -68.772333, 100),
  (2, 'Aroma', 'Calamarca', 'calamarca-lp', -16.890453, -68.112451, 100),
  (2, 'Pacajes', 'Caquiaviri', 'caquiaviri-lp', -17.085226, -68.817993, 100),
  (2, 'Caranavi', 'Caranavi', 'caranavi-lp', -15.844898, -67.487870, 100),
  (2, 'General José Manuel Pando', 'Catacora', 'catacora-lp', -17.252672, -69.480522, 100),
  (2, 'Gualberto Villarroe', 'Chacarilla', 'chacarilla-lp', -17.548594, -68.169975, 100),
  (2, 'Pacajes', 'Charaña', 'charana-lp', -17.659187, -69.157044, 100),
  (2, 'Bautista Saavedra', 'Charazani', 'charazani-lp', -15.096526, -68.773756, 100),
  (2, 'Omasuyos', 'Chua Cocani', 'chua-cocani-lp', -16.158343, -68.751662, 100),
  (2, 'Sud Yungas', 'Chulumani', 'chulumani-lp', -16.389181, -67.537682, 100),
  (2, 'Muñecas', 'Chuma', 'chuma-lp', -15.593236, -68.865694, 100),
  (2, 'Aroma', 'Collana', 'collana-lp', -16.903532, -68.300945, 100),
  (2, 'Aroma', 'Colquencha', 'colquencha-lp', -16.992021, -68.256906, 100),
  (2, 'Inquisivi', 'Colquiri', 'colquiri-lp', -17.421259, -66.994239, 100),
  (2, 'Pacajes', 'Comanche', 'comanche-lp', -16.950535, -68.450130, 100),
  (2, 'Larecaja', 'Combaya', 'combaya-lp', -15.815978, -68.753210, 100),
  (2, 'Manco Kapac', 'Copacabana', 'copacabana-lp', -16.153216, -69.049364, 100),
  (2, 'Nor Yungas', 'Coripata', 'coripata-lp', -16.209017, -67.567369, 100),
  (2, 'Pacajes', 'Corocoro', 'corocoro-lp', -17.173154, -68.432275, 100),
  (2, 'Nor Yungas', 'Coroico', 'coroico-lp', -16.162471, -67.772603, 100),
  (2, 'Bautista Saavedra', 'Curva', 'curva-lp', -14.985064, -68.965397, 100),
  (2, 'Ingavi', 'Desaguadero', 'desaguadero-lp', -16.614162, -68.978181, 100),
  (2, 'Camacho', 'Escoma', 'escoma-lp', -15.638118, -69.149306, 100),
  (2, 'Larecaja', 'Guanay', 'guanay-lp', -15.736207, -68.042262, 100),
  (2, 'Omasuyos', 'Huarina', 'huarina-lp', -16.164454, -68.593303, 100),
  (2, 'Omasuyos', 'Huatajata', 'huatajata-lp', -16.197979, -68.690703, 100),
  (2, 'Camacho', 'Humanata', 'humanata-lp', -15.414502, -69.170837, 100),
  (2, 'Inquisivi', 'Ichoca', 'ichoca-lp', -17.184854, -67.193482, 100),
  (2, 'Inquisivi', 'Inquisivi', 'inquisivi-lp', -16.683260, -66.978007, 100),
  (2, 'Sud Yungas', 'Irupana', 'irupana-lp', -16.511080, -67.510166, 100),
  (2, 'Abel Iturralde', 'Ixiamas', 'ixiamas-lp', -13.090133, -68.018731, 100),
  (2, 'Ingavi', 'Jesús de Machaka', 'jesus-de-machaka-lp', -16.760654, -68.739957, 100),
  (2, 'Sud Yungas', 'La Asunta', 'la-asunta-lp', -16.108065, -67.155870, 100),
  (2, 'Ingavi', 'La (Marka) San Andrés de Mach', 'la-marka-san-andres-de-mach-lp', -16.899717, -69.043485, 100),
  (2, 'Los Andes', 'Laja', 'laja-lp', -16.588496, -68.459568, 100),
  (2, 'Loayza', 'Luribay', 'luribay-lp', -17.093724, -67.634788, 100),
  (2, 'Loayza', 'Malla', 'malla-lp', -17.011409, -67.426805, 100),
  (2, 'Larecaja', 'Mapiri', 'mapiri-lp', -15.380016, -68.257718, 100),
  (2, 'Murillo', 'Mecapaca', 'mecapaca-lp', -16.718619, -67.978604, 100),
  (2, 'Camacho', 'Mocomoco', 'mocomoco-lp', -15.449980, -69.035785, 100),
  (2, 'Pacajes', 'Nazacara de Pacajes', 'nazacara-de-pacajes-lp', -16.926406, -68.757704, 100),
  (2, 'Murillo', 'Palca', 'palca-lp', -16.666290, -67.826193, 100),
  (2, 'Sud Yungas', 'Palos Blancos', 'palos-blancos-lp', -15.417734, -67.231598, 100),
  (2, 'Gualberto Villarroe', 'Papel Pampa', 'papel-pampa-lp', -17.697221, -67.709609, 100),
  (2, 'Aroma', 'Patacamaya', 'patacamaya-lp', -17.216468, -67.913196, 100),
  (2, 'Franz Tamayo', 'Pelechuco', 'pelechuco-lp', -14.800724, -69.090747, 100),
  (2, 'Los Andes', 'Pucarani', 'pucarani-lp', -16.360494, -68.416187, 100),
  (2, 'Camacho', 'Puerto Acosta', 'puerto-acosta-lp', -15.554909, -69.215611, 100),
  (2, 'Camacho', 'Puerto Mayor de Carabuco', 'puerto-mayor-de-carabuco-lp', -15.712131, -69.001082, 100),
  (2, 'Ingavi', 'Puerto Mayor de Guaqui', 'puerto-mayor-de-guaqui-lp', -16.606683, -68.821020, 100),
  (2, 'Los Andes', 'Puerto Pérez', 'puerto-perez-lp', -16.327383, -68.631063, 100),
  (2, 'Larecaja', 'Quiabaya', 'quiabaya-lp', -15.602374, -68.714259, 100),
  (2, 'Inquisivi', 'Quime', 'quime-lp', -16.848910, -67.340920, 100),
  (2, 'Abel Iturralde', 'San Buenaventura', 'san-buenaventura-lp', -14.259106, -67.744953, 100),
  (2, 'Gualberto Villarroel', 'San Pedro de Curahuara', 'san-pedro-de-curahuara-lp', -17.633455, -67.966651, 100),
  (2, 'Manco Kapac', 'San Pedro de Tiquina', 'san-pedro-de-tiquina-lp', -16.231196, -68.876762, 100),
  (2, 'Pacajes', 'Santiago de Callapa', 'santiago-de-callapa-lp', -17.400881, -68.347122, 100),
  (2, 'Omasuyos', 'Santiago de Huata', 'santiago-de-huata-lp', -16.086228, -68.834937, 100),
  (2, 'General José Manuel Pando', 'Santiago de Machaca', 'santiago-de-machaca-lp', -17.189381, -69.270513, 100),
  (2, 'Loayza', 'Sapahaqui', 'sapahaqui-lp', -16.953487, -67.836019, 100),
  (2, 'Aroma', 'Sicasica', 'sicasica-lp', -17.374483, -67.619092, 100),
  (2, 'Larecaja', 'Sorata', 'sorata-lp', -15.719276, -68.494055, 100),
  (2, 'Larecaja', 'Tacacoma', 'tacacoma-lp', -15.392448, -68.523026, 100),
  (2, 'Ingavi', 'Taraco', 'taraco-lp', -16.462507, -68.853747, 100),
  (2, 'Larecaja', 'Teoponte', 'teoponte-lp', -15.407423, -67.687240, 100),
  (2, 'Ingavi', 'Tiahuanacu', 'tiahuanacu-lp', -16.558759, -68.695779, 100),
  (2, 'Larecaja', 'Tipuani', 'tipuani-lp', -15.584458, -68.056001, 100),
  (2, 'Manco Kapac', 'Tito Yupanqui', 'tito-yupanqui-lp', -16.179894, -68.959487, 100),
  (2, 'Aroma', 'Umala', 'umala-lp', -17.403991, -67.997163, 100),
  (2, 'Ingavi', 'Viacha', 'viacha-lp', -16.733856, -68.310657, 100),
  (2, 'Omasuyos', 'Villa Ancoraimes', 'villa-ancoraimes-lp', -15.854303, -68.868753, 100),
  (2, 'Inquisivi', 'Villa Libertad Licoma', 'villa-libertad-licoma-lp', -16.811906, -67.203177, 100),
  (2, 'Pacajes', 'Waldo Ballivian', 'waldo-ballivian-lp', -17.115117, -68.219344, 100),
  (2, 'Loayza', 'Yaco', 'yaco-lp', -17.240146, -67.398726, 100),
  (2, 'Sud Yungas', 'Yanacachi', 'yanacachi-lp', -16.425728, -67.789458, 100),
  (3, 'Campero', 'Aiquile', 'aiquile-cb', -18.323321, -65.103804, 100),
  (3, 'Mizque', 'Alalay', 'alalay-cb', -17.773233, -65.630069, 100),
  (3, 'Esteban Arze', 'Anzaldo', 'anzaldo-cb', -17.843684, -65.916674, 100),
  (3, 'Arani', 'Arani', 'arani-cb', -17.592691, -65.726568, 100),
  (3, 'Esteban Arze', 'Arbieto', 'arbieto-cb', -17.558288, -66.065014, 100),
  (3, 'Arque', 'Arque', 'arque-cb', -17.825697, -66.416820, 100),
  (3, 'Ayopaya', 'Ayopaya', 'ayopaya-cb', -17.143947, -66.805246, 100),
  (3, 'Bolivar', 'Bolivar', 'bolivar-cb', -18.015598, -66.644538, 100),
  (3, 'Capinota', 'Capinota', 'capinota-cb', -17.777558, -66.226815, 100),
  (3, 'Carrasco', 'Chimoré', 'chimore-cb', -16.558692, -64.911420, 100),
  (3, 'Germán Jordán', 'Cliza', 'cliza-cb', -17.581921, -65.936537, 100),
  (3, 'Ayopaya', 'Cocapata', 'cocapata-cb', -16.489125, -66.552224, 100),
  (3, 'Quillacollo', 'Colcapirhua', 'colcapirhua-cb', -17.390441, -66.232538, 100),
  (3, 'Chapare', 'Colomi', 'colomi-cb', -17.233290, -65.920529, 100),
  (3, 'Carrasco', 'Entre Ríos', 'entre-rios-cb', -17.312176, -64.546434, 100),
  (3, 'Mizque', 'Mizque', 'mizque-cb', -18.055940, -65.419759, 100),
  (3, 'Ayopaya', 'Morochata', 'morochata-cb', -17.202888, -66.570590, 100),
  (3, 'Campero', 'Omereque', 'omereque-cb', -18.070483, -64.893322, 100),
  (3, 'Campero', 'Pasorapa', 'pasorapa-cb', -18.392313, -64.600913, 100),
  (3, 'Carrasco', 'Pocona', 'pocona-cb', -17.681729, -65.371859, 100),
  (3, 'Carrasco', 'Pojo', 'pojo-cb', -17.600466, -64.863524, 100),
  (3, 'Carrasco', 'Puerto Villarroel', 'puerto-villarroel-cb', -17.032576, -64.884530, 100),
  (3, 'Punata', 'Punata', 'punata-cb', -17.549321, -65.831384, 100),
  (3, 'Quillacollo', 'Quillacollo', 'quillacollo-cb', -17.211359, -66.329137, 100),
  (3, 'Chapare', 'Sacaba', 'sacaba-cb', -17.331643, -66.030455, 100),
  (3, 'Esteban Arze', 'Sacabamba', 'sacabamba-cb', -17.776444, -65.786224, 100),
  (3, 'Punata', 'San Benito', 'san-benito-cb', -17.498247, -65.878928, 100),
  (3, 'Capinota', 'Santivañez', 'santivanez-cb', -17.573495, -66.218123, 100),
  (3, 'Tiraque', 'Shinahota', 'shinahota-cb', -17.059303, -65.318557, 100),
  (3, 'Capinota', 'Sicaya', 'sicaya-cb', -17.791097, -66.341735, 100),
  (3, 'Quillacollo', 'Sipesipe', 'sipesipe-cb', -17.505367, -66.388593, 100),
  (3, 'Punata', 'Tacachi', 'tacachi-cb', -17.637964, -65.788402, 100),
  (3, 'Arque', 'Tacopaya', 'tacopaya-cb', -17.826525, -66.625838, 100),
  (3, 'Tapacarí', 'Tapacarí', 'tapacari-cb', -17.570832, -66.651477, 100),
  (3, 'Esteban Arze', 'Tarata', 'tarata-cb', -17.691857, -66.065380, 100),
  (3, 'Quillacollo', 'Tiquipaya', 'tiquipaya-cb', -17.188584, -66.202033, 100),
  (3, 'Tiraque', 'Tiraque', 'tiraque-cb', -17.336664, -65.517334, 100),
  (3, 'Germán Jordán', 'Toco', 'toco-cb', -17.647607, -65.920555, 100),
  (3, 'Germán Jordán', 'Tolata', 'tolata-cb', -17.526666, -66.002613, 100),
  (3, 'Carrasco', 'Totora', 'totora-cb', -17.586277, -65.144333, 100),
  (3, 'Arani', 'Vacas', 'vacas-cb', -17.589170, -65.582620, 100),
  (3, 'Mizque', 'Vila Vila', 'vila-vila-cb', -17.978245, -65.671407, 100),
  (3, 'Punata', 'Villa Gualberto Villarroel', 'villa-gualberto-villarroel-cb', -17.689927, -65.771134, 100),
  (3, 'Punata', 'Villa Rivero', 'villa-rivero-cb', -17.648258, -65.852792, 100),
  (3, 'Chapare', 'Villa Tunari', 'villa-tunari-cb', -16.634604, -65.571875, 100),
  (3, 'Quillacollo', 'Vinto', 'vinto-cb', -17.342164, -66.374260, 100),
  (4, 'Sur Carangas', 'Andamarca', 'andamarca-or', -18.892526, -67.381139, 100),
  (4, 'Poopó', 'Antequera', 'antequera-or', -18.525080, -66.775435, 100),
  (4, 'Sur Carangas', 'Belén de Andamarca', 'belen-de-andamarca-or', -18.892053, -67.749826, 100),
  (4, 'Cercado', 'Caracollo', 'caracollo-or', -17.691422, -67.292259, 100),
  (4, 'Mejillones', 'Carangas', 'carangas-or', -18.901554, -68.665420, 100),
  (4, 'Abaroa', 'Challapata', 'challapata-or', -18.890612, -66.552632, 100),
  (4, 'Sabaya', 'Chipaya', 'chipaya-or', -19.062588, -68.047655, 100),
  (4, 'Carangas', 'Choquecota', 'choquecota-or', -18.122166, -67.955004, 100),
  (4, 'Sabaya', 'Coipasa', 'coipasa-or', -19.325794, -68.313680, 100),
  (4, 'Carangas', 'Corque', 'corque-or', -18.464173, -67.799495, 100),
  (4, 'Litoral', 'Cruz de Machacamarca', 'cruz-de-machacamarca-or', -18.716891, -68.374351, 100),
  (4, 'Sajama', 'Curahuara de Carangas', 'curahuara-de-carangas-or', -17.988598, -68.667144, 100),
  (4, 'Cercado', 'El Choro', 'el-choro-or', -18.264140, -67.174682, 100),
  (4, 'Litoral', 'Escara', 'escara-or', -18.694405, -68.159394, 100),
  (4, 'Litoral', 'Esmeralda', 'esmeralda-or', -18.945707, -68.088196, 100),
  (4, 'Tomás Barrón', 'Eucaliptus', 'eucaliptus-or', -17.634557, -67.440861, 100),
  (4, 'Litoral', 'Huachacalla', 'huachacalla-or', -18.794564, -68.275084, 100),
  (4, 'Pantaleón Dalence', 'Huanuni', 'huanuni-or', -18.262794, -66.764960, 100),
  (4, 'Nor Carangas', 'Huayllamarca', 'huayllamarca-or', -17.927521, -67.820192, 100),
  (4, 'Mejillones', 'La Rivera', 'la-rivera-or', -19.062037, -68.660113, 100),
  (4, 'Pantaleón Dalence', 'Machacamarca', 'machacamarca-or', -18.153176, -66.974416, 100),
  (4, 'Ladislao Cabrera', 'Pampa Aullagas', 'pampa-aullagas-or', -19.231581, -67.165119, 100),
  (4, 'Cercado', 'Paria', 'paria-or', -17.857170, -66.935939, 100),
  (4, 'Poopó', 'Pazña', 'pazna-or', -18.613445, -66.912976, 100),
  (4, 'Poopó', 'Poopó', 'poopo-or', -18.366720, -66.941596, 100),
  (4, 'Sabaya', 'Sabaya', 'sabaya-or', -18.911146, -68.573675, 100),
  (4, 'Ladislao Cabrera', 'Salinas de Garcí Mendoza', 'salinas-de-garci-mendoza-or', -19.436677, -67.614127, 100),
  (4, 'Sebastián Pagador', 'Santiago de Huari', 'santiago-de-huari-or', -19.164305, -66.563693, 100),
  (4, 'Abaroa', 'Santuario de Quillacas', 'santuario-de-quillacas-or', -19.319370, -66.813340, 100),
  (4, 'Mejillones', 'Todos Santos', 'todos-santos-or', -19.028217, -68.758668, 100),
  (4, 'Saucarí', 'Toledo', 'toledo-or', -18.275644, -67.413224, 100),
  (4, 'San Pedro de Totora', 'Totora', 'totora-or', -17.854860, -68.179950, 100),
  (4, 'Sajama', 'Turco', 'turco-or', -18.337059, -68.530276, 100),
  (4, 'Litoral', 'Yunguyo del Litoral', 'yunguyo-del-litoral-or', -18.875897, -68.351723, 100),
  (5, 'General Bilbao', 'Acasio', 'acasio-pt', -18.049917, -66.014510, 100),
  (5, 'General Bilbao', 'Arampampa', 'arampampa-pt', -17.945263, -66.125875, 100),
  (5, 'Sur Chichas', 'Atocha', 'atocha-pt', -21.070327, -66.169923, 100),
  (5, 'Cornelio Saavedra', 'Betanzos', 'betanzos-pt', -19.458183, -65.227589, 100),
  (5, 'José María Linares', 'Caiza "D"', 'caiza-d-pt', -20.011307, -65.653667, 100),
  (5, 'Alonso de Ibáñez', 'Caripuyo', 'caripuyo-pt', -18.180184, -66.593311, 100),
  (5, 'Cornelio Saavedra', 'Chaquí', 'chaqui-pt', -19.625012, -65.546087, 100),
  (5, 'Rafael Bustillo', 'Chayanta', 'chayanta-pt', -18.414335, -66.350911, 100),
  (5, 'Rafael Bustillo', 'Chuquihuta Ayllu Jucumani', 'chuquihuta-ayllu-jucumani-pt', -18.632317, -66.353385, 100),
  (5, 'José María Linares', 'Ckochas', 'ckochas-pt', -19.742051, -65.022216, 100),
  (5, 'Nor Lipez', 'Colcha "K"', 'colcha-k-pt', -21.204962, -67.313910, 100),
  (5, 'Chayanta', 'Colquechaca', 'colquechaca-pt', -18.808117, -66.013530, 100),
  (5, 'Nor Chichas', 'Cotagaita', 'cotagaita-pt', -20.672950, -65.769397, 100),
  (5, 'Rafael Bustillo', 'Llallagua', 'llallagua-pt', -18.363430, -66.572236, 100),
  (5, 'Daniel Campos', 'Llica', 'llica-pt', -20.050124, -68.412388, 100),
  (5, 'Sur Lipez', 'Mojinete', 'mojinete-pt', -21.814037, -66.351243, 100),
  (5, 'Chayanta', 'Ocurí', 'ocuri-pt', -18.889780, -65.768407, 100),
  (5, 'Chayanta', 'Pocoata', 'pocoata-pt', -18.639286, -66.155666, 100),
  (5, 'Antonio Quijarro', 'Porco', 'porco-pt', -19.807957, -65.984186, 100),
  (5, 'José María Linares', 'Puna', 'puna-pt', -19.876704, -65.400149, 100),
  (5, 'Chayanta', 'Ravelo', 'ravelo-pt', -18.752703, -65.563403, 100),
  (5, 'Alonso de Ibáñez', 'Sacaca', 'sacaca-pt', -18.117584, -66.343648, 100),
  (5, 'Enrique Baldivieso', 'San Agustín', 'san-agustin-pt', -21.495309, -67.413941, 100),
  (5, 'Sur Lipez', 'San Antonio de Esmoruco', 'san-antonio-de-esmoruco-pt', -22.084152, -66.634486, 100),
  (5, 'Sur Lipez', 'San Pablo', 'san-pablo-pt', -22.177110, -67.234141, 100),
  (5, 'Chárcas', 'San Pedro', 'san-pedro-pt', -18.340555, -65.968245, 100),
  (5, 'Nor Lipez', 'San Pedro de Quemes', 'san-pedro-de-quemes-pt', -20.999932, -68.173768, 100),
  (5, 'Cornelio Saavedra', 'Tacobamba', 'tacobamba-pt', -19.213209, -65.554013, 100),
  (5, 'Daniel Campos', 'Tahua', 'tahua-pt', -20.496008, -67.979087, 100),
  (5, 'Tomás Frías', 'Tinguipaya', 'tinguipaya-pt', -19.169995, -65.904054, 100),
  (5, 'Antonio Quijarro', 'Tomave', 'tomave-pt', -20.101612, -66.394274, 100),
  (5, 'Chárcas', 'Toro Toro', 'toro-toro-pt', -18.209596, -65.700835, 100),
  (5, 'Sur Chichas', 'Tupiza', 'tupiza-pt', -21.491096, -65.796904, 100),
  (5, 'Rafael Bustillo', 'Uncía', 'uncia-pt', -18.588463, -66.531406, 100),
  (5, 'Tomás Frías', 'Urmiri', 'urmiri-pt', -19.472786, -66.180725, 100),
  (5, 'Antonio Quijarro', 'Uyuni', 'uyuni-pt', -20.078371, -66.792471, 100),
  (5, 'Modesto Omiste', 'Villazón', 'villazon-pt', -21.913103, -65.641991, 100),
  (5, 'Nor Chichas', 'Vitiche', 'vitiche-pt', -20.349685, -65.432460, 100),
  (5, 'Tomás Frías', 'Yocalla', 'yocalla-pt', -19.495607, -65.941026, 100),
  (6, 'Arce', 'Bermejo', 'bermejo-tj', -22.673030, -64.329440, 100),
  (6, 'Gran Chaco', 'Caraparí', 'carapari-tj', -21.815912, -63.898919, 100),
  (6, 'Méndez', 'El Puente', 'el-puente-tj', -21.278442, -65.049397, 100),
  (6, 'O''Connor', 'Entre Ríos', 'entre-rios-tj', -21.397979, -64.065909, 100),
  (6, 'Arce', 'Padcaya', 'padcaya-tj', -22.133947, -64.529514, 100),
  (6, 'Méndez', 'San Lorenzo', 'san-lorenzo-tj', -21.234141, -64.695257, 100),
  (6, 'Avilés', 'Uriondo', 'uriondo-tj', -21.743002, -64.708571, 100),
  (6, 'Gran Chaco', 'Villa Montes', 'villa-montes-tj', -21.400892, -62.911820, 100),
  (6, 'Gran Chaco', 'Yacuiba', 'yacuiba-tj', -21.796030, -63.284520, 100),
  (6, 'Avilés', 'Yunchará', 'yunchara-tj', -21.790203, -65.162844, 100),
  (7, 'Guarayos', 'Ascención de Guarayos', 'ascencion-de-guarayos-sc', -15.343818, -63.430894, 100),
  (7, 'Cordillera', 'Boyuibe', 'boyuibe-sc', -20.338882, -63.076306, 100),
  (7, 'Ichilo', 'Buena Vista', 'buena-vista-sc', -17.697750, -63.755919, 100),
  (7, 'Cordillera', 'Cabezas', 'cabezas-sc', -18.463885, -63.268501, 100),
  (7, 'Cordillera', 'Camiri', 'camiri-sc', -20.034739, -63.487866, 100),
  (7, 'Cordillera', 'Charagua', 'charagua-sc', -19.090409, -61.600997, 100),
  (7, 'Sara', 'Colpa Bélgica', 'colpa-belgica-sc', -17.543536, -63.292365, 100),
  (7, 'Manuel María Caballero', 'Comarapa', 'comarapa-sc', -17.802336, -64.431987, 100),
  (7, 'Ñuflo De Chávez', 'Concepción', 'concepcion-sc', -15.298454, -62.112125, 100),
  (7, 'Andrés Ibáñez', 'Cotoca', 'cotoca-sc', -17.754729, -62.908302, 100),
  (7, 'Ñuflo De Chávez', 'Cuatro Cañadas', 'cuatro-canadas-sc', -17.237283, -62.242647, 100),
  (7, 'Cordillera', 'Cuevo', 'cuevo-sc', -20.330173, -63.539244, 100),
  (7, 'Germán Busch', 'El Carmen Rivero Tórrez', 'el-carmen-rivero-torrez-sc', -18.455442, -58.586374, 100),
  (7, 'Guarayos', 'El Puente', 'el-puente-sc', -16.147486, -63.484856, 100),
  (7, 'Andrés Ibáñez', 'El Torno', 'el-torno-sc', -18.048882, -63.468827, 100),
  (7, 'Obispo Santistéban', 'Fernández Alonso', 'fernandez-alonso-sc', -16.888667, -63.212368, 100),
  (7, 'Obispo Santistéban', 'General Saavedra', 'general-saavedra-sc', -17.168113, -63.176202, 100),
  (7, 'Cordillera', 'Gutiérrez', 'gutierrez-sc', -19.395954, -63.501720, 100),
  (7, 'Andrés Ibáñez', 'La Guardia', 'la-guardia-sc', -18.053640, -63.233932, 100),
  (7, 'Cordillera', 'Lagunillas', 'lagunillas-sc', -19.771530, -63.644925, 100),
  (7, 'Florida', 'Mairana', 'mairana-sc', -17.984657, -64.006886, 100),
  (7, 'Obispo Santistéban', 'Mineros', 'mineros-sc', -17.052850, -63.273171, 100),
  (7, 'Obispo Santistéban', 'Montero', 'montero-sc', -17.332886, -63.249822, 100),
  (7, 'Vallegrande', 'Moromoro', 'moromoro-sc', -18.320568, -64.343996, 100),
  (7, 'Warnes', 'Okinawa Uno', 'okinawa-uno-sc', -17.322761, -62.865583, 100),
  (7, 'Chiquitos', 'Pailón', 'pailon-sc', -17.756944, -61.921486, 100),
  (7, 'Florida', 'Pampa Grande', 'pampa-grande-sc', -18.045415, -64.153425, 100),
  (7, 'Andrés Ibáñez', 'Porongo', 'porongo-sc', -17.750277, -63.364860, 100),
  (7, 'Sara', 'Portachuelo', 'portachuelo-sc', -17.356863, -63.448541, 100),
  (7, 'Vallegrande', 'Postrervalle', 'postrervalle-sc', -18.625063, -63.763231, 100),
  (7, 'Vallegrande', 'Pucará', 'pucara-sc', -18.762437, -64.191078, 100),
  (7, 'Germán Busch', 'Puerto Quijarro', 'puerto-quijarro-sc', -18.425798, -57.684908, 100),
  (7, 'Germán Busch', 'Puerto Suarez', 'puerto-suarez-sc', -19.071290, -58.256581, 100),
  (7, 'Florida', 'Quirusillas', 'quirusillas-sc', -18.370532, -63.937461, 100),
  (7, 'Chiquitos', 'Roboré', 'robore-sc', -18.215456, -59.611829, 100),
  (7, 'Manuel María Caballero', 'Saipina', 'saipina-sc', -18.023629, -64.639897, 100),
  (7, 'Florida', 'Samaipata', 'samaipata-sc', -18.175295, -63.750039, 100),
  (7, 'Ñuflo De Chávez', 'San Antonio de Lomerio', 'san-antonio-de-lomerio-sc', -16.806440, -61.874460, 100),
  (7, 'Ichilo', 'San Carlos', 'san-carlos-sc', -17.290795, -63.753601, 100),
  (7, 'Velasco', 'San Ignacio', 'san-ignacio-sc', -15.029639, -60.994534, 100),
  (7, 'Ñuflo De Chávez', 'San Javier', 'san-javier-sc', -16.233783, -62.490865, 100),
  (7, 'Chiquitos', 'San José', 'san-jose-sc', -17.702270, -60.424793, 100),
  (7, 'Ichilo', 'San Juan', 'san-juan-sc', -16.861442, -63.998607, 100),
  (7, 'Ñuflo De Chávez', 'San Julián', 'san-julian-sc', -16.792933, -62.813696, 100),
  (7, 'Angel Sandoval', 'San Matías', 'san-matias-sc', -17.255031, -58.823279, 100),
  (7, 'Velasco', 'San Miguel', 'san-miguel-sc', -16.842954, -61.272464, 100),
  (7, 'Obispo Santistéban', 'San Pedro', 'san-pedro-sc', -16.517313, -63.611984, 100),
  (7, 'Velasco', 'San Rafael', 'san-rafael-sc', -16.815509, -60.140764, 100),
  (7, 'Ñuflo De Chávez', 'San Ramón', 'san-ramon-sc', -16.576939, -62.434569, 100),
  (7, 'Sara', 'Santa Rosa', 'santa-rosa-sc', -16.659149, -63.838764, 100),
  (7, 'Vallegrande', 'Trigal', 'trigal-sc', -18.287021, -64.132732, 100),
  (7, 'Guarayos', 'Urubicha', 'urubicha-sc', -14.952747, -63.018558, 100),
  (7, 'Vallegrande', 'Vallegrande', 'vallegrande-sc', -18.783767, -63.940334, 100),
  (7, 'Warnes', 'Warnes', 'warnes-sc', -17.411777, -63.070186, 100),
  (7, 'Ichilo', 'Yapacaní', 'yapacani-sc', -16.751214, -64.362374, 100),
  (8, 'Iténez', 'Baures', 'baures-be', -13.625201, -62.875428, 100),
  (8, 'Yacuma', 'Exaltación', 'exaltacion-be', -12.803913, -65.783179, 100),
  (8, 'Vaca Diez', 'Guayaramerín', 'guayaramerin-be', -11.308990, -65.434999, 100),
  (8, 'Iténez', 'Huacaraje', 'huacaraje-be', -13.823963, -64.062730, 100),
  (8, 'Marbán', 'Loreto', 'loreto-be', -15.568060, -64.920391, 100),
  (8, 'Iténez', 'Magdalena', 'magdalena-be', -12.994801, -63.687522, 100),
  (8, 'General José Ballivián', 'Puerto Menor de Rurrenabaque', 'puerto-menor-de-rurrenabaque-be', -14.688658, -67.305710, 100),
  (8, 'Mamoré', 'Puerto Siles', 'puerto-siles-be', -12.424064, -64.986387, 100),
  (8, 'General José Ballivián', 'Reyes', 'reyes-be', -13.402810, -67.058027, 100),
  (8, 'Vaca Diez', 'Riberalta', 'riberalta-be', -11.527890, -66.100837, 100),
  (8, 'Marbán', 'San Andrés', 'san-andres-be', -15.374024, -64.142324, 100),
  (8, 'General José Ballivián', 'San Borja', 'san-borja-be', -15.003724, -66.808499, 100),
  (8, 'Moxos', 'San Ignacio', 'san-ignacio-be', -15.468720, -65.686815, 100),
  (8, 'Cercado', 'San Javier', 'san-javier-be', -14.422055, -64.425541, 100),
  (8, 'Mamoré', 'San Joaquín', 'san-joaquin-be', -12.960882, -64.855758, 100),
  (8, 'Mamoré', 'San Ramón', 'san-ramon-be', -13.508056, -64.599824, 100),
  (8, 'Yacuma', 'Santa Ana', 'santa-ana-be', -14.350133, -65.996414, 100),
  (8, 'General José Ballivián', 'Santa Rosa', 'santa-rosa-be', -13.318842, -66.661473, 100),
  (9, 'Nicolás Suárez', 'Bella Flor', 'bella-flor-pd', -10.932068, -67.931428, 100),
  (9, 'Nicolás Suárez', 'Bolpebra', 'bolpebra-pd', -11.170264, -69.225990, 100),
  (9, 'Manuripi', 'Filadelfia', 'filadelfia-pd', -11.756009, -68.532797, 100),
  (9, 'Abuná', 'Ingavi', 'ingavi-pd', -10.504591, -66.747339, 100),
  (9, 'Federico Román', 'Nueva Esperanza', 'nueva-esperanza-pd', -10.111315, -65.537781, 100),
  (9, 'Nicolás Suárez', 'Porvenir', 'porvenir-pd', -11.238195, -68.793302, 100),
  (9, 'Madre de Dios', 'Puerto Gonzalo Moreno', 'puerto-gonzalo-moreno-pd', -11.167284, -66.325112, 100),
  (9, 'Manuripi', 'Puerto Rico', 'puerto-rico-pd', -11.327732, -67.538014, 100),
  (9, 'Madre de Dios', 'San Lorenzo', 'san-lorenzo-pd', -11.596171, -66.821145, 100),
  (9, 'Manuripi', 'San Pedro', 'san-pedro-pd', -11.025444, -66.590028, 100),
  (9, 'Abuná', 'Santa Rosa', 'santa-rosa-pd', -10.731646, -67.278844, 100),
  (9, 'Federico Román', 'Santos Mercado', 'santos-mercado-pd', -10.153415, -66.136430, 100),
  (9, 'Madre de Dios', 'Sena', 'sena-pd', -11.855525, -67.359192, 100),
  (9, 'Federico Román', 'Villa Nueva', 'villa-nueva-pd', -10.650945, -66.105442, 100)
) as v(department_id, province, name, slug, latitude, longitude, sort_order)
on conflict (slug) do update set province = excluded.province;

-- ---------------------------------------------------------------------------
-- ¡Ya!: con GPS manda la distancia; sin GPS, el municipio y la zona.
-- ---------------------------------------------------------------------------
create or replace function public.ya_eligible_professionals(p_category int, p_city smallint, p_zone int, p_customer uuid,
                                                            p_latitude numeric default null, p_longitude numeric default null)
returns setof uuid
language sql stable security definer set search_path = public as $$
  select pp.user_id
  from public.professional_profiles pp
  join public.profiles pr on pr.id = pp.user_id
  left join public.professional_locations pl on pl.professional_id = pp.user_id
  where pp.status = 'approved'
    and pp.is_available
    and pr.suspended_at is null
    and pp.user_id <> p_customer
    and not public.hmy_blocked_between(pp.user_id, p_customer)
    and (pp.primary_category_id = p_category
         or exists (select 1 from public.professional_services s
                    where s.professional_id = pp.user_id and s.category_id = p_category))
    and public.hmy_pro_cleared(pp.user_id, p_category)
    and case
      when p_latitude is not null and pl.base_latitude is not null then
        public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) <= pl.service_radius_km
      else
        pp.city_id = p_city
        and (p_zone is null
             or not exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id)
             or exists (select 1 from public.professional_zones z where z.professional_id = pp.user_id and z.zone_id = p_zone))
    end
  order by public.hmy_distance_km(p_latitude, p_longitude, pl.base_latitude, pl.base_longitude) asc nulls last,
           pp.rating_avg desc, pp.available_since asc nulls last
$$;

-- ---------------------------------------------------------------------------
-- Búsqueda: el municipio elegido o quien lo cubre con su radio de servicio.
-- ---------------------------------------------------------------------------
create or replace function public.search_professionals(
  p_city_id smallint default null,
  p_category_id int default null,
  p_zone_id int default null,
  p_query text default null,
  p_available_now boolean default false,
  p_min_rating numeric default null,
  p_sort text default 'recommended',
  p_limit int default 20,
  p_offset int default 0
) returns table (
  id uuid,
  display_name text,
  photo_path text,
  primary_category_id int,
  primary_category text,
  specialties text[],
  city_id smallint,
  city text,
  zones text[],
  rating_avg numeric,
  rating_count int,
  completed_jobs int,
  is_available boolean,
  price_from numeric,
  is_verified boolean
)
language sql stable security definer set search_path = public as $$
  with base as (
    select pp.*,
           pc.name as cat_name,
           c.name as city_name,
           array(select coalesce(ps.specialty, sc.name) from public.professional_services ps
                 join public.service_categories sc on sc.id = ps.category_id
                 where ps.professional_id = pp.user_id order by sc.sort_order) as specs,
           array(select z.name from public.professional_zones pz
                 join public.service_zones z on z.id = pz.zone_id
                 where pz.professional_id = pp.user_id order by z.sort_order) as zone_names,
           (select min(ps.price_from) from public.professional_services ps
            where ps.professional_id = pp.user_id
              and (p_category_id is null or ps.category_id = p_category_id)) as min_price
    from public.professional_profiles pp
    left join public.service_categories pc on pc.id = pp.primary_category_id
    left join public.cities c on c.id = pp.city_id
    where pp.status = 'approved'
      and (p_city_id is null or pp.city_id = p_city_id
           or exists (select 1 from public.professional_locations pl
                      join public.cities ci on ci.id = p_city_id
                      where pl.professional_id = pp.user_id
                        and public.hmy_distance_km(ci.latitude, ci.longitude, pl.base_latitude, pl.base_longitude)
                            <= pl.service_radius_km))
      and (p_category_id is null or pp.primary_category_id = p_category_id
           or exists (select 1 from public.professional_services ps
                      where ps.professional_id = pp.user_id and ps.category_id = p_category_id))
      and (p_category_id is null or public.hmy_pro_cleared(pp.user_id, p_category_id))
      and (p_zone_id is null or exists (select 1 from public.professional_zones pz
                                        where pz.professional_id = pp.user_id and pz.zone_id = p_zone_id))
      and (not coalesce(p_available_now, false) or pp.is_available)
      and (p_min_rating is null or pp.rating_avg >= p_min_rating)
  )
  select b.user_id, b.display_name, b.photo_path, b.primary_category_id, b.cat_name, b.specs,
         b.city_id, b.city_name, b.zone_names, b.rating_avg, b.rating_count, b.completed_jobs,
         b.is_available, b.min_price, true
  from base b
  where p_query is null or trim(p_query) = ''
     or public.hmy_norm(b.display_name || ' ' || coalesce(b.cat_name, '') || ' '
                        || array_to_string(b.specs, ' ') || ' ' || array_to_string(b.zone_names, ' ')
                        || ' ' || coalesce(b.city_name, ''))
        like '%' || public.hmy_norm(trim(p_query)) || '%'
  order by
    case when p_sort = 'available' then (not b.is_available)::int end,
    case when p_sort = 'rating' then b.rating_avg end desc,
    case when p_sort = 'recommended' then (not b.is_available)::int end,
    case when p_sort = 'recommended' then b.rating_avg * ln(b.rating_count + 2) end desc,
    b.display_name
  limit least(greatest(p_limit, 1), 50) offset greatest(p_offset, 0)
$$;
