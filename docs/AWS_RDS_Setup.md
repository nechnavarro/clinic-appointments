# Clinic Appointment System on EC2 and Amazon RDS

Run the existing Spring Boot and Next.js Dockerfiles on an Ubuntu EC2 instance. The API connects over TLS to a private Amazon RDS PostgreSQL 17 instance. Use the existing local Compose files for WSL development.

This setup keeps both web ports on EC2's loopback interface. You can test from your laptop through an SSH tunnel. For a public release, add an HTTPS entry point such as an Application Load Balancer, then configure the frontend's API URL or a same-origin proxy. The commands below verify the database connection and both web services.

## 1. Add these files to your project

Extract the archive into the project root where `backend/` and `frontend/` already exist.

| File | Purpose |
| --- | --- |
| `compose.aws.yaml` | Builds the two application containers and connects the API to RDS |
| `deploy/aws/rds.env.example` | Lists the hostname and password needed by Spring Boot |
| `deploy/aws/init-rds.sh` | Loads the schema or schema and fictional demo data |
| `deploy/aws/.gitignore` | Excludes your RDS environment file and local certificate directory |
| `Clinic_Appointment_Database.sql` | The existing PostgreSQL 17 schema and demo seed. Keep your current copy if you have edited it and retained the seed marker and transaction. |

The backend must already include the PostgreSQL JDBC driver, Actuator, and the JDBC or JPA starter. The frontend Dockerfile assumes the npm lockfile and build scripts used in the existing Next.js setup.

Commit the setup to a feature branch using Git Bash from the project root. If the SQL is already tracked, adding it again is fine.

```bash
git switch -c chore/aws-rds-setup
git add -- compose.aws.yaml deploy/aws/.gitignore deploy/aws/rds.env.example \
  deploy/aws/init-rds.sh docs/AWS_RDS_Setup.md Clinic_Appointment_Database.sql
git diff --cached --check
git diff --cached --name-status
git commit -m "chore: add AWS RDS deployment setup"
git push -u origin HEAD
```

Use that branch for your first EC2 test, or merge the pull request and clone `main`.

## 2. Create EC2 and RDS in the same VPC

