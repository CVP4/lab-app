# Практическая работа Деплой в Docker Hub

Комплект содержит приложение, Dockerfile, файлы исключений, workflow GitHub Actions и сценарии PowerShell. Приложение и сценарии подготовлены для реального запуска. Наличие файлов не означает, что Docker-образ уже собран, опубликован или проверен в Docker Hub; эти результаты подтверждаются только фактическими выводами команд и скриншотами.

## Подготовка

1. Установите Docker Desktop с Linux containers или используйте компьютер с Docker Engine. Запустите Docker и проверьте обе команды:

   ```powershell
   docker --version
   docker info
   ```

2. Создайте аккаунт Docker Hub, затем публичный репозиторий `lab-app`.
3. Создайте Personal access token `lab-token` с правами Read & Write. Сохраните токен в менеджере паролей. Не вставляйте токен в `app.py`, Dockerfile, README или историю команд.
4. Откройте терминал PowerShell в папке этого проекта. Все дальнейшие команды выполняются из неё. Укажите настоящий логин:

   ```powershell
   $DockerHubUsername = 'ВАШ_ЛОГИН'
   ```

На Windows PowerShell 5.1 для корректного UTF-8 в терминале выполните:

```powershell
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
```

## Вход без сохранения токена в коде

Безопасный простой вариант — `docker login -u $DockerHubUsername`, затем вставить токен в интерактивный скрытый ввод Password. Для передачи через stdin используйте скрытый ввод ниже: токен существует в памяти процесса и не выводится в терминал.

```powershell
$secureToken = Read-Host 'Docker Hub token' -AsSecureString
$tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try {
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer) |
        docker login --username $DockerHubUsername --password-stdin
    if ($LASTEXITCODE -ne 0) { throw 'Docker Hub login failed' }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
    Remove-Variable secureToken, tokenPointer -ErrorAction SilentlyContinue
}
```

Не запускайте запись терминала или скриншот во время ввода токена. Docker хранит авторизацию согласно настройкам credential store; после работы при необходимости выполните `docker logout`.

## Сборка и проверка версии 1.0

Текущий исходник подготовлен для выпуска 1.2. Для повторения первого этапа команда ниже устанавливает `VERSION = "1.0"`; эта версия отвечает `Привет из контейнера!` с `Content-Type: text/plain; charset=utf-8`.

```powershell
& .\scripts\Set-Version.ps1 -Version 1.0
docker build -t lab-app:1.0 .
docker images
docker run --rm -p 8000:8000 lab-app:1.0
```

Откройте браузер по адресу `http://localhost:8000` и сохраните настоящий скриншот ответа. В другом терминале сохраните скриншот `docker images` с размером образа. Затем остановите контейнер сочетанием `Ctrl+C`.

`.dockerignore` использует разрешающий список: в контекст сборки попадают только `app.py`, Dockerfile и сам `.dockerignore`. Исходники Git, токены, `.env`, кэш Python, отчёт и скриншоты в образ не попадут.

## Теги и публикация

```powershell
docker tag lab-app:1.0 "${DockerHubUsername}/lab-app:1.0"
docker tag lab-app:1.0 "${DockerHubUsername}/lab-app:latest"
docker push "${DockerHubUsername}/lab-app:1.0"
docker push "${DockerHubUsername}/lab-app:latest"

& .\scripts\Set-Version.ps1 -Version 1.1
docker build -t lab-app:1.1 .
docker tag lab-app:1.1 "${DockerHubUsername}/lab-app:1.1"
docker push "${DockerHubUsername}/lab-app:1.1"
```

Скрипт `Set-Version.ps1` меняет константу в настоящем `app.py`, поэтому при сборке 1.1 меняется содержимое слоя `COPY`. Ответ версии 1.1: `Привет из контейнера! Версия 1.1.`. Сохраните вывод push с повторным использованием слоёв и скриншот вкладки Tags, где видны `1.0`, `1.1`, `latest`.

В этой работе `latest` оставлен у версии 1.0 в точном соответствии с порядком команд задания. Само имя `latest` не заставляет Docker выбирать наиболее новую версию.

Все сборки и теги можно подготовить одним сценарием:

```powershell
# Только сборка и тегирование, без публикации:
& .\scripts\Build-Versions.ps1 -DockerHubUsername $DockerHubUsername

# Сборка и настоящий push после успешного docker login:
& .\scripts\Build-Versions.ps1 -DockerHubUsername $DockerHubUsername -Push
```

