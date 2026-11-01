# Czujnik

Aplikacja Flutter odczytująca temperaturę i wilgotność z czujników BLE
LYWSD/MJ_HT_V1.

## Windows

W menu aplikacji wybierz **Tryb widżetu**, aby otworzyć bezramkowy panel w
prawym górnym rogu ekranu, stale widoczny nad innymi oknami. W tym samym menu
można włączyć **Uruchamiaj z Windows**. Autostart jest ustawiany dla bieżącego
użytkownika; po zalogowaniu Windows uruchomi aplikację bezpośrednio w trybie
widżetu.

## Uruchamianie i testy

- `flutter pub get`
- `flutter run`
- `flutter test`

## Wydanie Androida

Projekt jest skonfigurowany dla Google Play z identyfikatorem `pl.mkru77.czujnik`.
Pakiet AAB można zbudować poleceniem `flutter build appbundle --release`.

Podpis wydania korzysta z klucza przesyłania w `android/app/upload-keystore.jks`
oraz danych w `android/key.properties`. Te pliki są celowo wykluczone z Git.
Przechowuj bezpieczną kopię obu plików: klucz i hasło będą potrzebne przy
przygotowywaniu kolejnych wydań. Nie dodawaj ich do repozytorium ani nie
udostępniaj publicznie.
