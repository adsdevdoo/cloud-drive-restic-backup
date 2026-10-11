# A read-only OAuth app for Google Drive

One app serves all the Google accounts you back up, personal and Google Workspace alike. It asks only for
`drive.readonly`: it can list and download, nothing else.

Why your own app: rclone's built-in one is shared by every rclone user and hits Google's rate limits all the time,
and it asks for full access.

## Make the app

In the [Google Cloud console](https://console.cloud.google.com/), signed in with any Google account (it becomes
the owner of the app, not an account that gets backed up):

1. **A project.** The project picker at the top → **New project**, e.g. `drive-backup` → **Create**, then select it.
2. **The API.** **APIs & Services → Library**, find **Google Drive API** → **Enable**.
3. **The consent screen.** **Google Auth Platform** (APIs & Services → OAuth consent screen) → **Get started**:
   - **App information:** a name (shown when you sign in, e.g. `drive-backup`) and your e-mail.
   - **Audience:** **External**. (*Internal* works only if every account you back up is in the Workspace organisation
     of the project.)
   - **Contact information:** your e-mail. Agree to the policy → **Create**.
4. **The scope.** **Data Access → Add or remove scopes**, find `.../auth/drive.readonly` ("See and download all your
   Google Drive files"), tick it → **Update** → **Save**.
5. **Publish.** **Audience → Publishing status: Testing → Publish app → Confirm.** Don't skip this: in *Testing* every
   token expires after 7 days, and the backup stops a week after the sign-in. The app needs no verification by
   Google for your own use (up to 100 accounts): sign-in shows a warning instead, see below.
6. **The client.** **Clients → Create client**, application type **Desktop app**, a name → **Create**. Copy the
   **Client ID** and the **Client secret** (or download the JSON).

Save both in your password manager, and on the backup host:

```sh
read -rs v && printf '%s' "$v" > secrets/drive_client_id; unset v
read -rs v && printf '%s' "$v" > secrets/drive_client_secret; unset v
chmod 600 secrets/*
docker compose up -d
```

## Sign in

```sh
docker exec -it cloud-drive-backup backup.sh auth <source>
```

Open the link it prints in a browser (any device). Pick the account to back up. As the app is not verified, Google
says **Google hasn't verified this app**: **Advanced → Go to drive-backup (unsafe)** → **Continue**. Allow "See and
download all your Google Drive files".

The browser then goes to `http://127.0.0.1:53682/?state=…&code=…` and shows an error (nothing listens there): copy
the whole address from the address bar, paste it into the terminal, Enter. `auth` shows the e-mail of the account
it signed in to.

**Google Workspace accounts.** If sign-in ends with "Access blocked: … admin policy" or "This app is blocked", the
organisation doesn't let users give unknown apps access to Drive. A Workspace admin trusts the app once: **Admin
console → Security → Access and data control → API controls → Manage third-party app access → Add app → OAuth App
Name Or Client ID**, paste the client id, select it, **Trusted**.

## Shared drives and "Shared with me"

A source is one of: My Drive (default), a shared drive (`<NAME>_SHARED_DRIVE=<id>`) or the files others shared with
the account (`<NAME>_SHARED_WITH_ME=yes`). Give the extra sources `<NAME>_ACCOUNT=<the My Drive source>`, so that one
sign-in serves all of them. The ids of the shared drives:

```sh
docker exec cloud-drive-backup backup.sh drives <the My Drive source>
```

## Revoke

The account's [Third-party apps & services](https://myaccount.google.com/connections) page lists the app;
**Delete all connections** there revokes its tokens. Deleting the client in the console revokes the tokens of all
accounts.
