---
name: qlik-cloud
description: Complete Qlik analytics platform integration supporting both Qlik Cloud and Qlik Sense Enterprise on Windows (on-premise). 37+ tools covering health checks, search, app management, reloads, natural language queries (Insight Advisor), automations, AutoML, Qlik Answers AI, data alerts, spaces/streams, users, licenses, and lineage. Use when user asks about Qlik, Qlik Cloud, Qlik Sense apps, analytics dashboards, data reloads, or wants to query business data.
---

# Qlik Skill

Complete OpenClaw integration for **Qlik Cloud** and **Qlik Sense Enterprise on Windows (On-Premise)**.

## 🚀 Quick Setup

### Qlik Cloud

Add to TOOLS.md:

```markdown
### Qlik Cloud
- Tenant URL: https://your-tenant.region.qlikcloud.com
- API Key: your-api-key-here
```

Get an API key: Qlik Cloud → Profile icon → Profile settings → API keys → Generate new key

### Qlik Sense Enterprise (On-Premise)

Add to TOOLS.md:

```markdown
### Qlik Sense On-Premise
- Server URL: https://qlik-server.company.local
- Certificate Path: /path/to/client.pem
- Key Path: /path/to/client_key.pem
- Virtual Proxy: (optional)
```

**Or use header authentication:**

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
| `QLIK_TENANT` | Cloud | Tenant URL (e.g., `https://company.eu.qlikcloud.com`) |
| `QLIK_API_KEY` | Cloud | API key from profile settings |
| `QLIK_SERVER` | On-Prem | Server URL (e.g., `https://qlik.company.local`) |
| `QLIK_CERT` | On-Prem | Path to client certificate (PEM) |
| `QLIK_KEY` | On-Prem | Path to client key (PEM) |
| `QLIK_USER_DIRECTORY` | On-Prem | User directory for header auth |
| `QLIK_USER_ID` | On-Prem | User ID for header auth |
| `QLIK_VIRTUAL_PROXY` | On-Prem | Virtual proxy prefix (optional) |

## ⚡ Platform Comparison

| Feature | Cloud | On-Premise |
|---------|-------|------------|
| Apps & Reloads | ✅ | ✅ |
| Spaces / Streams | ✅ Spaces | ✅ Streams |
| Users & Governance | ✅ | ✅ |
| Health Check | ✅ | ✅ |
| Insight Advisor (NL Query) | ✅ REST API | ⚠️ Engine API only |
| Automations | ✅ | ❌ |
| AutoML | ✅ | ❌ |
| Qlik Answers | ✅ | ❌ |
| Data Alerts | ✅ | ❌ |
| Lineage (QRI) | ✅ | ❌ |
| Managed Datasets | ✅ | ❌ |

## 🔧 When to Use What

| You Want... | Use This | Example |
|-------------|----------|---------|
| **Actual data values** (KPIs, numbers, trends) | `qlik-insight.sh` | "what is total sales" |
| **App structure** (field names, tables) | `qlik-app-fields.sh` | Understanding data model |
| **Refresh data** | `qlik-reload.sh` | Trigger reload before querying |
| **Find apps** | `qlik-search.sh` or `qlik-apps.sh` | Locate app by name |
| **Test connectivity** | `qlik-health.sh` | Verify setup |

## Quick Reference

### Core Operations (Both Platforms)

| Script | Description | Args |
|--------|-------------|------|
| `qlik-health.sh` | Health check / connectivity test | — |
| `qlik-apps.sh` | List apps | `[--space ID] [--limit n]` |
| `qlik-reload.sh` | Trigger app reload | `<app-id> [--partial]` |
| `qlik-reload-status.sh` | Check reload status | `<reload-id>` |
| `qlik-reload-failures.sh` | Recent failed reloads | `[days] [limit]` |

### Cloud-Specific

| Script | Description | Args |
|--------|-------------|------|
| `qlik-tenant.sh` | Get tenant & user info | — |
| `qlik-search.sh` | Search all resources | `"query"` |
| `qlik-license.sh` | License info & usage | — |
| `qlik-insight.sh` | Natural language queries ⭐ | `"question" [app-id]` |
| `qlik-spaces.sh` | List spaces | `[limit]` |
| `qlik-automations.sh` | List automations | `[limit]` |
| `qlik-answers-ask.sh` | Ask AI assistant | `<id> "question"` |
| `qlik-alerts.sh` | List data alerts | `[limit]` |

### Apps

