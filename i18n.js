.pragma library
// Interface strings for the panel.
//
// The keys are the Russian literals the code was written with, so a string that has no
// translation falls back to itself instead of disappearing — a half-translated panel is
// readable, a panel with empty labels is not. English is the default language; every
// other one answers from this table.
//
// Adding a language: add its code to LANGUAGES and to every line of T, then add the code
// to the `language` enum in backend/backend.py so the setting accepts it.

var LANGUAGES = [
  { code: "en", name: "English" },
  { code: "de", name: "Deutsch" },
  { code: "es", name: "Español" },
  { code: "fr", name: "Français" },
  { code: "ja", name: "日本語" },
  { code: "zh", name: "中文" },
  { code: "uk", name: "Українська" },
  { code: "ru", name: "Русский" }
]

// Counted nouns need one, two or five forms depending on the language: Russian and
// Ukrainian three, English, German, Spanish and French two, Japanese and Chinese one.
// The code asks plural(n, one, few, many) with Russian forms, so each language maps the
// three groups onto its own.
function pluralIndex(language, count) {
  var n = Math.abs(Number(count) || 0)
  if (language === "ru" || language === "uk") {
    var mod100 = n % 100
    if (mod100 > 10 && mod100 < 20) return 2
    var mod10 = n % 10
    if (mod10 === 1) return 0
    if (mod10 >= 2 && mod10 <= 4) return 1
    return 2
  }
  if (language === "ja" || language === "zh") return 2
  return n === 1 ? 0 : 2
}

var T = {}

