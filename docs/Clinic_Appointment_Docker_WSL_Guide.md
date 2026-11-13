# Clinic Appointment System · Docker setup on Ubuntu WSL

Use this guide to clone the project, start PostgreSQL, Spring Boot, and Next.js with Docker Compose, and push your changes to GitHub. Use **Ubuntu** for the Docker commands and **Git Bash** for the Git commands if you already sign in to GitHub through Git for Windows.

| Service | Address |
| --- | --- |
| Next.js frontend | [http://localhost:3000](http://localhost:3000) |
| Spring Boot health check | [http://localhost:8081/actuator/health](http://localhost:8081/actuator/health) |
| PostgreSQL | `db:5432` from the backend container |

## 1. Set up Ubuntu 24.04 and Docker Engine

Skip the Ubuntu installation if you can already open Ubuntu 24.04 LTS. On a new computer, open **PowerShell as Administrator** and run:

```powershell
wsl --install -d Ubuntu-24.04
```

Restart Windows if prompted. Open Ubuntu from the Start menu and set your Linux username and password. In PowerShell, run `wsl -l -v` to confirm that `Ubuntu-24.04` is listed with `VERSION 2`. If the list is empty after the restart, rerun the install command. [Microsoft WSL installation guide](https://learn.microsoft.com/en-us/windows/wsl/install)

In **Ubuntu**, check whether Docker and Compose already work:

```bash
sudo docker version
sudo docker compose version
```

If Docker shows both Client and Server and Compose prints a version, continue to the clone. For a fresh Ubuntu 24.04 installation, add Docker’s package repository and install the Engine and plugins:

```bash
sudo apt update
sudo apt install -y curl ca-certificates git
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl start docker
sudo docker run --rm hello-world
sudo docker compose version
```

`Hello from Docker!` confirms the engine can pull and run an image. The `sudo` password is your Ubuntu account password. [Docker Engine installation guide](https://docs.docker.com/engine/install/ubuntu/)

## 2. Clone the project

For a fresh checkout, open **Git Bash** and run:

```bash
mkdir -p /d/08.Projects
cd /d/08.Projects
git clone https://github.com/nechnavarro/clinic-appointments.git
cd clinic-appointments
git remote -v
```

Use the existing checkout if you already have local work. Its folder name may be `clinic_appointmet_system`, as in the original Windows setup. If the Compose changes are on a remote branch, switch to that branch before continuing. Run `git branch -a` to see which branches are available. For example, if `origin/chore/compose-stack` exists and you do not yet have a local branch with that name, run `git switch --track origin/chore/compose-stack`.

Open **Ubuntu** and enter the same folder. For the fresh clone, use:

```bash
cd /mnt/d/08.Projects/clinic-appointments
ls -a
```

For the original checkout, use `cd /mnt/d/08.Projects/clinic_appointmet_system`. Run the Compose commands from this project root, where `backend/` and `frontend/` are siblings. [Working across Windows and WSL file systems](https://learn.microsoft.com/en-us/windows/wsl/filesystems)

### Check the files in your checkout

| Path | What it provides |
| --- | --- |
| `compose.yaml` | Defines `db`, `backend`, and `frontend`, with a PostgreSQL data volume |
| `backend/Dockerfile` | Builds the API with the Maven Wrapper and runs the Spring Boot JAR |
| `backend/pom.xml` | Declares Actuator, JDBC or Spring Data JPA, and the PostgreSQL driver |
| `frontend/Dockerfile` | Installs dependencies, builds Next.js, and runs it on port `3000` |
| `frontend/package-lock.json` | Lets the frontend image install the locked dependencies with `npm ci` |
| `.env.example` | Documents the PostgreSQL password variable with a placeholder |
| `.gitignore` | Keeps the root `.env` out of Git |

If `compose.yaml` is missing after cloning, check whether it’s on another branch or still in your original working folder. The Compose files and dependency changes need to be committed and pushed before a fresh clone can use them.

If this is the first commit of the Compose setup and `.env.example` is missing, create it at the project root with the placeholder `POSTGRES_PASSWORD=replace_with_your_local_password`. If the npm-based frontend is missing `package-lock.json`, run `npm install` from `frontend/` in your usual Node.js terminal and include the generated lockfile in the commit.

## 3. Set the local database password

In the project root, check that `.gitignore` contains this rule:

```gitignore
/.env
```

Create `.env` from the example only if `.env` is missing:

```bash
if [ ! -f .env ] && [ -f .env.example ]; then
  cp .env.example .env
fi
nano .env
```

Add or update this line. Replace the example value with your own local database password:

```dotenv
POSTGRES_PASSWORD='replace_with_your_local_password'
```

Save with **Ctrl+O**, press **Enter**, then exit with **Ctrl+X**. Spring Boot and PostgreSQL both use this value. On a fresh setup, PostgreSQL uses it when it initializes the data volume. If you already initialized the volume, keep the password you used then. Editing `.env` by itself leaves the existing PostgreSQL role password in place. [Compose environment variables](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/) · [PostgreSQL image configuration](https://hub.docker.com/_/postgres)

## 4. Build and start the stack

If the earlier standalone `clinic-api` container is still using port `8081`, stop it with `sudo docker stop clinic-api`. Stop any separately running Next.js process on port `3000` with **Ctrl+C** in its terminal.

In **Ubuntu**, from the project root:

```bash
sudo docker compose config -q && sudo docker compose up -d --build
sudo docker compose ps
```

`config -q` is silent on success. `--build` builds the app images and `-d` runs the stack in the background. On the first run, Compose also pulls the PostgreSQL image. Spring Boot waits for the database health check and connects to `jdbc:postgresql://db:5432/clinic_appointments`. `db` is the database service name on the Compose network. [Compose startup order](https://docs.docker.com/compose/how-tos/startup-order/) · [Compose networking](https://docs.docker.com/compose/how-tos/networking/)

### Verify all three services

1. In `sudo docker compose ps`, look for the `db` service to show `healthy`.
2. Open [the Spring Boot health endpoint](http://localhost:8081/actuator/health) in your Windows browser. Look for the top-level `"status":"UP"` and for `components.db.status` to be `UP`. The `db` component checks the API’s database connection. [Spring Boot Actuator health](https://docs.spring.io/spring-boot/reference/actuator/endpoints.html#actuator.endpoints.health)
3. Open [the Next.js frontend](http://localhost:3000) and check that the page loads.

To check the connection from the frontend container to the backend, run:

```bash
sudo docker compose exec frontend node -e \
  'fetch("http://backend:8080/actuator/health").then(async response => { if (!response.ok) throw new Error(`HTTP ${response.status}`); console.log(await response.json()) }).catch(error => { console.error(error); process.exitCode = 1 })'
```

That command uses the internal address `backend:8080`. A browser on Windows uses `localhost:8081`. The command checks connectivity even if the Next.js page has no API calls yet.

### Stop, restart, and inspect

| Action | Command from Ubuntu |
| --- | --- |
| Read recent logs | `sudo docker compose logs --tail=100 db backend frontend` |
| Follow one service’s logs | `sudo docker compose logs -f backend` |
| Rebuild after changing code | `sudo docker compose up -d --build` |
| Stop the stack and keep database data | `sudo docker compose down` |
| Start again using the existing images | `sudo docker compose up -d` |

Use `down` without `-v` for day-to-day work. Adding `-v` deletes the Compose database volume and its data. [Docker Compose down](https://docs.docker.com/reference/cli/docker/compose/down/)

### Fix common startup errors

| Symptom | What to check |
| --- | --- |
| `POSTGRES_PASSWORD is missing a value` | Create a nonempty `POSTGRES_PASSWORD` entry in the root `.env`. A file named `.env.example` or `.env.txt` will produce the same error if `.env` is missing. Run `sudo docker compose --env-file .env config -q` to check the intended file explicitly. |
| `Cannot connect to the Docker daemon` | Run `sudo systemctl start docker` in Ubuntu and retry `sudo docker version`. |
| `port is already allocated` | Stop the standalone process or container using the reported port, then rerun `up`. |
| `password authentication failed` after editing `.env` | Use the original password for the existing PostgreSQL volume, or change the database role password before updating `.env`. |
| API health has no `db` component | Check the JDBC or JPA starter and PostgreSQL driver in `backend/pom.xml`, plus `MANAGEMENT_ENDPOINT_HEALTH_SHOW_COMPONENTS: always` in the backend service. Rebuild after making corrections. |

## 5. Commit and push to GitHub

Use **Git Bash** in the same project root. To publish your first Compose changes, create a feature branch from the checkout that contains those changes. Run `git status --short` and `git branch --show-current` first. If you already have a feature branch for this work, continue on that branch.

```bash
git switch -c chore/compose-stack
git remote -v
```

`origin` should point to `https://github.com/nechnavarro/clinic-appointments.git`. If Git asks for your author identity, set it for this checkout. Replace the example values with your name and your GitHub email or GitHub-provided `noreply` address:

```bash
git config user.name "Your Name"
git config user.email "YOUR_GITHUB_EMAIL_OR_NOREPLY_ADDRESS"
```

Confirm `.env` is ignored and untracked:

```bash
git check-ignore -v -- .env
git ls-files -- .env
```

The first command should show the ignore rule. The second should print nothing. If `git ls-files` lists `.env`, untrack it with `git rm --cached -- .env` before committing. If a real password was already pushed, change it in PostgreSQL and update the local `.env`.

To add this guide to the repo, save it at `docs/Clinic_Appointment_Docker_WSL_Guide.md` and link to it from the root `README.md`.

Stage the Compose changes. Use the second `git add` only if you added the guide and updated the README:

```bash
git add -- compose.yaml .env.example .gitignore backend/pom.xml frontend/Dockerfile frontend/.dockerignore
git add -- README.md docs/Clinic_Appointment_Docker_WSL_Guide.md
git diff --cached --name-status
git diff --cached --check
```

Review the list. If you changed other setup files, such as `backend/Dockerfile`, stage those explicitly as well. Once you’ve verified the stack and the staged files, commit and push the current branch:

```bash
git commit -m "chore: run API, frontend, and PostgreSQL with Docker Compose"
git push -u origin HEAD
```

If a browser window opens, sign in to GitHub through Git Credential Manager. Open the repository on GitHub, create a pull request into `main`, and review the files. In the description, record the checks that passed, such as the Next.js page loading and Actuator reporting the database `UP`. [GitHub HTTPS authentication](https://docs.github.com/en/get-started/git-basics/caching-your-github-credentials-in-git) · [Creating a pull request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request)

After the pull request is merged, sync your local `main`:

```bash
git switch main
git pull --ff-only
```

For future changes, start a branch from the updated `main`, run the same checks, and push that branch. This keeps the setup reproducible while your project history shows what you built and verified.
