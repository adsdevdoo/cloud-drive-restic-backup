# A read-only app for Yandex Disk

One app serves all the Yandex accounts you back up, Yandex 360 for business included. It has read permissions only:
it can list and download, nothing else.

## Make the app

In [Yandex OAuth](https://oauth.yandex.ru/), signed in with any Yandex account (it becomes the owner of the app):

1. **Создать приложение** (Create app) → **Для доступа к API или отладки** (For API access or debugging). Its redirect
   is Yandex's own page that shows the code, which is what `backup.sh auth` needs.
2. A name (e.g. `disk-backup`) and your e-mail.
3. Permissions (Доступ к данным): find **Яндекс Диск REST API** and tick only
   - **Чтение всего Диска** (`cloud_api:disk.read`),
   - **Доступ к информации о Диске** (`cloud_api:disk.info`),

   nothing that writes. **Создать приложение**.
4. The app's page shows the **ClientID** and the **Client secret**: copy both.

Save both in your password manager, and on the backup host:

```sh
read -rs v && printf '%s' "$v" > secrets/yandex_client_id; unset v
read -rs v && printf '%s' "$v" > secrets/yandex_client_secret; unset v
chmod 600 secrets/*
docker compose up -d
```

## Sign in

```sh
docker exec -it cloud-drive-backup backup.sh auth <source>
```

Open the link it prints in a browser (any device), sign in to the account to back up, **Разрешить** (Allow). Yandex
shows a code: copy it, paste it into the terminal, Enter. `auth` shows the login of the account it signed in to.

A Yandex token lasts a year, and so does its refresh token. The backup has rclone renew the token once it is three
months old (as Yandex asks), long before both expire; sign in again only when a run says the token was refused.

## Revoke

[Yandex ID → Data access](https://id.yandex.ru/security/apps) lists the app; deleting it there revokes its token.
