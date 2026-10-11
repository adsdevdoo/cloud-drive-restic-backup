# A read-only app for Dropbox

One app serves all the Dropbox accounts you back up. It has read permissions only: it can list and download,
nothing else.

Why your own app, and why not `rclone authorize dropbox`: rclone asks Dropbox for write permissions when it signs in
(its own app can write, and with a read-only app that sign-in fails). `backup.sh auth` signs in without rclone and
gets a token with exactly the permissions of the app.

## Make the app

In the [App Console](https://www.dropbox.com/developers/apps), signed in with any Dropbox account (it becomes the
owner of the app):

1. **Create app** → **Scoped access** → **Full Dropbox** → a name (unique across Dropbox, e.g.
   `yourname-drive-backup`) → **Create app**.
2. **Permissions** tab: tick only
   - `account_info.read` (rclone reads the account's root folder at start, `auth` shows its e-mail),
   - `files.metadata.read`,
   - `files.content.read`,

   and nothing that ends in `.write`. **Submit**.
3. **Settings** tab: copy the **App key** and the **App secret** (Show). To back up accounts other than the app
   owner's, **Development users → Enable additional users**. No redirect URI is needed.

Save both in your password manager, and on the backup host:

```sh
read -rs v && printf '%s' "$v" > secrets/dropbox_client_id; unset v       # the App key
read -rs v && printf '%s' "$v" > secrets/dropbox_client_secret; unset v   # the App secret
chmod 600 secrets/*
docker compose up -d
```

## Sign in

```sh
docker exec -it cloud-drive-backup backup.sh auth <source>
```

Open the link it prints in a browser (any device), sign in to the account to back up, **Continue**, **Allow**.
Dropbox shows an access code: copy it, paste it into the terminal, Enter. `auth` shows the e-mail of the account it
signed in to.

Permissions added to the app later don't reach the tokens made before: sign in again after changing them.

## What is backed up

The whole account, or the folder in `<NAME>_ROOT`: your files, the shared folders added to your Dropbox, and with a
Dropbox team, the team folders. With a team, the source starts at the team space: your own files are in your member
folder there, so a `<NAME>_ROOT` in it starts with that folder's name. Paper documents are exported to html.

## Revoke

The account's [Connected apps](https://www.dropbox.com/account/connected_apps) lists the app; **Disconnect** revokes
its token.