Choose one AWS Region for both resources. Review pricing before creating them. RDS, EC2, storage, and public IPv4 can carry charges depending on your plan and usage. AWS Budgets alerts can help you track spend. [RDS PostgreSQL pricing](https://aws.amazon.com/rds/postgresql/pricing/) · [AWS Free Tier](https://aws.amazon.com/free/) · [AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/bcm-lite-view-budget.html) · [Public IPv4 pricing](https://aws.amazon.com/vpc/pricing/)

1. **EC2:** Launch an Ubuntu 24.04 LTS instance with a key pair. For this SSH-based setup, give the instance a public IPv4 address in a public subnet and allow inbound SSH (TCP `22`) from **My IP** on the EC2 security group. Both app ports are reached through the SSH tunnel. [EC2 connection prerequisites](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connection-prereqs-general.html)
2. **RDS:** Use **Create database → Standard create → PostgreSQL 17**. For a development environment, choose a Single-AZ DB instance. Select the same VPC, a DB subnet group that uses private subnets in at least two Availability Zones, and **Public access → No**. Use password authentication and keep storage encrypted. Create and securely store the master credentials. [Create an RDS instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateDBInstance.html)
3. **Networking:** On RDS, allow inbound TCP `5432` with the **EC2 security group** as the source. You can use RDS's **Set up EC2 connection** action to configure the security groups automatically for instances in the same VPC. Copy the endpoint hostname from **Connectivity & security**. [Connect EC2 and RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/ec2-rds-connect.html)

If the environment is temporary, review the remaining EC2, RDS, EBS, snapshots, and public IP resources after testing so you know which resources can still incur costs. Stopping RDS is temporary and storage costs may continue. [Stopping RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html)

## 3. Connect to EC2 and prepare the host

From your laptop's Ubuntu terminal or Git Bash, replace the key path and address:

```bash
ssh -i ~/keys/clinic-demo.pem ubuntu@EC2_PUBLIC_IP
```

On a fresh Ubuntu 24.04 EC2 instance, install Docker Engine and the Compose plugin from Docker's apt repository. If Docker and Compose are already installed, start the engine and install the Git and PostgreSQL clients as needed. [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)

```bash
sudo apt update
sudo apt install -y ca-certificates curl git postgresql-client
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
sudo systemctl enable --now docker
sudo docker version
sudo docker compose version
```

Clone the branch on EC2. If your repo is private, authenticate using your preferred GitHub method, such as a read-only SSH deploy key. [GitHub deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)

```bash
git clone -b chore/aws-rds-setup https://github.com/nechnavarro/clinic-appointments.git
cd clinic-appointments
mkdir -p deploy/aws/certs
curl -fL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o deploy/aws/certs/global-bundle.pem
chmod 644 deploy/aws/certs/global-bundle.pem
```

Use `-b main` after merging. Download the AWS CA bundle from the official trust store. Both the PostgreSQL client and Spring Boot use `verify-full` to check the server certificate and endpoint hostname. [RDS CA bundles](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html) · [PostgreSQL JDBC TLS](https://jdbc.postgresql.org/documentation/ssl/)

## 4. Initialize the RDS database

Run the following from the EC2 project root. Enter the hostname and the RDS master username you chose during setup. The master password is entered at the prompt.

```bash
read -rp 'RDS endpoint hostname: ' rds_host
read -rp 'RDS master username: ' rds_admin
PGSSLMODE=verify-full PGSSLROOTCERT="$PWD/deploy/aws/certs/global-bundle.pem" \
  psql -X -W -v ON_ERROR_STOP=1 -h "$rds_host" -p 5432 -U "$rds_admin" -d postgres
```

Run these commands in `psql` for a new instance. If you set `clinic_appointments` as the initial database name in the RDS console, skip the `CREATE DATABASE` line. Use a separate password for the application login.

```sql
CREATE ROLE clinic_app LOGIN;
\password clinic_app
CREATE DATABASE clinic_appointments;
REVOKE CONNECT ON DATABASE clinic_appointments FROM PUBLIC;
GRANT CONNECT ON DATABASE clinic_appointments TO clinic_app;
\q
```

From the EC2 shell, choose **one** initialization mode for the empty database:

```bash
# Fictional demo data and schema
bash deploy/aws/init-rds.sh demo "$rds_host" "$rds_admin"
```

```bash
# Schema only
bash deploy/aws/init-rds.sh schema "$rds_host" "$rds_admin"
```

The initializer uses your existing SQL and applies the app grants in the same transaction. The admin owns the schema objects. The app login can use the tables, with insert and read access on append-only audit and appointment history. The bootstrap is a one-time step for an empty app schema. Future schema changes should be deployed with Flyway using a migration identity. Amazon RDS PostgreSQL 17 supports `btree_gist`, which your schema uses for the provider-overlap constraint. If your RDS parameter group restricts extensions, make sure `btree_gist` is permitted. [RDS extension versions](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html)

## 5. Configure and start the containers on EC2

```bash
cp -n deploy/aws/rds.env.example deploy/aws/rds.env
chmod 600 deploy/aws/rds.env
nano deploy/aws/rds.env
```

Replace both placeholders with the RDS endpoint hostname and the password you set for `clinic_app`. Keep this file on the EC2 host. Use the AWS Compose file explicitly so it selects the two application services.

```bash
sudo docker compose --env-file deploy/aws/rds.env -f compose.aws.yaml config -q
sudo docker compose --env-file deploy/aws/rds.env -f compose.aws.yaml up -d --build
sudo docker compose --env-file deploy/aws/rds.env -f compose.aws.yaml ps
curl -fsS http://127.0.0.1:8081/actuator/health
curl -fsS -o /dev/null -w 'Next.js HTTP %{http_code}\n' http://127.0.0.1:3000/
```

Check for overall `"status":"UP"` and `components.db.status` equal to `UP`. The second command checks the HTTP status of the frontend. If the API fails to start, inspect its logs:

```bash
sudo docker compose --env-file deploy/aws/rds.env -f compose.aws.yaml logs --tail=100 backend
```

Verify the app login and the seed directly:

```bash
PGSSLMODE=verify-full PGSSLROOTCERT="$PWD/deploy/aws/certs/global-bundle.pem" \
  psql -X -W -v ON_ERROR_STOP=1 -h "$rds_host" -p 5432 \
  -U clinic_app -d clinic_appointments -c 'SELECT count(*) FROM appointments;'
```

Schema mode returns zero for a fresh database. Demo mode should return roughly 1,400 appointments, depending on the date.

To view the app from your laptop, open a second terminal and keep this tunnel running. Use unused local ports if you are running the WSL stack at the same time.

```bash
ssh -i ~/keys/clinic-demo.pem -N \
  -L 13000:127.0.0.1:3000 -L 18081:127.0.0.1:8081 ubuntu@EC2_PUBLIC_IP
```

Open [the frontend](http://localhost:13000) and [API health](http://localhost:18081/actuator/health). These links test the two services directly. Wire up the Next.js API calls separately if the starter frontend still displays its default page.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Connection to RDS times out | Same VPC, RDS available, and RDS inbound TCP 5432 sourced from the EC2 security group |
| Certificate validation fails | The real RDS endpoint hostname, the AWS CA bundle path, and the certificate selected on RDS |
| Password authentication fails | The username and the app role password set in step 4 |
| Permission denied for a table | Apply the bootstrap grants as the schema owner, or grant access in the new migration |
| Docker reports port already in use | Stop the service using the EC2 loopback port, or update both the mapping and the SSH tunnel |

This EC2 setup uses the existing Dockerfiles directly. If you later want a managed container deployment, you can build the same images into ECR and run them on ECS while using the same private RDS database.
