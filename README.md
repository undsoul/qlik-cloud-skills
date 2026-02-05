# Qlik Skill for OpenClaw

Complete Qlik integration with 37+ tools supporting **both Qlik Cloud and Qlik Sense Enterprise on Windows (On-Premise)**.

## Features

- **Core**: Health checks, tenant/server info, search, licensing
- **Apps**: List, create, delete, get details, inspect fields
- **Reloads**: Trigger, monitor, cancel, view history, failure tracking
- **Insight Advisor**: Natural language queries against your data ⭐ (Cloud only)
- **Automations**: List, run, monitor automation workflows (Cloud only)
- **AutoML**: Experiments and deployments (Cloud only)
- **Qlik Answers**: AI assistants and Q&A (Cloud only)
- **Alerts**: Data alerts management (Cloud only)
- **Users & Governance**: User search and management
- **Spaces / Streams**: Space organization (Cloud) / Stream management (On-Prem)
- **Data**: Dataset info, lineage tracking (Cloud only)

## Platform Comparison

| Feature | Cloud | On-Premise |
|---------|-------|------------|
| Apps & Reloads | ✅ | ✅ |
| Spaces / Streams | ✅ | ✅ |
| Users & Governance | ✅ | ✅ |
| Health Check | ✅ | ✅ |
| Insight Advisor (NL) | ✅ | ⚠️ Engine API only |
| Automations | ✅ | ❌ |
| AutoML | ✅ | ❌ |
| Qlik Answers | ✅ | ❌ |
| Data Alerts | ✅ | ❌ |
| Lineage | ✅ | ❌ |

## Installation

Copy the `qlik-cloud` folder to your OpenClaw skills directory, or install via ClawHub:

```bash
clawhub install qlik-cloud
```

## Setup

### Qlik Cloud

1. Get an API key: Qlik Cloud → Profile icon → Profile settings → API keys → Generate
2. Add to your `TOOLS.md`:

```markdown
### Qlik Cloud
- Tenant URL: https://your-tenant.region.qlikcloud.com
- API Key: your-api-key-here
```

### Qlik Sense Enterprise (On-Premise)

**Certificate Authentication:**

```markdown
### Qlik Sense On-Premise
- Server URL: https://qlik-server.company.local
- Certificate Path: /path/to/client.pem
- Key Path: /path/to/client_key.pem
- Virtual Proxy: (optional)
```

**Header Authentication:**

```markdown
### Qlik Sense On-Premise
- Server URL: https://qlik-server.company.local
- User Directory: DOMAIN
- User ID: username
- Virtual Proxy: (optional)
```

## Environment Variables

| Variable | Platform | Description |
|----------|----------|-------------|
| `QLIK_TENANT` | Cloud | Tenant URL |
| `QLIK_API_KEY` | Cloud | API key |
| `QLIK_SERVER` | On-Prem | Server URL |
| `QLIK_CERT` | On-Prem | Client certificate path |
| `QLIK_KEY` | On-Prem | Client key path |
| `QLIK_USER_DIRECTORY` | On-Prem | User directory (header auth) |
| `QLIK_USER_ID` | On-Prem | User ID (header auth) |
| `QLIK_VIRTUAL_PROXY` | On-Prem | Virtual proxy prefix |

## Usage

All scripts auto-detect the platform based on environment variables:

```bash
# Cloud
QLIK_TENANT="https://tenant.qlikcloud.com" \
QLIK_API_KEY="your-key" \
bash scripts/qlik-health.sh

# On-Premise (certificate auth)
QLIK_SERVER="https://qlik.company.local" \
QLIK_CERT="/path/to/client.pem" \
QLIK_KEY="/path/to/client_key.pem" \
bash scripts/qlik-health.sh
```

### Examples

```bash
# Health check
bash scripts/qlik-health.sh

# Search for apps
bash scripts/qlik-search.sh "sales"

# Natural language query (Cloud only)
bash scripts/qlik-insight.sh "show revenue by region" "app-uuid"

# Trigger app reload
bash scripts/qlik-reload.sh "app-id-here"

# List failed reloads
bash scripts/qlik-reload-failures.sh 7
```

## Scripts Reference

See [SKILL.md](SKILL.md) for complete documentation of all 37+ tools.

## Requirements

- bash
- curl
- Python 3 (standard library only)

## License

MIT

## Author

Built by [undsoul](https://github.com/undsoul) with [OpenClaw](https://github.com/openclaw/openclaw).
