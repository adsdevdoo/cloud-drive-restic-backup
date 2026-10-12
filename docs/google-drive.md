# A read-only OAuth app for Google Drive

One app serves all the Google accounts you back up, personal and Google Workspace alike. It asks only for
`drive.readonly`: it can list and download, nothing else.

Why your own app: rclone's built-in one is shared by every rclone user and hits Google's rate limits all the time.

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
4. **The scope.** **Data Access → Add or remove scopes**, filter for `drive.readonly` and tick the one whose scope
   is exactly `.../auth/drive.readonly` ("See and download all your Google Drive files"), not `drive.meet.readonly`
   or `drive.metadata.readonly` → **Update** → **Save**. Leave the questions under it (features, justification,
   demo video) empty: they are for Google's verification, which you don't need.
5. **Links for publishing.** **Branding → App domain:** an **Application home page** and an **Application privacy
   policy link** (one address of a site of yours does for both), then **Authorized domains → Add domain**: the
   domain of that address → **Save**. Without them *Publish app* stays grey ("you must complete your configuration
   on the Branding page"). Don't upload a logo: a logo needs verification.
6. **Publish.** **Audience → Publishing status: Testing → Publish app → Confirm.** Don't skip this: in *Testing* every
   token expires after 7 days, and the backup stops a week after the sign-in. The app needs no verification by
   Google for your own use (up to 100 accounts): sign-in shows a warning instead, see below.
7. **The client.** **Clients → Create client**, application type **Desktop app**, a name → **Create**. Copy the
   **Client ID** and the **Client secret** right away (or download the JSON): the console shows the secret only
   once.

Save both in your password manager, and on the backup host:

```sh
read -rs v && printf '%s' "$v" > secrets/drive_client_id; unset v
read -rs v && printf '%s' "$v" > secrets/drive_client_secret; unset v
chmod 600 secrets/*
docker compose up -d
```

## Sign in

`auth` runs `rclone authorize`, which waits for Google's answer on `http://127.0.0.1:53682/` of the backup host, in
the `sign-in` service of `compose.yml` (on the host's network). Your browser reaches it through an SSH tunnel:

```sh
ssh -L 53682:127.0.0.1:53682 you@backup-host          # on your computer; PuTTY: Connection → SSH → Tunnels,
                                                      # source port 53682, destination 127.0.0.1:53682
docker compose run --rm sign-in backup.sh auth <source>   # in that session, in the directory of compose.yml
```

Open the `http://127.0.0.1:53682/auth?state=…` link it prints in the browser on your computer. Pick the account to
back up. As the app is not verified, Google says **Google hasn't verified this app**: **Advanced → Go to
drive-backup (unsafe)** → **Continue**. Allow "See and download all your Google Drive files". The page then says
*Success*, and `auth` shows the e-mail of the account it signed in to.

Without Docker Compose on the backup host, or to sign in on another computer: run
`rclone authorize drive --auth-no-open-browser` there with the client in its environment
(`RCLONE_DRIVE_CLIENT_ID`, `RCLONE_DRIVE_CLIENT_SECRET`, and `RCLONE_DRIVE_SCOPE=drive.readonly`), then paste the
token it prints into `docker exec -it cloud-drive-backup backup.sh auth <source> --paste`.

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
