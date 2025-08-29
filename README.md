# Data Quality Core

Re-Data based service that logs and presents dbt project test results and data quality signals. Visualizes dbt model tests (business rules and technical checks) and runs scheduled quality jobs.

## Overview

This image integrates Re-Data with dbt projects to collect, store, and display data quality metrics. It installs dbt adapters and re_data, runs scheduled re_data tasks via cron, and exposes the Re-Data UI to review model health, tests, trends, and incidents.

## Architecture

### Core Components

- **Re-Data Runner**: Executes re_data collection and analysis jobs on a schedule
- **dbt Integration**: Uses dbt artifacts to correlate tests with models and sources
- **Schedulers**: Cron-based execution for periodic updates and backfills
- **Logging**: Centralized logs for re_data, dbt, and cron tasks

## Docker Image

### Base Image
- **Base**: Python 3.11.11-slim-bullseye with dbt adapters and re_data

### Build

```bash
# Build the image
./build.sh

# Or manually
docker build -t data-quality-core .
```

### Environment Variables

- `GITLINK_SECRET` – Repo URL (with token) to clone the dbt project
- `DBT_REPO_NAME` – Repo subdirectory containing the dbt project
- `DBT_PROJECT_NAME` – Logical project name
- `CRON_TIME` – Cron expression for re_data runs (e.g., `0 6 * * *`)
- `DATA_WAREHOUSE_PLATFORM` – bigquery | snowflake | redshift | fabric
- Warehouse credentials via GCP secrets or mounted files under `/fastbi/secrets/*`

## Main Functionality

1. Clone dbt repo and install dependencies
2. Configure profiles and warehouse credentials
3. Run re_data collectors on schedule (and backfills if configured)
4. Aggregate and expose data quality metrics and test results

## Health Checks

```bash
# Check container health
docker inspect --format='{{.State.Health.Status}}' data-quality-core

# View health check logs
docker inspect --format='{{range .State.Health.Log}}{{.Output}}{{end}}' data-quality-core
```

## Troubleshooting

- **Repo clone failures**: Validate `GITLINK_SECRET` and network access
- **Warehouse auth errors**: Confirm secrets and profiles configuration
- **No results displayed**: Ensure re_data tasks executed; check cron logs

## Getting Help

- **Documentation**: https://wiki.fast.bi
- **Issues**: https://github.com/fast-bi/data-quality-core/issues
- **Email**: support@fast.bi

## License

This project is licensed under the MIT License - see the LICENSE file for details.
