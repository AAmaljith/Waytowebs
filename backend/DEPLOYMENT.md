# Deploying the Waytowebs backend

The repository-level `render.yaml` defines a Render Free Web Service for this
backend. Connect the repository containing this project to Render and create
a Blueprint from `render.yaml`.

Render generates `JWT_SECRET` and sets `FIREBASE_PROJECT_ID`. In the service
Environment settings, provide the following values as secrets; do not commit
them or put them in the APK:

- `FIREBASE_SERVICE_ACCOUNT_JSON`: the full JSON content of a Firebase Admin
  service-account key for `waytowebs-interview-app`.
- `ZOHO_CLIENT_ID`
- `ZOHO_CLIENT_SECRET`
- `ZOHO_REFRESH_TOKEN`
- `ZOHO_ORG_ID`

After deployment, verify `https://<service>.onrender.com/` returns
`Backend running`. Free services can sleep while idle, so allow time for the
first request to wake the service.

Build the interview APK with the deployed HTTPS URL:

```powershell
cd C:\Users\Amal\AndroidStudioProjects\waytowebs_task\waytowebs_app
flutter build apk --release --dart-define=API_BASE_URL=https://<service>.onrender.com
```

The local `.env` is excluded from Git. Keep any downloaded Firebase Admin
service-account key outside the repository and never share it in chat.
