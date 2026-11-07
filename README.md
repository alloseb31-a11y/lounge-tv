# Lounge Tv — projet Flutter Android TV / multiplateforme

Cette archive contient le **code source** de Lounge Tv. Elle ne contient pas encore un APK compilé ni signé.

## Fonctions du MVP
- Import de playlists M3U/M3U8 depuis une URL ou un fichier local.
- Connexion Xtream Codes : chaînes, films et séries.
- Lecture réseau avec `video_player` (compatibilité dépendante du format, codec et fournisseur).
- Favoris persistants.
- Guide EPG XMLTV par URL.
- Sauvegarde locale de la position des films et épisodes.
- Interface responsive, thème noir, rouge et or.

## Générer l'APK Android
Prérequis : Flutter stable, Android SDK et Java/Android toolchain installés.

```bash
flutter create . --platforms=android --org fr.loungetv
flutter pub get
flutter build apk --release
```

Le fichier sera généré dans : `build/app/outputs/flutter-apk/app-release.apk`.

Pour Android TV, il faut tester la navigation à la télécommande sur un appareil réel et vérifier le manifeste/launcher Leanback. Le projet fournit un workflow GitHub Actions qui prépare le projet Android et compile l'APK.

## Télécharger avec Downloader
Downloader ne peut pas installer un dossier source ou un ZIP de code : il lui faut une **URL HTTPS publique qui pointe directement vers un APK**. Après compilation, il faut publier `app-release.apk` sur un hébergement accessible (par exemple une release GitHub publique ou votre propre site), puis saisir cette URL dans Downloader. Un lien sandbox ChatGPT n'est pas une URL publique utilisable par Downloader.

## Limites à connaître
- Cette archive est une base MVP de développement, pas une application déjà certifiée ou testée sur tous les téléviseurs.
- Certains flux IPTV (TS, codecs particuliers, DRM ou authentification spécifique) peuvent nécessiter un lecteur Android natif Media3/ExoPlayer.
- tvOS/Apple TV demande un portage et une validation spécifiques ; toutes les plateformes ne sont pas automatiquement couvertes par un seul APK.
- Les identifiants de connexion sont actuellement stockés localement via SharedPreferences. Pour une distribution publique, les migrer vers un stockage sécurisé Android Keystore/iOS Keychain.
- Utiliser uniquement des playlists et flux auxquels vous êtes autorisé à accéder. Lounge Tv ne fournit aucun contenu audiovisuel.