T["Пауза"] = { en: "Pause", de: "Pause", es: "Pausa", fr: "Pause", ja: "一時停止", zh: "暂停", uk: "Пауза", ru: "Пауза" }
T["Играть"] = { en: "Play", de: "Abspielen", es: "Reproducir", fr: "Lire", ja: "再生", zh: "播放", uk: "Грати", ru: "Играть" }
T["Назад"] = { en: "Back", de: "Zurück", es: "Atrás", fr: "Retour", ja: "戻る", zh: "返回", uk: "Назад", ru: "Назад" }
T["Горячие клавиши"] = { en: "Shortcuts", de: "Tastenkürzel", es: "Atajos", fr: "Raccourcis", ja: "ショートカット", zh: "快捷键", uk: "Скорочення", ru: "Горячие клавиши" }
T["Закрыть"] = { en: "Close", de: "Schließen", es: "Cerrar", fr: "Fermer", ja: "閉じる", zh: "关闭", uk: "Закрити", ru: "Закрыть" }
T["Отмена"] = { en: "Cancel", de: "Abbrechen", es: "Cancelar", fr: "Annuler", ja: "キャンセル", zh: "取消", uk: "Скасувати", ru: "Отмена" }
T["Очистить"] = { en: "Clear", de: "Leeren", es: "Vaciar", fr: "Vider", ja: "クリア", zh: "清空", uk: "Очистити", ru: "Очистить" }
T["Ещё"] = { en: "More", de: "Mehr", es: "Más", fr: "Plus", ja: "もっと", zh: "更多", uk: "Ще", ru: "Ещё" }
T["Открыть"] = { en: "Open", de: "Öffnen", es: "Abrir", fr: "Ouvrir", ja: "開く", zh: "打开", uk: "Відкрити", ru: "Открыть" }
T["Убрать"] = { en: "Remove", de: "Entfernen", es: "Quitar", fr: "Retirer", ja: "削除", zh: "移除", uk: "Прибрати", ru: "Убрать" }
T["Очередь"] = { en: "Queue", de: "Warteschlange", es: "Cola", fr: "File", ja: "キュー", zh: "队列", uk: "Черга", ru: "Очередь" }
T["Обзор"] = { en: "Browse", de: "Entdecken", es: "Explorar", fr: "Parcourir", ja: "見つける", zh: "发现", uk: "Огляд", ru: "Обзор" }
T["Поиск"] = { en: "Search", de: "Suche", es: "Buscar", fr: "Recherche", ja: "検索", zh: "搜索", uk: "Пошук", ru: "Поиск" }
T["Треки"] = { en: "Tracks", de: "Titel", es: "Pistas", fr: "Titres", ja: "曲", zh: "曲目", uk: "Треки", ru: "Треки" }
T["Плейлисты"] = { en: "Playlists", de: "Playlists", es: "Listas", fr: "Playlists", ja: "プレイリスト", zh: "歌单", uk: "Плейлисти", ru: "Плейлисты" }
T["Плейлист"] = { en: "Playlist", de: "Playlist", es: "Lista", fr: "Playlist", ja: "プレイリスト", zh: "歌单", uk: "Плейлист", ru: "Плейлист" }
T["Подсказки"] = { en: "Suggestions", de: "Vorschläge", es: "Sugerencias", fr: "Suggestions", ja: "候補", zh: "建议", uk: "Підказки", ru: "Подсказки" }
T["Люди"] = { en: "People", de: "Personen", es: "Personas", fr: "Personnes", ja: "人", zh: "用户", uk: "Люди", ru: "Люди" }
T["Друзья"] = { en: "Friends", de: "Freunde", es: "Amigos", fr: "Amis", ja: "友達", zh: "好友", uk: "Друзі", ru: "Друзья" }
T["Недавние"] = { en: "Recent", de: "Zuletzt", es: "Recientes", fr: "Récents", ja: "最近", zh: "最近", uk: "Нещодавні", ru: "Недавние" }
T["Радио"] = { en: "Radio", de: "Radio", es: "Radio", fr: "Radio", ja: "ラジオ", zh: "电台", uk: "Радіо", ru: "Радио" }
T["Раздел"] = { en: "Section", de: "Bereich", es: "Sección", fr: "Section", ja: "セクション", zh: "板块", uk: "Розділ", ru: "Раздел" }
T["Человек"] = { en: "Person", de: "Person", es: "Persona", fr: "Personne", ja: "ユーザー", zh: "用户", uk: "Людина", ru: "Человек" }
T["Настройки"] = { en: "Settings", de: "Einstellungen", es: "Ajustes", fr: "Réglages", ja: "設定", zh: "设置", uk: "Налаштування", ru: "Настройки" }
T["Список"] = { en: "List", de: "Liste", es: "Lista", fr: "Liste", ja: "リスト", zh: "列表", uk: "Список", ru: "Список" }
T["Пусто"] = { en: "Empty", de: "Leer", es: "Vacío", fr: "Vide", ja: "空", zh: "空", uk: "Порожньо", ru: "Пусто" }
T["пусто"] = { en: "empty", de: "leer", es: "vacío", fr: "vide", ja: "空", zh: "空", uk: "порожньо", ru: "пусто" }
T["Радио · в эфире"] = { en: "Radio · on air", de: "Radio · auf Sendung", es: "Radio · en directo", fr: "Radio · en direct", ja: "ラジオ · 放送中", zh: "电台 · 直播中", uk: "Радіо · в ефірі", ru: "Радио · в эфире" }
T["Ничего не играет"] = { en: "Nothing is playing", de: "Nichts läuft", es: "Nada suena", fr: "Rien ne joue", ja: "再生中ではありません", zh: "未在播放", uk: "Нічого не грає", ru: "Ничего не играет" }
T["Перемешать"] = { en: "Shuffle", de: "Zufällig", es: "Aleatorio", fr: "Aléatoire", ja: "シャッフル", zh: "随机", uk: "Перемішати", ru: "Перемешать" }
T["Перемешивание включено"] = { en: "Shuffle is on", de: "Zufallswiedergabe an", es: "Aleatorio activado", fr: "Aléatoire activé", ja: "シャッフル中", zh: "随机播放已开启", uk: "Перемішування увімкнено", ru: "Перемешивание включено" }
T["Повтор выключен"] = { en: "Repeat is off", de: "Wiederholen aus", es: "Repetición desactivada", fr: "Répétition désactivée", ja: "リピートなし", zh: "未开启循环", uk: "Повтор вимкнено", ru: "Повтор выключен" }
T["Повторять трек"] = { en: "Repeat track", de: "Titel wiederholen", es: "Repetir pista", fr: "Répéter le titre", ja: "曲をリピート", zh: "单曲循环", uk: "Повторювати трек", ru: "Повторять трек" }
T["Повторять очередь"] = { en: "Repeat queue", de: "Warteschlange wiederholen", es: "Repetir cola", fr: "Répéter la file", ja: "キューをリピート", zh: "列表循环", uk: "Повторювати чергу", ru: "Повторять очередь" }
T["Предыдущий трек"] = { en: "Previous track", de: "Vorheriger Titel", es: "Pista anterior", fr: "Titre précédent", ja: "前の曲", zh: "上一首", uk: "Попередній трек", ru: "Предыдущий трек" }
T["Следующий трек"] = { en: "Next track", de: "Nächster Titel", es: "Pista siguiente", fr: "Titre suivant", ja: "次の曲", zh: "下一首", uk: "Наступний трек", ru: "Следующий трек" }
T["Перейти к этому треку"] = { en: "Jump to this track", de: "Zu diesem Titel springen", es: "Ir a esta pista", fr: "Aller à ce titre", ja: "この曲へ", zh: "跳到这首", uk: "Перейти до цього треку", ru: "Перейти к этому треку" }
T["Играть сейчас"] = { en: "Play now", de: "Jetzt abspielen", es: "Reproducir ahora", fr: "Lire maintenant", ja: "今すぐ再生", zh: "立即播放", uk: "Грати зараз", ru: "Играть сейчас" }
T["В очередь"] = { en: "Add to queue", de: "Zur Warteschlange", es: "Añadir a la cola", fr: "Ajouter à la file", ja: "キューに追加", zh: "加入队列", uk: "У чергу", ru: "В очередь" }
T["Следующим"] = { en: "Play next", de: "Als nächstes", es: "A continuación", fr: "Juste après", ja: "次に再生", zh: "下一首播放", uk: "Наступним", ru: "Следующим" }
T["Добавить в конец очереди"] = { en: "Add to the end of the queue", de: "Ans Ende der Warteschlange", es: "Añadir al final de la cola", fr: "Ajouter à la fin de la file", ja: "キューの最後に追加", zh: "加到队列末尾", uk: "Додати в кінець черги", ru: "Добавить в конец очереди" }
T["Поставить сразу после текущего трека"] = { en: "Play right after the current track", de: "Direkt nach dem aktuellen Titel", es: "Justo después de la pista actual", fr: "Juste après le titre en cours", ja: "現在の曲の次に再生", zh: "接在当前曲目之后", uk: "Одразу після поточного треку", ru: "Поставить сразу после текущего трека" }
T["В мою музыку"] = { en: "Add to my music", de: "Zu meiner Musik", es: "Añadir a mi música", fr: "Ajouter à ma musique", ja: "マイミュージックに追加", zh: "加入我的音乐", uk: "До моєї музики", ru: "В мою музыку" }
T["Убрать из моей музыки"] = { en: "Remove from my music", de: "Aus meiner Musik entfernen", es: "Quitar de mi música", fr: "Retirer de ma musique", ja: "マイミュージックから削除", zh: "从我的音乐移除", uk: "Прибрати з моєї музики", ru: "Убрать из моей музыки" }
T["Убрать из очереди"] = { en: "Remove from the queue", de: "Aus der Warteschlange", es: "Quitar de la cola", fr: "Retirer de la file", ja: "キューから削除", zh: "从队列移除", uk: "Прибрати з черги", ru: "Убрать из очереди" }
T["Очистить очередь"] = { en: "Clear the queue", de: "Warteschlange leeren", es: "Vaciar la cola", fr: "Vider la file", ja: "キューをクリア", zh: "清空队列", uk: "Очистити чергу", ru: "Очистить очередь" }
T["Выключить звук"] = { en: "Mute", de: "Stummschalten", es: "Silenciar", fr: "Couper le son", ja: "ミュート", zh: "静音", uk: "Вимкнути звук", ru: "Выключить звук" }
T["Включить звук"] = { en: "Unmute", de: "Ton an", es: "Activar sonido", fr: "Rétablir le son", ja: "ミュート解除", zh: "取消静音", uk: "Увімкнути звук", ru: "Включить звук" }
T["Громкость"] = { en: "Volume", de: "Lautstärke", es: "Volumen", fr: "Volume", ja: "音量", zh: "音量", uk: "Гучність", ru: "Громкость" }
T["Играть весь плейлист"] = { en: "Play the whole playlist", de: "Ganze Playlist abspielen", es: "Reproducir la lista", fr: "Lire toute la playlist", ja: "プレイリスト全曲を再生", zh: "播放整张歌单", uk: "Грати весь плейлист", ru: "Играть весь плейлист" }
T["Галерея обложек"] = { en: "Covers", de: "Cover", es: "Portadas", fr: "Pochettes", ja: "カバー表示", zh: "封面视图", uk: "Галерея обкладинок", ru: "Галерея обложек" }
T["К плейлистам"] = { en: "To the playlists", de: "Zu den Playlists", es: "A las listas", fr: "Aux playlists", ja: "プレイリストへ", zh: "回到歌单", uk: "До плейлистів", ru: "К плейлистам" }
T["К списку людей"] = { en: "To the people", de: "Zu den Personen", es: "A las personas", fr: "Aux personnes", ja: "人一覧へ", zh: "回到用户", uk: "До людей", ru: "К списку людей" }
T["Друзья и любой человек по ссылке — их плейлисты"] = { en: "Friends and anyone by link — their playlists", de: "Freunde und jeder per Link — seine Playlists", es: "Amigos y cualquiera por enlace — sus listas", fr: "Amis et n'importe qui par lien — ses playlists", ja: "友達やリンク先の人のプレイリスト", zh: "好友或任何人 — 其歌单", uk: "Друзі й будь-хто за посиланням — їхні плейлисти", ru: "Друзья и любой человек по ссылке — их плейлисты" }
T["Ссылка, id или имя друга"] = { en: "Link, id or a friend's name", de: "Link, ID oder Name", es: "Enlace, id o nombre", fr: "Lien, id ou nom", ja: "リンク・ID・名前", zh: "链接、ID 或名字", uk: "Посилання, id або імʼя друга", ru: "Ссылка, id или имя друга" }
T["Список друзей пуст. Вставь ссылку на человека — например vk.com/id213706100."] = { en: "No friends here. Paste a profile link — for example vk.com/id213706100.", de: "Keine Freunde. Füge einen Profil-Link ein — etwa vk.com/id213706100.", es: "Sin amigos. Pega un enlace de perfil — por ejemplo vk.com/id213706100.", fr: "Aucun ami. Collez un lien de profil — par exemple vk.com/id213706100.", ja: "友達がいません。プロフィールのリンクを貼ってください — 例: vk.com/id213706100", zh: "没有好友。粘贴个人主页链接 — 例如 vk.com/id213706100。", uk: "Список друзів порожній. Встав посилання на людину — наприклад vk.com/id213706100.", ru: "Список друзей пуст. Вставь ссылку на человека — например vk.com/id213706100." }
T["Человек не найден"] = { en: "Person not found", de: "Person nicht gefunden", es: "Persona no encontrada", fr: "Personne introuvable", ja: "ユーザーが見つかりません", zh: "找不到该用户", uk: "Людину не знайдено", ru: "Человек не найден" }
T["Не удалось открыть плейлист"] = { en: "Could not open the playlist", de: "Playlist konnte nicht geöffnet werden", es: "No se pudo abrir la lista", fr: "Impossible d'ouvrir la playlist", ja: "プレイリストを開けません", zh: "无法打开歌单", uk: "Не вдалося відкрити плейлист", ru: "Не удалось открыть плейлист" }
T["Открываю…"] = { en: "Opening…", de: "Öffne…", es: "Abriendo…", fr: "Ouverture…", ja: "開いています…", zh: "正在打开…", uk: "Відкриваю…", ru: "Открываю…" }
T["Открываю плейлист…"] = { en: "Opening the playlist…", de: "Playlist wird geöffnet…", es: "Abriendo la lista…", fr: "Ouverture de la playlist…", ja: "プレイリストを開いています…", zh: "正在打开歌单…", uk: "Відкриваю плейлист…", ru: "Открываю плейлист…" }
T["загрузка…"] = { en: "loading…", de: "lädt…", es: "cargando…", fr: "chargement…", ja: "読み込み中…", zh: "加载中…", uk: "завантаження…", ru: "загрузка…" }
T["Друзья · загрузка…"] = { en: "Friends · loading…", de: "Freunde · lädt…", es: "Amigos · cargando…", fr: "Amis · chargement…", ja: "友達 · 読み込み中…", zh: "好友 · 加载中…", uk: "Друзі · завантаження…", ru: "Друзья · загрузка…" }
T["Раздел · загрузка…"] = { en: "Section · loading…", de: "Bereich · lädt…", es: "Sección · cargando…", fr: "Section · chargement…", ja: "セクション · 読み込み中…", zh: "板块 · 加载中…", uk: "Розділ · завантаження…", ru: "Раздел · загрузка…" }
T["Радио · загрузка…"] = { en: "Radio · loading…", de: "Radio · lädt…", es: "Radio · cargando…", fr: "Radio · chargement…", ja: "ラジオ · 読み込み中…", zh: "电台 · 加载中…", uk: "Радіо · завантаження…", ru: "Радио · загрузка…" }
T["Ищу…"] = { en: "Searching…", de: "Suche…", es: "Buscando…", fr: "Recherche…", ja: "検索中…", zh: "搜索中…", uk: "Шукаю…", ru: "Ищу…" }
T["Ничего не найдено"] = { en: "Nothing found", de: "Nichts gefunden", es: "Sin resultados", fr: "Rien trouvé", ja: "見つかりません", zh: "没有找到", uk: "Нічого не знайдено", ru: "Ничего не найдено" }
T["Ничего не найдено. Похожее:"] = { en: "Nothing found. Similar:", de: "Nichts gefunden. Ähnlich:", es: "Sin resultados. Parecido:", fr: "Rien trouvé. Similaire :", ja: "見つかりません。似ている候補:", zh: "没有找到。相近的：", uk: "Нічого не знайдено. Схоже:", ru: "Ничего не найдено. Похожее:" }
T["Плейлисты не найдены"] = { en: "No playlists found", de: "Keine Playlists gefunden", es: "Sin listas", fr: "Aucune playlist", ja: "プレイリストが見つかりません", zh: "没有找到歌单", uk: "Плейлисти не знайдено", ru: "Плейлисты не найдены" }
T["Очередь пуста"] = { en: "The queue is empty", de: "Die Warteschlange ist leer", es: "La cola está vacía", fr: "La file est vide", ja: "キューは空です", zh: "队列为空", uk: "Черга порожня", ru: "Очередь пуста" }
T["Очередь пуста. Начни с «Моя музыка»."] = { en: "The queue is empty. Start with «My music».", de: "Die Warteschlange ist leer. Fang mit «Meine Musik» an.", es: "La cola está vacía. Empieza con «Mi música».", fr: "La file est vide. Commencez par « Ma musique ».", ja: "キューは空です。「マイミュージック」から始めてください。", zh: "队列为空。从「我的音乐」开始。", uk: "Черга порожня. Почни з «Моя музика».", ru: "Очередь пуста. Начни с «Моя музыка»." }
T["Выбери раздел: подборки, новинки, эфир."] = { en: "Pick a section: picks, novelties, radio.", de: "Wähle einen Bereich: Auswahl, Neuheiten, Radio.", es: "Elige una sección: selección, novedades, radio.", fr: "Choisissez une section : sélection, nouveautés, radio.", ja: "セクションを選んでください: 特集・新着・ラジオ", zh: "选择一个板块：精选、新歌、电台。", uk: "Вибери розділ: підбірки, новинки, ефір.", ru: "Выбери раздел: подборки, новинки, эфир." }
T["Начни печатать — подсказки ВК появятся сами, поиск пойдёт после паузы"] = { en: "Start typing — VK's suggestions appear, the search runs after a pause", de: "Tippe los — VK schlägt vor, gesucht wird nach einer Pause", es: "Empieza a escribir — VK sugiere, la búsqueda llega tras una pausa", fr: "Tapez — VK suggère, la recherche part après une pause", ja: "入力すると候補が出て、少し待つと検索します", zh: "开始输入 — 会出现建议，停顿后开始搜索", uk: "Почни писати — підказки VK зʼявляться самі, пошук піде після паузи", ru: "Начни печатать — подсказки ВК появятся сами, поиск пойдёт после паузы" }
T["Недавние запросы"] = { en: "Recent searches", de: "Letzte Suchen", es: "Búsquedas recientes", fr: "Recherches récentes", ja: "最近の検索", zh: "最近搜索", uk: "Нещодавні запити", ru: "Недавние запросы" }
T["Фильтр по списку: название или исполнитель"] = { en: "Filter this list: title or artist", de: "Liste filtern: Titel oder Künstler", es: "Filtrar la lista: título o artista", fr: "Filtrer la liste : titre ou artiste", ja: "このリストを絞り込む: 曲名かアーティスト", zh: "筛选本列表：曲名或歌手", uk: "Фільтр по списку: назва або виконавець", ru: "Фильтр по списку: название или исполнитель" }
T["Артист, трек, альбом"] = { en: "Artist, track, album", de: "Künstler, Titel, Album", es: "Artista, pista, álbum", fr: "Artiste, titre, album", ja: "アーティスト・曲・アルバム", zh: "歌手、曲目、专辑", uk: "Артист, трек, альбом", ru: "Артист, трек, альбом" }
T["Искать плейлисты других людей"] = { en: "Search other people's playlists", de: "Playlists anderer suchen", es: "Buscar listas de otros", fr: "Chercher les playlists des autres", ja: "他の人のプレイリストを検索", zh: "搜索别人的歌单", uk: "Шукати плейлисти інших людей", ru: "Искать плейлисты других людей" }
T["Строка в баре"] = { en: "The bar row", de: "Die Leiste", es: "La barra", fr: "La barre", ja: "バーの表示", zh: "任务栏显示", uk: "Рядок у барі", ru: "Строка в баре" }
T["Вид"] = { en: "Looks", de: "Aussehen", es: "Aspecto", fr: "Aspect", ja: "外観", zh: "外观", uk: "Вигляд", ru: "Вид" }
T["Попап"] = { en: "Popup", de: "Popup", es: "Ventana", fr: "Fenêtre", ja: "ポップアップ", zh: "弹窗", uk: "Попап", ru: "Попап" }
T["Воспроизведение"] = { en: "Playback", de: "Wiedergabe", es: "Reproducción", fr: "Lecture", ja: "再生", zh: "播放", uk: "Відтворення", ru: "Воспроизведение" }
T["Уведомления"] = { en: "Notifications", de: "Mitteilungen", es: "Notificaciones", fr: "Notifications", ja: "通知", zh: "通知", uk: "Сповіщення", ru: "Уведомления" }
T["Кеш"] = { en: "Cache", de: "Cache", es: "Caché", fr: "Cache", ja: "キャッシュ", zh: "缓存", uk: "Кеш", ru: "Кеш" }
T["Язык"] = { en: "Language", de: "Sprache", es: "Idioma", fr: "Langue", ja: "言語", zh: "语言", uk: "Мова", ru: "Язык" }
T["Обложка трека"] = { en: "Cover art", de: "Cover", es: "Portada", fr: "Pochette", ja: "カバー", zh: "封面", uk: "Обкладинка треку", ru: "Обложка трека" }
T["Название трека"] = { en: "Track title", de: "Titel", es: "Título", fr: "Titre", ja: "曲名", zh: "曲目名称", uk: "Назва треку", ru: "Название трека" }
T["Исполнитель"] = { en: "Artist", de: "Künstler", es: "Artista", fr: "Artiste", ja: "アーティスト", zh: "歌手", uk: "Виконавець", ru: "Исполнитель" }
T["Кнопки управления"] = { en: "Controls", de: "Steuerung", es: "Controles", fr: "Commandes", ja: "操作ボタン", zh: "控制按钮", uk: "Кнопки керування", ru: "Кнопки управления" }
T["Линия прогресса"] = { en: "Progress line", de: "Fortschritt", es: "Barra de progreso", fr: "Barre de progression", ja: "進行バー", zh: "进度条", uk: "Лінія прогресу", ru: "Линия прогресса" }
T["Время трека"] = { en: "Track time", de: "Zeit", es: "Tiempo", fr: "Durée", ja: "時間", zh: "时间", uk: "Час треку", ru: "Время трека" }
T["Кнопка «Нравится»"] = { en: "Like button", de: "Gefällt-mir", es: "Botón Me gusta", fr: "Bouton J'aime", ja: "いいねボタン", zh: "喜欢按钮", uk: "Кнопка «Вподобайка»", ru: "Кнопка «Нравится»" }
T["Форма обложки"] = { en: "Cover shape", de: "Coverform", es: "Forma de la portada", fr: "Forme de la pochette", ja: "カバーの形", zh: "封面形状", uk: "Форма обкладинки", ru: "Форма обложки" }
T["Квадрат"] = { en: "Square", de: "Quadrat", es: "Cuadrada", fr: "Carrée", ja: "四角", zh: "方形", uk: "Квадрат", ru: "Квадрат" }
T["Скруглённая"] = { en: "Rounded", de: "Abgerundet", es: "Redondeada", fr: "Arrondie", ja: "角丸", zh: "圆角", uk: "Заокруглена", ru: "Скруглённая" }
T["Круг"] = { en: "Circle", de: "Kreis", es: "Círculo", fr: "Cercle", ja: "円", zh: "圆形", uk: "Коло", ru: "Круг" }
T["Длинные названия"] = { en: "Long titles", de: "Lange Titel", es: "Títulos largos", fr: "Titres longs", ja: "長い曲名", zh: "长标题", uk: "Довгі назви", ru: "Длинные названия" }
T["Обрезать"] = { en: "Truncate", de: "Kürzen", es: "Recortar", fr: "Tronquer", ja: "省略", zh: "截断", uk: "Обрізати", ru: "Обрезать" }
T["Прокрутка"] = { en: "Scroll", de: "Laufschrift", es: "Desplazar", fr: "Défiler", ja: "スクロール", zh: "滚动", uk: "Прокрутка", ru: "Прокрутка" }
T["Пауза перед прокруткой"] = { en: "Pause before scrolling", de: "Pause vor dem Lauf", es: "Pausa antes de desplazar", fr: "Pause avant défilement", ja: "スクロール前の停止", zh: "滚动前停顿", uk: "Пауза перед прокруткою", ru: "Пауза перед прокруткой" }
T["Скорость прокрутки"] = { en: "Scrolling speed", de: "Laufgeschwindigkeit", es: "Velocidad de desplazamiento", fr: "Vitesse de défilement", ja: "スクロール速度", zh: "滚动速度", uk: "Швидкість прокрутки", ru: "Скорость прокрутки" }
T["Ширина подписи"] = { en: "Label width", de: "Breite der Beschriftung", es: "Ancho de la etiqueta", fr: "Largeur du libellé", ja: "ラベルの幅", zh: "标签宽度", uk: "Ширина підпису", ru: "Ширина подписи" }
T["Узкая"] = { en: "Narrow", de: "Schmal", es: "Estrecha", fr: "Étroite", ja: "狭い", zh: "窄", uk: "Вузька", ru: "Узкая" }
T["Обычная"] = { en: "Regular", de: "Normal", es: "Normal", fr: "Normale", ja: "標準", zh: "标准", uk: "Звичайна", ru: "Обычная" }
T["Широкая"] = { en: "Wide", de: "Breit", es: "Ancha", fr: "Large", ja: "広い", zh: "宽", uk: "Широка", ru: "Широкая" }
T["Вид попапа"] = { en: "Popup view", de: "Popup-Ansicht", es: "Vista de la ventana", fr: "Vue de la fenêtre", ja: "ポップアップ表示", zh: "弹窗视图", uk: "Вигляд попапа", ru: "Вид попапа" }
T["Компактный"] = { en: "Compact", de: "Kompakt", es: "Compacta", fr: "Compacte", ja: "コンパクト", zh: "紧凑", uk: "Компактний", ru: "Компактный" }
T["Расширенный"] = { en: "Extended", de: "Erweitert", es: "Ampliada", fr: "Étendue", ja: "拡張", zh: "扩展", uk: "Розширений", ru: "Расширенный" }
T["Скачивать следующий трек заранее — переключение без паузы"] = { en: "Fetch the next track ahead — switching without a wait", de: "Nächsten Titel vorladen — Wechsel ohne Pause", es: "Precargar la pista siguiente — cambio sin espera", fr: "Précharger le titre suivant — changement sans attente", ja: "次の曲を先に取得 — 待たずに切り替え", zh: "提前获取下一首 — 切换不用等", uk: "Завантажувати наступний трек заздалегідь — перемикання без паузи", ru: "Скачивать следующий трек заранее — переключение без паузы" }
T["Возвращать при запуске"] = { en: "Restore on start", de: "Beim Start wiederherstellen", es: "Restaurar al iniciar", fr: "Restaurer au démarrage", ja: "起動時に復元", zh: "启动时恢复", uk: "Відновлювати під час запуску", ru: "Возвращать при запуске" }
T["Очередь (возврат)"] = { en: "Queue", de: "Warteschlange", es: "Cola", fr: "File", ja: "キュー", zh: "队列", uk: "Черга", ru: "Очередь (возврат)" }
T["Позицию"] = { en: "Position", de: "Position", es: "Posición", fr: "Position", ja: "再生位置", zh: "位置", uk: "Позицію", ru: "Позицию" }
T["Громкость (возврат)"] = { en: "Volume", de: "Lautstärke", es: "Volumen", fr: "Volume", ja: "音量", zh: "音量", uk: "Гучність", ru: "Громкость (возврат)" }
T["Уведомлять о смене трека"] = { en: "Notify on track change", de: "Bei Titelwechsel melden", es: "Avisar al cambiar de pista", fr: "Notifier au changement", ja: "曲の切り替えを通知", zh: "切歌时通知", uk: "Сповіщати про зміну треку", ru: "Уведомлять о смене трека" }
T["Показывать"] = { en: "Show", de: "Anzeigen", es: "Mostrar", fr: "Afficher", ja: "表示する", zh: "显示", uk: "Показувати", ru: "Показывать" }
T["Нет"] = { en: "No", de: "Nein", es: "No", fr: "Non", ja: "しない", zh: "否", uk: "Ні", ru: "Нет" }
T["Лимит кеша"] = { en: "Cache limit", de: "Cache-Grenze", es: "Límite de caché", fr: "Limite du cache", ja: "キャッシュ上限", zh: "缓存上限", uk: "Ліміт кешу", ru: "Лимит кеша" }
T["Очистить кеш"] = { en: "Clear the cache", de: "Cache leeren", es: "Vaciar la caché", fr: "Vider le cache", ja: "キャッシュをクリア", zh: "清空缓存", uk: "Очистити кеш", ru: "Очистить кеш" }
T["Освободить место прямо сейчас"] = { en: "Free space right now", de: "Platz jetzt freigeben", es: "Liberar espacio ahora", fr: "Libérer de l'espace", ja: "今すぐ空きを作る", zh: "立即释放空间", uk: "Звільнити місце зараз", ru: "Освободить место прямо сейчас" }
T["Хранить треки на диске · "] = { en: "Keep tracks on disk · ", de: "Titel auf der Platte · ", es: "Guardar pistas en disco · ", fr: "Garder les titres sur disque · ", ja: "曲をディスクに保存 · ", zh: "将曲目存到磁盘 · ", uk: "Тримати треки на диску · ", ru: "Хранить треки на диске · " }
T["Моя музыка"] = { en: "My music", de: "Meine Musik", es: "Mi música", fr: "Ma musique", ja: "マイミュージック", zh: "我的音乐", uk: "Моя музика", ru: "Моя музыка" }
T["Дальше в очереди"] = { en: "Next in the queue", de: "Als nächstes", es: "Siguiente en la cola", fr: "Ensuite dans la file", ja: "キューの続き", zh: "队列中接下来", uk: "Далі в черзі", ru: "Дальше в очереди" }
T["Найдено "] = { en: "Found ", de: "Gefunden ", es: "Encontrados ", fr: "Trouvés ", ja: "見つかった ", zh: "找到 ", uk: "Знайдено ", ru: "Найдено " }
T["Фильтр: "] = { en: "Filter: ", de: "Filter: ", es: "Filtro: ", fr: "Filtre : ", ja: "絞り込み: ", zh: "筛选：", uk: "Фільтр: ", ru: "Фильтр: " }
T["Поиск: "] = { en: "Search: ", de: "Suche: ", es: "Búsqueda: ", fr: "Recherche : ", ja: "検索: ", zh: "搜索：", uk: "Пошук: ", ru: "Поиск: " }
T["трек"] = { en: "track", de: "Titel", es: "pista", fr: "titre", ja: "曲", zh: "首", uk: "трек", ru: "трек" }
T["трека"] = { en: "tracks", de: "Titel", es: "pistas", fr: "titres", ja: "曲", zh: "首", uk: "треки", ru: "трека" }
T["треков"] = { en: "tracks", de: "Titel", es: "pistas", fr: "titres", ja: "曲", zh: "首", uk: "треків", ru: "треков" }
T["плейлист"] = { en: "playlist", de: "Playlist", es: "lista", fr: "playlist", ja: "プレイリスト", zh: "歌单", uk: "плейлист", ru: "плейлист" }
T["плейлиста"] = { en: "playlists", de: "Playlists", es: "listas", fr: "playlists", ja: "プレイリスト", zh: "歌单", uk: "плейлисти", ru: "плейлиста" }
T["плейлистов"] = { en: "playlists", de: "Playlists", es: "listas", fr: "playlists", ja: "プレイリスト", zh: "歌单", uk: "плейлистів", ru: "плейлистов" }
T["человек"] = { en: "person", de: "Personen", es: "personas", fr: "personnes", ja: "人", zh: "人", uk: "людей", ru: "человек" }
T["человека"] = { en: "people", de: "Personen", es: "personas", fr: "personnes", ja: "人", zh: "人", uk: "людини", ru: "человека" }
T["станция"] = { en: "station", de: "Sender", es: "emisora", fr: "station", ja: "局", zh: "台", uk: "станція", ru: "станция" }
T["станции"] = { en: "stations", de: "Sender", es: "emisoras", fr: "stations", ja: "局", zh: "台", uk: "станції", ru: "станции" }
T["станций"] = { en: "stations", de: "Sender", es: "emisoras", fr: "stations", ja: "局", zh: "台", uk: "станцій", ru: "станций" }
T["Space пауза · jk выбор · Enter играть · / фильтр · m вид · [ ] вкладки · ⇧H ⇧L раздел · Esc закрыть"] = { en: "Space pause · jk select · Enter play · / filter · m view · [ ] tabs · ⇧H ⇧L section · Esc close", de: "Space Pause · jk Auswahl · Enter spielen · / Filter · m Ansicht · [ ] Tabs · ⇧H ⇧L Bereich · Esc schließen", es: "Space pausa · jk elegir · Enter reproducir · / filtro · m vista · [ ] pestañas · ⇧H ⇧L sección · Esc cerrar", fr: "Space pause · jk sélection · Enter lire · / filtre · m vue · [ ] onglets · ⇧H ⇧L section · Esc fermer", ja: "Space 一時停止 · jk 選択 · Enter 再生 · / 絞り込み · m 表示 · [ ] タブ · ⇧H ⇧L セクション · Esc 閉じる", zh: "Space 暂停 · jk 选择 · Enter 播放 · / 筛选 · m 视图 · [ ] 标签 · ⇧H ⇧L 板块 · Esc 关闭", uk: "Space пауза · jk вибір · Enter грати · / фільтр · m вигляд · [ ] вкладки · ⇧H ⇧L розділ · Esc закрити", ru: "Space пауза · jk выбор · Enter играть · / фильтр · m вид · [ ] вкладки · ⇧H ⇧L раздел · Esc закрыть" }
T["Enter искать · Tab к списку · Esc выйти из поля"] = { en: "Enter search · Tab to the list · Esc leave the field", de: "Enter suchen · Tab zur Liste · Esc Feld verlassen", es: "Enter buscar · Tab a la lista · Esc salir del campo", fr: "Enter chercher · Tab vers la liste · Esc quitter le champ", ja: "Enter 検索 · Tab リストへ · Esc フィールドを出る", zh: "Enter 搜索 · Tab 到列表 · Esc 离开输入框", uk: "Enter шукати · Tab до списку · Esc вийти з поля", ru: "Enter искать · Tab к списку · Esc выйти из поля" }
T["команда не выполнена"] = { en: "the command failed", de: "der Befehl ist fehlgeschlagen", es: "el comando falló", fr: "la commande a échoué", ja: "コマンドが失敗しました", zh: "命令执行失败", uk: "команда не виконана", ru: "команда не выполнена" }
T["ошибка"] = { en: "error", de: "Fehler", es: "error", fr: "erreur", ja: "エラー", zh: "错误", uk: "помилка", ru: "ошибка" }
T["остановлен"] = { en: "stopped", de: "gestoppt", es: "detenido", fr: "arrêté", ja: "停止", zh: "已停止", uk: "зупинено", ru: "остановлен" }
T["готов"] = { en: "ready", de: "bereit", es: "listo", fr: "prêt", ja: "準備完了", zh: "就绪", uk: "готово", ru: "готов" }
T["нет входа"] = { en: "signed out", de: "abgemeldet", es: "sin sesión", fr: "déconnecté", ja: "未ログイン", zh: "未登录", uk: "немає входу", ru: "нет входа" }
T["радио"] = { en: "radio", de: "Radio", es: "radio", fr: "radio", ja: "ラジオ", zh: "电台", uk: "радіо", ru: "радио" }

