---
name: new-repo
description: Create a new GitHub repo under the Blueprint-Agency org. Handles existence checks and uses JavaScript fetch (not Python/curl) for API calls.
---

# New Repo

Create a new private GitHub repository under the **Blueprint-Agency** organization.

## Trigger

When the user asks to create a new repo, repository, or GitHub repo.

## Instructions

Follow these steps exactly:

### 1. Get the PAT

Read `GITHUB_PERSONAL_ACCESS_TOKEN` from the `.env` file in the infrastructure repo root.

### 2. Check if the repo already exists

Use `ctx_execute` with JavaScript to call the GitHub API:

```javascript
const res = await fetch(`https://api.github.com/repos/Blueprint-Agency/${repoName}`, {
  headers: {
    'Authorization': `token ${pat}`,
    'Accept': 'application/vnd.github+json'
  }
});
if (res.status === 200) {
  const d = await res.json();
  console.log(`Repo already exists: ${d.html_url}`);
} else if (res.status === 404) {
  console.log('Repo does not exist, safe to create.');
}
```

If the repo already exists, inform the user and stop. Do not attempt to create it.

### 3. Create the repo

Use `ctx_execute` with JavaScript (never Python or shell curl):

```javascript
const res = await fetch('https://api.github.com/orgs/Blueprint-Agency/repos', {
  method: 'POST',
  headers: {
    'Authorization': `token ${pat}`,
    'Accept': 'application/vnd.github+json'
  },
  body: JSON.stringify({
    name: repoName,
    private: true,
    auto_init: true
  })
});
const data = await res.json();
console.log(data.html_url || JSON.stringify(data));
```

### 4. Report result

Print the repo URL to the user. If the user wants it public, pass `"private": false` instead.

## Rules

- **Always use JavaScript `fetch` via `ctx_execute`** — Python is not available on this machine and shell curl is blocked by context-mode.
- **Always check existence first** to avoid 422 errors.
- **Default to private repos** unless the user says otherwise.
- **Org is always `Blueprint-Agency`** unless the user specifies differently.
- **PAT comes from `.env`** — never hardcode it.