| Script | Description | Args |
|--------|-------------|------|
| `qlik-app-get.sh` | Get app details | `<app-id>` |
| `qlik-app-create.sh` | Create new app | `"name" [space-id]` |
| `qlik-app-delete.sh` | Delete app | `<app-id>` |
| `qlik-app-fields.sh` | Get fields & tables | `<app-id>` |
| `qlik-app-lineage.sh` | Get app data sources | `<app-id>` |

### Reloads

| Script | Description | Args |
|--------|-------------|------|
| `qlik-reload.sh` | Trigger app reload | `<app-id> [--partial]` |
| `qlik-reload-status.sh` | Check reload status | `<reload-id>` |
| `qlik-reload-cancel.sh` | Cancel running reload | `<reload-id>` |
| `qlik-reload-history.sh` | App reload history | `<app-id> [limit]` |
| `qlik-reload-failures.sh` | Recent failed reloads | `[days] [limit]` |

### Users & Governance

| Script | Description | Args |
|--------|-------------|------|
| `qlik-users-search.sh` | Search users | `"query" [limit]` |
| `qlik-user-get.sh` | Get user details | `<user-id>` |

## 📍 Personal Space (Cloud Only)

**Personal space is VIRTUAL in Qlik Cloud** — it does NOT appear in the `/spaces` API!

```bash
# ❌ WRONG: qlik-spaces.sh will NOT show personal space
bash scripts/qlik-spaces.sh

# ✅ CORRECT: Use qlik-apps.sh with --space personal
bash scripts/qlik-apps.sh --space personal
```

## 🔥 Insight Advisor (Natural Language Queries)

**This is the primary tool for getting actual data!** Ask naturally:
- "what is total sales"
- "which stores have lowest availability"
- "show stock count by region"

```bash
# Query specific app
bash scripts/qlik-insight.sh "revenue by region" "app-uuid-here"
```

**Important:** Use `resourceId` (UUID format) from search results — NOT the item `id`.

## Example Workflows

### Cloud: Check Environment
```bash
export QLIK_TENANT="https://company.eu.qlikcloud.com"
export QLIK_API_KEY="your-api-key"

bash scripts/qlik-health.sh
bash scripts/qlik-tenant.sh
```

### On-Premise: Check Environment
```bash
export QLIK_SERVER="https://qlik.company.local"
export QLIK_CERT="/path/to/client.pem"
export QLIK_KEY="/path/to/client_key.pem"

bash scripts/qlik-health.sh
bash scripts/qlik-apps.sh
```

### On-Premise with Header Auth
```bash
export QLIK_SERVER="https://qlik.company.local"
export QLIK_USER_DIRECTORY="DOMAIN"
export QLIK_USER_ID="admin"
export QLIK_VIRTUAL_PROXY="prefix"  # optional

bash scripts/qlik-health.sh
```

### Find and Query an App
```bash
# Search returns resourceId (UUID)
bash scripts/qlik-search.sh "Sales"

# Use resourceId for operations
bash scripts/qlik-app-get.sh "950a5da4-0e61-466b-a1c5-805b072da128"
bash scripts/qlik-insight.sh "What were total sales?" "950a5da4-0e61-466b-a1c5-805b072da128"
```

### Reload Management
```bash
bash scripts/qlik-reload.sh "app-id"
bash scripts/qlik-reload-status.sh "reload-id"
bash scripts/qlik-reload-failures.sh 7  # Last 7 days
```

## Response Format

All scripts output JSON:
```json
{
  "success": true,
  "platform": "cloud",
  "data": { ... },
  "timestamp": "2026-02-05T12:00:00Z"
}
```

The `platform` field indicates whether the response is from `cloud` or `onprem`.

## On-Premise API Mapping

| Cloud Concept | On-Premise Equivalent | API Path |
|--------------|----------------------|----------|
| Spaces | Streams | `/qrs/stream` |
| `/api/v1/apps` | `/qrs/app` | QRS API |
| `/api/v1/reloads` | `/qrs/reloadtask` | QRS API |
| `/api/v1/users` | `/qrs/user` | QRS API |
| Bearer token | Certificate / Header auth | X-Qlik-User |

## Cloud-Only Features

The following features are **Qlik Cloud exclusive**:

- ⚙️ **Automations** — Low-code workflow automation
- 🤖 **AutoML** — Machine learning experiments & deployments  
- 💬 **Qlik Answers** — AI-powered Q&A assistants
- 🔔 **Data Alerts** — Threshold-based notifications
- 🔗 **Lineage (QRI)** — Data flow visualization
- 📊 **Managed Datasets** — Centralized data management
- 🗣️ **Insight Advisor REST API** — Natural language queries (Engine API available on-prem)