T["мс"] = { en: "ms", de: "ms", es: "ms", fr: "ms", ja: "ミリ秒", zh: "毫秒", uk: "мс", ru: "мс" }
T["мин"] = { en: " min", de: " Min", es: " min", fr: " min", ja: "分", zh: "分", uk: " хв", ru: "мин" }
T["ч "] = { en: " h ", de: " Std. ", es: " h ", fr: " h ", ja: "時間", zh: "小时", uk: " год ", ru: "ч " }
T["МБ"] = { en: "MB", de: "MB", es: "MB", fr: "Mo", ja: "MB", zh: "MB", uk: "МБ", ru: "МБ" }
T["из "] = { en: "of ", de: "von ", es: "de ", fr: "sur ", ja: "/ ", zh: "共 ", uk: "з ", ru: "из " }
T["px/с"] = { en: "px/s", de: "px/s", es: "px/s", fr: "px/s", ja: "px/秒", zh: "像素/秒", uk: "px/с", ru: "px/с" }
T["фильтр: "] = { en: "filter: ", de: "Filter: ", es: "filtro: ", fr: "filtre : ", ja: "絞り込み: ", zh: "筛选：", uk: "фільтр: ", ru: "фильтр: " }
T["Друзья · "] = { en: "Friends · ", de: "Freunde · ", es: "Amigos · ", fr: "Amis · ", ja: "友達 · ", zh: "好友 · ", uk: "Друзі · ", ru: "Друзья · " }
T["Радио · "] = { en: "Radio · ", de: "Radio · ", es: "Radio · ", fr: "Radio · ", ja: "ラジオ · ", zh: "电台 · ", uk: "Радіо · ", ru: "Радио · " }
T["Дальше в очереди · "] = { en: "Next in the queue · ", de: "Als nächstes · ", es: "Siguiente en la cola · ", fr: "Ensuite dans la file · ", ja: "キューの続き · ", zh: "队列中接下来 · ", uk: "Далі в черзі · ", ru: "Дальше в очереди · " }
T[" · файлов "] = { en: " · files ", de: " · Dateien ", es: " · archivos ", fr: " · fichiers ", ja: " · ファイル", zh: " · 文件 ", uk: " · файлів ", ru: " · файлов " }
T[" · загрузка…"] = { en: " · loading…", de: " · lädt…", es: " · cargando…", fr: " · chargement…", ja: " · 読み込み中…", zh: " · 加载中…", uk: " · завантаження…", ru: " · загрузка…" }
T[" · пусто"] = { en: " · empty", de: " · leer", es: " · vacío", fr: " · vide", ja: " · 空", zh: " · 空", uk: " · порожньо", ru: " · пусто" }
T["Войти через браузер"] = { en: "Sign in with the browser", de: "Über den Browser anmelden", es: "Entrar con el navegador", fr: "Se connecter via le navigateur", ja: "ブラウザでログイン", zh: "用浏览器登录", uk: "Увійти через браузер", ru: "Войти через браузер" }
T["Аккаунты"] = { en: "Accounts", de: "Konten", es: "Cuentas", fr: "Comptes", ja: "アカウント", zh: "账号", uk: "Акаунти", ru: "Аккаунты" }
T["Активный"] = { en: "Active", de: "Aktiv", es: "Activa", fr: "Actif", ja: "使用中", zh: "当前", uk: "Активний", ru: "Активный" }
T["Сеанс завершится."] = { en: "The session will end.", de: "Die Sitzung wird beendet.", es: "La sesión terminará.", fr: "La session sera fermée.", ja: "セッションが終了します。", zh: "会话将结束。", uk: "Сеанс завершиться.", ru: "Сеанс завершится." }
T["Переключить"] = { en: "Switch", de: "Wechseln", es: "Cambiar", fr: "Changer", ja: "切り替え", zh: "切换", uk: "Перемкнути", ru: "Переключить" }
T["Удалить"] = { en: "Remove", de: "Entfernen", es: "Eliminar", fr: "Supprimer", ja: "削除", zh: "删除", uk: "Видалити", ru: "Удалить" }
T["Удалить аккаунт"] = { en: "Remove the account", de: "Konto entfernen", es: "Eliminar la cuenta", fr: "Supprimer le compte", ja: "アカウントを削除", zh: "删除账号", uk: "Видалити акаунт", ru: "Удалить аккаунт" }
T["Добавить аккаунт"] = { en: "Add an account", de: "Konto hinzufügen", es: "Añadir una cuenta", fr: "Ajouter un compte", ja: "アカウントを追加", zh: "添加账号", uk: "Додати акаунт", ru: "Добавить аккаунт" }
T["Аккаунтов пока нет"] = { en: "No accounts yet", de: "Noch keine Konten", es: "Aún no hay cuentas", fr: "Aucun compte pour l'instant", ja: "アカウントはまだありません", zh: "还没有账号", uk: "Акаунтів ще немає", ru: "Аккаунтов пока нет" }
T["Аккаунт "] = { en: "Account ", de: "Konto ", es: "Cuenta ", fr: "Compte ", ja: "アカウント ", zh: "账号 ", uk: "Акаунт ", ru: "Аккаунт " }
T["Аккаунт добавлен: "] = { en: "Account added: ", de: "Konto hinzugefügt: ", es: "Cuenta añadida: ", fr: "Compte ajouté : ", ja: "アカウントを追加しました: ", zh: "账号已添加：", uk: "Акаунт додано: ", ru: "Аккаунт добавлен: " }
T["Аккаунт добавлен."] = { en: "Account added.", de: "Konto hinzugefügt.", es: "Cuenta añadida.", fr: "Compte ajouté.", ja: "アカウントを追加しました。", zh: "账号已添加。", uk: "Акаунт додано.", ru: "Аккаунт добавлен." }
T["Не удалось войти"] = { en: "Could not sign in", de: "Anmeldung fehlgeschlagen", es: "No se pudo entrar", fr: "Connexion impossible", ja: "ログインできませんでした", zh: "无法登录", uk: "Не вдалося увійти", ru: "Не удалось войти" }
T["Нужны логин и пароль"] = { en: "A login and a password are required", de: "Login und Passwort sind nötig", es: "Hacen falta el usuario y la contraseña", fr: "Identifiant et mot de passe requis", ja: "ログインとパスワードが必要です", zh: "需要账号和密码", uk: "Потрібні логін і пароль", ru: "Нужны логин и пароль" }
T["Телефон, email или id"] = { en: "Phone, email or id", de: "Telefon, E-Mail oder ID", es: "Teléfono, email o id", fr: "Téléphone, e-mail ou id", ja: "電話・メール・ID", zh: "电话、邮箱或 ID", uk: "Телефон, email або id", ru: "Телефон, email или id" }
T["Пароль"] = { en: "Password", de: "Passwort", es: "Contraseña", fr: "Mot de passe", ja: "パスワード", zh: "密码", uk: "Пароль", ru: "Пароль" }
T["Войти"] = { en: "Sign in", de: "Anmelden", es: "Entrar", fr: "Se connecter", ja: "ログイン", zh: "登录", uk: "Увійти", ru: "Войти" }
T["Вход…"] = { en: "Signing in…", de: "Anmeldung…", es: "Entrando…", fr: "Connexion…", ja: "ログイン中…", zh: "正在登录…", uk: "Вхід…", ru: "Вход…" }
T["Код из SMS или приложения"] = { en: "Code from the SMS or the app", de: "Code aus SMS oder App", es: "Código del SMS o de la app", fr: "Code par SMS ou dans l'appli", ja: "SMS またはアプリのコード", zh: "短信或应用中的验证码", uk: "Код із SMS або застосунку", ru: "Код из SMS или приложения" }
T["Код подтверждения"] = { en: "Confirmation code", de: "Bestätigungscode", es: "Código de confirmación", fr: "Code de confirmation", ja: "確認コード", zh: "确认码", uk: "Код підтвердження", ru: "Код подтверждения" }
T["Подтвердить"] = { en: "Confirm", de: "Bestätigen", es: "Confirmar", fr: "Confirmer", ja: "確認", zh: "确认", uk: "Підтвердити", ru: "Подтвердить" }
T["Открыть в браузере"] = { en: "Open in the browser", de: "Im Browser öffnen", es: "Abrir en el navegador", fr: "Ouvrir dans le navigateur", ja: "ブラウザで開く", zh: "在浏览器中打开", uk: "Відкрити в браузері", ru: "Открыть в браузере" }
T["VK просит капчу. Откройте ссылку, решите её и вставьте success_token."] = { en: "VK asks for a captcha. Open the link, solve it and paste the success_token.", de: "VK verlangt ein Captcha. Öffne den Link, löse es und füge den success_token ein.", es: "VK pide un captcha. Abre el enlace, resuélvelo y pega el success_token.", fr: "VK demande un captcha. Ouvrez le lien, résolvez-le et collez le success_token.", ja: "VK が captcha を求めています。リンクを開いて解き、success_token を貼り付けてください。", zh: "VK 要求验证码。打开链接完成验证，然后粘贴 success_token。", uk: "VK просить капчу. Відкрийте посилання, розв'яжіть її та вставте success_token.", ru: "VK просит капчу. Откройте ссылку, решите её и вставьте success_token." }
T["Через браузер — текущая сессия VK. Или войдите по логину и паролю: второй аккаунт в браузере не нужен."] = { en: "Through the browser is the VK session you are signed into now. Or sign in with a login and a password: a second account needs no browser session.", de: "Über den Browser ist die aktuell angemeldete VK-Sitzung. Oder melde dich mit Login und Passwort an: ein zweites Konto braucht keine Browsersitzung.", es: "Con el navegador es la sesión de VK actual. O entra con usuario y contraseña: una segunda cuenta no necesita sesión del navegador.", fr: "Via le navigateur, c'est la session VK en cours. Ou connectez-vous avec un identifiant et un mot de passe : un second compte n'a pas besoin de session navigateur.", ja: "ブラウザ経由なら現在の VK セッションです。ログインとパスワードでも入れます。2つ目のアカウントにブラウザのセッションは不要です。", zh: "通过浏览器登录的是当前 VK 会话。也可以用账号和密码登录：第二个账号不需要浏览器会话。", uk: "Через браузер — поточна сесія VK. Або увійдіть за логіном і паролем: другому акаунту сесія браузера не потрібна.", ru: "Через браузер — текущая сессия VK. Или войдите по логину и паролю: второй аккаунт в браузере не нужен." }
T["Нужен вход в VK. Возьмите cookie из браузера или войдите по логину и паролю — подойдёт любой аккаунт."] = { en: "VK sign-in is needed. Take the cookies from your browser or sign in with a login and a password — any account will do.", de: "VK-Anmeldung nötig. Nimm die Cookies aus dem Browser oder melde dich mit Login und Passwort an — jedes Konto passt.", es: "Hace falta iniciar sesión en VK. Toma las cookies del navegador o entra con usuario y contraseña — sirve cualquier cuenta.", fr: "Connexion à VK requise. Prenez les cookies du navigateur ou connectez-vous avec un identifiant et un mot de passe — n'importe quel compte convient.", ja: "VK へのログインが必要です。ブラウザの Cookie を使うか、ログインとパスワードで入ってください。どのアカウントでも構いません。", zh: "需要登录 VK。可以从浏览器读取 cookie，或用账号和密码登录 — 任何账号都可以。", uk: "Потрібен вхід у VK. Візьміть cookie з браузера або увійдіть за логіном і паролем — підійде будь-який акаунт.", ru: "Нужен вход в VK. Возьмите cookie из браузера или войдите по логину и паролю — подойдёт любой аккаунт." }
T["Нужен вход в VK. Плагин возьмёт cookie p и remixsid из профиля браузера и обменяет их на токен — пароль не спрашивается."] = { en: "VK sign-in is needed. The plugin takes the p and remixsid cookies from your browser profile and exchanges them for a token — no password is asked for.", de: "VK-Anmeldung nötig. Das Plugin nimmt die Cookies p und remixsid aus dem Browserprofil und tauscht sie gegen ein Token — kein Passwort.", es: "Hace falta iniciar sesión en VK. El plugin toma las cookies p y remixsid del perfil del navegador y las cambia por un token — sin contraseña.", fr: "Connexion à VK requise. Le plugin prend les cookies p et remixsid du profil du navigateur et les échange contre un jeton — sans mot de passe.", ja: "VKへのログインが必要です。プラグインはブラウザのプロファイルから p と remixsid の Cookie を取り、トークンと交換します — パスワードは不要です。", zh: "需要登录 VK。插件会从浏览器配置文件中读取 p 和 remixsid 两个 cookie，用它们换取令牌 — 不需要密码。", uk: "Потрібен вхід у VK. Плагін візьме cookie p і remixsid з профілю браузера й обміняє їх на токен — пароль не питається.", ru: "Нужен вход в VK. Плагин возьмёт cookie p и remixsid из профиля браузера и обменяет их на токен — пароль не спрашивается." }