Сценарий временно меняет `app.py` для обеих сборок и восстанавливает исходный файл в блоке `finally`. Не редактируйте `app.py` параллельно с работой этого сценария.

## Чистое скачивание и запуск

Выполняйте этот этап после успешной публикации. Другой компьютер или чистая VM — предпочтительный вариант. Если используется тот же Docker Engine, сначала завершите контейнеры этой работы. Удаляются только перечисленные ниже теги приложения; глобальные `prune` и удаление сторонних образов не нужны.

```powershell
docker rmi lab-app:1.0 lab-app:1.1 "${DockerHubUsername}/lab-app:1.0" "${DockerHubUsername}/lab-app:1.1" "${DockerHubUsername}/lab-app:latest"
docker images

docker pull "${DockerHubUsername}/lab-app:1.0"
docker run -d --name lab-app -p 8080:8000 "${DockerHubUsername}/lab-app:1.0"
docker ps
```

Откройте `http://localhost:8080`. Сохраните скриншот ответа 1.0, скриншот `docker ps` и вывод `docker pull`. Сравните digest с опубликованным образом.

```powershell
docker stop lab-app
docker rm lab-app
docker pull "${DockerHubUsername}/lab-app:1.1"
docker run -d --name lab-app -p 8080:8000 "${DockerHubUsername}/lab-app:1.1"
docker ps
docker logs lab-app
```

Обновите браузер и сохраните скриншот изменившегося ответа 1.1. Затем завершите контейнер:

```powershell
docker stop lab-app
docker rm lab-app
```

Воспроизводимая проверка с журналом, ожиданием HTTP и паузами для скриншотов:

```powershell
& .\scripts\Verify-Pull.ps1 -DockerHubUsername $DockerHubUsername
```

Сценарий проверяет, что имя контейнера `lab-app` свободно, удаляет только точные локальные ссылки этой работы, скачивает образы из Docker Hub и проверяет точные ответы 1.0 и 1.1. Логи и ответы сохраняются в локальную папку `evidence`, исключённую из Git и сборки. Базовые слои Python могут оставаться в кэше: такой вариант разрешён заданием, но не равнозначен запуску на отдельной чистой машине.

## GitHub Actions для дополнительных 10 баллов

Для публикации понадобятся действующий аккаунт GitHub и новый репозиторий. Добавьте два секрета через Settings → Secrets and variables → Actions → New repository secret:

- `DOCKERHUB_USERNAME` — логин Docker Hub;
- `DOCKERHUB_TOKEN` — отдельный токен Read & Write для CI.

Файл `.github/workflows/docker.yml` запускается при push тега `v*`, входит в Docker Hub через Actions secrets и публикует образ с тегом Git. Для примера `v1.2`:

```powershell
& .\scripts\Set-Version.ps1 -Version 1.2
git init -b main
git add app.py Dockerfile .dockerignore .gitignore README.md .github scripts
git diff --cached
git commit -m "Add Docker Hub lab app and publishing workflow"
git remote add origin https://github.com/ВАШ_GITHUB_ЛОГИН/lab-app.git
git push -u origin main
git tag v1.2
git push origin v1.2
```

Создайте пустой GitHub-репозиторий без автоматического README перед этими командами. Если Git-репозиторий уже инициализирован, пропустите `git init`; при существующем remote сначала проверьте `git remote -v`.

Дождитесь статуса Success во вкладке Actions и сохраните скриншот успешного запуска. Проверьте, что в Docker Hub появился `v1.2`, затем скачайте и запустите этот образ при желании. Workflow подготовлен; до успешного запуска нельзя писать в отчёте, что автоматическая публикация выполнена.

## Что приложить к отчёту

- Настоящую ссылку `https://hub.docker.com/r/ВАШ_ЛОГИН/lab-app`.
- Тексты `app.py`, Dockerfile и `.dockerignore`.
- Скриншот `docker images` с фактическим размером.
- Скриншот Docker Hub Tags с `1.0`, `1.1`, `latest`.
- Скриншоты браузера для скачанных версий 1.0 и 1.1.
- Вывод `docker pull`, `docker ps` и `docker logs`.
- Семь ответов на контрольные вопросы.
- Ссылку GitHub и скриншот успешного Actions для повышенной сложности.

Не вставляйте токены в отчёт и не заменяйте реальные результаты вымышленными скриншотами. Полный балл зависит от фактической сборки, публикации, запуска и проверки преподавателем.