T["Главная"] = { en: "Home", de: "Startseite", es: "Inicio", fr: "Accueil", ja: "ホーム", zh: "首页", uk: "Головна", ru: "Главная" }
T["Обновления"] = { en: "Updates", de: "Neues", es: "Novedades", fr: "Nouveautés", ja: "更新", zh: "更新", uk: "Оновлення", ru: "Обновления" }
T["Список пуст"] = { en: "The list is empty", de: "Die Liste ist leer", es: "La lista está vacía", fr: "La liste est vide", ja: "リストは空です", zh: "列表为空", uk: "Список порожній", ru: "Список пуст" }
T["not signed in"] = { en: "Not signed in", de: "Nicht angemeldet", es: "Sin sesión", fr: "Non connecté", ja: "ログインしていません", zh: "未登录", uk: "Немає входу", ru: "not signed in" }
T["VK needs a captcha"] = { en: "VK wants a captcha", de: "VK verlangt ein Captcha", es: "VK pide un captcha", fr: "VK demande un captcha", ja: "VKがキャプチャを要求しています", zh: "VK 要求验证码", uk: "VK вимагає капчу", ru: "VK needs a captcha" }
T["VK is rate limiting: wait a few minutes"] = { en: "VK is rate limiting: wait a few minutes", de: "VK begrenzt Anfragen: warte ein paar Minuten", es: "VK limita las peticiones: espera unos minutos", fr: "VK limite les requêtes : attendez quelques minutes", ja: "VKが制限中です。数分お待ちください", zh: "VK 正在限流：请等几分钟", uk: "VK обмежує запити: зачекай кілька хвилин", ru: "VK is rate limiting: wait a few minutes" }
T["VK rejected the token"] = { en: "VK rejected the token", de: "VK hat das Token abgelehnt", es: "VK rechazó el token", fr: "VK a rejeté le jeton", ja: "VKがトークンを拒否しました", zh: "VK 拒绝了令牌", uk: "VK відхилив токен", ru: "VK rejected the token" }
T["у станции нет ссылки на поток"] = { en: "This station has no stream", de: "Dieser Sender hat keinen Stream", es: "Esta emisora no tiene emisión", fr: "Cette station n'a pas de flux", ja: "この局にはストリームがありません", zh: "该电台没有流", uk: "У станції немає посилання на потік", ru: "у станции нет ссылки на поток" }

T["Сессия VK отклонена. Нужен повторный вход."] = { en: "VK rejected the session. Sign in again.", de: "VK hat die Sitzung abgelehnt. Melde dich erneut an.", es: "VK rechazó la sesión. Inicia sesión de nuevo.", fr: "VK a rejeté la session. Reconnectez-vous.", ja: "VKがセッションを拒否しました。再ログインしてください。", zh: "VK 拒绝了会话。请重新登录。", uk: "Сесію VK відхилено. Потрібен повторний вхід.", ru: "Сессия VK отклонена. Нужен повторный вход." }
T["VK включил ограничение на запросы. Плагин остановлен."] = { en: "VK is rate limiting. The plugin has stopped.", de: "VK begrenzt Anfragen. Das Plugin ist angehalten.", es: "VK limita las peticiones. El plugin se ha detenido.", fr: "VK limite les requêtes. Le plugin est arrêté.", ja: "VKが制限中です。プラグインを停止しました。", zh: "VK 正在限流。插件已停止。", uk: "VK увімкнув обмеження запитів. Плагін зупинено.", ru: "VK включил ограничение на запросы. Плагин остановлен." }
T["VK требует капчу. Плагин остановлен."] = { en: "VK wants a captcha. The plugin has stopped.", de: "VK verlangt ein Captcha. Das Plugin ist angehalten.", es: "VK pide un captcha. El plugin se ha detenido.", fr: "VK demande un captcha. Le plugin est arrêté.", ja: "VKがキャプチャを要求しています。プラグインを停止しました。", zh: "VK 要求验证码。插件已停止。", uk: "VK вимагає капчу. Плагін зупинено.", ru: "VK требует капчу. Плагин остановлен." }
T["Пропущен трек"] = { en: "Track skipped", de: "Titel übersprungen", es: "Pista omitida", fr: "Titre ignoré", ja: "曲をスキップ", zh: "已跳过曲目", uk: "Пропущено трек", ru: "Пропущен трек" }
T["нет ссылки на поток"] = { en: "no stream link", de: "kein Stream-Link", es: "sin enlace de emisión", fr: "aucun lien de flux", ja: "ストリームのリンクがありません", zh: "没有流链接", uk: "немає посилання на потік", ru: "нет ссылки на поток" }
T["пустая ссылка"] = { en: "empty link", de: "leerer Link", es: "enlace vacío", fr: "lien vide", ja: "リンクが空です", zh: "链接为空", uk: "порожнє посилання", ru: "пустая ссылка" }
T["Поиск"] = { en: "Search", de: "Suche", es: "Búsqueda", fr: "Recherche", ja: "検索", zh: "搜索", uk: "Пошук", ru: "Поиск" }

// The string in the chosen language, or the key itself when this language has no line
// for it: a half-translated panel stays readable.
function translate(language, key) {
  var row = T[key]
  if (!row) return key
  var value = row[language]
  return value === undefined || value === "" ? key : value
}

function languageName(code) {
  for (var i = 0; i < LANGUAGES.length; i++) {
    if (LANGUAGES[i].code === code) return LANGUAGES[i].name
  }
  return code
}
